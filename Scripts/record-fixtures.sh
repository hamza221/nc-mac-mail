#!/usr/bin/env bash
# SPDX-FileCopyrightText: Hamza Mahjoubi
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Record real server responses as test fixtures, scrubbed.
#
# Fixtures are recorded, never hand-written: a fixture someone typed tests that
# the decoder matches that person's idea of the payload, which is the thing most
# likely to be wrong. See docs/delivery/testing-strategy.md.
#
#   Scripts/record-fixtures.sh https://cloud.example.com alice 'app-password' [--scrub-content]
#
# Writes to Packages/NCMailTestSupport/Sources/NCMailFixtures/Resources/Fixtures/, the
# dependency-free target every package's tests can reach through Bundle.module (ADR-0026).
# Addresses, tokens, hmacs and hostnames are replaced before anything is written. Subjects
# and preview text are KEPT — they are what makes a decoding test real — unless
# --scrub-content is passed.

set -euo pipefail

if [ $# -lt 3 ]; then
    echo "usage: $0 <server-url> <login-name> <app-password> [--scrub-content]" >&2
    exit 64
fi

SERVER="${1%/}"
LOGIN="$2"
PASSWORD="$3"
SCRUB_CONTENT="${4:-}"

API="$SERVER/index.php/apps/mail/api"
OUT="$(cd "$(dirname "$0")/.." && pwd)/Packages/NCMailTestSupport/Sources/NCMailFixtures/Resources/Fixtures"
mkdir -p "$OUT"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 69; }

# --- scrubbing -------------------------------------------------------------
# Everything written passes through here. Never widen it without thinking about
# what ends up in git.
scrub() {
    local host
    host="$(printf '%s' "$SERVER" | sed -E 's#^https?://##; s#/.*##')"
    sed -E \
        -e "s#$host#cloud.example.com#g" \
        -e 's#"(appPassword|token|hmac|requesttoken)":[[:space:]]*"[^"]*"#"\1":"REDACTED"#g' \
        -e 's#(hmac=)[A-Za-z0-9%+/=_-]+#\1REDACTED#g' \
        -e 's#https?://[^/"]*:[^@"]*@#https://REDACTED@#g' \
        -e 's#[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}#user@example.com#g' \
        -e 's#[A-Za-z0-9._+-]+%40[A-Za-z0-9.-]+\.[A-Za-z]{2,}#user%40example.com#g' \
        -e 's#"(imapHost|smtpHost)":[[:space:]]*"[^"]*"#"\1":"mail.example.com"#g'
}

# Per-recipient tracking tokens. A marketing mail's links carry an opaque id
# that identifies the recipient to the sender's click tracker. The URL shape is
# what a WebView test needs; the token is not. Structure kept, token replaced.
scrub_tracking() {
    python3 -c '
import re, sys
# 24+ url-safe characters containing at least one digit. The digit requirement
# is what keeps CSS keywords such as -webkit-text-size-adjust intact.
sys.stdout.write(re.sub(r"(?=[A-Za-z0-9_-]*[0-9])[A-Za-z0-9_-]{24,}", "TRACKINGID", sys.stdin.read()))
'
}

scrub_content() {
    if [ "$SCRUB_CONTENT" = "--scrub-content" ]; then
        # Everything a human wrote or was named in. Addresses are handled by
        # scrub(); these are the fields that carry a person's NAME rather than
        # their address -- display labels, attachment filenames (a CV filename
        # is as identifying as an address), and the body text itself. The
        # shapes all survive: a label is still a string, an attachment still
        # has a fileName with its real extension.
        jq '(.. | objects | select(has("subject")) | .subject) |= "Subject redacted"
            | (.. | objects | select(has("previewText")) | .previewText) |= "Preview redacted"
            | (.. | objects | select(has("summary")) | .summary) |= "Summary redacted"
            | (.. | objects | select(has("label")) | .label) |= "Name redacted"
            | (.. | objects | select(has("body")) | .body) |= "Body redacted"
            | (.. | objects | select(has("fileName")) | .fileName) |=
                (if test("\\.") then "attachment." + (split(".") | last) else "attachment" end)'
    else
        cat
    fi
}

fetch() {
    # $1 output file, $2 url, $3 optional "raw" for non-JSON
    local out="$OUT/$1" url="$2" mode="${3:-json}" tmp
    tmp="$(mktemp)"
    local status
    status="$(curl -sS -o "$tmp" -w '%{http_code}' \
        -u "$LOGIN:$PASSWORD" \
        -H 'OCS-APIRequest: true' \
        -H 'Accept: application/json' \
        -H 'User-Agent: Nextcloud Mail (macOS)/fixtures' \
        "$url" || true)"

    if [ "$mode" = "json" ] && jq -e . >/dev/null 2>&1 < "$tmp"; then
        jq '.' < "$tmp" | scrub_content | scrub | scrub_tracking > "$out"
    else
        scrub < "$tmp" | scrub_tracking > "$out"
    fi
    printf '  %-38s HTTP %s  %s\n' "$1" "$status" "$(wc -c < "$out" | tr -d ' ') bytes"
    rm -f "$tmp"
}

post() {
    # $1 output file, $2 url, $3 json body
    local out="$OUT/$1" tmp status
    tmp="$(mktemp)"
    status="$(curl -sS -o "$tmp" -w '%{http_code}' -X POST \
        -u "$LOGIN:$PASSWORD" \
        -H 'OCS-APIRequest: true' \
        -H 'Accept: application/json' \
        -H 'Content-Type: application/json' \
        -H 'User-Agent: Nextcloud Mail (macOS)/fixtures' \
        -d "$3" "$2" || true)"
    if jq -e . >/dev/null 2>&1 < "$tmp"; then
        jq '.' < "$tmp" | scrub_content | scrub | scrub_tracking > "$out"
    else
        scrub < "$tmp" | scrub_tracking > "$out"
    fi
    printf '  %-38s HTTP %s  %s\n' "$1" "$status" "$(wc -c < "$out" | tr -d ' ') bytes"
    rm -f "$tmp"
}

echo "Recording fixtures into $OUT"

fetch capabilities.json "$SERVER/ocs/v2.php/cloud/capabilities"
fetch accounts.json "$API/accounts"

ACCOUNT_ID="$(jq -r '.[0].id // empty' < "$OUT/accounts.json")"
[ -n "$ACCOUNT_ID" ] || { echo "no accounts on this login; nothing more to record" >&2; exit 1; }

fetch "mailboxes-account.json" "$API/mailboxes?accountId=$ACCOUNT_ID"

# The inbox: first mailbox whose specialRole is inbox.
MAILBOX_ID="$(jq -r '[.mailboxes[] | select(.specialRole == "inbox")][0].databaseId // .mailboxes[0].databaseId' < "$OUT/mailboxes-account.json")"

# Prime the server cache, which also records what an init sync looks like.
post "sync-initial.json" "$API/mailboxes/$MAILBOX_ID/sync" '{"ids":[],"init":true}'

fetch "messages-inbox-page1.json" "$API/messages?mailboxId=$MAILBOX_ID&view=singleton&limit=100"

CURSOR="$(jq -r 'if type == "array" and length > 0 then (map(.dateInt) | min) else empty end' < "$OUT/messages-inbox-page1.json")"
if [ -n "$CURSOR" ]; then
    fetch "messages-inbox-page2.json" "$API/messages?mailboxId=$MAILBOX_ID&view=singleton&limit=100&cursor=$CURSOR"
fi

# An incremental sync with a small known window — the shape every sync test needs.
KNOWN_IDS="$(jq -c 'if type == "array" then [limit(5; .[].databaseId)] else [] end' < "$OUT/messages-inbox-page1.json")"
post "sync-incremental.json" "$API/mailboxes/$MAILBOX_ID/sync" "{\"ids\":$KNOWN_IDS,\"init\":false,\"sortOrder\":\"newest\"}"

# Bodies: one HTML message and one plain-text message, if both exist.
HTML_ID="$(jq -r 'if type == "array" then ([.[] | select(.previewText != null)][0].databaseId // .[0].databaseId) else empty end' < "$OUT/messages-inbox-page1.json")"
if [ -n "$HTML_ID" ]; then
    fetch "message-body.json" "$API/messages/$HTML_ID/body"
    fetch "message-html-plain.html" "$API/messages/$HTML_ID/html?plain=true" raw
    fetch "message-thread.json" "$API/messages/$HTML_ID/thread"
fi

# A body that carries an attachment. The attachment entries inside an envelope
# are a reduced shape -- id, fileName, mime, downloadUrl, mimeUrl -- and only
# the body endpoint returns the full one with size, cid, disposition, isImage
# and isCalendarEvent. Attachment is decoded from both, so both are recorded.
ATTACHMENT_MESSAGE_ID="$(jq -r 'if type == "array" then ([.[] | select((.attachments | length) > 0)][0].databaseId // empty) else empty end' < "$OUT/messages-inbox-page1.json")"
if [ -n "$ATTACHMENT_MESSAGE_ID" ]; then
    fetch "message-body-attachments.json" "$API/messages/$ATTACHMENT_MESSAGE_ID/body"
fi

# Small payloads with their own models: MailboxStats, Preference and the
# trusted-sender list, which arrives wrapped in the JsonResponse success
# envelope rather than as a bare array.
fetch "mailbox-stats.json" "$API/mailboxes/$MAILBOX_ID/stats"
fetch "preference-sort-order.json" "$API/preferences/sort-order"
fetch "trustedsenders.json" "$API/trustedsenders"

# Error shapes. These are the fixtures nobody has when they need them.
#
# A bad id on either route answers HTTP 403 with a body of exactly `[]`, not a 404 —
# DelegationService resolves the effective user before the controller runs, and an id that
# does not exist cannot be resolved to one the caller may see, so "gone" and "never yours"
# are the same answer. See docs/reference/api-payloads.md#what-a-missing-thing-actually-answers.
# Naming these "-not-found" would repeat the mistake this comment is fixing: the fixture
# names say what the server actually sent, not what the id turned out to mean.
fetch "error-mailbox-forbidden.json" "$API/mailboxes/99999999/stats"
fetch "error-message-forbidden.json" "$API/messages/99999999/body"
# A missing avatar is a genuine 404 with a zero-byte text/html body, not JSON — hence "raw"
# and the .txt extension rather than .json.
fetch "avatar-404.txt" "$API/avatars/image/nobody%40example.invalid" raw

echo
echo "Done. Before committing:"
echo "  1. grep the fixtures for your real domain and your real addresses."
echo "  2. Skim message-body.json — content is kept unless --scrub-content was passed."
echo "  3. Note the app version this was recorded against in the pull request."
