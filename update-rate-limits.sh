#!/bin/bash
# Rate-limit updater. Run by a LaunchAgent every 60s AND by the menu app's
# internal timer (independent of Claude Code activity). Writes a JSON cache
# that ClaudeUsageBar.app renders (simple 5h | 7d indicator).
#
# DATA SOURCE (priority order):
#   1. PRIMARY - GET /api/oauth/usage with the keychain "Claude Code-credentials"
#      token. A pure usage query: costs NO quota (unlike an inference probe) and
#      returns rich per-model data, which we append to a deduped history
#      (usage-history.jsonl) for periodic analysis. Needs the user:profile scope
#      that the keychain token has.
#   2. FALLBACK - a 1-year `claude setup-token` (usage-bar/setup-token) used for
#      a tiny max_tokens:1 /v1/messages probe, just to keep the indicator alive.
#      Independent of any client, so the bar never gets stuck even when only the
#      Claude desktop app is used (that app auths via web cookies and never
#      refreshes the keychain token, which is why the bar used to die for hours).
#
# SAFETY: this script NEVER calls an OAuth refresh endpoint and NEVER writes to
# the keychain. It only READS it (silently, via /usr/bin/security), so it can
# never rotate or invalidate the shared login credential. When the access
# token has expired it may run the OFFICIAL `claude` CLI headlessly (a usage
# query over its control channel, no model turn) so that the CLI rotates its
# own token the sanctioned way (see AUTO-REFRESH below), the same thing that
# happens when you open a terminal.
#
# If no usable token exists (keychain expired AND no setup-token), the script
# records status=token_expired and leaves the last-good cache untouched so the
# UI can dim + project, rather than hammering the API with doomed 401s.

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

CACHE="$HOME/.claude/rate-limits.json"
STATUS_FILE="$HOME/.claude/rate-limits-status.json"
LOG="$HOME/.claude/usage-bar/updater.log"
MODEL="claude-haiku-4-5-20251001"
EXPIRY_BUFFER_MS=60000   # treat the token as expired this long before its real expiry

# Caller can set LAUNCH_SRC=app|agent|manual to tag who invoked us.
LAUNCH_SRC="${LAUNCH_SRC:-manual}"

# FETCH CADENCE. The usage endpoint is documented as safe to poll at ~180s
# with the claude-code User-Agent (faster polling risks a 429 bucket), and
# the fallback probe is a real inference request, so both are rate-limited
# to one fetch per MIN_INTERVAL seconds, keyed on the cache file's mtime.
# The LaunchAgent and the app may still invoke us every minute; those runs
# exit here at near-zero cost. FORCE=1 (the app's "Refresh now") bypasses.
MIN_INTERVAL="${MIN_INTERVAL:-180}"
if [[ "${FORCE:-0}" != "1" && -f "$CACHE" ]]; then
    AGE=$(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || echo 0) ))
    if (( AGE < MIN_INTERVAL )); then
        exit 0
    fi
fi

# One line per run so a recurring staleness has a paper trail. Capped to the
# last 500 lines so it can't grow unbounded.
log() {
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$LAUNCH_SRC" "$1" >> "$LOG"
    if [[ $(wc -l < "$LOG" 2>/dev/null || echo 0) -gt 500 ]]; then
        # Per-process temp name so a concurrent app+agent rotation can't read a
        # half-written file (both fire on their own timers).
        tail -n 500 "$LOG" > "$LOG.$$" && mv "$LOG.$$" "$LOG"
    fi
}

# Write the latest fetch outcome so the UI can show a precise reason
# (ok | token_expired | error) without ever touching the keychain itself.
write_status() {
    local status="$1" detail="$2" now
    now=$(/usr/bin/python3 -c "import time; print(time.time())")
    printf '{"status":"%s","detail":"%s","checked_at":%s}\n' "$status" "$detail" "$now" > "$STATUS_FILE"
}

# Read access token + expiresAt (ms) from the keychain in one shot. Silent from
# any context (security is Apple-signed + in the item's ACL). Prints
# "<token>\t<expiresAt_ms>"; the token is never logged.
read_keychain() {
    security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | \
        /usr/bin/python3 -c "
import sys, json
try:
    o = json.loads(sys.stdin.read())['claudeAiOauth']
    print('%s\t%s' % (o.get('accessToken',''), o.get('expiresAt','')))
except Exception:
    pass
" 2>/dev/null
}

# Refresh-token state from the same keychain item: "<refreshTokenExpiresAt_ms>\t<1|0>".
read_refresh_state() {
    security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | \
        /usr/bin/python3 -c "
import sys, json
try:
    o = json.loads(sys.stdin.read())['claudeAiOauth']
    print('%s\t%s' % (o.get('refreshTokenExpiresAt', ''), 1 if o.get('refreshToken') else 0))
except Exception:
    pass
" 2>/dev/null
}

# Run a command with a hard wall-clock cap (macOS has no coreutils timeout).
run_with_timeout() {
    local secs="$1"; shift
    "$@" </dev/null >/dev/null 2>&1 &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null && (( waited < secs )); do
        sleep 1; waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        return 124
    fi
    wait "$pid"
}

# ---- Codex (OpenAI) ----
# Read-only: takes the access token the Codex CLI keeps in ~/.codex/auth.json
# and asks the ChatGPT backend for the subscription windows (primary = 5h,
# secondary = weekly). Written to its own cache so the Claude writers stay
# untouched. Never refreshes the token itself: when it expires (401) the
# cache is marked "expired" and the app tells the user to run `codex login`.
CODEX_AUTH="${CODEX_HOME:-$HOME/.codex}/auth.json"
CODEX_CACHE="$HOME/.claude/codex-limits.json"
fetch_codex() {
    [[ -f "$CODEX_AUTH" ]] || return 0
    /usr/bin/python3 - "$CODEX_AUTH" "$CODEX_CACHE" <<'CXEOF' 2>/dev/null
import json, sys, time, subprocess, os
auth_path, cache_path = sys.argv[1], sys.argv[2]
try:
    a = json.load(open(auth_path)); tok = a["tokens"]["access_token"]; acct = a["tokens"].get("account_id", "")
except Exception:
    sys.exit(0)
prev = {}
try:
    prev = json.load(open(cache_path))
except Exception:
    pass
r = subprocess.run(["curl", "-s", "-m", "8", "-w", "\n%{http_code}",
                    "https://chatgpt.com/backend-api/wham/usage",
                    "-H", "Authorization: Bearer " + tok, "-H", "ChatGPT-Account-Id: " + acct,
                    "-H", "User-Agent: codex-cli/0.50.0"], capture_output=True, text=True)
body, _, status = r.stdout.rpartition("\n"); status = status.strip()
now = time.time(); out = dict(prev)
if status == "200":
    try:
        d = json.loads(body); rl = d.get("rate_limit") or {}
        pw = rl.get("primary_window") or {}; sw = rl.get("secondary_window") or {}
        out = {"five_hour": float(pw.get("used_percent") or 0), "five_hour_reset": float(pw.get("reset_at") or 0),
               "five_hour_window": int(pw.get("limit_window_seconds") or 18000),
               "seven_day": float(sw.get("used_percent") or 0), "seven_day_reset": float(sw.get("reset_at") or 0),
               "plan": d.get("plan_type"), "timestamp": now, "status": "ok"}
    except Exception:
        out["status"] = "error"; out["checked_at"] = now
elif status == "401":
    out["status"] = "expired"; out["checked_at"] = now
else:
    out["status"] = "error"; out["checked_at"] = now
tmp = cache_path + ".tmp.%d" % os.getpid()
json.dump(out, open(tmp, "w")); os.replace(tmp, cache_path)
print(status or "none")
CXEOF
}

# GET the dedicated usage endpoint (no inference, costs no quota; returns rich
# per-model data + exact resets). Needs the user:profile scope, which the
# keychain token has but the setup-token does NOT. Prints "<body>\n<http_code>";
# the caller splits it (doing so here would lose the status to the $() subshell).
# The "claude-code/" User-Agent prefix is required or the endpoint 429s.
fetch_usage() {
    curl -s -w '\n%{http_code}' -m 6 "$USAGE_URL" \
        -H "Authorization: Bearer $1" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: $UA" 2>/dev/null
}

# OAuth subscription tokens (sk-ant-oat-*) need Bearer auth +
# anthropic-beta: oauth-2025-04-20. x-api-key returns a silent 401.
fetch_headers() {
    local token="$1"
    curl -s -D - -o /dev/null -m 5 \
        -X POST https://api.anthropic.com/v1/messages \
        -H "Authorization: Bearer $token" \
        -H "anthropic-version: 2023-06-01" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "content-type: application/json" \
        -d "{\"model\":\"$MODEL\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"x\"}]}" \
        2>/dev/null
}

# Parse utilization/reset headers from a response and write the cache.
# 429 also carries them (the "you're at 100%" signal). Returns 0 on success.
parse_and_write() {
    local headers="$1" FH SD FH_RESET SD_RESET FH_PCT SD_PCT NOW
    FH=$(echo "$headers" | grep -i "anthropic-ratelimit-unified-5h-utilization" | tr -d '\r' | awk '{print $2}')
    SD=$(echo "$headers" | grep -i "anthropic-ratelimit-unified-7d-utilization" | tr -d '\r' | awk '{print $2}')
    [[ -z "$FH" && -z "$SD" ]] && return 1
    FH_RESET=$(echo "$headers" | grep -i "anthropic-ratelimit-unified-5h-reset" | tr -d '\r' | awk '{print $2}')
    SD_RESET=$(echo "$headers" | grep -i "anthropic-ratelimit-unified-7d-reset" | tr -d '\r' | awk '{print $2}')
    FH_PCT=$(/usr/bin/python3 -c "print(round(max(float('${FH:-0}') * 100, 0), 2))" 2>/dev/null || echo 0)
    SD_PCT=$(/usr/bin/python3 -c "print(round(max(float('${SD:-0}') * 100, 0), 2))" 2>/dev/null || echo 0)
    NOW=$(/usr/bin/python3 -c "import time; print(time.time())")
    # Probe headers carry no scoped (Fable) weekly, only the rich endpoint
    # does. Carry the previous cache's scoped keys through fallback cycles
    # for up to 6h (stamped by usage-to-cache.py) so a rich-endpoint hiccup
    # doesn't blank the Fable slot every minute; after 6h they age out.
    SCOPED=$(/usr/bin/python3 - "$CACHE" <<'PYEOF' 2>/dev/null
import json, sys, time
try:
    d = json.load(open(sys.argv[1]))
    fa = d.get("scoped_7d_fetched_at")
    if fa and time.time() - fa < 6 * 3600 and d.get("scoped_7d") is not None:
        keep = {k: d[k] for k in ("scoped_7d", "scoped_7d_reset",
                "scoped_7d_label", "scoped_7d_fetched_at") if k in d}
        print(json.dumps(keep)[1:-1])
except Exception:
    pass
PYEOF
)
    # Atomic write (temp + rename) so a concurrent writer can't leave the menu
    # app reading a half-written cache.
    cat > "$CACHE.$$" <<JSONEOF
{"five_hour":${FH_PCT},"seven_day":${SD_PCT},"five_hour_reset":${FH_RESET:-0},"seven_day_reset":${SD_RESET:-0},"timestamp":${NOW}${SCOPED:+,${SCOPED}}}
JSONEOF
    mv -f "$CACHE.$$" "$CACHE"
    LAST_FH_PCT="$FH_PCT"; LAST_SD_PCT="$SD_PCT"
    return 0
}

# ---- main ----

USAGE_URL="https://api.anthropic.com/api/oauth/usage"
UA="claude-code/2.1.170"      # only the "claude-code/" prefix matters; bump freely
HISTORY="$HOME/.claude/usage-bar/usage-history.jsonl"
SIG="$HOME/.claude/usage-bar/.usage-sig"
WINDOWS="$HOME/.claude/usage-bar/usage-windows.jsonl"
WINSIG="$HOME/.claude/usage-bar/.5h-reset"
HELPER="$HOME/.claude/usage-bar/usage-to-cache.py"
RPC_HELPER="$HOME/.claude/usage-bar/claude-usage-rpc.py"
REFRESH_CWD="$HOME/.claude/usage-bar/.refresh-cwd"   # empty dir the headless CLI starts in
RPC_BODY=""   # usage payload from a headless CLI run this invocation, if any
SETUP_TOKEN_FILE="$HOME/.claude/usage-bar/setup-token"

# Read the keychain token + validated expiresAt, and decide if it's fresh.
NOW_MS="${TEST_NOW_MS:-$(/usr/bin/python3 -c 'import time; print(int(time.time()*1000))')}"
load_keychain() {
    KC=$(read_keychain)
    KC_TOKEN="${KC%%$'\t'*}"
    KC_EXP="${KC#*$'\t'}"
    [[ "$KC_EXP" =~ ^[1-9][0-9]{12,}$ ]] || KC_EXP=""
    KC_FRESH=""
    if [[ -n "$KC_TOKEN" && -n "$KC_EXP" ]]; then
        /usr/bin/python3 -c "import sys; sys.exit(0 if ${NOW_MS} < ${KC_EXP} - ${EXPIRY_BUFFER_MS} else 1)" 2>/dev/null && KC_FRESH=1
    elif [[ -n "$KC_TOKEN" ]]; then
        KC_FRESH=1   # expiresAt unknown: treat as usable, let the API be the judge
    fi
}
load_keychain

# AUTO-REFRESH. The access token lives ~8h and only the official CLI rotates
# it, so desktop-app-only days used to leave the rich endpoint (and the
# scoped Fable weekly) dead until the next terminal session. If the token is
# expired but the refresh token is still valid, start the CLI headlessly and
# ask it for usage over its control channel (claude-usage-rpc.py: no model
# turn, zero quota, ~2s); it rotates the token on the way in exactly as an
# interactive `claude` launch would, and its answer doubles as this run's
# data. The CLI is started from an EMPTY directory: it scans its working tree
# at startup, and inheriting the app's launchd cwd (`/`) sent that scan into
# Downloads, the Music/TV library and network volumes, each a macOS consent
# dialog attributed to the app. This script itself still never touches the
# OAuth endpoint or writes the keychain. One attempt per 6h (stamp file) so
# a failing CLI can't loop every minute.
REFRESH_STAMP="$HOME/.claude/usage-bar/.refresh-attempt"
if [[ -n "$KC_TOKEN" && -z "$KC_FRESH" && -z "$(find "$REFRESH_STAMP" -mmin -360 2>/dev/null)" ]]; then
    RS=$(read_refresh_state)
    R_EXP="${RS%%$'\t'*}"; R_HAS="${RS#*$'\t'}"
    [[ "$R_EXP" =~ ^[1-9][0-9]{12,}$ ]] || R_EXP=""
    R_OK=""
    if [[ "$R_HAS" == "1" ]]; then
        if [[ -z "$R_EXP" ]]; then
            R_OK=1
        else
            /usr/bin/python3 -c "import sys; sys.exit(0 if ${NOW_MS} < ${R_EXP} else 1)" 2>/dev/null && R_OK=1
        fi
    fi
    CLAUDE_BIN=""
    for c in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
        [[ -x "$c" ]] && { CLAUDE_BIN="$c"; break; }
    done
    touch "$REFRESH_STAMP"
    if [[ -z "$R_OK" ]]; then
        log "token expired and refresh token missing/expired - run \`claude\` in a terminal to sign in again"
    elif [[ -z "$CLAUDE_BIN" ]]; then
        log "token expired but no claude CLI found for headless refresh"
    else
        mkdir -p "$REFRESH_CWD"
        RPC_BODY=$(/usr/bin/python3 "$RPC_HELPER" "$CLAUDE_BIN" "$REFRESH_CWD" 2>/dev/null)
        if [[ -n "$RPC_BODY" ]]; then
            load_keychain
            log "headless usage request refreshed the keychain token (fresh=${KC_FRESH:-0})"
            # Answered, yet the keychain still reads as expiring: the CLI saw
            # the token as valid and left it alone. Retry in 10 min, not 6h.
            [[ -z "$KC_FRESH" ]] && touch -A -055000 "$REFRESH_STAMP"
        elif (cd "$REFRESH_CWD" && run_with_timeout 90 env -i HOME="$HOME" USER="${USER:-$(id -un)}" \
                PATH="/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin" \
                "$CLAUDE_BIN" -p "reply with the single word ok" --model "$MODEL" --max-turns 1); then
            # Control channel unavailable (Anthropic marks it experimental): a
            # one-turn Haiku call still makes the CLI rotate its token.
            load_keychain
            log "usage request unavailable; headless claude turn refreshed the keychain token (fresh=${KC_FRESH:-0})"
        else
            log "headless claude refresh failed (rc=$?) - will retry in 6h"
        fi
    fi
fi

SETUP_TOKEN=$(cat "$SETUP_TOKEN_FILE" 2>/dev/null | tr -d '[:space:]')

# Codex first: independent of the Claude token state, cheap, same cadence.
CODEX_HTTP=$(fetch_codex)
if [[ -n "$CODEX_HTTP" && "$CODEX_HTTP" != "200" ]]; then log "codex usage fetch status=$CODEX_HTTP"; fi

# PRIMARY: the rich, quota-free /api/oauth/usage payload. Either the answer
# the headless CLI just gave (RPC_BODY) or a direct GET with the keychain
# token (needs its user:profile scope; the setup-token lacks it). Also
# appends the full per-model payload to the deduped history for periodic
# analysis. The indicator cache schema is unchanged, so the menu bar looks
# identical. Exits the script on success.
use_usage_body() {
    local body="$1" src="$2" OUT
    OUT=$(CACHE="$CACHE" HISTORY="$HISTORY" SIG="$SIG" WINDOWS="$WINDOWS" WINSIG="$WINSIG" /usr/bin/python3 "$HELPER" <<<"$body" 2>/dev/null) || return 1
    [[ -n "$OUT" ]] || return 1
    write_status "ok" ""
    log "OK [$src] 5h=${OUT% *}% 7d=${OUT#* }%"
    if [[ $(wc -l < "$HISTORY" 2>/dev/null || echo 0) -gt 100000 ]]; then
        tail -n 90000 "$HISTORY" > "$HISTORY.$$" && mv "$HISTORY.$$" "$HISTORY"
    fi
    exit 0
}
if [[ -n "$RPC_BODY" ]]; then
    use_usage_body "$RPC_BODY" "usage:cli" || log "headless usage payload unparseable, trying the endpoint"
fi
if [[ -n "$KC_FRESH" ]]; then
    RESP=$(fetch_usage "$KC_TOKEN")
    USAGE_STATUS="${RESP##*$'\n'}"   # split in the parent shell (not the subshell)
    BODY="${RESP%$'\n'*}"
    [[ "$USAGE_STATUS" == "200" ]] && use_usage_body "$BODY" "usage"
    log "usage endpoint unavailable (status=${USAGE_STATUS:-none}), falling back to probe"
fi

# FALLBACK: a lightweight max_tokens:1 probe just to keep the indicator alive.
# Prefer the setup-token (no 8h expiry, works desktop-app-only); else the
# keychain token. Headers only, no rich history.
PROBE_TOKEN=""; PROBE_SRC=""
if [[ -n "$SETUP_TOKEN" ]]; then
    PROBE_TOKEN="$SETUP_TOKEN"; PROBE_SRC="setup-token"
elif [[ -n "$KC_FRESH" ]]; then
    PROBE_TOKEN="$KC_TOKEN"; PROBE_SRC="keychain"
fi

if [[ -z "$PROBE_TOKEN" ]]; then
    if [[ -n "$KC_TOKEN" && -z "$KC_FRESH" ]]; then
        write_status "token_expired" "keychain token expired (provision a setup-token to fix permanently)"
        log "SKIP keychain expired, no setup-token - leaving last-good cache"
    else
        write_status "error" "no token (open a Claude client to sign in)"
        log "FAIL no token available"
    fi
    exit 0
fi

HEADERS=$(fetch_headers "$PROBE_TOKEN")
STATUS=$(echo "$HEADERS" | grep -i "^HTTP" | tail -1 | tr -d '\r' | awk '{print $2}')

# 401 on the keychain probe: a client may have just refreshed it. Re-READ
# (never refresh) once and retry.
if [[ "$STATUS" == "401" && "$PROBE_SRC" == "keychain" ]]; then
    KC2=$(read_keychain); NEW_TOKEN="${KC2%%$'\t'*}"
    if [[ -n "$NEW_TOKEN" && "$NEW_TOKEN" != "$PROBE_TOKEN" ]]; then
        HEADERS=$(fetch_headers "$NEW_TOKEN")
        STATUS=$(echo "$HEADERS" | grep -i "^HTTP" | tail -1 | tr -d '\r' | awk '{print $2}')
        log "re-read keychain after 401, retry status=$STATUS"
    fi
fi

if [[ "$STATUS" == "401" ]]; then
    if [[ "$PROBE_SRC" == "setup-token" ]]; then
        write_status "error" "setup-token invalid, re-run provision-setup-token.sh"
        log "FAIL setup-token 401 (re-provision)"
    else
        write_status "token_expired" "401 from API (open a Claude client to refresh)"
        log "FAIL 401 (open a Claude client to refresh)"
    fi
    exit 0
fi

if parse_and_write "$HEADERS"; then
    write_status "ok" ""
    log "OK [probe:$PROBE_SRC] status=$STATUS 5h=${LAST_FH_PCT}% 7d=${LAST_SD_PCT}%"
else
    write_status "error" "no ratelimit headers (status=${STATUS:-none})"
    log "FAIL no ratelimit headers (status=${STATUS:-none}, curl may have timed out)"
fi
exit 0
