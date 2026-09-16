#!/usr/bin/env python3
"""tiiny duckeye — let the device write a duckeye command, then run it safely.

  ./tiiny-duckeye.py "where do we call execute in corpus.py"
  ./tiiny-duckeye.py --dry-run "what sections does the README have"
  ./tiiny-duckeye.py --answer  "which functions catch errors in parser.py"

THE MODEL EMITS JSON, NOT A COMMAND LINE. It returns
{"file": ..., "args": [...], "why": ...} and the args list is handed to
subprocess as argv with shell=False. Nothing is ever interpolated into a
shell string, so quoting stops being a security question: a selector
containing ; or $(...) is just an argument that duckeye will fail to parse.
This is the whole reason for the JSON detour — a model that writes
`duckeye -Q '.call#x' file.py` writes a string someone has to unquote, and
unquoting model output correctly is the bug you do not want to own.

Two more guards, because argv alone is not enough:

* FLAG ALLOW-LIST. Only the read-only query surface is accepted. -o/--output
  writes files, --init/--update mutate the duckeye install, -p/--page spawns
  a pager that would hang a pipeline. An unknown flag is refused rather than
  passed through, so a duckeye upgrade cannot silently widen what the model
  can reach.

* -w/--where IS NOT MODEL-AUTHORABLE by default. It is a raw SQL expression
  evaluated by DuckDB, which is a far wider surface than a selector — DuckDB
  functions can read other files. --allow-where opts in when you want it.

PATH CONTAINMENT: the chosen file must resolve inside --path. The model picks
from a listing we generate, but it can return anything, so the answer is
checked rather than trusted.

--plan runs the validator and duckeye WITHOUT the device, from a JSON file or
stdin. That is how the guards get tested: no NPU, no network, deterministic.
"""
import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CARD = os.path.join(os.path.dirname(HERE), "examples", "duckeye-card.md")
# Same device convention as tiiny-ask.py: a NAME by default (real DNS via the
# bridge), TIINY_IP to talk straight to the device.
DEVICE = os.environ.get("TIINY_IP") or os.environ.get("TIINY_HOST", "api.tiiny")
ROUTE = os.environ.get("TIINY_ROUTE", "default")   # 'default' = whatever is loaded

# Flags the model may use. True = the flag takes a value, False = boolean.
ALLOWED = {
    "-Q": True,  "--select": True,
    "-S": True,  "--section": True,
    "-s": True,  "--search": True,
    "-T": False, "--toc": False,
    "-P": True,  "--pages": True,
    "-t": True,  "--to": True,
    "-n": True,  "--limit": True,
    "-f": True,  "--from": True,
    "-d": False, "--data": False,
    "-D": False, "--document": False,
    "-z": False, "--summary": False,
    "-Z": False, "--profile": False,
}
WHERE = {"-w": True, "--where": True}
# Named so the refusal can say WHY, instead of "unknown flag".
REFUSED = {
    "-o": "writes a file", "--output": "writes a file",
    "-i": "the file comes from the plan's \"file\", not from args",
    "--input": "the file comes from the plan's \"file\", not from args",
    "-p": "spawns a pager and would hang", "--page": "spawns a pager and would hang",
    "--init": "mutates the duckeye installation",
    "--update": "mutates the duckeye installation",
}
# What duckeye can actually read; also keeps the file listing short enough to
# spend on a prompt.
EXTS = {".py", ".js", ".jsx", ".ts", ".tsx", ".go", ".rs", ".c", ".h", ".cc", ".cpp",
        ".java", ".rb", ".sh", ".bash", ".sql", ".lua", ".pl", ".php", ".swift", ".kt",
        ".md", ".markdown", ".rst", ".txt", ".org", ".tex", ".html", ".htm",
        ".pdf", ".docx", ".odt", ".epub", ".ipynb", ".zim",
        ".json", ".csv", ".tsv", ".parquet", ".xlsx", ".yaml", ".yml", ".toml"}


def q(s):
    """Single-quote a value. ALWAYS — even when it would survive unquoted.

    shlex.quote() quotes only what a shell would mangle, which prints a command
    where some arguments look special and others look bare, and leaves the reader
    deciding which is which. Quoting everything removes the question: the dry-run
    line pastes anywhere, and a value carrying a newline, a trailing space or a
    control character shows up instead of silently reshaping the output.

    That last point is why the error messages use this too. `file` and `args`
    come from the model, and a string with a newline in it could forge a second
    line of diagnostics that looks like it came from here. Wrapping such a value
    in quotes is NOT enough — the newline is still emitted and the message still
    spans two lines — so a value carrying control characters is rendered in bash
    ANSI-C form, $'READ\\nME.md', which stays on one line and still pastes
    correctly. Everything else gets ordinary single quotes.
    """
    s = str(s)
    if any(ord(c) < 0x20 or ord(c) == 0x7F for c in s):
        esc = (s.replace("\\", "\\\\").replace("'", "\\'")
                .replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r"))
        esc = "".join(c if 0x20 <= ord(c) != 0x7F else "\\x%02x" % ord(c) for c in esc)
        return "$'" + esc + "'"
    return "'" + s.replace("'", "'\\''") + "'"


def join(argv):
    """A command line with every token quoted, for display only."""
    return " ".join(q(x) for x in argv)


def auth_key():
    k = os.environ.get("TIINY_AUTH_KEY")
    if k:
        return k
    m = sorted(glob.glob(os.path.expanduser("~/.local/share/tiiny-pcsvr/auth_data/*.json")))
    if not m:
        raise SystemExit("tiiny-duckeye: no device token. Set TIINY_AUTH_KEY, or run on a\n"
                         "               host where pcsvr keeps auth_data/<serial>.json.")
    return json.load(open(m[0]))["auth_key"]


def list_files(root, cap):
    """Candidate files, git's view first — it already excludes build spoil."""
    out = []
    try:
        r = subprocess.run(["git", "-C", root, "ls-files"], capture_output=True,
                           text=True, timeout=10)
        if r.returncode == 0:
            out = [p for p in r.stdout.splitlines() if os.path.splitext(p)[1].lower() in EXTS]
    except (OSError, subprocess.SubprocessError):
        pass
    if not out:
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames
                           if not d.startswith(".") and d not in
                           ("node_modules", "site-packages", "__pycache__", "venv", ".venv")]
            for f in filenames:
                if os.path.splitext(f)[1].lower() in EXTS:
                    out.append(os.path.relpath(os.path.join(dirpath, f), root))
            if len(out) > cap * 4:
                break
    out.sort(key=lambda p: (p.count(os.sep), len(p)))     # shallow, short paths first
    return out[:cap]


def chat(prompt, key, max_tokens, timeout=300):
    body = {"model": ROUTE, "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens, "temperature": 0,
            "chat_template_kwargs": {"enable_thinking": False}}
    req = urllib.request.Request(f"http://{DEVICE}/v1/chat/completions", method="POST",
                                 headers={"Authorization": f"Bearer {key}",
                                          "Content-Type": "application/json"},
                                 data=json.dumps(body).encode())
    try:
        d = json.loads(urllib.request.urlopen(req, timeout=timeout).read())
    except urllib.error.HTTPError as e:
        if e.code == 502:
            raise SystemExit("tiiny-duckeye: device returned 502 — /data is probably "
                             "locked. Run:  ttt unlock")
        raise SystemExit(f"tiiny-duckeye: device HTTP {e.code}")
    return (d["choices"][0]["message"]["content"] or "").strip()


def parse_plan(text):
    """The first JSON object in the reply. Models fence, prefix and apologise."""
    start = text.find("{")
    end = text.rfind("}")
    if start < 0 or end <= start:
        raise SystemExit(f"tiiny-duckeye: model did not return JSON:\n{text[:400]}")
    try:
        return json.loads(text[start:end + 1])
    except json.JSONDecodeError as e:
        raise SystemExit(f"tiiny-duckeye: model returned unparseable JSON ({e}):\n"
                         f"{text[start:end + 1][:400]}")


def validate(plan, root, allow_where):
    """-> (abs_path, args). Raises SystemExit with a reason on anything unexpected."""
    if not isinstance(plan, dict):
        raise SystemExit("tiiny-duckeye: plan is not an object")
    f = plan.get("file")
    args = plan.get("args")
    if not isinstance(f, str) or not f.strip():
        raise SystemExit("tiiny-duckeye: plan has no \"file\"")
    if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
        raise SystemExit("tiiny-duckeye: plan's \"args\" must be a list of strings")

    # Containment: resolve against root and require the result to stay inside it.
    root_real = os.path.realpath(root)
    target = os.path.realpath(f if os.path.isabs(f) else os.path.join(root_real, f))
    if target != root_real and not target.startswith(root_real + os.sep):
        raise SystemExit(f"tiiny-duckeye: refusing a file outside --path: {q(f)}")
    if not os.path.isfile(target):
        raise SystemExit(f"tiiny-duckeye: no such file in {q(root)}: {q(f)}")

    table = dict(ALLOWED)
    if allow_where:
        table.update(WHERE)
    i = 0
    while i < len(args):
        a = args[i]
        flag, inline = (a.split("=", 1) + [None])[:2] if a.startswith("--") and "=" in a else (a, None)
        if flag in REFUSED:
            raise SystemExit(f"tiiny-duckeye: refusing {q(flag)} — {REFUSED[flag]}")
        if flag in WHERE and not allow_where:
            raise SystemExit("tiiny-duckeye: refusing -w/--where — it is a raw SQL "
                             "expression. Pass --allow-where to permit it.")
        if flag not in table:
            if flag.startswith("-"):
                raise SystemExit(f"tiiny-duckeye: refusing unknown flag {q(flag)}")
            raise SystemExit(f"tiiny-duckeye: refusing bare argument {q(a)} — the file "
                             "belongs in the plan's \"file\"")
        if table[flag] and inline is None:
            if i + 1 >= len(args):
                raise SystemExit(f"tiiny-duckeye: {q(flag)} needs a value")
            i += 2
        else:
            i += 1
    return target, args


def main():
    ap = argparse.ArgumentParser(description="device-authored duckeye commands")
    ap.add_argument("request", nargs="?", help="what you want to see")
    ap.add_argument("--path", default=os.getcwd(), help="root to search (default: cwd)")
    ap.add_argument("--card", default=CARD, help="prompt template")
    ap.add_argument("--plan", help="skip the device: read the JSON plan from FILE or -")
    ap.add_argument("--dry-run", action="store_true", help="print the command, run nothing")
    ap.add_argument("--answer", action="store_true", help="feed the output back for a written answer")
    ap.add_argument("--allow-where", action="store_true", help="permit -w/--where (raw SQL)")
    ap.add_argument("--max-files", type=int, default=200)
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    root = os.path.abspath(a.path)
    log = (lambda m: None) if a.quiet else (lambda m: print(m, file=sys.stderr, flush=True))

    if a.plan:
        raw = sys.stdin.read() if a.plan == "-" else open(a.plan).read()
        plan = parse_plan(raw)
        key = None
        # --plan supplies the command but not the question, and --answer needs
        # one: without this the model is asked "Question: None" and dutifully
        # replies that the question is not specified.
        if a.answer and not a.request:
            raise SystemExit('tiiny-duckeye: --answer needs the question too — give it '
                             'as the positional request alongside --plan')
    else:
        if not a.request:
            raise SystemExit('usage: tiiny-duckeye.py "<request>" [--path DIR] [--dry-run]')
        files = list_files(root, a.max_files)
        if not files:
            raise SystemExit(f"tiiny-duckeye: no readable files under {root}")
        card = open(a.card).read()
        prompt = card.replace("{{files}}", "\n".join("  " + f for f in files)) \
                     .replace("{{input}}", a.request)
        key = auth_key()
        log(f"[tiiny-duckeye] {len(files)} files · model={q(ROUTE)}")
        plan = parse_plan(chat(prompt, key, max_tokens=300))

    target, args = validate(plan, root, a.allow_where)
    duckeye = os.environ.get("DUCKEYE") or shutil.which("duckeye")
    if not duckeye:
        raise SystemExit("tiiny-duckeye: duckeye is not on PATH (set DUCKEYE=/path/to/duckeye)")
    argv = [duckeye] + args + [target]

    why = plan.get("why")
    if why:
        # Model-supplied prose: collapse whitespace so it cannot span lines, cap
        # it, and quote it like everything else.
        log("[tiiny-duckeye] " + q(" ".join(str(why).split())[:120]))
    if a.dry_run:
        print(join(argv))
        return 0

    # shell=False: args reach duckeye exactly as the model wrote them.
    r = subprocess.run(argv, capture_output=True, text=True)
    out = r.stdout
    # -Q, -S and -s exit 1 on no match. That is a result, not a failure: the
    # selector was simply wrong or too narrow (a model asked for calls to
    # "http" will match nothing, because the callee is named urlopen).
    empty = r.returncode != 0 and not out.strip()
    if empty:
        msg = (r.stderr or "").strip() or "no match"
        print(f"tiiny-duckeye: duckeye found nothing ({msg})", file=sys.stderr)
        if not a.answer:
            return r.returncode
        # In --answer mode the caller asked a QUESTION, so an empty extract still
        # gets answered — "that selector matched nothing" is the honest answer,
        # and going silent here would look like the command did nothing at all.
    elif not a.answer:
        sys.stdout.write(out)
        return 0

    key = key or auth_key()
    clipped = out[:6000]
    note = "\n[output truncated]" if len(out) > len(clipped) else ""
    extract = f"{clipped}{note}" if not empty else "(the command matched nothing)"
    follow = (f"Answer the question using ONLY the extract below. Quote the names and "
              f"line numbers you rely on. If the extract does not answer it, say so "
              f"plainly and name a better selector to try.\n\n"
              f"Question: {a.request}\n\nFrom {q(os.path.relpath(target, root))} "
              f"({join(args)}):\n{extract}")
    print(chat(follow, key, max_tokens=1200))
    return 0


if __name__ == "__main__":
    sys.exit(main())
