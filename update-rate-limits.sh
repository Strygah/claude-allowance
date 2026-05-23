#!/bin/bash
# Lightweight rate-limit updater — called by Claude Code PostToolUse hook
# Makes a cheap Haiku call just to read rate-limit headers, writes JSON cache

CACHE="$HOME/.claude/rate-limits.json"
TOKEN_FILE="$HOME/.claude/usage-bar/api-token"

# Skip if updated <30s ago (avoid hammering on rapid tool calls)
if [[ -f "$CACHE" ]]; then
    now=$(date +%s)
    mod=$(stat -f %m "$CACHE" 2>/dev/null || echo 0)
    if (( now - mod < 30 )); then
        exit 0
    fi
fi

# Read token
TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null | tr -d '[:space:]')
[[ -z "$TOKEN" ]] && exit 0

# One cheap API call — we only care about response headers
HEADERS=$(curl -s -D - -o /dev/null -m 5 \
    -X POST https://api.anthropic.com/v1/messages \
    -H "x-api-key: $TOKEN" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"x"}]}' \
    2>/dev/null)

# If 401, try refreshing token from keychain (one-shot, no prompt)
if echo "$HEADERS" | grep -q "HTTP.*401"; then
    NEW_TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | \
        python3 -c "import sys,json; print(json.loads(sys.stdin.read())['claudeAiOauth']['accessToken'])" 2>/dev/null)
    if [[ -n "$NEW_TOKEN" && "$NEW_TOKEN" != "$TOKEN" ]]; then
        echo -n "$NEW_TOKEN" > "$TOKEN_FILE"
        HEADERS=$(curl -s -D - -o /dev/null -m 5 \
            -X POST https://api.anthropic.com/v1/messages \
            -H "x-api-key: $NEW_TOKEN" \
            -H "anthropic-version: 2023-06-01" \
            -H "content-type: application/json" \
            -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"x"}]}' \
            2>/dev/null)
    fi
fi

# Parse headers
FH=$(echo "$HEADERS" | grep -i "anthropic-ratelimit-unified-5h-utilization" | tr -d '\r' | awk '{print $2}')
SD=$(echo "$HEADERS" | grep -i "anthropic-ratelimit-unified-7d-utilization" | tr -d '\r' | awk '{print $2}')

[[ -z "$FH" && -z "$SD" ]] && exit 0

# Parse reset timestamps
FH_RESET=$(echo "$HEADERS" | grep -i "anthropic-ratelimit-unified-5h-reset" | tr -d '\r' | awk '{print $2}')
SD_RESET=$(echo "$HEADERS" | grep -i "anthropic-ratelimit-unified-7d-reset" | tr -d '\r' | awk '{print $2}')

# Convert to percentage
FH_PCT=$(python3 -c "print(max(float('${FH:-0}') * 100, 0))" 2>/dev/null || echo 0)
SD_PCT=$(python3 -c "print(max(float('${SD:-0}') * 100, 0))" 2>/dev/null || echo 0)
NOW=$(python3 -c "import time; print(time.time())")

# Write cache
cat > "$CACHE" <<JSONEOF
{"five_hour":${FH_PCT},"seven_day":${SD_PCT},"five_hour_reset":${FH_RESET:-0},"seven_day_reset":${SD_RESET:-0},"timestamp":${NOW}}
JSONEOF
