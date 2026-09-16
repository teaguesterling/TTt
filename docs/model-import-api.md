# Tiiny model-import API — how to import a HuggingFace model

**Date:** 2026-08-14
**Source:** reverse-engineered from the device management API (`:8800`) OpenAPI spec + live calls
**Base:** `http://<device>:8800/api/v1/models/import` (device = `10.0.0.50` WiFi, DHCP-assigned, or `172.20.19.89` USB)
**Auth:** `Authorization: Bearer <pcsvr auth_key>` (from `~/.local/share/tiiny-pcsvr/auth_data/<serial>.json`)

## The endpoints

| Method | Path | Purpose |
|---|---|---|
| POST | `/models/import/inspect` | **Dry-run.** Fetch HF metadata, size, capabilities, and whether import is supported. No download. |
| GET | `/models/import/toolkits` | List conversion toolkits the device has/can fetch (this is what a model must match). |
| POST | `/models/import` | **Start the streaming import** (download + convert). SSE/stream response. |
| GET | `/models/import` | List import jobs. |
| GET | `/models/import/{import_id}` , `/{import_id}/events` | Poll one job / stream its progress. |
| POST | `/models/import/{import_id}/cancel` , `/{import_ref}/pause` | Control a running import. |
| POST | `/models/import/resume` | **Resume — NOT under `/{import_id}/`** (verified 2026-08-16; the per-job path returns 405). Body: `{"hf_url": "<required>", "import_id": "<optional, to disambiguate>"}`. Streams SSE; the job continues server-side after you detach. |
| GET/PUT | `/models/import/config` | Toolkit cache root config. |
| GET | `/models/import/residuals` , DELETE `/residuals/{id}` | Clean up partial/failed import leftovers. |

## Request bodies (from the OpenAPI schema)

**`ImportInspectRequest`** (POST /inspect):
```json
{ "hf_url": "<required>", "hf_revision": null, "hf_token": null,
  "base_model_id": null, "toolkit_id": null, "toolkit_revision": null }
```

**`ImportModelRequest`** (POST /import):
```json
{ "hf_url": "<required>", "base_model_id": null, "toolkit_id": null,
  "toolkit_revision": null, "model_id": null, "model_name": null,
  "display_name": null, "model_desc": null, "reasoning_enabled": null,
  "hf_token": null }
```

## Gotcha: the REAL error lives only in the resume POST's SSE stream

Verified 2026-08-16. When an import fails in stage 2 (`preprocessing`), **five**
state surfaces disagree and only one is correct:

| Source | What it said | Correct? |
|---|---|---|
| `GET /models/import/{id}` | `paused` / `DOWNLOAD_PAUSED` / `resumable: true` / stage 1 of 2 | NO — stale download error |
| `GET /models/import/{id}/events` | replays history, ends `event: done` on the OLD network error | NO — a replay, not live |
| `GET /models/{model_id}/get_progress` | `not_downloaded`, `progress: 0` | NO — 51 GiB was on disk |
| `GET /models/` | present, `status: download_stop` | partial |
| `GET /models/storage` | **absent** (only finished models appear) | yes — use as the completion signal |
| **SSE stream returned by `POST /models/import/resume`** | `event: error` + `event: done` with `stage: preprocessing`, `status: failed`, full traceback | **YES** |

**So: to find out why an import really failed, POST a resume and read the whole
stream.** Don't poll. The terminal error is never persisted anywhere.

Ground-truth checks that don't depend on the API at all:
- model bytes on disk: `/data/backend/tiiny_model_data/model_import/toolkits/cache/hf-models/<base64(repo_id) without padding>`
- store-download bytes: `/data/backend/tiiny_model_data/download_model/<owner>__<repo>/`
- is anything actually transferring: `cat /sys/class/net/wlan0/statistics/rx_bytes` twice

## Gotcha: `inspect` says "supported" for models the only toolkit cannot convert

`inspect` returned `supported` for a **27.8B** model and auto-selected toolkit
`qwen3.5-9b`; preprocessing then died with `TOOLKIT_EXECUTION_FAILED` /
`ValueError: Qwen3_5ForCausalLM config does not match golden config`
(num_hidden_layers 64 vs 32, hidden_size 5120 vs 4096, …) **after a 57 GB
download**. `GET /models/import/toolkits` lists exactly one toolkit
(`qwen3.5-9b`), so only ~9B Qwen3.5-architecture models can import.

**Check yourself before starting a large import:** fetch the repo's `config.json`
from HF and compare `num_hidden_layers` / `hidden_size` against the 9B golden
(32 / 4096). If they differ, it will fail at preprocessing — do not spend the
bandwidth.

## Gotcha: `status`, `error_code` and `speed_human` go STALE

Verified 2026-08-16 on a live resume: the job reported `status: paused`,
`error_code: DOWNLOAD_PAUSED`, `speed_human: "0 B/s"` **while actually downloading at
~50 MB/s**. Those fields only refresh on certain events and will happily describe a
dead state during healthy transfer.

**Trust `download_components.hf_model.downloaded_bytes`** (sample it twice and diff),
and cross-check against the device's own counters over SSH:
`cat /sys/class/net/wlan0/statistics/rx_bytes`. Never gate automation on `status`.

Also note `error_message` for a stalled download is huggingface_hub's
`LocalEntryNotFoundError` text ("...cannot find the requested files in the local
cache..."). That is a **network** error, not a missing file.

## The normal flow

1. **Inspect** — `POST /inspect {"hf_url": "..."}`. Read `import_support.supported`. If `true`, it echoes the `base_model_id` + `toolkit_id` it will use and `disk_space.required_display`.
2. **Import** — `POST /import` with the same `hf_url` plus a `display_name`/`model_name` and (optionally) the `toolkit_id`/`base_model_id` from step 1. Response streams progress.
3. **Track** — `GET /import/{import_id}/events` (or `/models/{model_id}/get_progress`) until done.
4. **Run** — once imported, `POST /models/{model_id}/launch` (or `/start`).

Reproducible inspect:
```bash
KEY=$(python3 -c "import json,glob,os;print(json.load(open(glob.glob(os.path.expanduser('~/.local/share/tiiny-pcsvr/auth_data/*.json'))[0]))['auth_key'])")
curl -s -X POST http://10.0.0.50:8800/api/v1/models/import/inspect \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"hf_url":"https://huggingface.co/<owner>/<repo>"}' | python3 -m json.tool
```

---

## Specific case: `HauhauCS/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive`

**Result: the API can reach it and read it, but reports it UNSUPPORTED for import.** Inspect returns:

```
status: unsupported
import_support.supported: false
import_support.reason_code: TOOLKIT_NOT_FOUND
import_support.message: "No compatible toolkit matched the HuggingFace model."
metadata_status: fetched        (so HF connectivity is fine)
```

What inspect *did* read successfully:
- Repo: `HauhauCS/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive` @ `main` (`0a41c68…`)
- **Format: GGUF only.** Weight files: BF16 17.92 GB, Q8_0 9.53 GB, Q6_K 7.36 GB, Q4_K_M 5.63 GB, + `mmproj-…BF16` 0.92 GB
- Total 41.36 GB; **import working space required: 117.5 GiB** (device has ~620 GB free — not the blocker)
- License apache-2.0; task text-generation; tags include `base_model:Qwen/Qwen3.5-9B`

### Why it's blocked

- `hf_config.architectures: []`, `model_type: ""` — the repo has **no usable `config.json`**. It's a pre-quantized **GGUF-only** drop, not a transformers/safetensors repo.
- The device's importer is **toolkit-based**: it matches a model to a conversion toolkit by the *detected* base model. With no config to read the architecture from, auto-detection fails → no toolkit match.
- A compatible toolkit **does exist** — `toolkits` lists `qwen3.5-9b` (`base_model_ids: [Qwen/Qwen3.5-9B, Qwen/Qwen3.5-9B-Base]`, `compatible: true`, 5.9 GB, not yet cached).
- **But passing `toolkit_id: "qwen3.5-9b"` + `base_model_id: "Qwen/Qwen3.5-9B"` to inspect did NOT clear it** — it still returned `TOOLKIT_NOT_FOUND` with `toolkit: None / base: None`. Inspect re-derives from the repo and ignores the hints. The importer appears to expect original (safetensors) weights it can convert with the toolkit, not an already-GGUF repo.

### Options (your call — I did not start any download)

1. **Force it through the `import` endpoint anyway.** The `import` schema also accepts `toolkit_id`/`base_model_id`; it's *possible* the import path honors the hint where inspect doesn't. **Risk:** inspect says unsupported, it's a 41 GB download + 117 GiB scratch, and if the toolkit truly can't consume a bare GGUF it will fail partway and leave residuals to clean up. I'd only try this on an explicit "go", and I'd watch `/events` to kill it early if it errors.
2. **Import a config-bearing version instead.** If HauhauCS (or a mirror) publishes the same fine-tune as **safetensors with `config.json`**, inspect should match the `qwen3.5-9b` toolkit and import cleanly. Worth a HF search for a non-GGUF variant of this exact model.
3. **Import the base and accept it's not the uncensored tune.** `Qwen/Qwen3.5-9B` itself matches the toolkit and would import normally — but that defeats the point of this specific model.
4. **Direct GGUF load, outside this API.** The device runs llama.cpp, which loads GGUF natively — but the exposed management API wraps everything in toolkits/containers; there's no "load this GGUF file" endpoint in the spec. This would mean going around the API (SSH/device-side), which is a different, more invasive path.

**Recommendation:** try option 1 once as a bounded experiment (start import, watch `/events`, cancel on first hard error) — cheap to attempt and it settles whether the import path honors the toolkit hint. If it fails, option 2 (find a safetensors copy) is the clean route. Say the word and I'll run option 1 and monitor it.

---

## Update — safetensors version found (option 2)

Searched HF for a config-bearing (safetensors) copy of this exact fine-tune. The original
`HauhauCS/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive` is confirmed **GGUF-only** (5 .gguf
files, `README.md`, `.gitattributes` — **no config.json, no safetensors**), which is why the
toolkit matcher can't identify it.

**Best safetensors candidate:** `DreamFast/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Safetensor-Benchmark`
- Has `config.json`, `model.safetensors`, `tokenizer.json`/`tokenizer_config.json`, `merges.txt`, `vocab.json` — a full transformers repo.
- Tags: `transformers`, `safetensors`, `qwen3_5`, `base_model:Qwen/Qwen3.5-9B`, `base_model:finetune:Qwen/Qwen3.5-9B`, `uncensored`, `abliterated`, apache-2.0.
- This is the structure the device's `qwen3.5-9b` toolkit matches on (real `model_type`/`config.json`, not a bare GGUF).
- Caveats to verify on-device: the repo name says "Benchmark" and lists a single `model.safetensors` (+ a `video_preprocessor_config.json`, hinting at a VL variant). Confirm actual `size_bytes` and `capabilities` via inspect before committing — a suspiciously small file could be a stub rather than full weights.

Rejected alternatives: `atlantis240805/Qwen3.5-9B-SFT-uncensored` (safetensors but **no config.json** → same TOOLKIT_NOT_FOUND); `AIOpsInSpace/...-MTP` (neither); everything else in search results is GGUF.

### Outcome — IMPORTED SUCCESSFULLY (2026-08-15)

Inspect on the DreamFast safetensors repo returned `supported` (toolkit `qwen3.5-9b`,
base `Qwen/Qwen3.5-9B`, `model.safetensors` 18.82 GB full BF16 — not a stub). Import
completed: `event: done / status: completed`, model registered on-device as
`DreamFast/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Safetensor-Benchmark` (status
`downloaded`; launch with `POST /models/{id}/launch` to serve).

**Gotchas learned doing it live:**
- `display_name` and `model_name` **must be identical** or POST /import returns
  `INVALID_REQUEST: "display_name and model_name differ"`.
- The 18.8 GB pull happens **device-side over the device's WiFi** (device→HF), so it
  rides the mesh-roam instability. First attempt died at 59% with
  `TOOLKIT_CATALOG_UNAVAILABLE` + `dns_error`/`ConnectError` when the device WiFi dropped.
- **Retry reuses the cache.** `POST /import/resume` returned `IMPORT_RESUME_NOT_FOUND`
  (the failed job wasn't registered resumable), but a **fresh `POST /import` reused the
  13.8 GB HF-xet cache** — toolkit stayed complete, model resumed from the 8.77 GB
  checkpoint. So on a roam-failure: just re-POST the same import; it continues, doesn't restart.
- Time a retry into a good WiFi window (see `wifi-trace.sh` / `wifi-trace.csv`). Bad
  roam windows lasted ~19 min; the good window sustained ~35 MiB/s and finished ~8 GB in minutes.
- Post-import there were ~23 GB of deletable download-cache residuals
  (`GET/DELETE /models/import/residuals`) — clean to reclaim space.

### Reasoning / thinking toggle — the import flag is cosmetic

`reasoning_enabled: false` at import only sets the model's **metadata**
(`thinking.enabled_by_default: false` in the catalog). It does **NOT** change
runtime behavior — the model still thinks by default, emitting `reasoning_content`
and burning the token budget before any `content`. So a "reasoning-off" import and
a "reasoning-on" import of the same repo are **behaviorally identical** (same
weights); only the label differs.

The **actual** per-request way to disable thinking (verified working on this runtime):
```json
{"model":"...","messages":[...],"chat_template_kwargs":{"enable_thinking":false}}
```
→ direct answer, `reasoning_content` empty, `finish: stop`. These do NOT work:
`/no_think` in the prompt, top-level `enable_thinking:false`, `reasoning:{enabled:false}`.

**Support is per-model — do not generalise a result from one model to another.**
`Qwen3-30B-Instruct` has no Thinking mode at all, `Qwen3-30B-Thinking` has it
and cannot turn it off, and the Model Store lists per-model status. Measured here on
`Qwen3.6-35B-A3B-turbo` (n=3, varied prompts, `max_tokens=800`, temp 0):

| request | `reasoning_content` | latency |
|---|---|---|
| no kwarg | 946 / 406 / 647 ch | 8.8 / 3.2 / 5.3 s |
| `chat_template_kwargs.enable_thinking=false` | **0 / 0 / 0 ch** | **0.6 / 1.0 / 0.7 s** |

So on the 35B it works and is worth ~5–10× on short prompts. On the 30B pair it
does nothing, for the two different reasons above.

**But speed is not the only axis, and the trade runs both ways** — on a
real-work battery the 35B scored 5/6 with thinking on and 3/6 with it off, while
GLM-4.7-Flash scored 0/6 on and 3/6 off. See
[`device-api.md`](device-api.md#-disabling-thinking-is-a-trade-and-its-direction-is-per-model)
before setting this globally. **Probe before assuming**:
one call each way, compare `reasoning_content` length. Twenty seconds, and it
stops a wrong result from propagating — an earlier over-generalised reading of
per-model thinking support cost another session an entire model characterisation.

**Through woollamad:** a *client-supplied* `chat_template_kwargs` is forwarded
faithfully on the pass-through route (measured identical to direct). Putting it
in an inferencer's `extra_body` does **not** work — woollama merges `extra_body`
into *orchestration* requests, and `/v1/chat/completions` pass-through is not
one. The caller must send it.

With thinking ON, give a generous `max_tokens` (~1–2k) or `content` comes back
empty (`finish: length`) — and note that is a *different* failure from a
suppressed reasoning pass, so don't conflate them when measuring.

### Deleting a model can purge weights shared by another (learned the hard way)

Re-importing the same HF repo under a new name is instant because all copies
**share one content-addressed weight cache**. Deleting any one copy can purge that
shared cache and orphan the others (they 404, cache → 0 B, a re-import must
re-download the full 18.8 GB). **To rename/dedup: delete the old copies FIRST
(while they are the only reference), THEN import fresh with the clean names** — one
download, no cascade. Do not import-then-delete.

**Structural fix if a large pull keeps roam-failing (not yet used):**
the device also reaches the internet through the USB gadget to the bridge host, whose own
WiFi connection does not roam. Share that host's internet over the USB /30 — `sysctl
net.ipv4.ip_forward=1` + MASQUERADE out its WiFi interface + FORWARD for 172.20.19.89, plus a
route on the device via 172.20.19.90 — so device→HF goes USB→bridge-host→stable-WiFi,
bypassing the mesh entirely. Needs root on the bridge host (iptables) and a device-side
route; left as a decision for whoever runs this, not done here.
