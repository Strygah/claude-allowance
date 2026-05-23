#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$DIR/ClaudeUsageBar.app/Contents/MacOS"

echo "Building ClaudeUsageBar..."
mkdir -p "$APP_DIR"
mkdir -p "$DIR/ClaudeUsageBar.app/Contents"

# Compile, then re-sign with a deterministic ad-hoc identity so the cdhash
# stays stable across rebuilds (identical source → identical binary →
# identical cdhash → no Keychain re-prompt). To intentionally force a new
# cdhash (e.g. after a broken Keychain trust entry needs busting), add
# `-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __build_id -Xlinker <file>`
# with unique file contents.
swiftc -O -o "$APP_DIR/ClaudeUsageBar" "$DIR/ClaudeUsageBar.swift" \
    -framework Cocoa

codesign --force --deep --sign - \
    --identifier com.claude.usage-bar \
    "$DIR/ClaudeUsageBar.app"

# Info.plist (hide from dock, mark as agent)
cat > "$DIR/ClaudeUsageBar.app/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ClaudeUsageBar</string>
    <key>CFBundleIdentifier</key>
    <string>com.claude.usage-bar</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
</dict>
</plist>
PLIST

echo "Built: $DIR/ClaudeUsageBar.app"
echo ""
echo "To run:  open $DIR/ClaudeUsageBar.app"
echo "To stop: click menu bar icon > Quit"
