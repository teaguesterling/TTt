#!/usr/bin/env python3
"""`ttt` must hand its resolved key and address to the helpers it launches.

    python3 tests/test_helper_env_passthrough.py

Hermetic: a shim `python3` earlier on PATH intercepts only the helper launches
(argv containing tiiny-ask.py / tiiny-duckeye.py) and prints the TIINY_* vars it
received; every other python call execs the real interpreter, so `ttt`'s own
JSON reads still work. No device, no network.

WHY. `ttt` resolves the device key from three sources -- TIINY_AUTH_KEY, pcsvr's
auth_data, then the vendor CLI's ~/.tiiny/config.json -- and the address from
TIINY_IP or that same vendor config. The helpers read ONLY the first two sources
and never the vendor config (bin/tiiny-ask.py, bin/tiiny-duckeye.py). So a host
set up the documented way -- `tiiny scan && tiiny connect && tiiny login`, no
Wine, no pcsvr -- had a working `ttt status` and a `ttt ask --code` that died
with "no device token", because the launch passed TIINY_ROUTE alone.

That made the README's "nothing else to configure" false for exactly the two
subcommands a new user is most likely to try after `status`. The librarian
launch had always got this right (`TIINY_IP="$IP" TIINY_AUTH_KEY="$KEY"`), which
is what made the omission visible.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TTT = os.path.join(HERE, os.pardir, "bin", "ttt")
KEY = "vendor-config-key-not-real"
ADDR = "203.0.113.17"            # TEST-NET-3, never a real host

SHIM = """#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    *tiiny-ask.py|*tiiny-duckeye.py)
      echo "SHIM_SAW TIINY_AUTH_KEY=${TIINY_AUTH_KEY-<unset>}"
      echo "SHIM_SAW TIINY_IP=${TIINY_IP-<unset>}"
      echo "SHIM_SAW TIINY_ROUTE=${TIINY_ROUTE-<unset>}"
      exit 0;;
  esac
done
exec %s "$@"
"""

fails = 0
with tempfile.TemporaryDirectory() as home, tempfile.TemporaryDirectory() as binz:
    os.makedirs(os.path.join(home, ".tiiny"))
    with open(os.path.join(home, ".tiiny", "config.json"), "w") as f:
        json.dump({"deviceAddress": ADDR, "account": {"authKey": KEY}}, f)
    shim = os.path.join(binz, "python3")
    with open(shim, "w") as f:
        f.write(SHIM % subprocess.run(["bash","-lc","command -v python3"],
                                      capture_output=True, text=True).stdout.strip())
    os.chmod(shim, 0o755)

    env = dict(os.environ)
    env.update({"HOME": home, "PATH": binz + os.pathsep + env["PATH"],
                "TIINY_HOST": "no-bridge.invalid", "TIINY_AUTH_HOST": "no-bridge.invalid"})
    for k in ("TIINY_IP", "TIINY_AUTH_KEY", "TIINY_MGMT"):
        env.pop(k, None)

    # Only `ask --code` reaches its launch without a device: `duckeye` must first
    # ask the device which model is loaded, so it cannot be driven this far
    # hermetically. Its launch is checked statically below instead -- weaker, but
    # honest about which of the two is actually exercised.
    for name, argv, want_ip in (
            ("ask --code", ["ask", "--code", HERE, "what is this"], True),):
        p = subprocess.run([TTT] + argv, capture_output=True, text=True, env=env, timeout=180)
        out = p.stdout + p.stderr
        saw = dict(re.findall(r"SHIM_SAW (\w+)=(.*)", out))
        if not saw:
            print("FAIL %-12s helper was never launched; output:\n%s" % (name, out[:400]))
            fails += 1
            continue
        if saw.get("TIINY_AUTH_KEY") != KEY:
            print("FAIL %-12s TIINY_AUTH_KEY=%r, expected the vendor-config key"
                  % (name, saw.get("TIINY_AUTH_KEY")))
            print("              -> the helper cannot reach the device; it reads no vendor config")
            fails += 1
        else:
            print("ok   %-12s received the resolved key" % name)
        if want_ip and saw.get("TIINY_IP") != ADDR:
            print("FAIL %-12s TIINY_IP=%r, expected the vendor-config deviceAddress"
                  % (name, saw.get("TIINY_IP")))
            fails += 1
        elif want_ip:
            print("ok   %-12s received the resolved address" % name)
        if KEY in out.replace("SHIM_SAW TIINY_AUTH_KEY=" + KEY, ""):
            print("FAIL %-12s key leaked elsewhere in output" % name)
            fails += 1

# --- static check: every helper launch carries the key -----------------------
# A launch that forgets TIINY_AUTH_KEY produces a "no device token" exit on a
# vendor-CLI-only host, which is what this whole file exists to prevent. The
# behavioural test above covers ask --code; this covers the rest without needing
# a device, and will fail if a future launch is added without the key.
src = open(TTT).read()
launches = re.findall(r"TIINY_ROUTE=[^\n]*(?:\\\n\s*)?[^\n]*(tiiny-ask\.py|tiiny-duckeye\.py|tiiny-librarian\.py)", src)
for helper in ("tiiny-ask.py", "tiiny-duckeye.py", "tiiny-librarian.py"):
    # the launch is the TIINY_ROUTE=... run of text ending at the helper name
    m = re.search(r"(TIINY_ROUTE=[\s\S]{0,300}?%s)" % re.escape(helper), src)
    if not m:
        print("FAIL static   no launch found for %s" % helper); fails += 1; continue
    blk = m.group(1)
    if "TIINY_AUTH_KEY=" in blk:
        print("ok   static    %-22s launch carries TIINY_AUTH_KEY" % helper)
    else:
        print("FAIL static   %-22s launch does NOT pass TIINY_AUTH_KEY" % helper); fails += 1

print("\n%d failure(s)" % fails)
sys.exit(1 if fails else 0)
