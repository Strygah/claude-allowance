#!/bin/bash
# Rebuild + relaunch. Two traps this script exists to dodge:
#   1. Gatekeeper: replacing the binary of a recently-running app and
#      launching immediately can get the first spawn SIGKILL'd ("Launch
#      Constraint Violation", stale signature cache); something then
#      retries, sometimes leaving 0 or 2 instances.
#   2. launchd: the app normally runs under the com.claude.usage-bar.app
#      LaunchAgent with KeepAlive, so killall+open RACES launchd's
#      auto-relaunch (~10s later) into duplicate instances. When the
#      agent is loaded, restart THROUGH launchd (kickstart -k), never
#      via open.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP_AGENT="gui/$(id -u)/com.claude.usage-bar.app"

agent_loaded() {
    launchctl print "$APP_AGENT" >/dev/null 2>&1
}

restart_app() {
    if agent_loaded; then
        launchctl kickstart -k "$APP_AGENT"
    else
        killall ClaudeUsageBar 2>/dev/null || true
        sleep 1
        open "$DIR/ClaudeUsageBar.app"
    fi
}

"$DIR/build.sh"
restart_app

# Converge: wait until exactly one instance has survived two consecutive
# checks (covers the Gatekeeper kill-and-retry and any leftover manual
# instance running outside launchd).
STABLE=0
for _ in 1 2 3 4 5 6; do
    sleep 3
    COUNT=$(pgrep -x ClaudeUsageBar | wc -l | tr -d ' ')
    if [ "$COUNT" = "1" ]; then
        STABLE=$((STABLE + 1))
        [ "$STABLE" -ge 2 ] && break
    else
        STABLE=0
        killall ClaudeUsageBar 2>/dev/null || true
        sleep 2
        restart_app
    fi
done

COUNT=$(pgrep -x ClaudeUsageBar | wc -l | tr -d ' ')
echo "ClaudeUsageBar: $COUNT instance(s) running"
[ "$COUNT" = "1" ]
