#!/usr/bin/env python3
"""`ttt` picks up the device address and key from the vendor CLI's own config.

    python3 tests/test_vendor_config_fallback.py

Hermetic: runs against a throwaway $HOME holding a synthetic
`~/.tiiny/config.json`, and an unresolvable `.invalid` name for the bridge, so
it needs neither a device nor a network.

WHY THIS EXISTS. Before it, `ttt` could find a key in exactly one place --
pcsvr's `auth_data/<serial>.json` -- and pcsvr is a Windows Go binary with no
Linux build, needing a patched Wine and a ~1.8 GB compile. So the documented
route to the CLI ran through the whole desktop stack, and the "headless host"
shortcut said `export TIINY_AUTH_KEY=...` without saying where anyone would
get one. There was no answer in the repo.

There is one: the vendor `tiiny` CLI runs natively on Linux and writes BOTH
facts to `~/.tiiny/config.json` -- `deviceAddress` (from `tiiny scan` /
`tiiny connect`) and `account.authKey` (from `tiiny login`). Reading it makes
the CLI work with no Wine, no pcsvr and no bridge.

Precedence is unchanged where it already worked: explicit env wins, then
pcsvr's auth_data, then this. The bridge name is still preferred when it
resolves, so a host with the `*.tiiny` bridge behaves exactly as before.
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TTT = os.path.join(HERE, os.pardir, "bin", "ttt")
ADDR = "203.0.113.17"          # TEST-NET-3: routable-looking, never a real host
KEY = "vendor-config-key-not-real"

fails = 0
with tempfile.TemporaryDirectory() as home:
    os.makedirs(os.path.join(home, ".tiiny"))
    with open(os.path.join(home, ".tiiny", "config.json"), "w") as f:
        json.dump({"deviceAddress": ADDR, "account": {"authKey": KEY}}, f)

    env = dict(os.environ)
    env["HOME"] = home
    env["TIINY_HOST"] = "no-bridge.invalid"          # the bridge does not exist here
    env["TIINY_AUTH_HOST"] = "no-bridge.invalid"
    for k in ("TIINY_IP", "TIINY_AUTH_KEY", "TIINY_MGMT"):
        env.pop(k, None)

    p = subprocess.run([TTT, "doctor"], capture_output=True, text=True, env=env, timeout=180)
    out = p.stdout + p.stderr
    print(out, end="")
    print("--- exit %d ---\n" % p.returncode)

    # 1. the address from the vendor config is the one it talks to
    if ADDR in out:
        print("ok: used deviceAddress from ~/.tiiny/config.json")
    else:
        print("FAIL: never used deviceAddress %s from the vendor config" % ADDR)
        fails += 1

    # 2. it did NOT demand a token: the key came from the same file
    if "no device token" in out:
        print("FAIL: demanded TIINY_AUTH_KEY despite account.authKey being present")
        fails += 1
    else:
        print("ok: took the key from the vendor config")

    # 3. the key itself is never echoed
    if KEY in out:
        print("FAIL: the auth key appears in output")
        fails += 1
    else:
        print("ok: key not echoed")

print("\n%d failure(s)" % fails)
sys.exit(1 if fails else 0)
