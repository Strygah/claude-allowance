#!/bin/bash
# Rebuild + relaunch in the order that keeps Gatekeeper calm. Replacing the
# binary of a recently-running app and launching immediately can get the
# first spawn SIGKILL'd ("Launch Constraint Violation" — stale signature
# cache); LaunchServices then retries, sometimes leaving 0 or 2 instances.
# Quit first, build, launch once, then converge to exactly one instance.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"

killall ClaudeUsageBar 2>/dev/null || true
sleep 1
"$DIR/build.sh"
open "$DIR/ClaudeUsageBar.app"
sleep 4

# LaunchServices' post-crash retry can spawn a duplicate several seconds
# after the first successful launch, so check repeatedly until the count
# has been stable at 1 for two consecutive checks.
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
        open "$DIR/ClaudeUsageBar.app"
    fi
done

COUNT=$(pgrep -x ClaudeUsageBar | wc -l | tr -d ' ')
echo "ClaudeUsageBar: $COUNT instance(s) running"
[ "$COUNT" = "1" ]
