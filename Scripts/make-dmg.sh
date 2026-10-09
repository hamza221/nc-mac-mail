#!/usr/bin/env bash
# SPDX-FileCopyrightText: Hamza Mahjoubi
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build NextcloudMail in Release and package it as a styled drag-to-install DMG.
# Single source of truth for release packaging: the release workflow calls this
# script, and it runs unchanged on a developer Mac.
#
#   Scripts/make-dmg.sh [output-dir]        # default: ./build
#
# Environment (all optional):
#   DERIVED_DATA   xcodebuild -derivedDataPath. Defaults to a private temp dir so
#                  a packaging run never fights another xcodebuild over the shared
#                  DerivedData locks.
#   VERSION_TAG    Fallback version (e.g. a git tag like v0.1.0) if the built
#                  app's Info.plist has no CFBundleShortVersionString.
#   CODE_SIGN_IDENTITY, DEVELOPMENT_TEAM
#                  When both are set, build with real manual signing instead of
#                  the project's ad-hoc default. Left unset, the DMG ships an
#                  ad-hoc-signed app (ADR-0018) and notarization does not apply.
#
# Styling is done by create-dmg (brew install create-dmg): it drives Finder via
# AppleScript to place the icons and background and bakes the result into the
# image's .DS_Store, which is the only supported way to style a DMG — hdiutil
# alone cannot, and hand-rolling the same osascript is what create-dmg already
# is, with retries for Finder's flakiness on headless CI runners.

set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="${1:-build}"
DERIVED_DATA="${DERIVED_DATA:-$(mktemp -d /tmp/nextcloudmail-release.XXXXXX)}"
BACKGROUND_PNG="Scripts/release/dmg-background.png"

command -v create-dmg >/dev/null || {
  echo "error: create-dmg not found (brew install create-dmg)" >&2
  exit 1
}

# --- Build -------------------------------------------------------------------

SIGNING_ARGS=()
if [[ -n "${CODE_SIGN_IDENTITY:-}" && -n "${DEVELOPMENT_TEAM:-}" ]]; then
  echo "== building Release (signing as ${DEVELOPMENT_TEAM})"
  # A plain `xcodebuild build` injects get-task-allow and signs without a
  # secure timestamp; the notary service rejects both, so turn them off here
  # rather than going through an archive/export round trip.
  SIGNING_ARGS=(
    CODE_SIGN_STYLE=Manual
    "CODE_SIGN_IDENTITY=${CODE_SIGN_IDENTITY}"
    "DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}"
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
    "OTHER_CODE_SIGN_FLAGS=--timestamp"
  )
else
  # The checked-in project signs ad hoc (CODE_SIGN_IDENTITY = "-", ADR-0018),
  # so no flags are needed for the unsigned/ad-hoc release build.
  echo "== building Release (ad-hoc signing)"
fi

xcodebuild \
  -project NextcloudMail.xcodeproj \
  -scheme NextcloudMail \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  SUPPRESS_WARNINGS=NO \
  "${SIGNING_ARGS[@]+"${SIGNING_ARGS[@]}"}" \
  build

APP="$DERIVED_DATA/Build/Products/Release/NextcloudMail.app"
[[ -d "$APP" ]] || { echo "error: $APP not found after build" >&2; exit 1; }

# Sparkle's helpers ship ad-hoc signed and Xcode's copy step re-signs only the framework's
# outer layer, so the notary service would reject the DMG. Re-sign them inside out with the
# release identity, then the app, whose seal covers the framework (ADR-0108). This is the
# order Sparkle's own documentation gives; Downloader.xpc keeps its entitlements.
if [[ -n "${CODE_SIGN_IDENTITY:-}" && -n "${DEVELOPMENT_TEAM:-}" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning \
    | awk -v name="$CODE_SIGN_IDENTITY" -v team="($DEVELOPMENT_TEAM)" \
      'index($0, name) && index($0, team) { print $2; exit }')"
  [[ -n "$IDENTITY" ]] || { echo "error: no '$CODE_SIGN_IDENTITY' identity for $DEVELOPMENT_TEAM" >&2; exit 1; }
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
  resign() { codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@"; }
  resign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
  resign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
  resign "$SPARKLE/Versions/B/Autoupdate"
  resign "$SPARKLE/Versions/B/Updater.app"
  resign "$SPARKLE"
  resign --preserve-metadata=entitlements,requirements,flags "$APP"
  codesign --verify --deep --strict "$APP"
fi

# --- Version -----------------------------------------------------------------

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ -z "$VERSION" ]]; then
  # Strip a leading "v" so a tag-derived name matches the plist-derived one.
  VERSION="${VERSION_TAG#v}"
fi
[[ -n "$VERSION" ]] || { echo "error: no version in Info.plist and no VERSION_TAG" >&2; exit 1; }

# --- Background --------------------------------------------------------------

# The committed PNG is 1564x1006 pixels, drawn for a 782x503-point window. A
# bare PNG would render at 1:1 pixels-to-points in Finder and show only a
# quarter of the art, so build a multi-resolution TIFF (1x + 2x pages) that
# Finder resolves to the window's point size on any display.
STAGE="$(mktemp -d /tmp/nextcloudmail-dmg.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
sips --resampleHeightWidth 503 782 "$BACKGROUND_PNG" \
  --out "$STAGE/background-1x.png" >/dev/null
tiffutil -cathidpicheck "$STAGE/background-1x.png" "$BACKGROUND_PNG" \
  -out "$STAGE/background.tiff"

# --- Package -----------------------------------------------------------------

mkdir -p "$OUT_DIR"
DMG="$OUT_DIR/NextcloudMail-$VERSION.dmg"
rm -f "$DMG"

# Icon positions match the background art: app on the left, /Applications on
# the right, arrow between them. create-dmg adds the /Applications symlink.
create-dmg \
  --volname "Nextcloud Mail" \
  --background "$STAGE/background.tiff" \
  --window-pos 200 160 \
  --window-size 782 503 \
  --icon-size 128 \
  --icon "NextcloudMail.app" 200 260 \
  --app-drop-link 582 260 \
  --hide-extension "NextcloudMail.app" \
  --no-internet-enable \
  "$DMG" \
  "$APP"

echo "== wrote $DMG"
du -h "$DMG"
