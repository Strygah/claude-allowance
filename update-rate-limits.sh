#!/bin/bash
# Lightweight rate-limit updater — called by Claude Code SessionStart +
# PostToolUse hooks. Makes a cheap Haiku call to read the ratelimit
# headers and writes JSON cache that ClaudeUsageBar.app reads.

CACHE="$HOME/.claude/rate-limits.json"
TOKEN_FILE="$HOME/.claude/usage-bar/api-token"
MODEL="claude-haiku-4-5-20251001"

# Skip if updated <30s ago (avoid hammering on rapid tool calls)
if [[ -f "$CACHE" ]]; then
    now=$(date +%s)
    mod=$(stat -f %m "$CACHE" 2>/dev/null || echo 0)
    if (( now - mod < 30 )); then
        exit 0
    fi
fi

# Read token from file (kept fresh by refresh-token.sh on SessionStart;
# this script refreshes it on 401).
TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null | tr -d '[:space:]')
[[ -z "$TOKEN" ]] && exit 0

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

HEADERS=$(fetch_headers "$TOKEN")

# On 401, refresh the file from keychain (silent here — we're in Claude Code's
# process tree which is the keychain item's creator) and retry once.
if echo "$HEADERS" | grep -q "HTTP.*401"; then
    NEW_TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | \
        /usr/bin/python3 -c "import sys,json; print(json.loads(sys.stdin.read())['claudeAiOauth']['accessToken'])" 2>/dev/null)
    if [[ -n "$NEW_TOKEN" && "$NEW_TOKEN" != "$TOKEN" ]]; then
        printf '%s' "$NEW_TOKEN" > "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE"
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
