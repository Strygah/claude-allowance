#!/bin/bash
# Rate-limit updater. Run by a LaunchAgent every 60s (independent of Claude
# Code activity). Reads the OAuth token, makes a cheap Haiku call to read the
# ratelimit headers, writes JSON cache that ClaudeUsageBar.app renders.
#
# Self-bootstrapping: pulls the token from the Claude Code keychain item when
# the api-token file is missing or returns 401. `security` reads the keychain
# silently from any context (it's Apple-signed and in the item's ACL), so this
# works fine from launchd without a password prompt.

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

CACHE="$HOME/.claude/rate-limits.json"
TOKEN_FILE="$HOME/.claude/usage-bar/api-token"
MODEL="claude-haiku-4-5-20251001"

# Pull access token from keychain → api-token file. Silent from any context.
refresh_token_from_keychain() {
    local t
    t=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | \
        /usr/bin/python3 -c "import sys,json; print(json.loads(sys.stdin.read())['claudeAiOauth']['accessToken'])" 2>/dev/null)
    [[ -z "$t" ]] && return 1
    printf '%s' "$t" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    printf '%s' "$t"
}

# OAuth subscription tokens (sk-ant-oat-*) need Bearer auth +
# anthropic-beta: oauth-2025-04-20. x-api-key returns silent 401.
fetch_headers() {
    local token="$1"
    curl -s -D - -o /dev/null -m 5 \
        -X POST https://api.anthropic.com/v1/messages \
        -H "Authorization: Bearer $token" \
        -H "anthropic-version: 2023-06-01" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "content-type: application/json" \
        -d "{\"model\":\"$MODEL\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"x\"}]}" \
        2>/dev/null
}

# Read token; bootstrap from keychain if the file is empty/missing.
TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null | tr -d '[:space:]')
if [[ -z "$TOKEN" ]]; then
    TOKEN=$(refresh_token_from_keychain) || exit 0
fi

HEADERS=$(fetch_headers "$TOKEN")

# On 401, refresh the token from keychain and retry once.
if echo "$HEADERS" | grep -q "HTTP.*401"; then
    NEW_TOKEN=$(refresh_token_from_keychain) || exit 0
    if [[ -n "$NEW_TOKEN" && "$NEW_TOKEN" != "$TOKEN" ]]; then
        HEADERS=$(fetch_headers "$NEW_TOKEN")
    fi
fi

# Parse utilization headers. 429 also includes them — that's the "you're
# at 100%" signal we want to display.
FH=$(echo "$HEADERS" | grep -i "anthropic-ratelimit-unified-5h-utilization" | tr -d '\r' | awk '{print $2}')
SD=$(echo "$HEADERS" | grep -i "anthropic-ratelimit-unified-7d-utilization" | tr -d '\r' | awk '{print $2}')

[[ -z "$FH" && -z "$SD" ]] && exit 0

FH_RESET=$(echo "$HEADERS" | grep -i "anthropic-ratelimit-unified-5h-reset" | tr -d '\r' | awk '{print $2}')
SD_RESET=$(echo "$HEADERS" | grep -i "anthropic-ratelimit-unified-7d-reset" | tr -d '\r' | awk '{print $2}')

FH_PCT=$(/usr/bin/python3 -c "print(max(float('${FH:-0}') * 100, 0))" 2>/dev/null || echo 0)
SD_PCT=$(/usr/bin/python3 -c "print(max(float('${SD:-0}') * 100, 0))" 2>/dev/null || echo 0)
NOW=$(/usr/bin/python3 -c "import time; print(time.time())")

cat > "$CACHE" <<JSONEOF
{"five_hour":${FH_PCT},"seven_day":${SD_PCT},"five_hour_reset":${FH_RESET:-0},"seven_day_reset":${SD_RESET:-0},"timestamp":${NOW}}
JSONEOF
