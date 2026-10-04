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
#
# NOT READ-ONLY: mutating routes are recorded against scratch objects the run creates
# and deletes, and three messages are sent to the account's own address (ADR-0080).
# Point it at a dedicated test account, never a production one.

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

# The account's real identity, derived up front so every scrub pass below can
# rewrite it wherever it appears — not just in the fields the v1 scrubber knew
# about (an MX lookup answers bare hostnames, a DAV ORGANIZER line carries the
# profile address). Never written anywhere except through a scrub.
REAL_ACCOUNT="$(curl -s -u "$LOGIN:$PASSWORD" -H 'OCS-APIRequest: true' -H 'Accept: application/json' "$API/accounts")"
SELF_EMAIL="$(printf '%s' "$REAL_ACCOUNT" | jq -r '.[0].emailAddress // empty' 2>/dev/null || true)"
IMAP_HOST="$(printf '%s' "$REAL_ACCOUNT" | jq -r '.[0].imapHost // empty' 2>/dev/null || true)"
MAIL_DOMAIN="${SELF_EMAIL#*@}"
IMAP_DOMAIN="$(printf '%s' "$IMAP_HOST" | awk -F. 'NF >= 2 {print $(NF-1)"."$NF}')"

# Rewrites ONLY the operator's real identity: server host, mail/IMAP domains,
# the DAV login path segment. The targeted pass shared by every fixture kind —
# it deliberately leaves synthetic *.example addresses alone, because the DAV
# content fixtures depend on their variety (three distinct EMAILs on one card).
scrub_identity() {
    local host args
    host="$(printf '%s' "$SERVER" | sed -E 's#^https?://##; s#/.*##')"
    args=(-E
        -e "s#$host#cloud.example.com#g"
        -e "s#/(addressbooks/users|calendars|files|principals/users)/$LOGIN([/<])#/\1/user\2#g"
        -e "s#>principals/users/$LOGIN<#>principals/users/user<#g")
    [ -n "$MAIL_DOMAIN" ] && args+=(
        -e "s#[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.)?$MAIL_DOMAIN#user@example.com#g"
        -e "s#([A-Za-z0-9-]+\.)*$MAIL_DOMAIN#example.com#g")
    [ -n "$IMAP_DOMAIN" ] && args+=(
        -e "s#([A-Za-z0-9-]+\.)*$IMAP_DOMAIN#mail.example.com#g")
    sed "${args[@]}"
}

scrub() {
    scrub_identity | sed -E \
        -e 's#"(appPassword|token|hmac|requesttoken)":[[:space:]]*"[^"]*"#"\1":"REDACTED"#g' \
        -e 's#(hmac=)[A-Za-z0-9%+/=_-]+#\1REDACTED#g' \
        -e 's#https?://[^/"]*:[^@"]*@#https://REDACTED@#g' \
        -e 's#[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}#user@example.com#g' \
        -e 's#[A-Za-z0-9._+-]+%40[A-Za-z0-9.-]+\.[A-Za-z]{2,}#user%40example.com#g' \
        -e 's#"(imapHost|smtpHost)":[[:space:]]*"[^"]*"#"\1":"mail.example.com"#g' \
        -e 's#/var/www/html/#/srv/nextcloud/#g'
}

# A server in debug mode appends the PHP stack to every JSON error body
# (`data.trace`, plus `file`/`line` beside it, nested again under `previous`).
# The client decodes `status`, `message`, `type` and `code`; the stack is
# server layout, not payload. Dropped wherever a `trace` key appears. The HTML
# error pages keep their trace text, with the install root rewritten by scrub().
scrub_debug() {
    jq 'walk(if type == "object" and has("trace") then del(.trace, .file, .line) else . end)'
}

# Per-recipient tracking tokens. A marketing mail's links carry an opaque id
# that identifies the recipient to the sender's click tracker. The URL shape is
# what a WebView test needs; the token is not. Structure kept, token replaced.
scrub_tracking() {
    python3 -c '
import re, sys
# 24+ url-safe characters containing at least one digit. The digit requirement
# is what keeps CSS keywords such as -webkit-text-size-adjust intact, and the
# lookbehind keeps a match from starting right after a backslash — otherwise a
# JSON "\t" escape followed by a folded DKIM value loses its "t" and the
# fixture stops being JSON at all.
sys.stdout.write(re.sub(r"(?<!\\)(?=[A-Za-z0-9_-]*[0-9])[A-Za-z0-9_-]{24,}", "TRACKINGID", sys.stdin.read()))
'
}

scrub_content() {
    if [ "$SCRUB_CONTENT" = "--scrub-content" ]; then
        # Everything a human wrote or was named in. Addresses are handled by
        # scrub(); these are the fields that carry a person's NAME rather than
        # their address -- display labels, attachment filenames (a CV filename
        # is as identifying as an address), and the body text itself. The
        # shapes all survive: a label is still a string, an attachment still
        # has a fileName with its real extension — and a null stays null,
        # because "the field can be null" is part of what a decode test tests.
        jq '(.. | objects | select(.subject? | type == "string") | .subject) |= "Subject redacted"
            | (.. | objects | select(.previewText? | type == "string") | .previewText) |= "Preview redacted"
            | (.. | objects | select(.summary? | type == "string") | .summary) |= "Summary redacted"
            | (.. | objects | select(.label? | type == "string") | .label) |= "Name redacted"
            | (.. | objects | select(.body? | type == "string") | .body) |= "Body redacted"
            | (.. | objects | select(.fileName? | type == "string") | .fileName) |=
                (if test("\\.") then "attachment." + (split(".") | last) else "attachment" end)'
    else
        cat
    fi
}

# The unscrubbed bytes of the most recent fetch/post/req/post_multipart
# response. Lifecycle steps read ids (and the one vCard UID) from here, never
# from the written fixture — scrub_tracking happily rewrites a long sabre UID.
LAST_RAW="$(mktemp)"
fetch() {
    # $1 output file, $2 url, $3 optional "raw" for non-JSON text, "bin" for binary
    local out="$OUT/$1" url="$2" mode="${3:-json}" tmp
    tmp="$(mktemp)"
    local status
    status="$(curl -sS -o "$tmp" -w '%{http_code}' \
        -u "$LOGIN:$PASSWORD" \
        -H 'OCS-APIRequest: true' \
        -H 'Accept: application/json' \
        -H 'User-Agent: Nextcloud Mail (macOS)/fixtures' \
        "$url" || true)"

    cp "$tmp" "$LAST_RAW"
    if [ "$mode" = "json" ] && jq -e . >/dev/null 2>&1 < "$tmp"; then
        jq '.' < "$tmp" | scrub_debug | scrub_content | scrub | scrub_tracking > "$out"
    elif [ "$mode" = "bin" ]; then
        # sed would mangle NUL bytes; a zip or image is committed verbatim. Nothing textual
        # survives uncompressed in these, which is why "bin" is reserved for true binaries.
        cat "$tmp" > "$out"
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
    cp "$tmp" "$LAST_RAW"
    if jq -e . >/dev/null 2>&1 < "$tmp"; then
        jq '.' < "$tmp" | scrub_debug | scrub_content | scrub | scrub_tracking > "$out"
    else
        scrub < "$tmp" | scrub_tracking > "$out"
    fi
    printf '  %-38s HTTP %s  %s\n' "$1" "$status" "$(wc -c < "$out" | tr -d ' ') bytes"
    rm -f "$tmp"
}

# Internal fetch for ids and addresses the lifecycle targets below need. Never
# writes a fixture, so it carries the REAL values — nothing from here may reach
# a file except through scrub().
rawget() {
    curl -s -u "$LOGIN:$PASSWORD" \
        -H 'OCS-APIRequest: true' -H 'Accept: application/json' \
        -H 'User-Agent: Nextcloud Mail (macOS)/fixtures' "$1"
}

# Setup/cleanup requests that record nothing: restoring a signature, deleting a
# scratch object a recorded DELETE already covered elsewhere.
quiet() {
    # $1 method, $2 url, $3 optional json body
    if [ -n "${3:-}" ]; then
        curl -sS -o /dev/null -X "$1" -u "$LOGIN:$PASSWORD" \
            -H 'OCS-APIRequest: true' -H 'Accept: application/json' \
            -H 'Content-Type: application/json' -d "$3" "$2" || true
    else
        curl -sS -o /dev/null -X "$1" -u "$LOGIN:$PASSWORD" \
            -H 'OCS-APIRequest: true' -H 'Accept: application/json' "$2" || true
    fi
}

# Like post(), any method. The recorder's mutating targets (PUT/PATCH/DELETE)
# all go through here so every response body passes the same scrub pipeline.
req() {
    # $1 method, $2 output file, $3 url, $4 optional json body
    local method="$1" out="$OUT/$2" url="$3" body="${4:-}" tmp status
    tmp="$(mktemp)"
    local args=(-sS -o "$tmp" -w '%{http_code}' -X "$method" \
        -u "$LOGIN:$PASSWORD" \
        -H 'OCS-APIRequest: true' \
        -H 'Accept: application/json' \
        -H 'User-Agent: Nextcloud Mail (macOS)/fixtures')
    [ -n "$body" ] && args+=(-H 'Content-Type: application/json' -d "$body")
    status="$(curl "${args[@]}" "$url" || true)"
    cp "$tmp" "$LAST_RAW"
    if jq -e . >/dev/null 2>&1 < "$tmp"; then
        jq '.' < "$tmp" | scrub_debug | scrub_content | scrub | scrub_tracking > "$out"
    else
        scrub < "$tmp" | scrub_tracking > "$out"
    fi
    printf '  %-38s HTTP %s  %s\n' "$2" "$status" "$(wc -c < "$out" | tr -d ' ') bytes"
    rm -f "$tmp"
}

# Multipart upload — POST /api/attachments and S/MIME import. Fields arrive as
# curl -F arguments after the url.
post_multipart() {
    # $1 output file, $2 url, $3.. -F arguments
    local out="$OUT/$1" url="$2" tmp status
    shift 2
    tmp="$(mktemp)"
    status="$(curl -sS -o "$tmp" -w '%{http_code}' -X POST \
        -u "$LOGIN:$PASSWORD" \
        -H 'OCS-APIRequest: true' \
        -H 'Accept: application/json' \
        -H 'User-Agent: Nextcloud Mail (macOS)/fixtures' \
        "$@" "$url" || true)"
    cp "$tmp" "$LAST_RAW"
    if jq -e . >/dev/null 2>&1 < "$tmp"; then
        jq '.' < "$tmp" | scrub_debug | scrub_content | scrub | scrub_tracking > "$out"
    else
        scrub < "$tmp" | scrub_tracking > "$out"
    fi
    printf '  %-38s HTTP %s  %s\n' "${out##*/}" "$status" "$(wc -c < "$out" | tr -d ' ') bytes"
    rm -f "$tmp"
}

# --- DAV -------------------------------------------------------------------
# CardDAV/CalDAV fixtures all pass through scrub_identity and nothing else: no
# jq, no tracking pass, no blanket address rewrite. WS-17's round-trip tests
# compare the fixture's exact bytes (server line folding included) and depend
# on the variety of the synthetic *.example addresses; only the operator's
# real identity is rewritten, which scrub_identity already does everywhere —
# including an ORGANIZER line sabre derives from the principal's profile.

dav() {
    # $1 output file, $2 method, $3 url, $4 depth ('' omits the header), $5 optional body,
    # $6 optional content type (default XML — pass text/calendar for an invalid-PUT probe)
    local out="$OUT/$1" method="$2" url="$3" depth="${4:-}" body="${5:-}" tmp status
    tmp="$(mktemp)"
    local args=(-sS -o "$tmp" -w '%{http_code}' -X "$method" \
        -u "$LOGIN:$PASSWORD" \
        -H 'User-Agent: Nextcloud Mail (macOS)/fixtures')
    [ -n "$depth" ] && args+=(-H "Depth: $depth")
    [ -n "$body" ] && args+=(-H "Content-Type: ${6:-application/xml; charset=utf-8}" --data-binary "$body")
    status="$(curl "${args[@]}" "$url" || true)"
    scrub_identity < "$tmp" > "$out"
    printf '  %-38s HTTP %s  %s\n' "$1" "$status" "$(wc -c < "$out" | tr -d ' ') bytes"
    rm -f "$tmp"
}

# A request whose fixture is the response HEADERS (the ETag is the payload
# WS-17 decodes) — a PUT answering 201/204, an extended MKCOL or an oc:share
# POST answering with an empty body.
dav_headers() {
    # $1 output file, $2 method, $3 url, $4 optional body, $5 optional content type
    local out="$OUT/$1" method="$2" url="$3" body="${4:-}" tmp status
    tmp="$(mktemp)"
    local args=(-sS -D "$tmp" -o /dev/null -w '%{http_code}' -X "$method" \
        -u "$LOGIN:$PASSWORD" \
        -H 'User-Agent: Nextcloud Mail (macOS)/fixtures')
    [ -n "$body" ] && args+=(-H "Content-Type: ${5:-application/xml; charset=utf-8}" --data-binary "$body")
    status="$(curl "${args[@]}" "$url" || true)"
    # Session cookies (oc_sessionPassphrase, the instance cookie) are live
    # credentials; request ids and debug tokens identify one server log line.
    # None is payload — WS-17 reads the status line and ETag — so all are dropped.
    # X-User-Id is the operator's login, which scrub_identity only rewrites inside paths.
    scrub_identity < "$tmp" | tr -d '\r' | grep -viE '^(set-cookie|x-request-id|x-debug-token|x-user-id):' > "$out" || true
    printf '  %-38s HTTP %s  %s\n' "$1" "$status" "$(wc -c < "$out" | tr -d ' ') bytes"
    rm -f "$tmp"
}

# Internal DAV request — discovery and setup/cleanup, records nothing.
rawdav() {
    # $1 method, $2 url, $3 optional depth, $4 optional body, $5 optional content type
    local args=(-sS -X "$1" -u "$LOGIN:$PASSWORD" -H 'User-Agent: Nextcloud Mail (macOS)/fixtures')
    [ -n "${3:-}" ] && args+=(-H "Depth: $3")
    [ -n "${4:-}" ] && args+=(-H "Content-Type: ${5:-application/xml; charset=utf-8}" --data-binary "$4")
    curl "${args[@]}" "$2" || true
}

urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

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

# Bodies: one message's body and thread. The HTML route is recorded further
# down, from the attachment self-send, which is the one message the recorder
# guarantees has a non-empty HTML part.
HTML_ID="$(jq -r 'if type == "array" then ([.[] | select(.previewText != null)][0].databaseId // .[0].databaseId) else empty end' < "$OUT/messages-inbox-page1.json")"
if [ -n "$HTML_ID" ]; then
    fetch "message-body.json" "$API/messages/$HTML_ID/body"
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

# ===========================================================================
# v2 (WS-19): every WS-16 route, CardDAV/CalDAV, and the non-Mail OCS probes.
#
# Reads are fetched as-is. Mutating routes are recorded against SCRATCH OBJECTS
# the recorder creates and deletes in the same run (a tag, an alias, a mailbox,
# a draft, an outbox message, a text block, a quick action, an uploaded
# attachment, a self-signed S/MIME certificate), so a run leaves the account
# the way it found it — modulo one message sent BY the account TO ITSELF,
# which is the standing rule for send fixtures: never record a send to any
# address but the test account's own (docs/delivery/testing-strategy.md).
#
# Routes whose precondition the test server cannot meet (LLM processing off,
# ManageSieve disabled, notifications app absent, no MDN request on any
# message) still get their fixture: the honest error body the server sends,
# which is exactly what the client must decode in that situation.
# ===========================================================================

NOW="$(date +%s)"

echo
echo "-- accounts"
fetch account-quota.json "$API/accounts/$ACCOUNT_ID/quota"
fetch account-test.json "$API/accounts/$ACCOUNT_ID/test"
req PATCH account-patch.json "$API/accounts/$ACCOUNT_ID" '{"order":0}'
req PUT account-signature.json "$API/accounts/$ACCOUNT_ID/signature" '{"signature":"Recorded fixture signature"}'
quiet PUT "$API/accounts/$ACCOUNT_ID/signature" '{"signature":null}'

echo "-- aliases"
post alias-created.json "$API/accounts/$ACCOUNT_ID/aliases" "{\"alias\":\"fixture-alias@$MAIL_DOMAIN\",\"aliasName\":\"Fixture Alias\"}"
ALIAS_ID="$(jq -r '.id // .data.id // empty' < "$LAST_RAW" 2>/dev/null || true)"
fetch aliases.json "$API/accounts/$ACCOUNT_ID/aliases"
if [ -n "$ALIAS_ID" ]; then
    req PUT alias-updated.json "$API/accounts/$ACCOUNT_ID/aliases/$ALIAS_ID" "{\"alias\":\"fixture-alias@$MAIL_DOMAIN\",\"aliasName\":\"Fixture Alias Renamed\"}"
    req PUT alias-signature.json "$API/accounts/$ACCOUNT_ID/aliases/$ALIAS_ID/signature" '{"signature":"Alias signature"}'
    # WS-21: the accounts index with an account signature and an alias signature both
    # set, so the mirror's "signatures come from the payload, never a blank" has a real
    # payload to be tested against. Restored to no signature straight after.
    quiet PUT "$API/accounts/$ACCOUNT_ID/signature" '{"signature":"Recorded fixture signature"}'
    fetch accounts-signatures.json "$API/accounts"
    quiet PUT "$API/accounts/$ACCOUNT_ID/signature" '{"signature":null}'
    req DELETE alias-deleted.json "$API/accounts/$ACCOUNT_ID/aliases/$ALIAS_ID"
else
    echo "  (alias lifecycle skipped — create returned no id)"
fi

echo "-- autoconfig (rate limited 5/60s; run at most once per minute)"
fetch autoconfig-ispdb.json "$API/autoconfig/ispdb/gmail.com/user%40gmail.com"
fetch autoconfig-mx.json "$API/autoconfig/mx/$(urlencode "$SELF_EMAIL")"
fetch autoconfig-test.json "$API/autoconfig/test?host=$IMAP_HOST&port=993"

# Message ids are re-listed here, immediately before use, and every route that
# only reads runs BEFORE anything that moves a message — a snooze renumbers the
# message's databaseId, and a request with the old id answers the delegation
# 403, which is an honest fixture but not the one these names promise.
echo "-- message routes"
FRESH_IDS="$(rawget "$API/messages?mailboxId=$MAILBOX_ID&view=singleton&limit=100")"
MID="$(printf '%s' "$FRESH_IDS" | jq -r 'if type == "array" then (.[0].databaseId // empty) else empty end' 2>/dev/null || true)"
MID_THREAD="$(printf '%s' "$FRESH_IDS" | jq -r 'if type == "array" then (.[1].databaseId // empty) else empty end' 2>/dev/null || true)"
if [ -n "$MID" ]; then
    fetch message-source.json "$API/messages/$MID/source"
    fetch message-export.eml "$API/messages/$MID/export" raw
    fetch message-itineraries.json "$API/messages/$MID/itineraries"
    fetch message-dkim.json "$API/messages/$MID/dkim"
    # LLM processing is off on the test server: these answer the honest body
    # the client decodes when the admin has not enabled it (204, empty).
    fetch thread-summary.json "$API/thread/$MID/summary"
    fetch thread-eventdata.json "$API/thread/$MID/eventdata"
    fetch message-smartreply.json "$API/messages/$MID/smartreply"
    # No message on the test account requests an MDN and none carries
    # List-Unsubscribe; both record the server's refusal, which is the shape
    # the client sees when the user asks for either on the wrong message.
    post message-mdn.json "$API/messages/$MID/mdn" '{}'
    post unsubscribe.json "$API/list/unsubscribe/$MID" '{}'
    post message-saved-to-files.json "$API/messages/$MID/file" '{"targetPath":"/"}'
else
    echo "  (message routes skipped — inbox is empty)"
fi

echo "-- tags"
post tag-created.json "$API/tags" '{"displayName":"Fixture tag","color":"#0082c9"}'
TAG_ID="$(jq -r '.id // .data.id // empty' < "$LAST_RAW" 2>/dev/null || true)"
TAG_LABEL="$(jq -r '.imapLabel // .data.imapLabel // empty' < "$LAST_RAW" 2>/dev/null || true)"
if [ -n "$TAG_ID" ]; then
    req PUT tag-updated.json "$API/tags/$TAG_ID" '{"displayName":"Fixture tag renamed","color":"#aa0000"}'
    if [ -n "$TAG_LABEL" ] && [ -n "$MID" ]; then
        req PUT message-tag-added.json "$API/messages/$MID/tags/$(urlencode "$TAG_LABEL")"
        req DELETE message-tag-removed.json "$API/messages/$MID/tags/$(urlencode "$TAG_LABEL")"
    fi
    req DELETE tag-deleted.json "$API/tags/$ACCOUNT_ID/delete/$TAG_ID"
else
    echo "  (tag lifecycle skipped — create returned no id)"
fi

echo "-- mailbox lifecycle (scratch folder; also the snooze destination)"
# Self-healing: a previous run that died mid-lifecycle leaves a scratch folder
# behind. Leftovers are swept first, and each run's folder carries the run's
# timestamp anyway — an IMAP folder the Mail cache no longer lists (so the
# sweep cannot see it) must not make this run's create collide with it.
sweep_scratch_mailboxes() {
    for OLD_ID in $(rawget "$API/mailboxes?accountId=$ACCOUNT_ID" | jq -r '.mailboxes[] | select(.name | test("^FixtureScratch")) | .databaseId' 2>/dev/null || true); do
        quiet DELETE "$API/mailboxes/$OLD_ID"
    done
}
sweep_scratch_mailboxes
# The space keeps the name under scrub_tracking's 24-character token length,
# so the fixture shows the real name rather than TRACKINGID.
SCRATCH_NAME="FixtureScratch $NOW"
post mailbox-created.json "$API/mailboxes" "{\"accountId\":$ACCOUNT_ID,\"name\":\"$SCRATCH_NAME\"}"
SCRATCH_ID="$(jq -r '.databaseId // empty' < "$LAST_RAW" 2>/dev/null || true)"
if [ -n "$SCRATCH_ID" ]; then
    if [ -n "$MID" ]; then
        post message-snoozed.json "$API/messages/$MID/snooze" "{\"unixTimestamp\":$((NOW + 3600)),\"destMailboxId\":$SCRATCH_ID}"
        # The move gives the message a new databaseId, and the new folder's
        # cache is cold — sync it, then address the message by its new id.
        quiet POST "$API/mailboxes/$SCRATCH_ID/sync" '{"ids":[],"init":true}'
        SNOOZED_ID="$(rawget "$API/messages?mailboxId=$SCRATCH_ID&view=singleton&limit=10" | jq -r '.[0].databaseId // empty' 2>/dev/null || true)"
        post message-unsnoozed.json "$API/messages/${SNOOZED_ID:-$MID}/unsnooze" '{}'
    fi
    if [ -n "$MID_THREAD" ]; then
        post thread-snoozed.json "$API/thread/$MID_THREAD/snooze" "{\"unixTimestamp\":$((NOW + 3600)),\"destMailboxId\":$SCRATCH_ID}"
        quiet POST "$API/mailboxes/$SCRATCH_ID/sync" '{"ids":[],"init":true}'
        SNOOZED_T="$(rawget "$API/messages?mailboxId=$SCRATCH_ID&view=singleton&limit=10" | jq -r '.[0].databaseId // empty' 2>/dev/null || true)"
        post thread-unsnoozed.json "$API/thread/${SNOOZED_T:-$MID_THREAD}/unsnooze" '{}'
    fi
    # Clearing deletes whatever is in the folder. A snoozed message whose
    # unsnooze failed would still be here; move it home before the clear.
    quiet POST "$API/mailboxes/$SCRATCH_ID/sync" '{"ids":[],"init":true}'
    for STRANDED in $(rawget "$API/messages?mailboxId=$SCRATCH_ID&view=singleton&limit=50" | jq -r 'if type == "array" then .[].databaseId else empty end' 2>/dev/null || true); do
        quiet POST "$API/messages/$STRANDED/move" "{\"destFolderId\":$MAILBOX_ID}"
    done
    post mailbox-read.json "$API/mailboxes/$SCRATCH_ID/read" '{}'
    post mailbox-cleared.json "$API/mailboxes/$SCRATCH_ID/clear" '{}'
    post mailbox-repaired.json "$API/mailboxes/$SCRATCH_ID/repair" '{}'
    req DELETE mailbox-sync-dropped.json "$API/mailboxes/$SCRATCH_ID/sync"
    # The IMAP rename gives the folder a NEW databaseId — the rename goes last,
    # and the delete takes its id from the PATCH response.
    req PATCH mailbox-patched.json "$API/mailboxes/$SCRATCH_ID" "{\"name\":\"${SCRATCH_NAME}Renamed\"}"
    RENAMED_ID="$(jq -r '.databaseId // empty' < "$LAST_RAW" 2>/dev/null || true)"
    req DELETE mailbox-deleted.json "$API/mailboxes/${RENAMED_ID:-$SCRATCH_ID}"
else
    echo "  (mailbox lifecycle skipped — create returned no id)"
fi
sweep_scratch_mailboxes

echo "-- drafts and outbox (sends go to the account's own address, never anywhere else)"
DRAFT_JSON="{\"accountId\":$ACCOUNT_ID,\"subject\":\"Fixture draft\",\"bodyPlain\":\"Recorded by the fixture recorder.\",\"bodyHtml\":\"\",\"editorBody\":\"\",\"isHtml\":false,\"smimeSign\":false,\"smimeEncrypt\":false,\"to\":[{\"label\":\"Self\",\"email\":\"$SELF_EMAIL\"}],\"cc\":[],\"bcc\":[],\"attachments\":[]}"
post draft-created.json "$API/drafts" "$DRAFT_JSON"
DRAFT_ID="$(jq -r '.id // .data.id // empty' < "$OUT/draft-created.json" 2>/dev/null || true)"
if [ -n "$DRAFT_ID" ]; then
    req PUT draft-updated.json "$API/drafts/$DRAFT_ID" "$(printf '%s' "$DRAFT_JSON" | jq -c '.subject = "Fixture draft updated" | .failed = false')"
fi
post draft-second.tmp.json "$API/drafts" "$DRAFT_JSON"
DRAFT2_ID="$(jq -r '.id // .data.id // empty' < "$OUT/draft-second.tmp.json" 2>/dev/null || true)"
rm -f "$OUT/draft-second.tmp.json"
if [ -n "$DRAFT2_ID" ]; then
    post draft-moved.json "$API/drafts/move/$DRAFT2_ID" '{}'
fi
post draft-third.tmp.json "$API/drafts" "$DRAFT_JSON"
DRAFT3_ID="$(jq -r '.id // .data.id // empty' < "$OUT/draft-third.tmp.json" 2>/dev/null || true)"
rm -f "$OUT/draft-third.tmp.json"
if [ -n "$DRAFT3_ID" ]; then
    post outbox-from-draft.json "$API/outbox/from-draft/$DRAFT3_ID" "{\"sendAt\":$((NOW + 86400))}"
    OB_FD="$(jq -r '.id // .data.id // empty' < "$OUT/outbox-from-draft.json" 2>/dev/null || true)"
fi
OUTBOX_JSON="$(printf '%s' "$DRAFT_JSON" | jq -c ". + {\"subject\":\"Fixture outbox message\",\"sendAt\":$((NOW + 86400))} | del(.attachments) + {\"attachments\":[]}")"
post outbox-created.json "$API/outbox" "$OUTBOX_JSON"
OB1="$(jq -r '.id // .data.id // empty' < "$OUT/outbox-created.json" 2>/dev/null || true)"
fetch outbox.json "$API/outbox"
if [ -n "$OB1" ]; then
    req PUT outbox-updated.json "$API/outbox/$OB1" "$(printf '%s' "$OUTBOX_JSON" | jq -c '.subject = "Fixture outbox updated"')"
    fetch outbox-message.json "$API/outbox/$OB1"
fi
if [ -n "${OB_FD:-}" ]; then
    # The one real send of the run — to the account itself (see the rule above).
    post outbox-sent.json "$API/outbox/$OB_FD" '{}'
fi
if [ -n "$OB1" ]; then
    req DELETE outbox-deleted.json "$API/outbox/$OB1"
fi
# WS-21: the outbox once this run's scratch messages are gone — what the 60 s poll reads
# when it is about to stop.
fetch outbox-drained.json "$API/outbox"
if [ -n "$DRAFT_ID" ]; then
    req DELETE draft-deleted.json "$API/drafts/$DRAFT_ID"
fi
# The moved draft now sits in the IMAP drafts folder; a run must not leave one
# behind per invocation, so it is deleted through the message route.
DRAFTS_MAILBOX_ID="$(rawget "$API/mailboxes?accountId=$ACCOUNT_ID" | jq -r '[.mailboxes[] | select(.specialRole == "drafts")][0].databaseId // empty' 2>/dev/null || true)"
if [ -n "$DRAFTS_MAILBOX_ID" ]; then
    quiet POST "$API/mailboxes/$DRAFTS_MAILBOX_ID/sync" '{"ids":[],"init":true}'
    for STALE_DRAFT in $(rawget "$API/messages?mailboxId=$DRAFTS_MAILBOX_ID&view=singleton&limit=50" | jq -r '.[] | select(.subject | startswith("Fixture draft")) | .databaseId' 2>/dev/null || true); do
        quiet DELETE "$API/messages/$STALE_DRAFT"
    done
fi

echo "-- attachment upload (multipart), and a self-send that carries it"
ATT_FILE="$(mktemp)"
printf 'WS19 fixture attachment payload\n' > "$ATT_FILE"
post_multipart attachment-uploaded.json "$API/attachments" -F "attachment=@$ATT_FILE;filename=fixture.txt;type=text/plain"
LOCAL_ATTACHMENT="$(jq -c '. // empty' < "$LAST_RAW" 2>/dev/null || true)"
rm -f "$ATT_FILE"
# Sending the upload to the account itself is what puts a message WITH an
# attachment into the inbox — the attachment body shape, the zip download and
# save-to-Files have nothing to answer otherwise. It is also the HTML message:
# real markup, so the html route has something to answer. The subject carries
# the run's timestamp so the poll below finds THIS run's message, not a
# previous run's.
if [ -n "$LOCAL_ATTACHMENT" ] && [ "$LOCAL_ATTACHMENT" != "null" ]; then
    ATT_SUBJECT="Fixture attachment message $NOW"
    OUTBOX_ATT_JSON="$(printf '%s' "$DRAFT_JSON" | jq -c --argjson att "$LOCAL_ATTACHMENT" --arg subject "$ATT_SUBJECT" \
        '.subject = $subject | .attachments = [$att] | .isHtml = true
        | .bodyHtml = "<p>Recorded by the <strong>fixture recorder</strong>.</p><ul><li>one</li><li>two</li></ul><p><a href=\"https://example.com/\">A link</a></p>"
        | .editorBody = .bodyHtml')"
    ATT_OB_ID="$(curl -sS -u "$LOGIN:$PASSWORD" -H 'OCS-APIRequest: true' -H 'Accept: application/json' -H 'Content-Type: application/json' -d "$OUTBOX_ATT_JSON" "$API/outbox" | jq -r '.id // .data.id // empty' 2>/dev/null || true)"
    if [ -n "$ATT_OB_ID" ]; then
        quiet POST "$API/outbox/$ATT_OB_ID"
        # SMTP round trip: poll the inbox for this run's message.
        ATT_MSG_ID=""
        for _ in 1 2 3 4 5 6 7 8; do
            sleep 3
            quiet POST "$API/mailboxes/$MAILBOX_ID/sync" '{"ids":[],"init":true}'
            ATT_MSG_ID="$(rawget "$API/messages?mailboxId=$MAILBOX_ID&view=singleton&limit=50" | jq -r --arg subject "$ATT_SUBJECT" '[.[] | select(.subject == $subject)][0].databaseId // empty' 2>/dev/null || true)"
            [ -n "$ATT_MSG_ID" ] && break
        done
        if [ -n "$ATT_MSG_ID" ]; then
            fetch message-body-attachments.json "$API/messages/$ATT_MSG_ID/body"
            FULL_ATT_ID="$(jq -r '.attachments[0].id // empty' < "$LAST_RAW" 2>/dev/null || true)"
            fetch message-html-plain.html "$API/messages/$ATT_MSG_ID/html?plain=true" raw
            fetch message-attachments.zip "$API/messages/$ATT_MSG_ID/attachments" bin
            if [ -n "$FULL_ATT_ID" ]; then
                post attachment-saved-to-files.json "$API/messages/$ATT_MSG_ID/attachment/$FULL_ATT_ID" '{"targetPath":"/"}'
            fi
        else
            echo "  (attachment message never arrived — html, zip and save-to-Files not recorded)"
        fi
    fi
fi

echo "-- a remote-content HTML self-send (the rewriter's subject matter)"
# The attachment message above is deliberately small. The message-view rewriter
# needs what real marketing mail carries, and nothing in a fresh test inbox
# guarantees one: remote images with their own inline style, a 1x1 tracking
# pixel, a <style> block that @imports a stylesheet from a fourth host, several
# anchors onto two click-tracker URLs. So this run sends one to the account
# itself. The markup goes out as the author wrote it; what is recorded is what
# the server's sanitiser makes of it — blocked-image placeholders, proxied
# data-original-src URLs (hmac scrubbed), the pixel's URL dropped. The envelope
# is recorded beside it so a test can seed the same message the body belongs to.
REMOTE_HTML="$(cat <<'HTML'
<html><head><style type="text/css">
@import url(https://fonts.example.org/css/brand-fonts.css);
.preheader { display: none !important; }
.mobile-only { display: none !important; }
@media only screen and (max-width: 480px) { .desktop-only { display: none !important; } }
</style></head><body>
<div class="preheader">The autumn collection is here.</div>
<table width="600" cellpadding="0" cellspacing="0" border="0"><tr><td>
<a href="https://click.example.net/l/shop"><img alt="Brand logo" title="Brand logo" src="https://images.example.net/brand/logo.png" width="600" style="display:block;text-decoration:none;height:auto;font-size:13px;width:100%;"></a>
<img alt="The autumn collection" title="The autumn collection" src="https://images.example.net/campaign/hero.jpg" width="600" style="display:block;text-decoration:none;height:auto;font-size:13px;width:100%;">
<img alt="Scarves" title="Scarves" src="https://images.example.net/campaign/scarves.jpg" width="600" style="display:block;text-decoration:none;height:auto;font-size:13px;width:100%;">
<img alt="Hoodies" title="Hoodies" src="https://images.example.net/campaign/hoodies.jpg" width="600" style="display:block;text-decoration:none;height:auto;font-size:13px;width:100%;">
<img alt="Gloves" title="Gloves" src="https://images.example.net/campaign/gloves.jpg" width="600" style="display:block;text-decoration:none;height:auto;font-size:13px;width:100%;">
<img alt="Every purchase plants a tree" title="Every purchase plants a tree" src="https://images.example.net/campaign/purpose.jpg" width="600" style="display:block;text-decoration:none;height:auto;font-size:13px;width:100%;">
<p class="desktop-only"><a style="color:#f1a7a5;text-decoration:underline;" href="https://click.example.net/l/shop">Shop the collection</a></p>
<p class="mobile-only"><a style="color:#f1a7a5;text-decoration:underline;" href="https://click.example.net/l/shop">Hoodies</a> and <a style="color:#f1a7a5;text-decoration:underline;" href="https://click.example.net/l/shop">Scarves</a></p>
<p>
<img alt="Facebook" src="https://images.example.net/social/facebook_96.png" width="32" style="width:32px;">
<img alt="Instagram" src="https://images.example.net/social/instagram_96.png" width="32" style="width:32px;">
<img alt="Mastodon" src="https://images.example.net/social/mastodon_96.png" width="32" style="width:32px;">
</p>
<p><a class="unsubscribe-link" style="color:#f1a7a5;font-weight:normal;text-decoration:underline;" href="https://click.example.net/p/unsubscribe">Unsubscribe</a></p>
<img src="https://track.example.net/open.gif" alt="" width="1" height="1" border="0" style="height:1px;width:1px;border-width:0;margin:0;padding:0;">
</td></tr></table>
</body></html>
HTML
)"
REMOTE_SUBJECT="Fixture remote images message $NOW"
OUTBOX_REMOTE_JSON="$(printf '%s' "$DRAFT_JSON" | jq -c --arg html "$REMOTE_HTML" --arg subject "$REMOTE_SUBJECT" \
    '.subject = $subject | .isHtml = true | .bodyPlain = "" | .bodyHtml = $html | .editorBody = $html')"
REMOTE_OB_ID="$(curl -sS -u "$LOGIN:$PASSWORD" -H 'OCS-APIRequest: true' -H 'Accept: application/json' -H 'Content-Type: application/json' -d "$OUTBOX_REMOTE_JSON" "$API/outbox" | jq -r '.id // .data.id // empty' 2>/dev/null || true)"
if [ -n "$REMOTE_OB_ID" ]; then
    quiet POST "$API/outbox/$REMOTE_OB_ID"
    REMOTE_MSG_ID=""
    for _ in 1 2 3 4 5 6 7 8; do
        sleep 3
        quiet POST "$API/mailboxes/$MAILBOX_ID/sync" '{"ids":[],"init":true}'
        REMOTE_MSG_ID="$(rawget "$API/messages?mailboxId=$MAILBOX_ID&view=singleton&limit=50" | jq -r --arg subject "$REMOTE_SUBJECT" '[.[] | select(.subject == $subject)][0].databaseId // empty' 2>/dev/null || true)"
        [ -n "$REMOTE_MSG_ID" ] && break
    done
    if [ -n "$REMOTE_MSG_ID" ]; then
        fetch message-remote-images-envelope.json "$API/messages/$REMOTE_MSG_ID"
        fetch message-html-remote-images.html "$API/messages/$REMOTE_MSG_ID/html?plain=true" raw
    else
        echo "  (remote-images message never arrived — its html and envelope not recorded)"
    fi
fi

echo "-- S/MIME certificates (multipart; a throwaway self-signed certificate)"
if command -v openssl >/dev/null 2>&1; then
    CERT_DIR="$(mktemp -d)"
    openssl req -x509 -newkey rsa:2048 -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
        -days 2 -nodes -subj "/CN=Fixture User/emailAddress=$SELF_EMAIL" >/dev/null 2>&1
    post_multipart smime-certificate-created.json "$API/smime/certificates" \
        -F "certificate=@$CERT_DIR/cert.pem" -F "privateKey=@$CERT_DIR/key.pem"
    CERT_ID="$(jq -r '.id // .data.id // empty' < "$OUT/smime-certificate-created.json" 2>/dev/null || true)"
    fetch smime-certificates.json "$API/smime/certificates"
    if [ -n "$CERT_ID" ]; then
        req PUT account-smime-certificate.json "$API/accounts/$ACCOUNT_ID/smime-certificate" "{\"smimeCertificateId\":$CERT_ID}"
        quiet PUT "$API/accounts/$ACCOUNT_ID/smime-certificate" '{"smimeCertificateId":null}'
        req DELETE smime-certificate-deleted.json "$API/smime/certificates/$CERT_ID"
    fi
    rm -rf "$CERT_DIR"
else
    fetch smime-certificates.json "$API/smime/certificates"
    echo "  (openssl not found — certificate import/link/delete not recorded)"
fi

echo "-- preferences, trusted senders, internal addresses"
req PUT preference-saved.json "$API/preferences/sort-order" '{"key":"sort-order","value":"newest"}'
req PUT trusted-sender-added.json "$API/trustedsenders/example.org?type=domain"
# WS-21: the list with one domain and one individual entry, so both kinds the mirror
# keeps apart are in a recording. The individual is in another domain on purpose: the
# server leaves an address out of the listing while its domain is trusted (measured).
# Scratch entries, removed straight after.
quiet PUT "$API/trustedsenders/$(urlencode "fixture-sender@example.net")?type=individual"
fetch trustedsenders-populated.json "$API/trustedsenders"
quiet DELETE "$API/trustedsenders/$(urlencode "fixture-sender@example.net")?type=individual"
req DELETE trusted-sender-removed.json "$API/trustedsenders/example.org?type=domain"
fetch internal-addresses.json "$API/internalAddress"
req PUT internal-address-created.json "$API/internalAddress/example.org?type=domain"
fetch internal-addresses-populated.json "$API/internalAddress"
req DELETE internal-address-deleted.json "$API/internalAddress/example.org?type=domain"

echo "-- sieve, filters, out of office (ManageSieve is off on the test server; errors are the honest shape)"
req PUT sieve-account-updated.json "$API/sieve/account/$ACCOUNT_ID" '{"sieveEnabled":false,"sieveHost":"","sievePort":4190,"sieveUser":"","sievePassword":"","sieveSslMode":"none"}'
fetch sieve-active.json "$API/sieve/active/$ACCOUNT_ID"
# A 422 needs ManageSieve on, which the test server's account is not. Scratch
# lifecycle (ADR-0080): enable it against the account's own IMAP host with
# an empty sieveUser (the server then reuses the IMAP credentials), send one
# script that does not parse, and switch it off again whatever happened.
SIEVE_HOST="$(rawget "$API/accounts" | jq -r --argjson id "$ACCOUNT_ID" '.[] | select(.id == $id) | .imapHost // empty' 2>/dev/null || true)"
if [ -n "$SIEVE_HOST" ] && nc -z -G 5 "$SIEVE_HOST" 4190 >/dev/null 2>&1; then
    quiet PUT "$API/sieve/account/$ACCOUNT_ID" "{\"sieveEnabled\":true,\"sieveHost\":\"$SIEVE_HOST\",\"sievePort\":4190,\"sieveUser\":\"\",\"sievePassword\":\"\",\"sieveSslMode\":\"tls\"}"
    req PUT error-sieve-script-422.json "$API/sieve/active/$ACCOUNT_ID" '{"script":"require [\"fileinto\"];\nthis is not sieve;\n"}'
    # WS-21: what the server-state mirror reads from an account with Sieve on — the
    # account entry carrying the Sieve settings, the active script, the parsed filters and
    # the out-of-office state.
    fetch accounts-sieve-enabled.json "$API/accounts"
    fetch sieve-active-enabled.json "$API/sieve/active/$ACCOUNT_ID"
    fetch filters-enabled.json "$API/filter/$ACCOUNT_ID"
    fetch out-of-office-enabled.json "$API/out-of-office/$ACCOUNT_ID"
    quiet PUT "$API/sieve/account/$ACCOUNT_ID" '{"sieveEnabled":false,"sieveHost":"","sievePort":4190,"sieveUser":"","sievePassword":"","sieveSslMode":"none"}'
else
    echo "  (no ManageSieve on the account's IMAP host — error-sieve-script-422.json not recorded)"
fi
# Both filter routes answer an HTTP 500 HTML page on this server (uncaught
# exception when ManageSieve is disabled) — recorded under names that say so.
fetch error-filter-500.html "$API/filter/$ACCOUNT_ID" raw
req PUT error-filter-put-500.html "$API/filter/$ACCOUNT_ID" '{"filters":[]}'
fetch out-of-office.json "$API/out-of-office/$ACCOUNT_ID"
post out-of-office-updated.json "$API/out-of-office/$ACCOUNT_ID" '{"enabled":false,"start":null,"end":null,"subject":"","message":""}'
post out-of-office-follow-system.json "$API/out-of-office/$ACCOUNT_ID/follow-system" '{}'

echo "-- follow-up reminders"
post follow-up-check.json "$API/follow-up/check-message-ids" "{\"messageIds\":$KNOWN_IDS}"

echo "-- quick actions"
post quick-action-created.json "$API/quick-actions" "{\"name\":\"Fixture action\",\"accountId\":$ACCOUNT_ID}"
QA_ID="$(jq -r '.id // .data.id // empty' < "$OUT/quick-action-created.json" 2>/dev/null || true)"
if [ -n "$QA_ID" ]; then
    post action-step-created.json "$API/action-step" "{\"name\":\"markAsRead\",\"order\":1,\"actionId\":$QA_ID}"
    STEP_ID="$(jq -r '.id // .data.id // empty' < "$OUT/action-step-created.json" 2>/dev/null || true)"
    if [ -n "$STEP_ID" ]; then
        req PUT action-step-updated.json "$API/action-step/$STEP_ID" '{"name":"markAsUnread","order":1}'
    fi
    req PUT quick-action-updated.json "$API/quick-actions/$QA_ID" '{"name":"Fixture action renamed"}'
    fetch quick-actions.json "$API/quick-actions"
    if [ -n "$STEP_ID" ]; then
        req DELETE action-step-deleted.json "$API/action-step/$STEP_ID"
    fi
    req DELETE quick-action-deleted.json "$API/quick-actions/$QA_ID"
else
    fetch quick-actions.json "$API/quick-actions"
    echo "  (quick-action lifecycle skipped — create returned no id)"
fi

echo "-- text blocks"
post text-block-created.json "$API/textBlocks" '{"title":"Fixture block","content":"Recorded by the fixture recorder."}'
TB_ID="$(jq -r '.id // .data.id // empty' < "$OUT/text-block-created.json" 2>/dev/null || true)"
if [ -n "$TB_ID" ]; then
    req PUT text-block-updated.json "$API/textBlocks/$TB_ID" '{"title":"Fixture block renamed","content":"Updated content."}'
    post text-block-share-created.json "$API/textBlockshares" "{\"textBlockId\":$TB_ID,\"shareWith\":\"admin\",\"type\":\"group\"}"
    fetch text-block-shares.json "$API/textBlocks/$TB_ID/shares"
    fetch text-blocks.json "$API/textBlocks"
    fetch text-block-shares-all.json "$API/textBlockshares"
    req DELETE text-block-share-deleted.json "$API/textBlockshares/$TB_ID?shareWith=admin"
    req DELETE text-block-deleted.json "$API/textBlocks/$TB_ID"
else
    fetch text-blocks.json "$API/textBlocks"
    echo "  (text-block lifecycle skipped — create returned no id)"
fi

echo "-- delegation (a second server user; self-delegation for the refusal)"
# The server refuses self-delegation — that refusal is its own fixture.
post error-delegation-self.json "$API/delegations/$ACCOUNT_ID" "{\"userId\":\"$LOGIN\"}"
DELEGATE="$(rawget "$SERVER/ocs/v2.php/cloud/users" | jq -r --arg me "$LOGIN" '[.ocs.data.users[]? | select(. != $me)][0] // empty' 2>/dev/null || true)"
if [ -n "$DELEGATE" ]; then
    # A grant left by a dead run would make the create collide.
    quiet DELETE "$API/delegations/$ACCOUNT_ID/$DELEGATE"
    post delegation-created.json "$API/delegations/$ACCOUNT_ID" "{\"userId\":\"$DELEGATE\"}"
    fetch delegations.json "$API/delegations/$ACCOUNT_ID"
    req DELETE delegation-deleted.json "$API/delegations/$ACCOUNT_ID/$DELEGATE"
else
    fetch delegations.json "$API/delegations/$ACCOUNT_ID"
    echo "  (delegation lifecycle skipped — no second user on this server)"
fi

echo "-- oauth state"
post oauth-state.json "$API/oauth/state" "{\"accountId\":$ACCOUNT_ID}"
# The state token is a signed secret; the shape is the fixture, the value is not.
OAUTH_TMP="$(mktemp)"
sed -E 's#"state": *"[^"]*"#"state": "REDACTED"#' "$OUT/oauth-state.json" > "$OAUTH_TMP" && mv "$OAUTH_TMP" "$OUT/oauth-state.json"

# ---------------------------------------------------------------------------
# CardDAV / CalDAV (WS-17).
#
# The .vcf and .ics fixtures are byte-precise: WS-17's round-trip tests parse
# and re-serialise them and compare bytes, so they pass through scrub_identity
# only (plain sed, real identity only, server line folding preserved — no jq,
# no tracking pass, no blanket address rewrite). The recorder assumes the
# default addressbook holds the two
# non-trivial contacts named *alice* and *bob* and the default calendar holds
# a *standup* event and a *todo* task — synthetic objects, kept on the test
# server precisely so this script can re-record them.
# ---------------------------------------------------------------------------

echo "-- DAV: principal discovery"
DAVROOT="$SERVER/remote.php/dav"
dav dav-current-user-principal.xml PROPFIND "$DAVROOT/" 0 \
    '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:current-user-principal/></d:prop></d:propfind>'
dav dav-principal-home-sets.xml PROPFIND "$DAVROOT/principals/users/$LOGIN/" 0 \
    '<?xml version="1.0"?><d:propfind xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav" xmlns:cal="urn:ietf:params:xml:ns:caldav"><d:prop><d:displayname/><card:addressbook-home-set/><cal:calendar-home-set/></d:prop></d:propfind>'
dav dav-addressbooks-depth1.xml PROPFIND "$DAVROOT/addressbooks/users/$LOGIN/" 1 \
    '<?xml version="1.0"?><d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/" xmlns:card="urn:ietf:params:xml:ns:carddav"><d:prop><d:resourcetype/><d:displayname/><cs:getctag/><d:sync-token/><card:supported-address-data/></d:prop></d:propfind>'

echo "-- DAV: sync-collection (temp contacts arrange one changed and one removed entry)"
AB_URL="$DAVROOT/addressbooks/users/$LOGIN/contacts"
V_REMOVED="$(printf 'BEGIN:VCARD\r\nVERSION:3.0\r\nUID:ws19-temp-removed\r\nFN:WS19 Temp Removed\r\nEMAIL;TYPE=HOME:temp-removed@example.org\r\nEND:VCARD\r\n')"
V_CHANGED="$(printf 'BEGIN:VCARD\r\nVERSION:3.0\r\nUID:ws19-temp-changed\r\nFN:WS19 Temp Changed\r\nEMAIL;TYPE=WORK:temp-changed@example.org\r\nEND:VCARD\r\n')"
rawdav PUT "$AB_URL/ws19-temp-removed.vcf" '' "$V_REMOVED" 'text/vcard; charset=utf-8' >/dev/null
SYNC_PROPS='<d:sync-level>1</d:sync-level><d:prop><d:getetag/></d:prop>'
dav dav-sync-initial.xml REPORT "$AB_URL/" 0 \
    '<?xml version="1.0"?><d:sync-collection xmlns:d="DAV:"><d:sync-token/>'"$SYNC_PROPS"'</d:sync-collection>'
SYNC_TOKEN="$(grep -o '<d:sync-token>[^<]*</d:sync-token>' "$OUT/dav-sync-initial.xml" | head -1 | sed -E 's#</?d:sync-token>##g' || true)"
dav_headers dav-put-contact-response.txt PUT "$AB_URL/ws19-temp-changed.vcf" "$V_CHANGED" 'text/vcard; charset=utf-8'
rawdav DELETE "$AB_URL/ws19-temp-removed.vcf" >/dev/null
if [ -n "$SYNC_TOKEN" ]; then
    dav dav-sync-incremental.xml REPORT "$AB_URL/" 0 \
        '<?xml version="1.0"?><d:sync-collection xmlns:d="DAV:"><d:sync-token>'"$SYNC_TOKEN"'</d:sync-token>'"$SYNC_PROPS"'</d:sync-collection>'
else
    echo "  (dav-sync-incremental skipped — no sync token in the initial response)"
fi
# Truncation: sabre answers HTTP 207 whose last d:response carries an inline
# "HTTP/1.1 507 Insufficient Storage" status plus a valid sync-token — the
# top-level status does NOT become 507.
dav dav-sync-truncated.xml REPORT "$AB_URL/" 0 \
    '<?xml version="1.0"?><d:sync-collection xmlns:d="DAV:"><d:sync-token/>'"$SYNC_PROPS"'<d:limit><d:nresults>1</d:nresults></d:limit></d:sync-collection>'
rawdav DELETE "$AB_URL/ws19-temp-changed.vcf" >/dev/null

echo "-- DAV: contacts (verbatim vCards and multiget)"
VCF_HREFS="$(rawdav PROPFIND "$AB_URL/" 1 '<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></d:propfind>' | grep -o '<d:href>[^<]*\.vcf</d:href>' | sed -E 's#</?d:href>##g' || true)"
ALICE_HREF="$(printf '%s\n' "$VCF_HREFS" | grep -i alice | head -1 || true)"
BOB_HREF="$(printf '%s\n' "$VCF_HREFS" | grep -i bob | head -1 || true)"
[ -n "$ALICE_HREF" ] || ALICE_HREF="$(printf '%s\n' "$VCF_HREFS" | sed -n 1p)"
[ -n "$BOB_HREF" ] || BOB_HREF="$(printf '%s\n' "$VCF_HREFS" | sed -n 2p)"
if [ -n "$ALICE_HREF" ] && [ -n "$BOB_HREF" ]; then
    dav contact-alice.vcf GET "$SERVER$ALICE_HREF"
    dav contact-bob.vcf GET "$SERVER$BOB_HREF"
    dav dav-addressbook-multiget.xml REPORT "$AB_URL/" 1 \
        '<?xml version="1.0"?><card:addressbook-multiget xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav"><d:prop><d:getetag/><card:address-data/></d:prop><d:href>'"$ALICE_HREF"'</d:href><d:href>'"$BOB_HREF"'</d:href></card:addressbook-multiget>'
else
    echo "  (contacts skipped — fewer than two .vcf in $AB_URL)"
fi

echo "-- DAV: calendars"
CAL_HOME="$DAVROOT/calendars/$LOGIN"
dav dav-calendars-depth1.xml PROPFIND "$CAL_HOME/" 1 \
    '<?xml version="1.0"?><d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/" xmlns:cal="urn:ietf:params:xml:ns:caldav"><d:prop><d:resourcetype/><d:displayname/><cs:getctag/><d:sync-token/><cal:supported-calendar-component-set/></d:prop></d:propfind>'

echo "-- DAV: WS-24 listings (the properties ContactsSync and CalendarListSync request)"
# Exactly the PROPFIND bodies NCMailSync sends, so a parse test reads what the
# sync reads. A scratch book is created first and disabled (oc:enabled=0), so
# the listing carries a disabled book next to the read-only, system-owned
# "Accounts" book; deleted right after.
WS24_AB_PROPS='<d:prop><d:resourcetype/><d:displayname/><d:sync-token/><d:current-user-privilege-set/><o:enabled/><o:read-only/><o:owner-principal/></d:prop>'
WS24_TMP_AB="$DAVROOT/addressbooks/users/$LOGIN/ws24-temp-disabled"
rawdav MKCOL "$WS24_TMP_AB/" '' '<?xml version="1.0"?><d:mkcol xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav"><d:set><d:prop><d:resourcetype><d:collection/><card:addressbook/></d:resourcetype><d:displayname>WS24 Temp Disabled</d:displayname></d:prop></d:set></d:mkcol>' >/dev/null
rawdav PROPPATCH "$WS24_TMP_AB/" '' '<?xml version="1.0"?><d:propertyupdate xmlns:d="DAV:" xmlns:o="http://owncloud.org/ns"><d:set><d:prop><o:enabled>0</o:enabled></d:prop></d:set></d:propertyupdate>' >/dev/null
dav dav-addressbooks-ws24.xml PROPFIND "$DAVROOT/addressbooks/users/$LOGIN/" 1 \
    '<?xml version="1.0"?><d:propfind xmlns:d="DAV:" xmlns:o="http://owncloud.org/ns">'"$WS24_AB_PROPS"'</d:propfind>'
rawdav DELETE "$WS24_TMP_AB/" >/dev/null
dav dav-calendars-ws24.xml PROPFIND "$CAL_HOME/" 1 \
    '<?xml version="1.0"?><d:propfind xmlns:d="DAV:" xmlns:o="http://owncloud.org/ns" xmlns:cal="urn:ietf:params:xml:ns:caldav" xmlns:a="http://apple.com/ns/ical/"><d:prop><d:resourcetype/><d:displayname/><d:current-user-privilege-set/><cal:supported-calendar-component-set/><a:calendar-color/><a:calendar-order/><o:read-only/><o:owner-principal/></d:prop></d:propfind>'
# Nextcloud answers schedule-default-calendar-URL on the principal, not on the
# schedule inbox where RFC 6638 puts it (measured: the inbox answers 404).
dav dav-principal-schedule-default.xml PROPFIND "$DAVROOT/principals/users/$LOGIN/" 0 \
    '<?xml version="1.0"?><d:propfind xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav"><d:prop><cal:schedule-default-calendar-URL/></d:prop></d:propfind>'

echo "-- DAV: WS-24 concurrent-edit lifecycle (scratch book ws24-temp-merge, deleted after)"
# One card PUT three times, as a second client would: the base, then a different-field edit
# (TEL), then a same-field edit (EMAIL). Each version is captured by a one-href multiget —
# the request the 412 recovery sends — so the merge tests run on server-normalised text.
# The empty book's first sync-collection is the "nothing in here" answer.
WS24_MERGE_AB="$DAVROOT/addressbooks/users/$LOGIN/ws24-temp-merge"
WS24_CARD="$WS24_MERGE_AB/ws24-merge.vcf"
WS24_CARD_HREF="${WS24_CARD#$SERVER}"
WS24_MULTIGET='<?xml version="1.0"?><card:addressbook-multiget xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav"><d:prop><d:getetag/><card:address-data/></d:prop><d:href>'"$WS24_CARD_HREF"'</d:href></card:addressbook-multiget>'
rawdav MKCOL "$WS24_MERGE_AB/" '' '<?xml version="1.0"?><d:mkcol xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav"><d:set><d:prop><d:resourcetype><d:collection/><card:addressbook/></d:resourcetype><d:displayname>WS24 Temp Merge</d:displayname></d:prop></d:set></d:mkcol>' >/dev/null
dav dav-sync-empty.xml REPORT "$WS24_MERGE_AB/" 0 \
    '<?xml version="1.0"?><d:sync-collection xmlns:d="DAV:"><d:sync-token/>'"$SYNC_PROPS"'</d:sync-collection>'
rawdav PUT "$WS24_CARD" '' "$(printf 'BEGIN:VCARD\r\nVERSION:3.0\r\nUID:ws24-merge\r\nFN:WS24 Merge\r\nN:Merge;WS24;;;\r\nEMAIL;TYPE=WORK:merge-base@example.org\r\nTEL;TYPE=CELL:+1 555 0100\r\nNOTE:base\r\nEND:VCARD\r\n')" 'text/vcard; charset=utf-8' >/dev/null
dav dav-ws24-merge-base.xml REPORT "$WS24_MERGE_AB/" 1 "$WS24_MULTIGET"
# A book without a sync-token ("Recently contacted" answers sync-collection with 415
# ReportNotSupported) is mirrored from a Depth-1 ETag listing; this is that listing's shape.
dav dav-ws24-merge-etags.xml PROPFIND "$WS24_MERGE_AB/" 1 \
    '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></d:propfind>'
rawdav PUT "$WS24_CARD" '' "$(printf 'BEGIN:VCARD\r\nVERSION:3.0\r\nUID:ws24-merge\r\nFN:WS24 Merge\r\nN:Merge;WS24;;;\r\nEMAIL;TYPE=WORK:merge-base@example.org\r\nTEL;TYPE=CELL:+1 555 0199\r\nNOTE:base\r\nEND:VCARD\r\n')" 'text/vcard; charset=utf-8' >/dev/null
dav dav-ws24-merge-server-tel.xml REPORT "$WS24_MERGE_AB/" 1 "$WS24_MULTIGET"
rawdav PUT "$WS24_CARD" '' "$(printf 'BEGIN:VCARD\r\nVERSION:3.0\r\nUID:ws24-merge\r\nFN:WS24 Merge\r\nN:Merge;WS24;;;\r\nEMAIL;TYPE=WORK:merge-web@example.org\r\nTEL;TYPE=CELL:+1 555 0199\r\nNOTE:base\r\nEND:VCARD\r\n')" 'text/vcard; charset=utf-8' >/dev/null
dav dav-ws24-merge-server-email.xml REPORT "$WS24_MERGE_AB/" 1 "$WS24_MULTIGET"
dav dav-ws24-merge-sync.xml REPORT "$WS24_MERGE_AB/" 0 \
    '<?xml version="1.0"?><d:sync-collection xmlns:d="DAV:"><d:sync-token/>'"$SYNC_PROPS"'</d:sync-collection>'
# A token the server never issued: 403 + Sabre\DAV\Exception\InvalidSyncToken (measured).
dav dav-error-invalid-sync-token.xml REPORT "$WS24_MERGE_AB/" 0 \
    '<?xml version="1.0"?><d:sync-collection xmlns:d="DAV:"><d:sync-token>ws24-not-a-token</d:sync-token>'"$SYNC_PROPS"'</d:sync-collection>'
rawdav DELETE "$WS24_MERGE_AB/" >/dev/null
CAL_URL="$CAL_HOME/personal"
ICS_HREFS="$(rawdav PROPFIND "$CAL_URL/" 1 '<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></d:propfind>' | grep -o '<d:href>[^<]*\.ics</d:href>' | sed -E 's#</?d:href>##g' || true)"
STANDUP_HREF="$(printf '%s\n' "$ICS_HREFS" | grep -i standup | head -1 || true)"
# The task may live in its own VTODO-only calendar; search every calendar in
# the home, the personal one first.
TODO_HREF="$(printf '%s\n' "$ICS_HREFS" | grep -iE 'todo|task' | head -1 || true)"
if [ -z "$TODO_HREF" ]; then
    for CAL_HREF in $(grep -o '<d:href>[^<]*/</d:href>' "$OUT/dav-calendars-depth1.xml" | sed -E 's#</?d:href>##g; s#^/remote.php/dav/calendars/user/##' | grep -vE '^$|^(personal|inbox|outbox|trashbin|contact_birthdays)/$' || true); do
        TODO_HREF="$(rawdav PROPFIND "$CAL_HOME/$CAL_HREF" 1 '<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></d:propfind>' | grep -o '<d:href>[^<]*\.ics</d:href>' | sed -E 's#</?d:href>##g' | grep -iE 'todo|task' | head -1 || true)"
        [ -n "$TODO_HREF" ] && break
    done
fi
[ -n "$STANDUP_HREF" ] || STANDUP_HREF="$(printf '%s\n' "$ICS_HREFS" | sed -n 1p)"
if [ -n "$STANDUP_HREF" ]; then
    dav event-standup.ics GET "$SERVER$STANDUP_HREF"
    CMG_HREFS="<d:href>$STANDUP_HREF</d:href>"
    if [ -n "$TODO_HREF" ]; then
        dav todo-task.ics GET "$SERVER$TODO_HREF"
        # calendar-multiget answers for its own collection only.
        case "$TODO_HREF" in
            "${CAL_URL#$SERVER}"/*) CMG_HREFS="$CMG_HREFS<d:href>$TODO_HREF</d:href>" ;;
        esac
    fi
    dav dav-calendar-multiget.xml REPORT "$CAL_URL/" 1 \
        '<?xml version="1.0"?><cal:calendar-multiget xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/><cal:calendar-data/></d:prop>'"$CMG_HREFS"'</cal:calendar-multiget>'
else
    echo "  (calendar objects skipped — no .ics in $CAL_URL)"
fi
# The personal calendar accepts VEVENT and VTODO; a VJOURNAL PUT records the
# supported-calendar-component precondition error body.
dav dav-error-invalid-component.xml PUT "$CAL_URL/ws19-journal.ics" '' \
    "$(printf 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//WS19//EN\r\nBEGIN:VJOURNAL\r\nUID:ws19-journal\r\nDTSTAMP:20260101T000000Z\r\nSUMMARY:Not allowed here\r\nEND:VJOURNAL\r\nEND:VCALENDAR\r\n')" \
    'text/calendar; charset=utf-8'

echo "-- DAV: extended MKCOL, PROPPATCH, oc:share (temp addressbook, deleted after)"
TMP_AB="$DAVROOT/addressbooks/users/$LOGIN/ws19-temp-book"
# MKCOL and the share POST answer 201/200 with empty bodies; the headers are
# the informative part, hence .txt header fixtures like the PUT one above.
dav_headers dav-mkcol-response.txt MKCOL "$TMP_AB/" \
    '<?xml version="1.0"?><d:mkcol xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav"><d:set><d:prop><d:resourcetype><d:collection/><card:addressbook/></d:resourcetype><d:displayname>WS19 Temp Book</d:displayname></d:prop></d:set></d:mkcol>'
dav dav-proppatch.xml PROPPATCH "$TMP_AB/" '' \
    '<?xml version="1.0"?><d:propertyupdate xmlns:d="DAV:"><d:set><d:prop><d:displayname>WS19 Temp Book Renamed</d:displayname></d:prop></d:set></d:propertyupdate>'
dav_headers dav-share-response.txt POST "$TMP_AB/" \
    '<?xml version="1.0"?><o:share xmlns:d="DAV:" xmlns:o="http://owncloud.org/ns"><o:set><d:href>principal:principals/groups/admin</d:href><o:summary>WS19 fixture share</o:summary><o:read-only/></o:set></o:share>'
rawdav DELETE "$TMP_AB/" >/dev/null

echo "-- contact integration (after the DAV sync fixtures, so the new contact cannot pollute them)"
fetch autocomplete.json "$API/autoComplete?term=a"
fetch contact-autocomplete.json "$API/contactIntegration/autoComplete/a"
ALICE_MAIL="$(rawdav GET "${ALICE_HREF:+$SERVER$ALICE_HREF}" | grep -i '^EMAIL' | head -1 | sed 's/.*://' | tr -d '\r' || true)"
fetch contact-match.json "$API/contactIntegration/match/$(urlencode "${ALICE_MAIL:-user@example.com}")"
req PUT contact-created.json "$API/contactIntegration/new" '{"contactName":"WS19 Fixture","mail":"ws19-fixture@example.org"}'
# The UID comes from the raw response: the scrubbed fixture's UID is TRACKINGID.
NEW_UID="$(jq -r '.. | objects | .UID? // .uid? // empty' < "$LAST_RAW" 2>/dev/null | head -1 || true)"
if [ -n "$NEW_UID" ]; then
    req PUT contact-added-email.json "$API/contactIntegration/add" "{\"uid\":\"$NEW_UID\",\"mail\":\"ws19-extra@example.org\"}"
    # Best-effort cleanup through CardDAV; the contact lands in the default book.
    NEW_HREF="$(rawdav PROPFIND "$AB_URL/" 1 '<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></d:propfind>' | grep -o "<d:href>[^<]*$NEW_UID[^<]*</d:href>" | sed -E 's#</?d:href>##g' | head -1 || true)"
    if [ -n "$NEW_HREF" ]; then
        rawdav DELETE "$SERVER$NEW_HREF" >/dev/null
    fi
fi

# ---------------------------------------------------------------------------
# OCS: the Mail OCS surface plus the non-Mail integrations WS-16 must confirm.
# Absent apps and disabled providers answer errors; those bodies ARE the
# fixture — the client decodes exactly this when the server lacks the feature.
# ---------------------------------------------------------------------------

echo "-- OCS"
OCSAPI="$SERVER/ocs/v2.php"
fetch ocs-account-list.json "$OCSAPI/apps/mail/account/list"
fetch ocs-mailboxes.json "$OCSAPI/apps/mail/ocs/mailboxes?accountId=$ACCOUNT_ID"
fetch ocs-messages.json "$OCSAPI/apps/mail/ocs/mailboxes/$MAILBOX_ID/messages?limit=10&view=singleton"
# Direct SMTP send — to the account's own address, per the standing rule.
post ocs-message-sent.json "$OCSAPI/apps/mail/message/send" \
    "{\"accountId\":$ACCOUNT_ID,\"fromEmail\":\"$SELF_EMAIL\",\"subject\":\"Fixture OCS send\",\"body\":\"Recorded by the fixture recorder.\",\"isHtml\":false,\"to\":[{\"label\":\"Self\",\"email\":\"$SELF_EMAIL\"}]}"
fetch references-providers.json "$OCSAPI/references/providers"
fetch picker-search-files.json "$OCSAPI/search/providers/files/search?term=fixture"
fetch notifications.json "$OCSAPI/apps/notifications/api/v2/notifications"
fetch translation-languages.json "$OCSAPI/translation/languages"
post translation-translate.json "$OCSAPI/translation/translate" '{"text":"Hello","fromLanguage":null,"toLanguage":"de"}'
fetch taskprocessing-tasktypes.json "$OCSAPI/taskprocessing/tasktypes"
fetch circles.json "$OCSAPI/apps/circles/circles"

echo "-- OCS: share link (first file in the account's root, unshared afterwards)"
FILE_HREF="$(rawdav PROPFIND "$DAVROOT/files/$LOGIN/" 1 '<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>' | grep -o '<d:href>[^<]*</d:href>' | sed -E 's#</?d:href>##g' | grep -v '/$' | head -1 || true)"
if [ -n "$FILE_HREF" ]; then
    FILE_PATH="$(printf '%s' "${FILE_HREF#/remote.php/dav/files/$LOGIN}" | sed 's/%20/ /g')"
    post share-link-created.json "$OCSAPI/apps/files_sharing/api/v1/shares" "{\"path\":\"$FILE_PATH\",\"shareType\":3}"
    SHARE_ID="$(jq -r '.ocs.data.id // empty' < "$OUT/share-link-created.json" 2>/dev/null || true)"
    if [ -n "$SHARE_ID" ]; then
        req DELETE share-link-deleted.json "$OCSAPI/apps/files_sharing/api/v1/shares/$SHARE_ID"
    fi
else
    echo "  (share link skipped — no file found in the root folder)"
fi

echo
echo "Done. Before committing:"
echo "  1. grep the fixtures for your real domain and your real addresses."
echo "  2. Skim message-body.json — content is kept unless --scrub-content was passed."
echo "  3. Note the app version this was recorded against in the pull request."
