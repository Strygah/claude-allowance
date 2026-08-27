#!/bin/bash
# Remove the LaunchAgents and stop the app. Leaves this directory and the
# cache files (~/.claude/rate-limits*.json) in place — delete those manually
# if you want a full cleanup.
set -uo pipefail
GUI="gui/$(id -u)"
AGENTS_DIR="$HOME/Library/LaunchAgents"

launchctl bootout "$GUI/com.claude.usage-bar" 2>/dev/null || true
launchctl bootout "$GUI/com.claude.usage-bar.app" 2>/dev/null || true
killall ClaudeUsageBar 2>/dev/null || true
rm -f "$AGENTS_DIR/com.claude.usage-bar.plist" "$AGENTS_DIR/com.claude.usage-bar.app.plist"

echo "Removed both LaunchAgents and stopped the app."
echo "Repo left at ~/.claude/usage-bar; cache at ~/.claude/rate-limits*.json."
