#!/usr/bin/env python3
"""tiiny ask — an agentic code-intelligence companion backed by the (free, local)
Tiiny device. The device model orchestrates squackit's MCP tools over a repo to
answer a question, so codebase exploration is offloaded off my context.

  ./tiiny-ask.py "which functions call ensure_loaded, and where is it defined?"
  ./tiiny-ask.py --path ~/code/some-project "outline the inference dispatch flow"
  TIINY_ROUTE=tiiny/default ./tiiny-ask.py "..."   # thinking model for hard ones

Design notes baked in from evaluation:
- squackit's MCP schemas DON'T document the selector DSL, so it's in the system
  prompt here (the .fn#NAME cheat-sheet) — without it the model guesses XPath.
- find_names returns NAMES; find returns FILE PATHS + ranges. Guidance included.
- device serves one model at a time; ensure the target is loaded before use.
"""
import argparse, asyncio, glob, json, os, shutil, sys, urllib.request
from fastmcp import Client

HERE = os.path.dirname(os.path.abspath(__file__))


def squackit_bin():
    """Locate squackit, or say so in one line.

    A venv beside this script is the workstation layout, and it is NOT what you
    get on a fresh clone. When the binary is missing, fastmcp discovers it deep
    inside an async connect and raises an ExceptionGroup whose last line is a
    FileNotFoundError naming a path the caller never chose -- 25 lines that read
    like a bug in this tool. The check belongs here, before the client opens.
    """
    env = os.environ.get("SQUACKIT")
    if env:
        if os.access(env, os.X_OK):
            return env
        raise SystemExit(f"tiiny-ask: SQUACKIT={env} is not an executable")
    local = os.path.join(HERE, ".venv/bin/squackit")
    if os.access(local, os.X_OK):
        return local
    found = shutil.which("squackit")
    if found:
        return found
    raise SystemExit(
        "tiiny-ask: squackit not found — it is what drives the code-intelligence\n"
        "           tools, so `ttt ask --code` cannot run without it.\n"
        f"           Looked at: $SQUACKIT, {local}, then PATH.\n"
        "           Install squackit, or set SQUACKIT=/path/to/squackit.")
# Device OpenAI endpoint (:80). Default is a NAME: *.tiiny is real DNS via the
# bridge host's dnsmasq, proxied to the device over the USB /30 — so this survives
# the device's DHCP drift and its roam-unstable radio, and works from any LAN host.
# Set TIINY_IP to talk to the device directly (off-LAN, or the bridge host down).
DEVICE = os.environ.get("TIINY_IP") or os.environ.get("TIINY_HOST", "api.tiiny")

# Bearer: env first so this runs where pcsvr doesn't (pcsvr only runs on one host);
# its auth_data dir is the fallback, not the requirement.
def _auth_key() -> str:
    k = os.environ.get("TIINY_AUTH_KEY")
    if k:
        return k
    matches = glob.glob(os.path.expanduser("~/.local/share/tiiny-pcsvr/auth_data/*.json"))
    if not matches:
        raise SystemExit(
            "tiiny-ask: no device token. Set TIINY_AUTH_KEY, or run on a host where\n"
            "           pcsvr keeps ~/.local/share/tiiny-pcsvr/auth_data/<serial>.json."
        )
    return json.load(open(matches[0]))["auth_key"]

KEY = _auth_key()
ROUTE = os.environ.get("TIINY_ROUTE", "default")  # device model id; 'default' = loaded model
MAX_STEPS = 12

# Curated, high-signal squackit tools with usage hints (the model only sees these).
TOOLSET = {
    "project_overview": "file counts by language for the project — call first to orient.",
    "explore":          "first-contact briefing: languages, key defs, docs, recent activity.",
    "find":             "AST nodes + FILE PATHS + line ranges matching a selector. USE THIS to locate where things are defined.",
    "find_names":       "just the NAMES of matching AST nodes (no paths). Use only when you want names, not locations.",
    "search":           "full-text search: definitions + call sites + docs in one call. Good for 'where is X mentioned'.",
    "investigate":      "deep dive on ONE symbol: its definition + source + callers + callees. Best for 'what calls X' / 'what does X do'.",
    "call_graph":       "call relationships within a file pattern.",
    "read_source":      "read specific lines of a file (file_path, lines?, ctx?).",
}

SELECTOR_GUIDE = (
    "squackit AST selectors are CSS-like (NOT XPath, NOT `function[name=...]`):\n"
    "  .fn = any function   .cls = any class   .fn#NAME = function named NAME   .cls#NAME = class named NAME\n"
    "  .fn:has(.call#X) = functions that call X\n"
    "The `source` arg is a file glob, e.g. **/*.py . Example: find(source='**/*.py', selector='.fn#ensure').\n"
    "To LOCATE definitions use `find` (returns paths); `find_names` returns only names.\n"
    "To understand ONE symbol (definition, callers, callees) use `investigate(name)`."
)

def chat(messages, tools, max_tokens):
    body = {"model": ROUTE, "messages": messages, "tools": tools, "tool_choice": "auto",
            "max_tokens": max_tokens, "chat_template_kwargs": {"enable_thinking": ROUTE.endswith("Thinking")}}
    r = urllib.request.Request(f"http://{DEVICE}/v1/chat/completions", method="POST",
        headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"},
        data=json.dumps(body).encode())
    return json.loads(urllib.request.urlopen(r, timeout=400).read())["choices"][0]

async def ask(question, path, quiet):
    # cwd (not env PWD) is what scopes squackit to the target repo — the stdio
    # transport otherwise spawns it in the parent's cwd and analyzes the wrong tree.
    cfg = {"mcpServers": {"squackit": {"command": squackit_bin(), "args": ["mcp", "serve"],
                                       "cwd": path,
                                       # quiet the MCP subprocess so its banner/INFO
                                       # logs don't pollute the companion's output
                                       "env": {"PWD": path,
                                               "FASTMCP_SHOW_SERVER_BANNER": "false",
                                               "FASTMCP_LOG_LEVEL": "ERROR"}}}}
    def log(m):
        if not quiet: print(m, file=sys.stderr, flush=True)
    async with Client(cfg) as sq:
        avail = {t.name: t for t in await sq.list_tools()}
        oai = [{"type": "function", "function": {
                    "name": n, "description": TOOLSET[n],
                    "parameters": avail[n].inputSchema or {"type": "object", "properties": {}}}}
               for n in TOOLSET if n in avail]
        log(f"[tiiny-ask] repo={path} model={ROUTE} tools={[t['function']['name'] for t in oai]}")
        messages = [
            {"role": "system", "content":
             f"You are a precise code-intelligence agent working in the repo at {path}. "
             "Answer the user's question by calling tools to gather FACTS — never guess "
             "about code you haven't inspected. Analyze the PROJECT'S OWN code — ignore "
             "vendored dependency trees (.venv, node_modules, site-packages); scope globs "
             "to the project source (e.g. src/**/*.py or the top-level package), not blanket "
             "**/*.py. Prefer the fewest calls that establish the "
             f"answer, then state it plainly and concisely.\n\n{SELECTOR_GUIDE}"},
            {"role": "user", "content": question},
        ]
        for step in range(1, MAX_STEPS + 1):
            ch = chat(messages, oai, max_tokens=900)
            msg = ch["message"]; messages.append(msg)
            calls = msg.get("tool_calls") or []
            if not calls:
                print((msg.get("content") or "").strip())
                return
            for c in calls:
                name = c["function"]["name"]
                try: args = json.loads(c["function"]["arguments"] or "{}")
                except Exception: args = {}
                log(f"  · {name}({json.dumps(args)[:100]})")
                try:
                    res = await sq.call_tool(name, args)
                    out = "".join(getattr(b, "text", "") for b in (res.content or []))[:2000]
                    if not out.strip(): out = "(no results)"
                except Exception as e:
                    out = f"tool error: {e}"
                messages.append({"role": "tool", "tool_call_id": c["id"], "content": out})
        print("(tiiny-ask: reached step limit without a final answer)", file=sys.stderr)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("question")
    ap.add_argument("--path", default=os.getcwd(), help="repo root to analyze (default: cwd)")
    ap.add_argument("--quiet", action="store_true", help="suppress the tool trail on stderr")
    a = ap.parse_args()
    asyncio.run(ask(a.question, os.path.abspath(a.path), a.quiet))
