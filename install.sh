#!/bin/bash
# One-shot installer: builds the app, writes both LaunchAgents with real
# absolute paths (launchd doesn't expand ~ or $HOME), and bootstraps them.
# Idempotent — safe to re-run after a git pull to upgrade in place.
#
# Requires: macOS 13+, Xcode Command Line Tools (swiftc), and a Claude
# Pro/Max sign-in (run `claude` in a terminal once) for live data.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTS_DIR="$HOME/Library/LaunchAgents"
UPDATER_LABEL="com.claude.usage-bar"
APP_LABEL="com.claude.usage-bar.app"
GUI="gui/$(id -u)"

# The app and updater reference this path internally — enforce it rather
# than fail mysteriously later.
EXPECTED="$HOME/.claude/usage-bar"
if [[ "$DIR" != "$EXPECTED" ]]; then
    echo "Install location must be $EXPECTED (the app hardcodes it)."
    echo "Run:"
    echo "  git clone https://github.com/Strygah/claude-usage-bar.git ~/.claude/usage-bar"
    echo "  cd ~/.claude/usage-bar && ./install.sh"
    exit 1
fi

command -v swiftc >/dev/null 2>&1 || {
    echo "swiftc not found. Install the Xcode Command Line Tools first:"
    echo "  xcode-select --install"
    exit 1
}

"$DIR/build.sh"

mkdir -p "$AGENTS_DIR"

# Updater agent: refreshes ~/.claude/rate-limits.json every 60s, whether or
# not the app (or any Claude client) is running.
cat > "$AGENTS_DIR/$UPDATER_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$UPDATER_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$DIR/update-rate-limits.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>60</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>LAUNCH_SRC</key>
        <string>agent</string>
    </dict>
</dict>
</plist>
PLIST

# App agent: starts the menu bar app at login and relaunches it on crash.
# SuccessfulExit=false means a clean Quit from the menu is honored.
cat > "$AGENTS_DIR/$APP_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$APP_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DIR/ClaudeUsageBar.app/Contents/MacOS/ClaudeUsageBar</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST

launchctl bootout "$GUI/$UPDATER_LABEL" 2>/dev/null || true
launchctl bootout "$GUI/$APP_LABEL" 2>/dev/null || true
sleep 1
launchctl bootstrap "$GUI" "$AGENTS_DIR/$UPDATER_LABEL.plist"
launchctl bootstrap "$GUI" "$AGENTS_DIR/$APP_LABEL.plist"

echo ""
echo "Installed. The meter should appear in your menu bar within a few seconds."
echo ""
echo "If it shows --|-- : sign in once by running \`claude\` in a terminal"
echo "(Claude Pro/Max account), then click the item > Refresh now."
echo "Optional resilience token (survives sign-outs, lasts ~1 year):"
echo "  ./provision-setup-token.sh"
