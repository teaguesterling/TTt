#!/usr/bin/env python3
"""Guards for `ttt duckeye` — the model writes the command, so the command is
checked before it runs.

    python3 tests/test_duckeye_guards.py

No framework and no dependencies: TTt is bash plus a few stdlib helpers, and a
test that needed pytest installed would not get run. Exits non-zero on failure,
so it drops straight into a hook or a CI step.

It needs `duckeye` on PATH (tiiny-duckeye.py resolves the binary before it will
even print a dry-run), and SKIPS loudly rather than failing when that is
missing — a suite that fails for the wrong reason teaches people to ignore it.
It does NOT need the Tiiny device: every case goes through `--plan`, which
feeds the JSON in directly instead of asking a model for it. That is the whole
point of `--plan` existing.
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELPER = os.path.join(REPO, "bin", "tiiny-duckeye.py")

if shutil.which("duckeye") is None and not os.environ.get("DUCKEYE"):
    print("SKIPPED: duckeye is not on PATH, so none of these guards were exercised.")
    print("         Install duckeye, or set DUCKEYE=/path/to/duckeye, and re-run.")
    raise SystemExit(0)

spec = importlib.util.spec_from_file_location("dk", HELPER)
dk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dk)

fails = []


def run_plan(plan, extra=()):
    r = subprocess.run([sys.executable, HELPER, "--plan", "-", "--path", REPO, *extra],
                       input=json.dumps(plan), capture_output=True, text=True)
    return r.returncode, (r.stdout + r.stderr).strip()


print("== bash decodes q() back to the ORIGINAL bytes ==")
# If any of these round-trips loses a byte, a selector reaches duckeye altered.
cases = ["plain.md", "Start here", "it's here", "READ\nME.md", "a\tb",
         "trailing ", "x\x7fy", "back\\slash", "it's\nboth", "$(whoami)",
         ".call#x; rm -rf /"]
for original in cases:
    quoted = dk.q(original)
    r = subprocess.run(["bash", "-c", "printf '%s' " + quoted],
                       capture_output=True, text=True)
    ok = r.stdout == original
    oneline = "\n" not in quoted
    if not ok:
        fails.append(("roundtrip", original, quoted, r.stdout))
    if not oneline:
        fails.append(("multiline-quote", original, quoted, ""))
    print("  %-4s %-3s %-30r -> %r" % ("OK" if ok else "FAIL",
                                       "1ln" if oneline else "MUL", quoted, r.stdout))

print("\n== a control char in a model-supplied value must not span lines ==")
# Wrapping in quotes is not enough: the newline still prints, and a second line
# of output looks like a second diagnostic from the tool itself.
for name, val in [("newline", "READ\nME.md"), ("tab", "READ\tME.md"),
                  ("del", "READ\x7fME.md"), ("quote+newline", "it's\nhere.md")]:
    rc, msg = run_plan({"file": val, "args": ["-T"]}, ["--dry-run"])
    n = len(msg.splitlines())
    if n != 1:
        fails.append(("forge", name, msg, ""))
    print("  %-4s lines=%d  %s" % ("OK" if n == 1 else "FAIL", n,
                                   msg.splitlines()[0][:80] if msg else ""))

print("\n== guard matrix ==")
matrix = [
    ("valid",         {"file": "README.md", "args": ["-T"]},                 0),
    ("-o",            {"file": "README.md", "args": ["-o", "PWN"]},          1),
    ("unknown",       {"file": "README.md", "args": ["--nope"]},             1),
    ("bare arg",      {"file": "README.md", "args": ["-T", "other.md"]},     1),
    ("escape abs",    {"file": "/etc/passwd", "args": ["-T"]},               1),
    ("escape rel",    {"file": "../../etc/passwd", "args": ["-T"]},          1),
    ("-w",            {"file": "README.md", "args": ["-w", "1=1"]},          1),
    ("missing value", {"file": "README.md", "args": ["-Q"]},                 1),
    ("--init",        {"file": "README.md", "args": ["--init"]},             1),
    # A selector is one argv element: it never reaches a shell, so this is data.
    ("injection",     {"file": "README.md",
                       "args": ["-Q", ".call#x; rm -rf / $(whoami)"]},       0),
]
# The -o target is unique per run: a shared /tmp path that happens to exist for
# an unrelated reason would report a failure that is not one.
with tempfile.TemporaryDirectory() as td:
    pwn = os.path.join(td, "pwn")
    for name, plan, want in matrix:
        plan = {**plan, "args": [pwn if a == "PWN" else a for a in plan["args"]]}
        rc, msg = run_plan(plan, ["--dry-run"])
        ok = rc == want
        if not ok:
            fails.append(("guard", name, str(rc), msg))
        print("  %-4s %-14s rc=%d  %s" % ("OK" if ok else "FAIL", name, rc, msg[:66]))

    print("\n== -o must not have created its file ==")
    wrote = os.path.exists(pwn)
    if wrote:
        fails.append(("wrote", pwn, "", ""))
    print("  %-4s %s exists=%s" % ("FAIL" if wrote else "OK", pwn, wrote))

print("\n== real execution (no --dry-run) ==")
rc, msg = run_plan({"file": "README.md", "args": ["-T"]})
ok = rc == 0 and len(msg.splitlines()) > 1
if not ok:
    fails.append(("exec", "-T", str(rc), msg[:200]))
print("  %-4s rc=%d lines=%d" % ("OK" if ok else "FAIL", rc, len(msg.splitlines())))

print("\n== a bogus DUCKEYE is refused by name, not as a traceback ==")
# Found by this test the first time it ran: a wrong DUCKEYE used to reach
# subprocess.run and surface as a FileNotFoundError traceback. Dry-runs never
# caught it, because they only print the command.
r = subprocess.run([sys.executable, HELPER, "--plan", "-", "--path", REPO],
                   input=json.dumps({"file": "README.md", "args": ["-T"]}),
                   capture_output=True, text=True,
                   env={**os.environ, "DUCKEYE": "/nonexistent/duckeye"})
msg = (r.stdout + r.stderr).strip()
ok = r.returncode != 0 and "Traceback" not in msg and len(msg.splitlines()) == 1
if not ok:
    fails.append(("bogus-duckeye", str(r.returncode), msg[:200], ""))
print("  %-4s rc=%d lines=%d  %s" % ("OK" if ok else "FAIL", r.returncode,
                                     len(msg.splitlines()), msg[:72]))

print("\n%d failure(s)" % len(fails))
for f in fails:
    print("  ", f)
sys.exit(1 if fails else 0)
