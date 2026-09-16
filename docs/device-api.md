# Tiiny device API reference

The model service exposes **132 paths**. This documents the ones worth knowing,
what reaches them, and where the map lies to you.

Auth: `Authorization: Bearer <auth_key>` on everything.

---

## 1. Access paths — this part bites first

There are two ways in, and they do **not** expose the same surface.

| | direct `<device>:8800` | via `:80` vhosts (i.e. over the bridge host's proxy) |
|---|---|---|
| `/v1/*` — OpenAI surface | 200 | **200** |
| `/api/v1/models/*` — management | 200 | **200** |
| `/api/tags`, `/api/ps` — Ollama surface | 200 | **404** |
| `/health` | 200 | **404** |

The device's own nginx proxies `/v1/*` and `/api/v1/*` from port 80 to the
internal 8800. It does **not** proxy the bare `/api/…` Ollama-shaped paths, so
those exist only on a direct connection.

**Two traps inside that:**

- **`<ip>:8800` does not ride the bridge.** The bridge host's Caddy reverse proxy handles port 80 only.
  Use the vhost **`p8800.api.tiiny`** on :80 for the management API.
- **`p8800.api.tiiny/openapi.json` returns the WRONG spec** — the gateway's
  44-path app, not the model service's 132-path one, because only
  `/api/v1/models/*` is routed to :8800 under that vhost. For the real spec,
  fetch `/openapi.json` from `:8800` directly.

Vhost choice barely matters for `/v1/*`: `api.tiiny`, `openai.api.tiiny`,
`ollama.api.tiiny` and `p8800.api.tiiny` all return 200 for `/v1/models`. The
names are organisational, not functional.

**Consequence for woollamad:** the `device` management protocol
(`/api/v1/models/{running,start,stop}`) rides the bridge; the `ollama` protocol
(`/api/ps`, `/api/generate`) does **not**. A router configured against the
names can only use the `device` protocol. Pointing at `172.20.19.89:8800`
directly — which the bridge host can, over USB — gets both.

---

**The 132-path spec is served only from ON the device**, at
`127.0.0.1:8800/openapi.json`. Both `api.tiiny` and `p8800.api.tiiny` return the
gateway's 44-path spec instead, which lists none of the model service's routes.
Every ASR path was discoverable in seconds once the right spec was in hand — and
not before. Relatedly: the gateway's 60 s deadline turns a fast, specific error
into a bare 504. The same malformed ASR request that 504'd through the gateway
returned an actionable `400` naming the missing field in **23 milliseconds**
against `127.0.0.1:8800`. When something here looks dead, go direct before
concluding anything.

## 2. Model lifecycle

The part the CLI mostly doesn't expose yet.

### Inspecting

| Method | Path | Notes |
|---|---|---|
| GET | `/api/v1/models/` | All registered models. **Trailing slash required** — without it you get a 307. |
| GET | `/api/v1/models/running` | Currently loaded. |
| GET | `/api/v1/models/running/stream` | SSE stream of the above. |
| GET | `/api/v1/models/types` | Models grouped by capability (`Text-to-Image`, etc. with counts). |
| GET | `/api/v1/models/online_models` | Catalog, including not-yet-downloaded. |
| GET | `/api/v1/models/storage` | Per-model disk accounting + fleet total. |
| GET | `/api/v1/models/{id}/storage` | One model's footprint. |
| POST | `/api/v1/models/{id}/storage/refresh` | Recompute it. |
| GET | `/v1/capabilities` | What the *currently loaded* model supports. |

### Loading and unloading

| Method | Path | Notes |
|---|---|---|
| POST | `/api/v1/models/{id}/start` | Load. `…/start/stream` streams progress. |
| POST | `/api/v1/models/{id}/launch` | Also load — `…/launch/stream` too. Relationship to `start` is not documented upstream; `start` is what the CLI uses and what works. |
| POST | `/api/v1/models/{id}/stop` | Unload one model. |
| POST | `/api/v1/models/unload_all` | Unload everything. |
| POST | `/api/v1/models/{id}/interrupt` | Cancel in-flight generation, keep it loaded. |
| POST | `/api/v1/models/interrupt_all` | Same, fleet-wide. |
| GET | `/api/v1/models/{id}/unload_candidate` | **What would be evicted** to make room. Useful before a load on a full device. |

**The device runs MULTIPLE models concurrently, bounded by NPU RAM** — not one
at a time. Each loaded model is its own instance on its own port (embedding on
:9083, etc.), and models carry an `npu_usage` percentage. Observed live: an
embedding model (0.9 GiB), a reranker (0.7 GiB) and a 35B chat model (16.6 GiB)
all `running` together.

What *is* bounded is NPU RAM, and `unload_candidate` is how you find out before
you hit it:

```json
{"unload_required": true,
 "message": "Not enough NPU RAM available. Would you like to unload
             [Qwen/Qwen3-Reranker-0.6B] to make room for the model?",
 "target_model": {"model_id": "Qwen/Qwen3-30B-A3B-Instruct", "npu_usage": 55},
 "candidate":    {"model_id": "Qwen/Qwen3-Reranker-0.6B", "instance_id": "..."}}
```

So the mental model is a **memory-bounded pool with an eviction candidate**, not
a single slot. Ask `unload_candidate` before a large load; **never reboot to
swap models**.

#### The budget is a percentage, and file size does not predict it

`GET /api/v1/npu/status` reports the hardware: an `LQ50-48GB`, ~47.9 GiB total,
separate from the ~31 GB of system RAM. Residency is gated by summed
`npu_usage`, and **disk size is not merely a weak proxy for it — it inverts**:

| model | disk | `npu_usage` |
|---|---|---|
| `Qwen/Qwen3.6-35B-A3B-turbo` (MoE, vision) | 17.9 GB | 55% |
| `black-forest-labs/FLUX.2-klein-4B` (diffusion) | **7.8 GB** | **50%** |
| `baidu/ERNIE-Image-Turbo` | 11.4 GB | 42% |
| `Tongyi-MAI/Z-Image-Turbo` | 10.2 GB | 32% |
| `Qwen/Qwen3-8B` (dense) | 4.3 GB | 28% |
| `tencent/SongGeneration-v2-large` | 5.1 GB | 18% |
| `Qwen/Qwen3-ASR-1.7B` | 3.6 GB | 7% |
| `Qwen/Qwen3-Reranker-0.6B` | 0.7 GB | 2% |
| `Qwen/Qwen3-Embedding-0.6B` | 0.9 GB | 1% |

The smallest file on the list is the one that will not fit beside the 35B.
A sparse MoE activates a fraction of its parameters, while a diffusion model
materialises large activation buffers — so pick residency by `npu_usage`, never
by GB. `unload_candidate` returns `unload_required: false` when a model fits as
things stand, which makes it a cheap read-only fit test.

Practically: the utility models are nearly free (1–2%), so a useful standing
set is a vision chat model, an image generator, an embedder and a reranker at
about 90% combined. **Six models loaded at once has been run in practice**
(rerank, embeddings, Z-Image and two small Qwens among them) — the ceiling is
the budget, not a slot count.

Separately and genuinely: a loaded chat model serves **one request at a time**
(`parallel = 1`) and concurrent requests wedge it — see §5. Don't conflate the
two: request concurrency is limited, model residency is not.

### Instances

| Method | Path |
|---|---|
| GET, POST, PUT | `/api/v1/models/{id}/instances` |
| GET | `/api/v1/models/instances/{instance_id}` |
| POST | `/api/v1/models/instances/{instance_id}/{stop,interrupt}` |
| POST | `/api/v1/models/{id}/instances/{stop,interrupt}` |

A finer-grained layer under the model-level verbs. Not exercised by our tooling.

### Downloading (Model Store)

| Method | Path | Notes |
|---|---|---|
| POST | `/api/v1/models/{id}/download` | Start. `…/download/stream` streams. No request body. |
| POST | `/api/v1/models/{id}/pause_download` | Pause. Returns the current progress. |
| GET | `/api/v1/models/{id}/get_progress` | **Accurate for store downloads; NOT wired up for imports** — it reports `not_downloaded, progress: 0` for an imported model with 51 GiB verifiably on disk. |
| POST | `/api/v1/models/{id}/update` | Update an installed model. |
| DELETE | `/api/v1/models/{id}` | Delete. This is what reclaims a failed download's disk. |

⚠️ **Store downloads can loop forever.** Observed twice on
`openai/gpt-oss-120b`: progress climbs to ~80%, the zip extracts *successfully*,
then a fresh zip download starts from zero — indefinitely, with `status` never
leaving `downloading`. ~24 GiB re-fetched every ~20 minutes. Watch the byte
counter, not the status.

### Import (HuggingFace)

Fifteen endpoints; see [`model-import-api.md`](model-import-api.md) for the full
treatment including which fields lie. The short version:

- `resume` is **top-level** (`POST /api/v1/models/import/resume`), unlike every
  sibling verb. The intuitive `/{import_id}/resume` returns 405.
- `status`, `error_code` and `speed_human` **go stale** — they reported
  `paused` / `DOWNLOAD_PAUSED` / `0 B/s` during a healthy 53 MB/s transfer.
- The real terminal error appears **only** in the SSE stream returned by the
  resume POST. It is never persisted.
- `GET /import/residuals` **under-reports**: a failed import's cache is
  invisible until you `POST /import/{id}/cancel`, so failed imports leak ~50 GB
  each with no API-visible way to reclaim them.

---

## 3. Inference surfaces

The device speaks three dialects on the same port.

**OpenAI** (`/v1/*` — rides the bridge):
`chat/completions`, `completions`, `embeddings`, `rerank`, `responses`,
`models`, `images/generations`, `audio/speech`, `audio/speech/sse`,
`audio/transcriptions`.

**Anthropic-shaped**: `POST /v1/messages` and `POST /v1/messages/count_tokens`.

**Ollama-compatible** (`/api/*` — direct `:8800` only, **not** over the bridge):
`api/generate`, `api/chat`, `api/embed`, `api/tags`, `api/ps`.

That last group is why the stock Ollama harness can drive this device directly —
and why it can't through the bridge.

---

## 4. Other subsystems

**Modalities.** Music is a whole subsystem (`/v1/music/*`: generate, preview,
mp3/wav, cover, repaint, extract, lego, complete, sessions, progress, info).
Also ASR (`/v1/asr/*`, **see 4b**), TTS (`/v1/synthesize`, `/v1/audio/speech`),
OCR (`/v1/ocr`), and 3D (`/v1/3d/{upstream_path}`).

**Model logs** (`/api/v1/model-logs/*`): sessions, entries, raw, timeline,
cleanup. **Runtime inference sessions only** — no record of downloads or
imports, so it will not tell you why an install failed.

**Statistics** (`/api/v1/statistics/*`): today / week / app totals.

**Scheduled tasks** (`/api/v1/scheduled-tasks/*`): CRUD plus run, pause, resume,
terminate. Unexplored.

**Media** (`/api/v1/media/*`): upload, fetch content, delete.

**System** — on the gateway app (`:80`), not the model service:
`sys/device_info`, `sys/status`, `sys/performance`, `sys/network`,
`sys/storage{,/llm,/agent}`, `sys/wifi/*` (list, connect, disconnect, switch,
auto-connect, `connection_status`), `sys/reboot/`, `sys/shutdown/`,
`sys/ac_power/`, `sys/setting`, `sys/base_urls`.
Account management lives there too (`/api/v1/account/*`), including
`unlock_with_auth_key` — the one that gets you out of a locked boot.

---

## 4b. ASR — the working invocation

`/v1/asr/{health,models,recognize}`. **Working, ~5.9x real time** (measured over
226 minutes of speech spanning 1- to 63-minute files, model warm). The model is
`Qwen/Qwen3-ASR-1.7B` at ~7% of the NPU budget, so unlike the OCR VLM it does
**not** evict the resident chat model.

```bash
ffmpeg -v error -i in.mp3 -f s16le -ar 16000 -ac 1 out.raw
curl -H "Authorization: Bearer $KEY" -F 'audio=@out.raw' \
     http://api.tiiny/v1/asr/recognize
```

**Three details, each of which returns a different error if you get it wrong:**

| detail | if wrong |
|---|---|
| route is `/v1/asr/recognize` | `/v1/audio/transcriptions` **hangs** — nothing after 120 s locally, 504 via gateway |
| field is `audio`, not `file` | `400 Missing required multipart file field 'audio'` |
| payload is raw PCM16 (16 kHz mono s16le) | `400 PCM16 data must be non-empty with even byte count` |

`/v1/audio/transcriptions` is the OpenAI-compatible shim, and it hangs rather
than completing — when it does surface an error, it's `Transcription failed:
timed out during opening handshake`, a WebSocket it cannot open to the speech
server. The native route beneath it works fine. Do not reach for the OpenAI
spelling here; use `/v1/asr/recognize`.

**Segment long audio.** The gateway kills any request at 60 s, and at ~5.9x an
8-minute file needs ~80 s. 120-second windows leave comfortable margin. Carry
each window's offset if you want absolute timestamps.

The response is richer than the OpenAI shape it hides behind — VAD segmentation,
forced alignment, speaker embeddings (`GET /v1/asr/models` lists the
capabilities). **But `confidence` is a hardcoded `1.0`** — one distinct value
across every segment observed. It is not a quality signal; check whether a field
varies before building on it.

**`ttt asr <audio>`** implements all of the above.

---

## 5. Behaviours to design around

- **One model at a time**, `parallel = 1`. Concurrent load wedges the chat model
  so that *every* request 504s, including trivial ones.
- **Single-session**: a second connecting client silently drops the first. Two
  clients connect/disconnect each other in a loop forever.
- **Boots locked.** `/data` is LUKS2; until unlocked, docker won't start and the
  model API returns **502** with no cue that unlocking is the fix.
- **404s are normal on this unit** for `/api/v1/npu/status`,
  `/api/services`, and the upgrade endpoints. Don't read the high 4xx rate in
  `sys/performance` as a connectivity signal.
- **`signal_strength` is not a health metric.** It reads 100 during a dead
  WiFi roam. Measure the path, not the metric.

## 5b. Controlling reasoning ("thinking")

Pass `chat_template_kwargs: {"enable_thinking": false}` as a **top-level body
field**. `/no_think` in the prompt, a top-level `enable_thinking`, and
`reasoning: {enabled: false}` all do nothing.

**It is per-model, and the device tells you which.** `GET /api/v1/models/`
carries a `thinking` object on every catalog entry — **do not probe, read it**:

```json
"thinking": {"supported": true, "toggleable": true,
             "enabled_by_default": true, "levels": [], "default_level": null}
```

| model | supported | toggleable |
|---|---|---|
| `Qwen3.6-35B-A3B-turbo` | ✅ | ✅ |
| `Qwen3.6-35B-A3B`, `Qwen3.5-35B-A3B`, `Qwen3-8B` | ✅ | ✅ |
| `zai-org/GLM-4.7-Flash` | ✅ | ✅ |
| `Qwen3-30B-A3B-Thinking` | ✅ | ❌ cannot be turned off |
| `Qwen3-30B-A3B-Instruct`, `Qwen3-Coder-30B-A3B-Instruct` | ❌ | ❌ |
| `openai/gpt-oss-20b` | ✅ | ❌ — but `levels: [low, medium, high]` |

Verified against behaviour on `Qwen3.6-35B-A3B-turbo`: reasoning 946→0 chars,
~5–10× faster on short prompts. And `30B-Thinking` at `toggleable: false` **is**
that no-op — the device had been declaring it all along.

### ⚠️ Disabling thinking is a TRADE, and its direction is per-model

It is not free speed. Measured on a real-work battery (diagnose → fix → ship,
scored by actually running `pytest`, not by grading an answer):

| model | thinking on | thinking off |
|---|---|---|
| `Qwen3.6-35B-A3B-turbo` | **5/6**, 12–59 s | 3/6, ~8 s |
| `zai-org/GLM-4.7-Flash` | 0/6, ~69 s | **3/6**, 9–17 s |

**Opposite directions.** On the 35B the reasoning pass does real work and buys
two multi-step tasks; turning it off is ~4× faster and measurably worse. On GLM
the reasoning pass was consuming the budget before a tool call was ever emitted,
so disabling it took the model from unusable to mid-field.

**Do not read a single direction off this table.** A reader who sees only
"35B: on is better" will set it globally on and pay ~4× on GLM for nothing. The
knob has no default; it has a measurement.

A tempting mechanism — *"reasoning buys its way around a restricted-execution
sandbox, so the tighter the language the more thinking is worth"* — was
**checked against the generated programs and does not hold**. The forbidden-AST
failure it rested on came from a model with no thinking mode at all, so it was
never an on/off contrast. It remains an interesting hypothesis and it inverts
the usual intuition, which is why it wants testing rather than asserting; the
battery that suggested it contained no task where a simple formulation was
unavailable, so it could not have tested it.

What is defensible is duller: **thinking tends to produce simpler programs, and
a simpler program has fewer chances to reach for a forbidden construct.** Same
direction, much weaker claim.

Rule: measure per model and per task class. Short factual prompts → off.
Multi-step work → measure; do not assume.

⚠️ This field was missed three times in one day while asserting the opposite.
It sits in a payload that is easy to fetch and skim past. Read it.

Through woollamad, a client-supplied kwarg is forwarded on the pass-through
route; an inferencer's `extra_body` is **not** applied there. Full detail in
[`model-import-api.md`](model-import-api.md#reasoning--thinking-toggle--the-import-flag-is-cosmetic).

## 5b-ii. ⚠️ `temperature: 0` is not greedy, `seed` is ignored, `logprobs` returns nothing

All three are declared in `ChatCompletionRequest` and all three silently no-op.
Measured 2026-08-17 on `Qwen3.6-35B-A3B-turbo`, direct to `:8800`:

| input | runs | result |
|---|---|---|
| dense multi-column ad page | 5 | **5 distinct outputs**, diverging after ~7 words |
| same, two runs sharing `seed=1001` | 2 | **differ from each other** |
| clean 1870 prose page | 3 | byte-identical, 1444/1444 chars |
| clean 1916 prose page | 3 | byte-identical, 2733/2733 chars |

**Nondeterminism is content-dependent.** Unambiguous input reproduces exactly;
genuinely ambiguous input diverges immediately and *semantically* — the same
printed line came back as "Get the latest in aircraft communications", "Get the
best in aircraft communications", and "The world's most versatile aircraft…".
These are re-readings, not token noise.

`logprobs: true, top_logprobs: 5` is accepted and `choices[0]` comes back as
`['index','message','finish_reason']` — no `logprobs` key at all. So model
confidence cannot be measured here, and the margin cannot be inspected.

**Consequences for anything you measure on this device:**

- a result on clean/unambiguous input is reproducible and can be quoted as one run
- a result on ambiguous input (poor scans, dense layout, degraded print) is a
  **single draw** and needs n>1 or an explicit caveat
- **retry is a live mitigation** on exactly the inputs that fail, because those
  are the ones that vary — a re-run of a degenerate output will likely differ
- do not build anything on `seed` reproducibility or on `logprobs`

## 5c. `GET /api/v1/models/running` carries two shapes at once

Easy to misparse, and the distinction matters to anything doing capability
discovery:

```json
{"object": "list",
 "running":  ["Qwen/Qwen3.6-35B-A3B-turbo"],          // bare STRINGS
 "pending":  [],
 "instances": {
   "running": [{                                       // sibling array of OBJECTS
     "model_id": "Qwen/Qwen3.6-35B-A3B-turbo", "port": 9084,
     "status": "running", "active_request_count": 3, "npu_usage": 55,
     "created_at": …, "use_time": …, "last_inference_time": …,
     "type": "Image-Text-to-Text", "capabilities": ["main"],
     "input": "Text,Image", "output": "Text"}],
   "pending": []}}
```

So a client reading `running` gets ids, and the capability/port/liveness detail
is in `instances.running` **in the same response** — capability discovery costs
no extra call and no per-model fan-out.

`capabilities` is the field that matters for routing: `["main"]` is a chat
model; `["embedding"]` and `["rerank"]` will **503 on the chat path** with the
misleading message `"X" is not loaded` (it *is* loaded, just not servable
there). `active_request_count` is the honest way to tell whether someone else is
using the device before you start.

## 6. Not on this service

`connectors` on **:5005** is a separate service (third-party accounts + an MCP
registry) and shares nothing with the model service documented here. See
[`apis.md`](apis.md) for the full service map.
