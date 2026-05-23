# UsageLeftBar

macOS menu bar app showing Claude API rate limit utilization (5-hour session + 7-day weekly) with green→yellow→red gradient.

## Status: Working prototype (personal use)

Built 2026-04-02 in a single Claude Code session. Works, but the menu bar app category is saturated (10+ competitors). The real opportunity is a **Chrome extension + anonymized usage data product**.

## How it works

1. Reads OAuth token from macOS Keychain (`Claude Code-credentials` entry)
2. Makes a minimal Haiku API call every 60s (1 output token)
3. Parses `anthropic-ratelimit-unified-*` response headers for live utilization %
4. Displays `XX|YY` in menu bar (5h|7d) with color gradient
5. Click → dropdown with details, reset timers, link to usage page

## Key technical discovery

Rate limit data is ONLY available via successful API response headers:
```
anthropic-ratelimit-unified-5h-utilization: 0.54
anthropic-ratelimit-unified-7d-utilization: 0.40
anthropic-ratelimit-unified-5h-reset: 1775145600
anthropic-ratelimit-unified-7d-reset: 1775469600
```
- Error responses (400, 401) do NOT return these headers
- `count_tokens` endpoint doesn't accept OAuth tokens
- Minimum cost: 1 Haiku token per poll (~$0.00/day)

## Files

- `ClaudeUsageBar.swift` — single-file native Swift menu bar app (~180 lines)
- `build.sh` — compiles to `.app` bundle with Info.plist (LSUIElement=true for no dock icon)
- Compiled app lives at `~/.claude/usage-bar/ClaudeUsageBar.app`
- Also writes `~/.claude/rate-limits.json` as cache

## Build & run

```bash
bash build.sh
open ~/.claude/usage-bar/ClaudeUsageBar.app
```

Requires: Xcode CLI tools (swift compiler), macOS 13+, Claude Code logged in (for keychain token).

## Known issues

- Keychain popup on first launch (app reads Claude Code's credential entry — unsigned app triggers macOS security dialog)
- Only works for Claude Code users (needs the OAuth token in keychain)
- Browser-only claude.ai users have no way to use this

## Competitive landscape (as of 2026-04-02)

### Menu bar apps (saturated)
| App | GitHub Stars |
|-----|-------------|
| Claude-Code-Usage-Monitor | 7,296 |
| Claude-Usage-Tracker | 1,886 |
| Tokscale | 1,512 |
| ClaudeBar | 869 |
| ccseva | 790 |
| CUStats, SessionWatcher | Paid apps |

### Browser extensions for Claude.ai usage: ZERO (gap)

### Anonymized consumer usage data products: NONE (gap)
- OpenRouter State of AI report covers API/router traffic only
- Tokscale has a leaderboard but shallow (just totals)
- Nobody collects: limit-hitting patterns, model switching behavior, tokens-per-session, cache hit ratios, usage by plan tier

## Product direction (not built yet)

The real opportunity is NOT another menu bar app. It's:

1. **Chrome extension for claude.ai** — zero competitors, zero API cost (intercepts existing request headers), works for all users (not just Claude Code)
2. **Opt-in anonymized telemetry** — collect usage patterns from extension users
3. **"State of Claude Usage" dataset** — aggregated analytics on how consumers use Claude, valuable to Anthropic (pricing), enterprises (capacity planning), developers (benchmarking)

### Telemetry payload design (opt-in)
```json
{
  "ts": 1775124000,
  "5h_pct": 54.0,
  "7d_pct": 40.0,
  "plan": "max_5x",
  "model": "claude-opus-4-6",
  "input_tokens": 1234,
  "output_tokens": 567,
  "cache_read_tokens": 890,
  "client": "browser_ext"
}
```

### Derivable insights
- Usage patterns by time of day / day of week
- Limit-hitting frequency by plan tier
- Model preference distribution
- Token consumption curves
- Cache effectiveness across real users
- "Effective capacity" benchmarks per plan
- Model switching behavior near limits

## Auth options for public distribution

| Approach | UX | Works for |
|----------|-----|-----------|
| Piggyback Claude Code keychain | Zero setup, but keychain popup | Claude Code users |
| Paste API key | 10 seconds | API users |
| OAuth browser flow | Click login → authorize | Everyone with claude.ai account |
| Browser extension (no auth needed) | Zero setup | Browser users |
