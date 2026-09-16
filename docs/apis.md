# APIs exposed by the Tiiny

An overview of **every** service the device runs — what it is, where it listens,
whether it's authenticated, and whether it's reachable from the LAN.

For depth on the model service see [`device-api.md`](device-api.md); for imports
see [`model-import-api.md`](model-import-api.md).

All path/port data below was enumerated live from the device.

---

## The service map

| Port | Service | Paths | Auth | Bind | Notes |
|---|---|---|---|---|---|
| **80** | nginx gateway | — | varies | `0.0.0.0` | fronts ~18 `.tiiny` vhosts; routes to :8888 and :8800 |
| **8888** | "Tiiny Server" (FastAPI) | 44 | bearer | `0.0.0.0` | system, account, wifi, apps, chat history |
| **8800** | model service (FastAPI) | **132** | bearer | — | inference + model lifecycle + import |
| **5005** | `connectors` | 119 | — | `0.0.0.0` | 3rd-party accounts + MCP registry |
| **5555** | AI-Box Upgrade Service | 47 | bearer (root open) | `0.0.0.0` | firmware/app updates |
| **5003** | SimpleMem Knowledge Base | 42 | bearer | `0.0.0.0` | the Vault / KB |
| **8880** | Docker Compose Manager API | 34 | bearer | `0.0.0.0` | **container orchestration** |
| **8004** | conversation-history-service | 19 | bearer | `0.0.0.0` | chat transcripts |
| **5004** | llama-server (embeddings) | — | none | `*` | raw `Qwen3-Embedding-0.6B-Q8_0.gguf`, `-c 4096` |
| **9083 / 9087 / 9096** | per-model instance ports | — | — | `0.0.0.0` | one per loaded model |
| **3001** | websocket | — | — | `127.0.0.1` | `426 Upgrade Required` |
| **8777** | tiiny-wifi (uvicorn) | — | — | `[::1]` | loopback only |
| **3588** | sshd | — | key | `*` | user `tiiny` |
| **39218** | discovery agent | — | — | `*` | UDP discovery + IPv6 multicast |
| **5201** | iperf | — | none | `*` | throughput testing |
| **1234 / 6666** | unidentified | — | — | `*` / `127.0.0.1` | no OpenAPI; not investigated |

**Most of these are LAN-exposed but authenticated**, taking the same bearer
token — a defensible posture for an appliance on a home LAN.

---

## What each one is for

### `:80` — the gateway

nginx, fronting ~18 vhost names under the fake `.tiiny` TLD (`api.tiiny`,
`auth.api.tiiny`, `kb.api.tiiny`, `openai.api.tiiny`, `p8800.api.tiiny`, …).
Vhost names are largely **organisational**: they mostly reach the same app.
Routing is by **path**, not by name:

- `/v1/*` and `/api/v1/*` → the model service on :8800
- everything else → the "Tiiny Server" app on :8888
- bare `/api/…` (Ollama-shaped) → **not proxied**; direct `:8800` only

This is the routing that determines what rides the bridge host's proxy. See
[`networking.md`](networking.md).

### `:8888` — "Tiiny Server" (44 paths)

The system/account plane:

- **sys** (20): `device_info`, `status`, `performance`, `network`,
  `storage{,/llm,/agent}`, `wifi/*` (list, connect, disconnect, switch,
  auto-connect, `connection_status`), `reboot/`, `shutdown/`, `ac_power/`,
  `setting`, `base_urls`
- **account** (13): `auth`, `unlock_with_auth_key`, mail-code login, password
  set/change/reset, `upload_feedback`
- **webapp** (4), **chat/history** (3), **apps** (2), **connect** (1)

`POST /api/v1/account/unlock_with_auth_key` is the one that gets you out of a
locked boot — auth key only, no decryption password.

### `:8800` — the model service (132 paths)

Inference, model lifecycle, and import. Three inference dialects on one port:

- **OpenAI** `/v1/*` — chat, completions, embeddings, rerank, responses, models,
  images, audio speech + transcription
- **Anthropic-shaped** — `/v1/messages`, `/v1/messages/count_tokens`
- **Ollama** `/api/*` — generate, chat, embed, tags, ps (**direct only**)

Plus music (12 endpoints), ASR, TTS, OCR, 3D, model-logs, statistics,
scheduled-tasks, media upload. Full treatment in
[`device-api.md`](device-api.md).

### `:5005` — `connectors`

Third-party account integrations — Gmail, Outlook, Calendar, Telegram, WhatsApp,
Discord, X, with OAuth flows and connection management — **and** an MCP server
registry (`/v1/mcp/servers`, `import-json`, `tools`, `tools/call`).

The registry accepts `transport: http|streamableHttp|sse|stdio` and a
`runEnvironment` of `Computer` or `Tiiny` — that pair is how TiinyOS syncs
"Tiiny-managed MCP servers" between desktop and device. One server is registered
today (`zim-wikipedia`, a DuckDB MCP server running on the device).

This is the surface behind the app's "Connectors" and "Tiiny-managed MCP
servers" panes; it is not part of the model service and is not proxied through
the bridge host.

### `:8880` — Docker Compose Manager API (34 paths)

Container orchestration, exposed on the network (authenticated). This is what
brings the backend stack up after `/data` unlocks. Not explored; worth knowing it
exists before assuming the device's containers are unmanaged.

### `:5003` — SimpleMem Knowledge Base (42 paths)

The **Vault** — the app's knowledge base. Physically
`/data/backend/lancedb_data`, a LanceDB vector store on the LUKS volume, so it's
encrypted at rest and unreadable until unlock.

### `:5555` — AI-Box Upgrade Service (47 paths)

Firmware and app updates. Root answers `200` without auth (a status page); the
API itself requires a bearer token. Note that most device-side update endpoints
**404** on this unit — the service is present, the endpoints aren't
deployed.

### `:8004` — conversation-history-service (19 paths)

Chat transcript storage, bearer-authenticated.

### `:5004` — raw embedding server

A bare `llama-server` with `--embeddings`, no auth, serving
`Qwen3-Embedding-0.6B-Q8_0.gguf` at `-c 4096`. **4096 tokens is a hard input
ceiling**; over-limit input errors rather than truncating.

### `:9083 / :9087 / :9096` — model instances

One port per loaded model. Visible in
`GET /api/v1/models/running` under `instances`, each with an `instance_id`,
`model_id`, `port` and `startup_session_id`. This is the concrete evidence that
the device runs several models at once.

---

## Host-side APIs (not on the device)

| Port | What | Bind |
|---|---|---|
| **60000** | `pcsvr` — the Tiiny PC Service, under patched Wine | `127.0.0.1` |
| **60080** | agent-catalog-proxy — rewrites the store's OS filter | `127.0.0.1` |
| **47600** | woollama router (when running) | `127.0.0.1` |

`pcsvr` holds the device auth key (`~/.local/share/tiiny-pcsvr/auth_data/`) and
is what the desktop app connects to. Loopback-only.

---

## Auth, in one paragraph

The model service, the gateway app, the KB, the history service, the compose
manager and the upgrade service all take
`Authorization: Bearer <auth_key>`, where the key comes from pcsvr's
`auth_data/<serial>.json`. The same key works across services. Our tools read
`TIINY_AUTH_KEY` first so they run on hosts without pcsvr — see
[`utilities.md`](utilities.md).
