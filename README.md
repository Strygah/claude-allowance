# ClaudeUsageBar

macOS menu bar app showing Claude API rate limit utilization (5-hour
session + 7-day weekly) with green→yellow→red gradient.

Repo: github.com/Strygah/claude-usage-bar (private)
Install location: `~/.claude/usage-bar/`

## Architecture

Three pieces:

| Piece | When it runs | What it does |
|-------|--------------|--------------|
| `refresh-token.sh` | Claude Code `SessionStart` hook | Reads `claudeAiOauth.accessToken` from the `Claude Code-credentials` keychain item, writes it to `~/.claude/usage-bar/api-token`. Silent because the hook runs inside Claude Code's process tree, where macOS treats Claude Code (the keychain item's creator) as implicitly trusted. |
| `update-rate-limits.sh` | Claude Code `SessionStart` + `PostToolUse` hooks | Reads `api-token`, hits `POST /v1/messages` with `max_tokens:1`, parses the `anthropic-ratelimit-unified-*` response headers, writes `~/.claude/rate-limits.json`. Self-throttles to 30s. On 401, refreshes the api-token from keychain and retries once. |
| `ClaudeUsageBar.swift` | All the time (menu bar app) | Reads `~/.claude/rate-limits.json` every 30s, renders the menu bar text and dropdown. No network calls, no keychain access. |

Why split this way: macOS Sequoia/Tahoe periodically re-attests
ad-hoc-signed apps that read OAuth-class keychain items, prompting the
user for their login password several times a day. Moving keychain
access into Claude Code's process tree (via hooks) avoids the prompts
entirely. The app process never touches the keychain.

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

Rate-limit data is ONLY available via successful API response headers:
```
anthropic-ratelimit-unified-5h-utilization: 0.43
anthropic-ratelimit-unified-7d-utilization: 0.56
anthropic-ratelimit-unified-5h-reset: 1779571800
anthropic-ratelimit-unified-7d-reset: 1779883200
```

- 200 + 429 both return these headers (429 reports 100%)
- 401 returns nothing useful
- The minimum-cost ping is 1 Haiku output token (~$0.0001/poll)

## Build & install

```bash
# 1. Clone into the install location
git clone git@github.com:Strygah/claude-usage-bar.git ~/.claude/usage-bar
cd ~/.claude/usage-bar

# 2. Add hooks to ~/.claude/settings.json (merge with any existing hooks):
#   "hooks": {
#     "SessionStart": [{
#       "hooks": [{
#         "type": "command",
#         "command": "~/.claude/usage-bar/refresh-token.sh && ~/.claude/usage-bar/update-rate-limits.sh &"
#       }]
#     }],
#     "PostToolUse": [{
#       "hooks": [{
#         "type": "command",
#         "command": "~/.claude/usage-bar/update-rate-limits.sh &"
#       }]
#     }]
#   }

# 3. Bootstrap the token + cache (one-time, run from inside a CC session
# so security CLI is silent):
~/.claude/usage-bar/refresh-token.sh
~/.claude/usage-bar/update-rate-limits.sh

# 4. Build and launch
./build.sh
open ./ClaudeUsageBar.app
```

Requires: Xcode CLI tools (`swift`), macOS 13+, Claude Code logged in.

## How the menu reads

| Display | Meaning |
|---------|---------|
| `42\|18` vivid | Fresh data — 5h=42%, 7d=18% |
| `42\|18` dimmed | Cache is stale (>5 min old, no recent CC activity) — values still informative but possibly out of date |
| `--\|--` | No cache file. Run any CC command, or the bootstrap scripts above. |

Click the menu to see exact percentages, reset times, and the timestamp
of the last cache write.

## Files

- `ClaudeUsageBar.swift` — single-file Swift menu bar app. Pure UI; no
  auth, no network. Reads only `~/.claude/rate-limits.json`.
- `build.sh` — compiles to `.app` bundle with Info.plist
  (LSUIElement=true → no dock icon). Ad-hoc signed with stable identifier
  `com.claude.usage-bar`.
- `refresh-token.sh` — extracts OAuth access token from keychain into
  `~/.claude/usage-bar/api-token` (mode 600).
- `update-rate-limits.sh` — fetches and caches ratelimit headers in
  `~/.claude/rate-limits.json`.

## Known limits

- Menu data only updates while Claude Code is active (hook-driven). During
  long idle periods, the menu shows stale-but-dimmed values plus a
  `(stale)` label in the "updated" line. Self-heals on next CC interaction.
- The `api-token` file lives in plaintext under `~/.claude/usage-bar/`,
  mode 600. Same blast radius as your shell history. Gitignored.
- Ad-hoc signed — fresh macOS install may need to allow first launch via
  System Settings → Privacy & Security if Gatekeeper complains.
