# Utilities reference

Everything in `bin/`. All of it talks to the Tiiny Pocket; none of it needs the
TiinyOS desktop app running.

## Conventions shared by every tool

**Addressing — names, not IPs.** `*.tiiny` is real DNS: the bridge host's
dnsmasq answers `address=/tiiny/10.0.0.2`, and its Caddy proxies to the device
over the USB /30 (`172.20.19.89`). So the defaults are names. They survive the
device's DHCP drift on WiFi (its address has moved before) and its
roam-unstable radio, and they work from any host on the LAN.

**The `:8800` trap.** The management API is *not* reachable as `<ip>:8800`
through the bridge — Caddy proxies port 80 only. Use the vhost
**`p8800.api.tiiny`** on :80 instead; the device's own nginx maps it to the
internal 8800, so it rides the bridge. This is why the tools no longer dial
`:8800` directly.

**Environment:**

| Variable | Effect |
|---|---|
| `TIINY_AUTH_KEY` | Bearer token. **Checked first**, so the tools run on hosts with no pcsvr. |
| `TIINY_IP` | Force a direct connection to the device, bypassing the bridge. For off-LAN use, the bridge host being down, or debugging the bridge itself. |
| `TIINY_HOST` | Override the `:80` vhost (default `api.tiiny`). |
| `TIINY_MGMT` | Override the management base (default `http://p8800.api.tiiny/api/v1`). |

**Token fallback.** With no `TIINY_AUTH_KEY`, tools read
`~/.local/share/tiiny-pcsvr/auth_data/<serial>.json` — pcsvr's directory,
which exists only on the host where pcsvr runs. On any other host, set
`TIINY_AUTH_KEY` or the tool exits with a message saying exactly that.

---

## `ttt` — the companion CLI

The main entry point. Offloads real work to the device instead of spending
cloud tokens.

```
ttt ask    "<question>" [--smart]                ask the device (general; default)
ttt ask    --code [DIR] "<question>"             agentic code-intelligence
ttt ask    --librarian "<question>" [--raw]      answer from a tiibrarian corpus
ttt do     "<intent>"   [--path DIR]             sandboxed file task via lackpy
ttt code   "<prompt>"   [--smart]                direct coding via woollama
ttt review <file>       [--smart]                first-pass code review
ttt judge  <rubric> <candidate> [--smart]        grade candidate against rubric
ttt image  "<prompt>" [--transparent] [--px N] [--out F]
ttt embed  "<text>" … | --file F                 1024-dim local embeddings
ttt ocr    <image> [--engine tiiny|rapidocr] [--model ID] [--out F]  image → text
ttt asr    <audio> [--model ID] [--out F]        speech → text (~6x real time)
ttt say    "<text>" [--voice F1] [--lang L] [--play] [--out F]   text → speech
ttt listen [--seconds N] [--out F]               microphone → text
ttt rerank "<query>" <candidate> … | --file F    order candidates by relevance
ttt prompt ["<text>"] [--template FILE]          ask the device; text in, text out
ttt dialog ["<text>"] [--template FILE]          the same, in a zenity window
ttt load   <alias|ID>                            load a model (aliases below)
ttt unload <alias|ID> | --all                    free NPU again
ttt models [--all]                               what's loaded (--all = installed)
ttt top                                          NPU budget + resident models
ttt status                                       device + woollama health
ttt doctor                                       every check, in diagnostic order
ttt logs   ["<text>"] [--errors] [-n N]          the device's own service log
ttt api    <PATH> [--post JSON]                  raw authenticated API call
ttt unlock                                       unlock /data after a reboot
```

**Model aliases.** `load`, `unload` and `--model` resolve names through
`~/.config/ttt/models` (`alias = model id`), then through built-ins (`fast`,
`smart`, `35b`, `small`, `coder`, `tts`, `asr`, `embed`), then pass anything
else through as a literal id. See
[`../deploy/ttt.models.example`](https://github.com/teaguesterling/TTt/blob/main/deploy/ttt.models.example). `load` and
`unload` hand off to the vendor `tiiny` CLI when it is installed, and use the
API when it isn't.

**`say` and `listen`.** Speech synthesis needs a TTS model resident — the
service returns 503 until then — so `say` loads one on demand; it costs ~0% of
the NPU and evicts nothing. Voices are `F1`–`F5` and `M1`–`M5` (the OpenAI-style
`voice` names are rejected), and 18 languages are supported, `auto` by default.
`listen` records from the default microphone and hands the file to `asr`.

**`music` previews first, then resumes.** `ttt music "<description>"` renders a
short piece from a text description; `--seconds N` sets its length and `--full`
continues that same generation to roughly three times as long. Both write a WAV;
`--play` plays it. Reckon on **6–9 seconds of render per second of audio** — a
5 s preview takes about 80 s, and `--full` about three minutes.

Three things about this API are worth knowing before you poke at it directly:

- **`/v1/music/generate/preview` is the route that works**, and
  `config.preview_seconds` is what makes it work. Without that field it answers
  `preview_seconds must be set for preview generation`.
- **`/v1/music/generate/mp3` and `/wav` are in the device's OpenAPI and 404 at
  the music service.** The bare-string error shape (`{"error":"Endpoint not
  found"}`) is the service answering, not the gateway.
- **Bare `/v1/music/generate` needs a session id from an earlier preview.**
  Without one it fails in about three seconds with `SESSION_NOT_FOUND` — for a
  session it just minted. `resume` needs the session id *and* the config.

Everything the model takes goes inside `config`; a top-level `generation_type`
is rejected as an extra input. And because a render outlives the bridge's 60 s
cap, `ttt music` talks to `:8800` directly and refuses up front — before loading
anything — if it can't find a direct route.

**`rerank` is a prompt, not an endpoint.** The device has no rerank route, so
this asks the resident chat model to order the candidates. Fine for a handful
of strings; not a scoring function.

**One payload rule, everywhere.** A bare argument is the payload — text for the
text commands, a path for the file ones. `-` is stdin for both. `--text` and
`--file` say the same thing explicitly, and with no argument at all a piped
stdin is read anyway, so the dash is optional in a pipeline:

```bash
ttt say "hello"            ttt ocr shot.png          # bare argument
ttt say -                  ttt ocr -                 # stdin
ttt say --text="hello"     ttt ocr --file=shot.png   # explicit
… | ttt say                … | ttt ocr               # piped, no dash needed
```

An empty or whitespace-only stdin counts as *nothing supplied* and prints usage
— `ttt say < /dev/null` will not synthesise silence. A terminal with no
argument prints usage rather than hanging on a read.

Three commands differ, because their payload is shaped differently: `judge`
takes **two** paths (rubric, then candidate), and `embed` and `rerank` treat
`--file` as a **list** — one text or candidate per line.

Results go to **stdout**, progress and warnings to **stderr**, so they compose
like any other Unix tool, and a dialog is just another stage:

```bash
ttt listen | ttt prompt --template card.md | duckeye -Q -        # speech → selector → code
cat notes.md | ttt prompt "summarise in two sentences" | ttt say --play
ttt prompt --dialog                                              # same command, zenity front end
```

`ttt dialog` is `ttt prompt --dialog`: a zenity entry for the question and a
window for the answer, for hotkeys and launchers. It still prints the answer to
stdout, so it can sit in a pipeline too. Without zenity or a display it says so
and falls back to text rather than failing.

[`examples/voice-code-query.sh`](https://github.com/teaguesterling/TTt/blob/main/examples/voice-code-query.sh) wires the
whole chain together — microphone → selector → `duckeye -Q` retrieval →
summary → speech — as five pipes and nothing else.

**`logs` finds its own route.** The log API answers only on the device's own
`:8800` and 404s through the gateway, unlike the rest of the model API — so
`ttt logs` probes for a direct route instead of asking you for one: it tries
`TIINY_LOGS_BASE`, then `TIINY_IP`, then the address the vendor CLI recorded in
`~/.tiiny/config.json` (`tiiny scan` refreshes it), then the proxy, then the
fixed USB `/30`, and uses the first that actually answers.
Set `TIINY_IP` or `TIINY_LOGS_BASE` to skip the probing. If none answer it says
so rather than returning an empty log, which is the failure this whole command
exists to avoid.

`--smart` selects the Thinking/35B route. It only means something if a
reasoning model is actually loaded. The device can hold several models at once
(bounded by NPU RAM), but the chat route uses whichever chat model is resident —
so `ttt load smart` first. The CLI warns rather than silently no-op'ing.

**Host requirements:** `ask` and `do` need `squackit` / `lackpy` from a venv
beside the script; `ocr --engine rapidocr` needs `rapidocr_onnxruntime`
(`pip install`, CPU-only, no sudo — it prints the exact install line if missing);
everything else needs only `python3` and `curl`. The interpreter search is
venv-beside-script → venv-one-level-up → system `python3`.

`ocr` has two backends. It is a *feeding* step: `ttt ocr shot.png | ttt ask "…"`.

- **`--engine tiiny`** (default) — a vision model **on the device** (an
  `Image-Text-to-Text` model). More accurate on messy/handwritten text and can
  follow instructions, but it is a **chat model, so loading it evicts the resident
  chat model** (the device serves one at a time) and it needs a device token.
  Default model `Qwen/Qwen3.6-35B-A3B-turbo` (vision-enabled; MoE, 3B active →
  fast). Override per-call with `--model ID`. Not every vision-capable model
  serves images here — `google/gemma-4-26B-A4B-it` does not — so stay on the
  default unless you have tested the one you want.
- **`--engine rapidocr`** — host CPU (RapidOCR/ONNX): ~1s, free, no device, no
  token, no eviction. Best for clean docs/screenshots; slightly weaker on odd
  glyphs (dropped an em-dash the device model kept).

Defaults come from config: `~/.config/ttt/config` (see `deploy/ttt.config.example`),
`TTT_OCR_ENGINE` / `TTT_OCR_MODEL`. Precedence: `--flag` > env var > config > default.

**Failure reporting:** `ttt models` distinguishes a rejected token (`HTTP
401`), an unreachable endpoint, and a genuinely idle device. It used to render
all three as an empty list — worth preserving, since that ambiguity is the
single most time-wasting failure mode on this platform.

## `tiiny-ask.py` — one-shot agentic question

Drives the device model through squackit's MCP tools against a directory.
Invoked by `ttt ask --code`; usable directly. Honours `TIINY_ROUTE` to name a
device model id (`default` = whatever is loaded).

`ask` is general by default: a bare `ttt ask "<question>"` is a plain question
to the device, and code intelligence is the `--code` mode rather than the
default. `--code` takes an optional directory — bare `--code` means the current
one, and a following argument is consumed only when it is an existing
directory, so `ttt ask --code "where do we parse flags"` still reads as a
question. An explicit `--path DIR` also selects code mode, since in `ask` it
never meant anything else.

## `tiiny-librarian.py` — answer from a corpus (loose)

Invoked by `ttt ask --librarian`; usable directly. Retrieves passages from a
[tiibrarian](https://github.com/teaguesterling/tiibrarian) corpus and has the
device answer from them, with locators like `somebook.pdf#p.27`.

**This is a relaxed cordexa, and the relaxation is the whole caveat.** The full
pipeline retrieves, synthesizes, then *grounds*: a claim survives only if it
quotes a span verbatim from the page it cites, and the answer abstains when
none survive. That check is deliberately not here. So the model can say things
the passages do not support, and a citation tells you which page was
**retrieved** — not that the sentence beside `[3]` is on page 3. Treat the
answer as a lead and the locators as where to look.

What is real is the retrieval: two-stage vector search over page embeddings,
HNSW on a stored 256-d truncation then an exact re-rank on the full 1024-d
vector. The query must be embedded by the same NPU encoder that built the
index — the helper raises rather than falling back to the device's CPU
embedder, whose vectors are close enough to look fine and retrieve worse.

| | |
|---|---|
| `TIIBRARIAN_CORPUS` | the corpus `.duckdb` |
| `TIIBRARIAN_HOME` | the checkout (default `~/Projects/tiibrarian`) |
| `TIIBRARIAN_PY` | interpreter to use — see below |

Needs the NPU embedder resident, and a chat model too unless `--raw`. `--raw`
prints the retrieved passages and stops, so it pipes; the loose-mode caveat
goes to stderr on both paths, never into stdout.

It also needs an interpreter with `duckdb`, which `$PY` frequently is not —
`$PY` only has to parse JSON, and on a host with no venv beside the script it
is the system `python3`. `ttt` probes `TIIBRARIAN_PY`, then `$PY`, then
`~/.local/share/venv/bin/python`, then `python3`, and takes the first that can
import duckdb rather than failing inside the helper with a traceback that
blames tiibrarian.

## `tiiny-duckeye.py` — the device writes a duckeye command

Invoked by `ttt duckeye`; usable directly. Turns a plain-English request into
one `duckeye` invocation and runs it. Honours `TIINY_ROUTE` and `DUCKEYE`.

The model returns **JSON**, not a command line — `{"file", "args", "why"}` —
and `args` is handed to `subprocess` as argv with `shell=False`. Nothing is
interpolated into a shell string, so quoting stops being a security question:
a selector containing `;` or `$(…)` is just an argument duckeye will reject.
Unquoting model output correctly is the bug this avoids owning.

Three guards sit on top of argv, because argv alone is not enough:

- **A flag allow-list.** Only the read-only query surface is accepted. `-o`
  writes files, `--init`/`--update` mutate the duckeye install, `-p` spawns a
  pager that would hang a pipeline. An *unknown* flag is refused rather than
  passed through, so a duckeye upgrade cannot silently widen what the model
  can reach.
- **`-w`/`--where` is withheld.** It is a raw SQL expression evaluated by
  DuckDB — a far wider surface than a selector. `--allow-where` opts in.
- **Path containment.** The chosen file must resolve inside `--path`. The
  model picks from a listing we generate, but it can return anything, so the
  answer is checked rather than trusted.

`--dry-run` prints the command without running it, with **every token single
quoted** — not just the ones a shell would mangle. A line where some arguments
are quoted and others are bare leaves the reader deciding which is which;
quoting all of them means the line pastes anywhere, and a value carrying a
newline or a trailing space is visible rather than silently reshaping the
output. The error messages quote the offending value for the same reason:
`file` and `args` come from the model, and an unquoted string with a newline
in it could forge a second line of diagnostics.

`--plan FILE|-` skips the device entirely and feeds the JSON in directly,
which is how the guards are tested: no NPU, no network, deterministic.

```bash
python3 tests/test_duckeye_guards.py     # exits non-zero if a guard stops holding
```

`tests/test_duckeye_guards.py` exercises every refusal, both path escapes, the
bash round-trip of each quoted form, and the fact that `-o` never creates its
file. It needs `duckeye` on PATH and skips loudly without it; it never needs the
device. It is the only test in this repo — there is no framework and nothing
else to run.

A no-match (`-Q`/`-S`/`-s` exit 1) is a result, not a failure — under
`--answer` the model is told the extract was empty so it can say the selector
was wrong, rather than the command going silent.

## `tiiny-import-model.sh` — HuggingFace import

Imports a model onto the device via the management API, encoding several
behaviours learned painfully:

- **inspect first.** A GGUF-only repo (no `config.json`) fails
  `TOOLKIT_NOT_FOUND`; you need a safetensors/transformers repo the toolkit
  matcher recognises.
- **`display_name` must equal `model_name`**, or the import POST returns
  `INVALID_REQUEST`.

⚠️ **`inspect` reporting `supported` is not a guarantee.** It will accept a
model the only shipped toolkit cannot convert, and you find out *after*
downloading tens of GB — see [`model-import-api.md`](model-import-api.md).
Check the repo's `config.json` `num_hidden_layers` / `hidden_size` against the
toolkit's golden values first.

`--host <addr>` forces a direct connection instead of the bridge.

## `tiiny-unlock.sh` — unlock `/data` after a reboot

The device boots with `/data` (LUKS2, detached header) **locked**. Until it is
unlocked, `docker.service` won't start and the model API returns **502** with no
user-facing cue that unlocking is what's needed. This drives the same unlock the
desktop app uses: `POST /api/v1/account/unlock_with_auth_key` — auth key only,
no decryption password.

**`ttt unlock` is the portable path** and does the same thing: `/api/v1/connect`
reports `data_state` without a token, and the unlock itself needs only the auth
key, so neither requires the serial or pcsvr's `auth_data`. This script stays
for hosts where pcsvr holds the key and for scripting the unlock without the
CLI; it reads `TIINY_AUTH_KEY` first and falls back to `auth_data`.

Both wait for the **model API to answer**, not just for the flag to flip:
`data_state` reports `unlocked` before the backend finishes starting, and a
caller that stops at the flag gets a 502 a second later.

## `device-watch.sh` — reachability watcher

Logs **state transitions**, not every probe, so the log stays readable over
hours. Separates three things that are constantly conflated:

- **DEVICE** — is it answering on the address we think it has?
- **DRIFT** — has its IP changed under a running app? (The desktop app bakes
  `--host-resolver-rules` at launch, so a DHCP change strands the renderer until
  a full restart. This is the check that catches it.)
- **APP** — is the TiinyOS process still alive at all?

Observe-only; it never restarts anything.

**This is the tool that most wants to live on the bridge host.** It is a
monitor, and on a laptop it stops watching every time the lid closes.

## `pick-device-ip.sh` — choose a live device address

Probes and writes the pcsvr hosts file. Preference order: **USB** (fixed /30,
doesn't roam) then **WiFi** (from `TIINY_IP` if set, else UDP discovery).

**Largely superseded by real DNS.** It remains useful for the direct-connection
path (`TIINY_IP`) and for the desktop app's launcher on the workstation.
Hardcoded IPs here are appropriate — it is a *prober*, so the addresses are its
input.

## `resolve-device-ip.py` / `discover.py` — UDP discovery

`resolve-device-ip.py` discovers the device and writes the hosts file + pcsvr
DNS. `discover.py` is a standalone prober. Same note as above: these are
discovery tools, so literal addresses are the point.

---

## What deliberately did **not** move here

- **Desktop app machinery** — `tiiny-native.sh`, the Electron build, the Wine
  prefix, `agent-catalog-proxy.py`. Workstation-only; the bridge host is
  headless.
- **Eval / bench harnesses** — `bench-*.py`, `eval-*.py`, `squackit-agent.py`,
  `escalation-probe.sh`. Work product tied to specific experiments, not
  utilities.
- **Reports and the feedback sheet** — findings, not tools.
- **Corpora, installers, builds** — 210 GB, already gitignored.

The line: *if it would be useful on a host that has never seen the desktop app,
it belongs here.*
