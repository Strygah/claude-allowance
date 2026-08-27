#!/bin/bash
# One-time: mint a 1-year `claude setup-token` and save it for ClaudeUsageBar.
# This token is INDEPENDENT of your normal Claude logins (it does not touch the
# "Claude Code-credentials" keychain item), so it cannot log you out of the
# CLI, Cursor, or the desktop app. It just lets the menu bar poll on its own,
# without depending on another client to refresh the 8h OAuth token.

echo "============================================================"
echo " ClaudeUsageBar: provisioning a 1-year setup-token"
echo "============================================================"
echo
echo "A browser window will open. Click AUTHORIZE."
echo "(This does NOT affect your CLI / Cursor / desktop-app logins.)"
echo
echo "------------------------------------------------------------"

claude setup-token | tee /tmp/stk.raw
grep -oE 'sk-ant-oat[0-9A-Za-z_-]+' /tmp/stk.raw | tail -1 > "$HOME/.claude/usage-bar/setup-token"
chmod 600 "$HOME/.claude/usage-bar/setup-token"
rm -f /tmp/stk.raw

echo "------------------------------------------------------------"
BYTES=$(wc -c < "$HOME/.claude/usage-bar/setup-token" 2>/dev/null | tr -d ' ')
if [[ "${BYTES:-0}" -ge 80 ]]; then
    echo " SAVED ${BYTES} bytes to ~/.claude/usage-bar/setup-token"
    echo " Done. You can close this window and tell Claude it's saved."
else
    echo " Something went wrong (only ${BYTES:-0} bytes captured)."
    echo " Re-run, or copy the sk-ant-oat... token manually into:"
    echo "   ~/.claude/usage-bar/setup-token"
fi
echo "============================================================"
