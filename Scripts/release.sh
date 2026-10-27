#!/usr/bin/env bash
# SPDX-FileCopyrightText: Hamza Mahjoubi
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Cut a release: build, sign, notarize and staple the DMG, publish it as a GitHub release,
# and add it to the in-app update feed (appcast.xml, ADR-0108).
#
#   NOTARY_PROFILE=<notarytool keychain profile> Scripts/release.sh
#
# Run on a clean, pushed main whose MARKETING_VERSION and CURRENT_PROJECT_VERSION were
# bumped for this release. A version with a pre-release suffix (0.4.0-beta) is published
# as a GitHub pre-release and only offered on the beta update channel.
#
# Safe to run again after a failure. Everything that can fail locally (build, notarization,
# signing, writing and validating the feed) happens before anything is published. If the
# tag or the GitHub release already exist from an earlier attempt on this same commit, they
# are reused and the DMG asset is replaced; the feed item always signs the DMG uploaded by
# the run that pushes it. Only a failed final push of appcast.xml needs a hand: reset to
# origin/main and run again.
#
# Environment:
#   NOTARY_PROFILE       required; see `xcrun notarytool store-credentials`.
#   CODE_SIGN_IDENTITY   default "Developer ID Application".
#   DEVELOPMENT_TEAM     default 5L5C5L86RV.
#   SPARKLE_KEY_ACCOUNT  Keychain account of the EdDSA update key; default nc-mac-mail.
#   DERIVED_DATA         passed through to make-dmg.sh.
#
# This runs locally rather than on CI because the EdDSA private key lives in the release
# manager's Keychain, and each appcast item signs the exact bytes of the DMG it names: an
# asset uploaded by anything else breaks every update to that version.

set -euo pipefail

cd "$(dirname "$0")/.."

die() { echo "error: $*" >&2; exit 1; }

: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"
export CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Developer ID Application}"
export DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-5L5C5L86RV}"
export DERIVED_DATA="${DERIVED_DATA:-$(mktemp -d /tmp/nextcloudmail-release.XXXXXX)}"
KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-nc-mac-mail}"
REPO="hamza221/nc-mac-mail"
APPCAST="appcast.xml"
MARKER="<!-- items: newest first -->"

# --- Preflight ---------------------------------------------------------------
# Everything that can be known before a build is checked before one.

command -v gh >/dev/null || die "gh not found"
command -v xmllint >/dev/null || die "xmllint not found"
[[ -z "$(git status --porcelain)" ]] || die "working tree is not clean"
[[ "$(git branch --show-current)" == main ]] || die "release from main"
git fetch -q --tags origin main
COMMIT="$(git rev-parse HEAD)"
[[ "$COMMIT" == "$(git rev-parse origin/main)" ]] || die "main is not the same as origin/main"
grep -qF "$MARKER" "$APPCAST" || die "$APPCAST has lost its insertion marker"

SETTINGS="$(xcodebuild -project NextcloudMail.xcodeproj -target NextcloudMail \
  -configuration Release -showBuildSettings 2>/dev/null)"
setting() { awk -v key="$1" '$1 == key && $2 == "=" { print $3; exit }' <<<"$SETTINGS"; }
VERSION="$(setting MARKETING_VERSION)"
BUILD="$(setting CURRENT_PROJECT_VERSION)"
[[ -n "$VERSION" ]] || die "no MARKETING_VERSION in the build settings"
[[ "$BUILD" =~ ^[0-9]+$ ]] || die "CURRENT_PROJECT_VERSION '$BUILD' is not a whole number"
TAG="v$VERSION"
DMG="build/NextcloudMail-$VERSION.dmg"

# Sparkle decides "newer" by CFBundleVersion, not by the marketing version.
LAST_BUILD="$(sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' "$APPCAST" | sort -n | tail -1)"
((BUILD > ${LAST_BUILD:-0})) || die "CFBundleVersion $BUILD is not above the feed's $LAST_BUILD; bump CURRENT_PROJECT_VERSION"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  [[ "$(git rev-list -n 1 "$TAG")" == "$COMMIT" ]] || die "tag $TAG already exists on another commit"
  echo "== $TAG exists on this commit; resuming"
fi

# --- Build -------------------------------------------------------------------

Scripts/make-dmg.sh build

APP="$DERIVED_DATA/Build/Products/Release/NextcloudMail.app"
SPARKLE_BIN="$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
[[ "$(plist CFBundleShortVersionString)" == "$VERSION" && "$(plist CFBundleVersion)" == "$BUILD" ]] \
  || die "the built app is not $VERSION ($BUILD)"
MIN_OS="$(plist LSMinimumSystemVersion)"

# --- Notarize ----------------------------------------------------------------

# make-dmg.sh signed the DMG with the release certificate.
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG" || die "Gatekeeper rejects $DMG"

# Stapling rewrites the DMG, so the update signature has to come after it.
SIGNATURE="$("$SPARKLE_BIN/sign_update" --account "$KEY_ACCOUNT" "$DMG")"

# --- Feed --------------------------------------------------------------------
# Written, validated and committed locally now; pushed only once the asset is up.

PRERELEASE=()
CHANNEL=""
if [[ "$VERSION" == *-* ]]; then
  PRERELEASE=(--prerelease)
  CHANNEL="<sparkle:channel>beta</sparkle:channel>"
fi

# Generated without needing the tag or the release to exist yet.
NOTES="$(gh api -X POST "repos/$REPO/releases/generate-notes" \
  -f tag_name="$TAG" -f target_commitish="$COMMIT" --jq .body)"

# Markdown release notes, because Sparkle renders HTML ones in a web view (ADR-0108).
ITEM="    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>${CHANNEL:+
      $CHANNEL}
      <description sparkle:format=\"markdown\"><![CDATA[${NOTES//]]>/]] >}]]></description>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <enclosure url=\"https://github.com/$REPO/releases/download/$TAG/NextcloudMail-$VERSION.dmg\" type=\"application/octet-stream\" $SIGNATURE/>
    </item>"
ITEM="$ITEM" MARKER="$MARKER" awk '{ print } index($0, ENVIRON["MARKER"]) { print ENVIRON["ITEM"] }' \
  "$APPCAST" >"$APPCAST.new"
xmllint --noout "$APPCAST.new" || { rm -f "$APPCAST.new"; die "the new $APPCAST is not valid XML"; }
mv "$APPCAST.new" "$APPCAST"
git add "$APPCAST"
git commit -q -m "Appcast: $VERSION"

# --- Publish -----------------------------------------------------------------

trap 'echo "error: publishing stopped. Run \`git reset --hard origin/main\` and run this script again; it reuses the tag and the release." >&2' ERR

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag "$TAG" "$COMMIT"
git push -q origin "refs/tags/$TAG"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  # The feed item about to go out signs this run's DMG, so this run's DMG must be the asset.
  gh release upload "$TAG" "$DMG" --repo "$REPO" --clobber
else
  gh release create "$TAG" "$DMG" --repo "$REPO" --verify-tag --notes-file - \
    --title "Nextcloud Mail for macOS $VERSION" "${PRERELEASE[@]+"${PRERELEASE[@]}"}" <<<"$NOTES"
fi

# The feed goes out last: an item must never point at an asset that is not there yet.
git push -q origin main

echo "== released $TAG ($BUILD)"
