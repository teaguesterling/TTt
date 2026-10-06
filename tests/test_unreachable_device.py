#!/usr/bin/env python3
"""`ttt status` when the device cannot be reached — the first thing a new user hits.

    python3 tests/test_unreachable_device.py

No device and no network: every name below is under `.invalid`, which RFC 2606
guarantees will never resolve. That makes this the one path that is always
reproducible, and it is also the most likely first experience of anyone who
clones TTt without the `*.tiiny` bridge host — the default `HOST` is a NAME
(`api.tiiny`) served by a dnsmasq+Caddy bridge most people will not have.

Two things it pins, both found 2026-10-05:

1. `device_state` returned `"?\\n?"` rather than `"?"`. `set -euo pipefail` is
   on, so when curl fails the PIPELINE fails even though the python fallback
   already printed `?` — and the `|| printf '?'` fired as well. The caller
   interpolates that into a sentence, so the status output broke across two
   lines and the second was a bare `? — run 'ttt unlock'` with no context.
2. `ttt status` exited 0 while printing UNREACHABLE, so nothing scripted could
   tell success from a device that is simply not there. `ttt doctor` already
   gets this right ("at least one check failed"), which is what made the
   inconsistency visible.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TTT = os.path.join(HERE, os.pardir, "bin", "ttt")

env = dict(os.environ)
env.update({
    "TIINY_HOST": "no-bridge.invalid",
    "TIINY_AUTH_HOST": "no-bridge.invalid",
    "TIINY_MGMT": "http://no-bridge.invalid/api/v1",
    "TIINY_AUTH_KEY": "dummy-not-a-real-token",
})
env.pop("TIINY_IP", None)

p = subprocess.run([TTT, "status"], capture_output=True, text=True, env=env, timeout=180)
out = p.stdout
print(out, end="")
print("--- exit %d ---\n" % p.returncode)

fails = 0

# 1. every line of the report is a report line, not the tail of a broken one.
stray = [ln for ln in out.splitlines() if ln and not ln.startswith((" ", "device ", "woollama"))]
if stray:
    print("FAIL: output has line(s) that are not part of the report: %r" % stray)
    print("      (device_state leaking a newline splits its caller's sentence)")
    fails += 1
else:
    print("ok: no stray lines")

# 2. the unknown lock state is reported once, as one token.
if out.count("?") > 1:
    print("FAIL: the unknown-state marker appears %d times; expected 1" % out.count("?"))
    fails += 1
else:
    print("ok: unknown lock state reported once")

# 3. an unreachable device is a failure, not a success.
if "UNREACHABLE" in out and p.returncode == 0:
    print("FAIL: printed UNREACHABLE but exited 0 — a caller cannot detect this")
    fails += 1
elif "UNREACHABLE" not in out:
    print("FAIL: expected UNREACHABLE against an unresolvable host; got:\n%s" % out)
    fails += 1
else:
    print("ok: unreachable device exits non-zero (%d)" % p.returncode)

print("\n%d failure(s)" % fails)
sys.exit(1 if fails else 0)
