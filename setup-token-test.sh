#!/bin/bash
# TEMPORARY diagnostic. Compares the rate-limit headers returned by the
# INTERACTIVE keychain token vs a long-lived `claude setup-token` token, to
# decide whether a setup-token is safe to drive the menu bar. The open
# question: does a setup-token report the SAME interactive 5h/7d utilization,
# especially across the 2026-06-15 Agent-SDK billing change (after which
# `claude -p` / Agent-SDK usage draws from a separate monthly credit)?
#
# If int[] and stk[] track each other -> setup-token is safe and would kill the
# 8h-expiry staleness for good. If they diverge -> a setup-token would show the
# wrong bucket, so we keep the keychain token. Revisit setup-token-test.log.
#
# Makes 2 tiny max_tokens:1 calls per run. Remove this + its LaunchAgent
# (com.claude.usage-bar.tokentest) once decided.

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
DIR="$HOME/.claude/usage-bar"
LOG="$DIR/setup-token-test.log"
STK_FILE="$DIR/setup-token"
MODEL="claude-haiku-4-5-20251001"

# $1 = token -> echoes "status|5h|7d|5hreset|7dreset"
probe() {
    local token="$1" h
    [[ -z "$token" ]] && { echo "NOTOKEN|na|na|na|na"; return; }
    h=$(curl -s -D - -o /dev/null -m 8 -X POST https://api.anthropic.com/v1/messages \
        -H "Authorization: Bearer $token" -H "anthropic-version: 2023-06-01" \
        -H "anthropic-beta: oauth-2025-04-20" -H "content-type: application/json" \
        -d "{\"model\":\"$MODEL\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"x\"}]}" 2>/dev/null)
    local status fh sd fr sr
    status=$(echo "$h" | grep -i "^HTTP" | tail -1 | tr -d '\r' | awk '{print $2}')
    fh=$(echo "$h" | grep -i "unified-5h-utilization" | tr -d '\r' | awk '{print $2}')
    sd=$(echo "$h" | grep -i "unified-7d-utilization" | tr -d '\r' | awk '{print $2}')
    fr=$(echo "$h" | grep -i "unified-5h-reset" | tr -d '\r' | awk '{print $2}')
    sr=$(echo "$h" | grep -i "unified-7d-reset" | tr -d '\r' | awk '{print $2}')
    echo "${status:-na}|${fh:-na}|${sd:-na}|${fr:-na}|${sr:-na}"
}

INT_TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | \
    /usr/bin/python3 -c "import sys,json; print(json.loads(sys.stdin.read())['claudeAiOauth']['accessToken'])" 2>/dev/null)
STK_TOKEN=$(cat "$STK_FILE" 2>/dev/null | tr -d '[:space:]')

INT=$(probe "$INT_TOKEN")
STK=$(probe "$STK_TOKEN")
TS=$(date '+%Y-%m-%d %H:%M:%S')

IFS='|' read -r is i5 i7 i5r i7r <<<"$INT"
IFS='|' read -r ss s5 s7 s5r s7r <<<"$STK"

MATCH="?"
if [[ "$i5" =~ ^[0-9.]+$ && "$s5" =~ ^[0-9.]+$ ]]; then
    [[ "$i5" == "$s5" && "$i7" == "$s7" ]] && MATCH="MATCH" || MATCH="DIFF"
fi

printf '%s  int[%s 5h=%s 7d=%s]  stk[%s 5h=%s 7d=%s]  => %s\n' \
    "$TS" "$is" "$i5" "$i7" "$ss" "$s5" "$s7" "$MATCH" >> "$LOG"

# Keep the log bounded.
if [[ $(wc -l < "$LOG" 2>/dev/null || echo 0) -gt 1000 ]]; then
    tail -n 1000 "$LOG" > "$LOG.$$" && mv "$LOG.$$" "$LOG"
fi
