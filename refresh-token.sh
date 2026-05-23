#!/bin/bash
# Refresh ~/.claude/usage-bar/api-token from Claude Code's keychain OAuth.
# Runs silently when invoked from inside Claude Code's process tree
# (Claude Code is the keychain item's creator; partition_id trusts apple-tool).
set -euo pipefail
TOKEN_FILE="$HOME/.claude/usage-bar/api-token"
TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
    | /usr/bin/python3 -c 'import sys,json;print(json.loads(sys.stdin.read())["claudeAiOauth"]["accessToken"])' 2>/dev/null)
[ -z "$TOKEN" ] && exit 0
printf '%s' "$TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
