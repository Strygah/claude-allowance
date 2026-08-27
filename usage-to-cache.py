#!/usr/bin/env python3
# Reads a GET /api/oauth/usage JSON body on stdin. Does two things:
#   1. Writes the SIMPLE cache the menu bar renders ($CACHE) - unchanged schema,
#      so the indicator stays exactly as-is (5h | 7d).
#   2. Appends the FULL payload (per-model breakdowns, severity, spend, exact
#      resets) to a deduped JSONL history ($HISTORY) for periodic rich analysis.
# Prints "<5h> <7d>" for the updater's log line. Exit 0 on success; non-zero if
# the body is not valid usage JSON (so the updater falls back to the probe).
import sys, os, json, time, re
from datetime import datetime

CACHE = os.environ["CACHE"]
HISTORY = os.environ.get("HISTORY", "")
SIG = os.environ.get("SIG", "")
WINDOWS = os.environ.get("WINDOWS", "")   # explicit 5h-window-start event log
WINSIG = os.environ.get("WINSIG", "")     # sidecar: last-seen 5h reset epoch


def iso_to_epoch(s):
    if not s:
        return 0
    try:
        # py3.9's fromisoformat is picky: it rejects a trailing 'Z' and any
        # fractional-second precision other than 3 or 6 digits. Normalise the
        # 'Z' and drop fractional seconds entirely (reset times are minute-
        # granular, so sub-second precision is irrelevant). Robust to API
        # format drift.
        s = s.strip()
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        s = re.sub(r"\.\d+", "", s)
        return datetime.fromisoformat(s).timestamp()
    except Exception:
        return 0


raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    sys.exit(2)
if not isinstance(d, dict):
    sys.exit(2)

fh = d.get("five_hour") or {}
sd = d.get("seven_day") or {}
five, seven = fh.get("utilization"), sd.get("utilization")
if five is None and seven is None:
    sys.exit(3)
five = float(five or 0)
seven = float(seven or 0)
now = time.time()

# Atomic write (temp + rename) so a concurrent writer (app timer + LaunchAgent,
# or a manual "Refresh now" overlapping an in-flight fetch) can never leave the
# menu app reading a half-written, unparseable cache.
cache = {
    "five_hour": five,
    "seven_day": seven,
    "five_hour_reset": iso_to_epoch(fh.get("resets_at")),
    "seven_day_reset": iso_to_epoch(sd.get("resets_at")),
    "timestamp": now,
}

# Model-scoped weekly (today: "Fable"). Only the rich endpoint has this —
# the header-probe fallback writes a cache without these keys, and the app
# hides the scoped slot whenever they're absent. Label comes from the
# payload so a future Opus/Sonnet-scoped week works unchanged.
for lim in (d.get("limits") or []):
    if isinstance(lim, dict) and lim.get("kind") == "weekly_scoped" \
            and lim.get("percent") is not None:
        scope = lim.get("scope") or {}
        model = scope.get("model") or {}
        cache["scoped_7d"] = float(lim["percent"])
        cache["scoped_7d_reset"] = iso_to_epoch(lim.get("resets_at"))
        cache["scoped_7d_label"] = model.get("display_name") or "Scoped"
        # Fetch stamp lets the probe fallback carry these keys for a bounded
        # time instead of blanking the slot on every fallback cycle.
        cache["scoped_7d_fetched_at"] = now
        break

tmp = "%s.tmp.%d" % (CACHE, os.getpid())
with open(tmp, "w") as f:
    json.dump(cache, f)
os.replace(tmp, CACHE)

# Rich history, deduped on the utilization signature so idle minutes don't flood
# the file. Signature is kept in a tiny sidecar so we never read the big log.
if HISTORY:
    def util(x):
        return (x or {}).get("utilization") if isinstance(x, dict) else None
    signature = json.dumps(
        {k: util(d.get(k)) for k in (
            "five_hour", "seven_day", "seven_day_opus",
            "seven_day_sonnet", "seven_day_oauth_apps")},
        sort_keys=True)
    last = ""
    if SIG:
        try:
            with open(SIG) as f:
                last = f.read()
        except Exception:
            last = ""
    if signature != last:
        with open(HISTORY, "a") as f:
            f.write(json.dumps({"t": round(now, 1), "data": d}) + "\n")
        if SIG:
            with open(SIG, "w") as f:
                f.write(signature)

# 5h window-start detection. The 5h reset creeps forward minute-by-minute as a
# rolling window, then jumps ~5h at a true rollover. We log a window-start event
# only on a big jump (>30 min beyond the last-seen reset), which cleanly ignores
# the creep. window_start is the new window's reset minus 5h.
if WINDOWS:
    fr_iso = fh.get("resets_at")
    fr = iso_to_epoch(fr_iso)
    if fr:
        last_reset = 0.0
        if WINSIG:
            try:
                last_reset = float(open(WINSIG).read().strip() or 0)
            except Exception:
                last_reset = 0.0
        if fr - last_reset > 1800:
            start = fr - 5 * 3600
            with open(WINDOWS, "a") as f:
                f.write(json.dumps({
                    "kind": "5h",
                    "detected_at": round(now, 1),
                    "window_start": round(start, 1),
                    "window_start_iso": datetime.fromtimestamp(start).astimezone().isoformat(timespec="seconds"),
                    "reset_at": round(fr, 1),
                    "reset_at_iso": datetime.fromtimestamp(fr).astimezone().isoformat(timespec="seconds"),
                    "five_hour_util_at_detect": five,
                }) + "\n")
        if fr > last_reset and WINSIG:
            with open(WINSIG, "w") as f:
                f.write(repr(fr))

print("%g %g" % (five, seven))
