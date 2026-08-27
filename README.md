# ClaudeUsageBar

macOS menu bar app showing Claude API rate limit utilization (5-hour
session + 7-day weekly) with green→yellow→red gradient.

Repo: github.com/Strygah/claude-usage-bar (private)
Install location: `~/.claude/usage-bar/`

## Architecture

Two pieces plus a LaunchAgent:

| Piece | When it runs | What it does |
|-------|--------------|--------------|
| `update-rate-limits.sh` | LaunchAgent, every 60s | Reads the OAuth token (`api-token` file, bootstrapped from keychain), hits `POST /v1/messages` with `max_tokens:1`, parses the `anthropic-ratelimit-unified-*` response headers, writes `~/.claude/rate-limits.json`. Self-bootstrapping: pulls a fresh token from the `Claude Code-credentials` keychain item whenever the file is missing or returns 401. |
| `com.claude.usage-bar.plist` | `~/Library/LaunchAgents/` | Runs the updater every 60s regardless of whether Claude Code is active. This is what keeps the data fresh during idle periods. |
| `ClaudeUsageBar.swift` | All the time (menu bar app) | Reads `~/.claude/rate-limits.json` every 10s and on every menu open. Renders the menu bar text + dropdown. No network calls, no keychain access. |

### Why this shape

macOS Sequoia/Tahoe periodically re-attests ad-hoc-signed apps that read
OAuth-class keychain items, prompting for the login password several times
a day. The fix: the menu bar app never touches the keychain. All keychain
access goes through `/usr/bin/security` (Apple-signed, trusted in the
item's ACL) inside the updater script — which reads the keychain silently
from any context, including a background LaunchAgent.

Earlier versions used Claude Code `SessionStart` + `PostToolUse` hooks to
drive the refresh, but that only updated during CC activity, leaving the
menu stale during idle. The LaunchAgent removes the CC dependency entirely.

## Auth: OAuth tokens need Bearer, not x-api-key

The Anthropic API rejects `sk-ant-oat-*` OAuth tokens passed via
`x-api-key` (silent HTTP 401, no ratelimit headers). The correct
pattern for subscription OAuth tokens is:

```
Authorization: Bearer <sk-ant-oat-...>
anthropic-version: 2023-06-01
anthropic-beta: oauth-2025-04-20
```

`x-api-key` is only valid for actual API keys (`sk-ant-api03-*`).

## Key technical discovery

Rate-limit data is ONLY available via API response headers:
```
anthropic-ratelimit-unified-5h-utilization: 0.43
anthropic-ratelimit-unified-7d-utilization: 0.56
anthropic-ratelimit-unified-5h-reset: 1779571800
anthropic-ratelimit-unified-7d-reset: 1779883200
```

- 200 + 429 both return these headers (429 reports 100%)
- 401 returns nothing useful
- The minimum-cost ping is 1 Haiku output token. NB: it's an OAuth
  subscription call, so it counts a sliver against the very rate limit
  it measures — negligible at `max_tokens:1` / 60s, but real.

## Build & install

```bash
# 1. Clone into the install location
git clone git@github.com:Strygah/claude-usage-bar.git ~/.claude/usage-bar
cd ~/.claude/usage-bar

# 2. Install + load the LaunchAgent (refreshes the cache every 60s)
cp com.claude.usage-bar.plist ~/Library/LaunchAgents/
#   edit the hardcoded /Users/<you> path in the plist if not strygah
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude.usage-bar.plist

# 3. Build and launch the menu bar app
./build.sh
open ./ClaudeUsageBar.app
```

Requires: Xcode CLI tools (`swift`), macOS 13+, Claude Code logged in
(for the keychain OAuth token).

To stop/remove the agent:
```bash
launchctl bootout gui/$(id -u)/com.claude.usage-bar
```

## How the menu reads

| Display | Meaning |
|---------|---------|
| `42⣿18` vivid | Fresh data — 5h=42%, 7d=18%. The separator is five stacked hour notches: bright ones are whole hours left in the 5h window, the in-progress hour fades with its remaining fraction, spent hours are faint stubs. |
| `42⣿18/37` (stacked right column) | "Show Fable weekly" toggled on in the menu: the right column stacks the all-models weekly (top) over the model-scoped Fable weekly (bottom) at small size; 5h stays full size. The scoped bucket comes only from the rich usage endpoint (`scoped_7d*` cache keys); on probe-fallback data it's carried for up to 6h from its last real fetch, then the bar reverts to the two-number display. |
| `42\|18` (plain pipe) | No active 5h window (reset already passed, or no reset data) — nothing to count down. |
| `42⣿18` dimmed | Cache >5 min old. With the LaunchAgent running this should be rare — means the updater is failing (check `launchctl list \| grep usage-bar`). |
| `--\|--` | No cache file. Run `update-rate-limits.sh` manually, or check the LaunchAgent loaded. |

Click the menu to see exact percentages, reset times, and the timestamp
of the last cache write. The menu re-reads the cache on open, so it's
always current the moment you look.

## Files

- `ClaudeUsageBar.swift` — single-file Swift menu bar app. Pure UI; no
  auth, no network. Reads only `~/.claude/rate-limits.json`.
- `build.sh` — compiles to `.app` bundle with Info.plist
  (LSUIElement=true → no dock icon). Ad-hoc signed with stable identifier
  `com.claude.usage-bar`.
- `update-rate-limits.sh` — fetches and caches ratelimit headers; pulls the
  OAuth token from keychain as needed.
- `usage-to-cache.py` — parses the rich `/api/oauth/usage` payload into the
  cache (incl. the scoped Fable weekly) + appends the deduped history.
- `restart.sh` — quit → build → relaunch → verify a single instance survived
  (dodges the Gatekeeper stale-signature SIGKILL and the LaunchServices
  duplicate-relaunch race).
- `com.claude.usage-bar.plist` — LaunchAgent that runs the updater every 60s.

## Known limits

- The `api-token` file lives in plaintext under `~/.claude/usage-bar/`,
  mode 600. Same blast radius as your shell history. Gitignored.
- If Claude Code logs out / the keychain item disappears, the updater can't
  get a token and the menu shows `--`. Log back into CC.
- Ad-hoc signed — fresh macOS install may need to allow first launch via
  System Settings → Privacy & Security if Gatekeeper complains.
- The LaunchAgent path in the plist is hardcoded to an absolute home dir.
  Edit it on a different machine/user.
