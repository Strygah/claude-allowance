#!/usr/bin/env python3
"""Ask the official Claude Code CLI for the account's usage, the sanctioned way.

Starts the CLI headlessly in stream-json mode from an EMPTY working directory,
sends a single `get_usage` control request, prints the usage payload (the same
shape as GET /api/oauth/usage) as one JSON line on stdout, and stops the CLI.

  * No model turn: zero quota, no prompt text, no session transcript.
  * The CLI authenticates itself. If its OAuth access token has expired it
    rotates it exactly as an interactive launch would, and that side effect
    is what keeps the keychain token fresh for the updater's direct fetches.
    This script never reads or writes the keychain.
  * The EMPTY cwd matters. The CLI scans its working tree at startup; when it
    inherits the menu bar app's launchd cwd (`/`) that scan reaches Downloads,
    the Music/TV library, network volumes... each one a macOS consent dialog
    attributed to the app. From an empty directory it touches nothing gated.

Usage: claude-usage-rpc.py <claude-binary> <empty-cwd>
Exit 0 with the JSON on stdout; non-zero (reason on stderr) on any failure,
including a protocol change (Anthropic marks this control API experimental),
so the caller can fall back.
"""
import json
import os
import pwd
import select
import subprocess
import sys
import time

DEADLINE_S = 45


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: claude-usage-rpc.py <claude-binary> <empty-cwd>")
    claude_bin, cwd = sys.argv[1], sys.argv[2]
    os.makedirs(cwd, exist_ok=True)
    home = os.path.expanduser("~")
    env = {  # the same minimal environment a launchd job gives us: nothing inherited
        "HOME": home,
        "USER": os.environ.get("USER") or pwd.getpwuid(os.getuid()).pw_name,
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:" + os.path.join(home, ".local", "bin"),
    }
    cmd = [claude_bin, "-p", "--input-format", "stream-json",
           "--output-format", "stream-json", "--verbose"]
    try:
        p = subprocess.Popen(cmd, cwd=cwd, env=env, bufsize=0, stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError as e:
        sys.exit("cannot start %s: %s" % (claude_bin, e))

    req = {"type": "control_request", "request_id": "usage-1",
           "request": {"subtype": "get_usage", "skip_behaviors": True}}
    result, reason = None, "no control_response within %ds" % DEADLINE_S
    buf = b""
    try:
        p.stdin.write((json.dumps(req) + "\n").encode())
        p.stdin.flush()
        deadline = time.time() + DEADLINE_S
        fd = p.stdout.fileno()
        while result is None and time.time() < deadline:
            ready, _, _ = select.select([fd], [], [], 1.0)
            if not ready:
                if p.poll() is not None:
                    reason = "cli exited (rc=%s) without answering" % p.returncode
                    break
                continue
            chunk = os.read(fd, 65536)
            if not chunk:
                reason = "cli closed its output (rc=%s)" % p.poll()
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if msg.get("type") != "control_response":
                    continue
                resp = msg.get("response") or {}
                if resp.get("subtype") != "success":
                    reason = "cli refused get_usage: %s" % (resp.get("error") or resp.get("subtype"))
                    break
                payload = resp.get("response") or {}
                limits = payload.get("rate_limits") or {}
                if payload.get("rate_limits_available") is False or not isinstance(limits, dict) \
                        or not (limits.get("five_hour") or limits.get("seven_day")):
                    reason = "get_usage answered without rate limits"
                    break
                result = limits
                break
            if reason.startswith("cli refused") or reason.startswith("get_usage answered"):
                break
    except OSError as e:
        reason = "pipe error: %s" % e
    finally:
        for stream in (p.stdin, p.stdout):
            try:
                stream.close()
            except OSError:
                pass
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()
    if result is None:
        sys.exit(reason)
    sys.stdout.write(json.dumps(result, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
