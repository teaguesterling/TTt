#!/usr/bin/env python3
"""tiiny librarian — answer a question from a tiibrarian corpus. LOOSE mode.

  ./tiiny-librarian.py "how do you purify water with bleach"
  ./tiiny-librarian.py --raw --topk 5 "field expedient antenna"

This is a RELAXED cordexa. The full pipeline retrieves, synthesizes, and then
grounds: a claim survives only if it quotes a span verbatim from the page it
cites, and the answer abstains when none survive. That check is deliberately
NOT here.

What that costs you, stated plainly: the model can say things the passages do
not support, and the citations tell you which pages were RETRIEVED, not that
the sentence next to [3] is actually in page 3. Treat the answer as a lead and
the locators as where to look. The grounded path is `corpus.ask_grounded`.

What is real: the retrieval. Two-stage vector search over page embeddings —
HNSW on a stored 256-d truncation, then an exact re-rank on the full 1024-d
vector (recall 0.987 at shortlist 100, 0.996 at 200). The query MUST be
embedded by the same NPU encoder that built the index; corpus.embed_query
raises rather than falling back to the device's CPU embedder, whose vectors
are close enough to look fine and retrieve worse.

Needs: the NPU embedder resident, a chat model resident (unless --raw), and a
corpus. TIIBRARIAN_CORPUS names the database; TIIBRARIAN_HOME the checkout.
"""
import argparse
import glob
import json
import os
import sys
import urllib.request

TIIBRARIAN = os.path.expanduser(os.environ.get("TIIBRARIAN_HOME", "~/Projects/tiibrarian"))
DEVICE = os.environ.get("TIINY_IP") or os.environ.get("TIINY_HOST", "api.tiiny")
ROUTE = os.environ.get("TIINY_ROUTE", "default")


def auth_key():
    k = os.environ.get("TIINY_AUTH_KEY")
    if k:
        return k
    m = sorted(glob.glob(os.path.expanduser("~/.local/share/tiiny-pcsvr/auth_data/*.json")))
    if not m:
        raise SystemExit("tiiny-librarian: no device token. Set TIINY_AUTH_KEY, or run on\n"
                         "                 a host where pcsvr keeps auth_data/<serial>.json.")
    return json.load(open(m[0]))["auth_key"]


def import_corpus(corpus_path):
    """Import tiibrarian's corpus module.

    Both the corpus path and the token are read by that module AT IMPORT TIME,
    so they are placed in the environment first — setting them afterwards binds
    nothing and fails later, at the embedder, with a confusing message.
    """
    if corpus_path:
        os.environ["TIIBRARIAN_CORPUS"] = os.path.abspath(os.path.expanduser(corpus_path))
    os.environ.setdefault("TIINY_AUTH_KEY", auth_key())
    if not os.path.isdir(TIIBRARIAN):
        raise SystemExit(f"tiiny-librarian: no tiibrarian checkout at {TIIBRARIAN}\n"
                         f"                 set TIIBRARIAN_HOME to point at one.")
    sys.path.insert(0, TIIBRARIAN)
    try:
        import corpus                                    # noqa: E402
    except ImportError as e:
        raise SystemExit(f"tiiny-librarian: cannot import tiibrarian's corpus module "
                         f"({e}).\n                 duckdb is required — this needs an "
                         f"interpreter that has it,\n                 not necessarily the "
                         f"one `ttt` runs by default.")
    # Checked HERE, before the caller embeds anything: the embedding is an NPU
    # round trip, and spending it on a question that cannot be answered — then
    # failing with a duckdb traceback — is the wrong order and the wrong error.
    if not os.path.exists(corpus.CORPUS):
        raise SystemExit(f"tiiny-librarian: no corpus at {corpus.CORPUS}\n"
                         f"                 set TIIBRARIAN_CORPUS or pass --corpus.")
    return corpus


def chat(prompt, key, max_tokens=1200, timeout=300):
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
            raise SystemExit("tiiny-librarian: device returned 502 — /data is probably "
                             "locked. Run:  ttt unlock")
        raise SystemExit(f"tiiny-librarian: device HTTP {e.code}")
    return (d["choices"][0]["message"]["content"] or "").strip()


def passage(corpus, hit, chars):
    text = " ".join((hit["text"] or "").split())
    if len(text) > chars:
        text = text[:chars].rsplit(" ", 1)[0] + " …"
    return text


def main():
    ap = argparse.ArgumentParser(description="loose retrieval over a tiibrarian corpus")
    ap.add_argument("question")
    ap.add_argument("--topk", type=int, default=8, help="passages to retrieve (default 8)")
    ap.add_argument("--shortlist", type=int, default=200,
                    help="coarse shortlist before the exact re-rank (default 200)")
    ap.add_argument("--chars", type=int, default=1200, help="max chars per passage")
    ap.add_argument("--corpus", help="corpus .duckdb (default: $TIIBRARIAN_CORPUS)")
    ap.add_argument("--raw", action="store_true",
                    help="print the retrieved passages and stop — no model, no summary")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    log = (lambda m: None) if a.quiet else (lambda m: print(m, file=sys.stderr, flush=True))
    corpus = import_corpus(a.corpus)
    log(f"[librarian] corpus={corpus.CORPUS}")

    qvec = corpus.embed_query(a.question)               # NPU embedder; raises if absent
    try:
        con = corpus.connect()
    except Exception as e:                              # locked, unreadable, not a database
        raise SystemExit(f"tiiny-librarian: cannot open {corpus.CORPUS}: "
                         f"{type(e).__name__}: {str(e).splitlines()[0]}")
    try:
        hits = corpus.retrieve(qvec, topk=a.topk, shortlist=a.shortlist, con=con)
    finally:
        con.close()
    if not hits:
        print("tiiny-librarian: nothing retrieved", file=sys.stderr)
        return 1
    log(f"[librarian] {len(hits)} passages, best score {hits[0]['score']:.3f}")

    # Said on stderr so it cannot be mistaken for part of the answer, and on BOTH
    # paths: --raw is the one most likely to be piped somewhere that keeps it.
    log("[librarian] loose mode — retrieval is exact, claims are NOT checked "
        "against the passages")

    numbered = [(h["n"], corpus.locator_str(h), passage(corpus, h, a.chars)) for h in hits]
    if a.raw:
        for n, loc, text in numbered:
            print(f"[{n}] {loc}\n{text}\n")
        return 0

    body = "\n\n".join(f"[{n}] {loc}\n{text}" for n, loc, text in numbered)
    prompt = ("Answer the question using ONLY the numbered passages below. Cite the "
              "passages you rely on as [n]. If they do not answer the question, say so "
              "plainly rather than filling the gap.\n\n"
              f"Question: {a.question}\n\nPassages:\n{body}")
    key = auth_key()
    print(chat(prompt, key))
    print("\nSources")
    for n, loc, _ in numbered:
        print(f"  [{n}] {loc}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
