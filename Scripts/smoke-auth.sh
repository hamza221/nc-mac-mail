#!/usr/bin/env bash
# SPDX-FileCopyrightText: Hamza Mahjoubi
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Step 0 of WS-01: prove that an app password over HTTP Basic, plus the
# OCS-APIRequest header, is accepted by the Mail app's non-OCS routes.
#
# A JSON array of accounts means the plan in ADR-0002 holds.
# A 412 or a CSRF error means authentication has to change shape, and WS-01
# should stop and report rather than improvise.
#
#   Scripts/smoke-auth.sh https://cloud.example.com alice 'app-password'

set -euo pipefail

if [ $# -ne 3 ]; then
    echo "usage: $0 <server-url> <login-name> <app-password>" >&2
    exit 64
fi

SERVER="${1%/}"
LOGIN="$2"
PASSWORD="$3"

request() {
    # $1 label, $2 url
    printf '\n\033[1m%s\033[0m\n  %s\n' "$1" "$2"
    local status body
    body="$(mktemp)"
    status="$(curl -sS -o "$body" -w '%{http_code}' \
        -u "$LOGIN:$PASSWORD" \
        -H 'OCS-APIRequest: true' \
        -H 'Accept: application/json' \
        -H 'User-Agent: Nextcloud Mail (macOS)/smoke' \
        "$2" || true)"
    printf '  HTTP %s\n' "$status"
    if command -v jq >/dev/null 2>&1; then
        jq -C '.' < "$body" 2>/dev/null | head -40 || head -c 600 < "$body"
    else
        head -c 600 < "$body"
    fi
    printf '\n'
    rm -f "$body"
    LAST_STATUS="$status"
}

request "1. Capabilities (theming colour for NCBrand)" \
    "$SERVER/ocs/v2.php/cloud/capabilities"

request "2. Mail accounts — THE test" \
    "$SERVER/index.php/apps/mail/api/accounts"
ACCOUNTS_STATUS="$LAST_STATUS"

printf '\n\033[1mVerdict\033[0m\n'
case "$ACCOUNTS_STATUS" in
    200)
        printf '  OK. App-password auth works against the Mail API.\n'
        printf '  Paste this output into the WS-01 pull request.\n'
        ;;
    401)
        printf '  Unauthorized. Wrong login name or app password, or the app\n'
        printf '  password was revoked. Not a CSRF problem.\n'
        exit 1
        ;;
    412|403)
        printf '  CSRF or precondition failure. ADR-0002 does NOT hold on this\n'
        printf '  instance. STOP: report this before writing Swift. The fallback\n'
        printf '  is a session cookie plus a scraped requesttoken, which reshapes\n'
        printf '  WS-01, WS-02 and the security model.\n'
        exit 1
        ;;
    404)
        printf '  Not found. Is the Mail app installed and enabled on this\n'
        printf '  instance, and is the server URL right (including any path prefix)?\n'
        exit 1
        ;;
    *)
        printf '  Unexpected status %s. Investigate before proceeding.\n' "$ACCOUNTS_STATUS"
        exit 1
        ;;
esac
