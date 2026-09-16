# Architecture — how the Tiiny stack comes up

What runs where, what depends on what, and the order things have to happen in.
Most Tiiny "outages" are really a dependency earlier in this chain.

---

## The whole picture

```
┌─ workstation ────────────────────────────────────────────────────┐
│                                                                  │
│  TiinyOS (Electron, native linux-x64 build)                      │
│      │                                                           │
│      ├──► pcsvr  127.0.0.1:60000   (Go binary, PATCHED Wine)     │
│      │      holds auth_data/<serial>.json — the device token     │
│      │                                                           │
│      ├──► agent-catalog-proxy 127.0.0.1:60080                    │
│      │      intercepts agent-services.api.tiiny to rewrite the   │
│      │      store's OS filter (linux agents show up)             │
│      │                                                           │
│      └──► *.tiiny ──► systemd-resolved ──► bridge-host           │
└──────────────────────────────────────────────────────────────────┘
                              │
┌─ bridge-host (always-on) ───▼────────────────────────────────────┐
│  dnsmasq   address=/tiiny/10.0.0.2   (suffix match, any depth)   │
│  Caddy :80  podman quadlet, Network=host                         │
│      reverse_proxy ──► 172.20.19.89:80                           │
│  USB gadget iface enx…  172.20.19.90/30                          │
│  [planned] woollamad — gates chat traffic to the device          │
│  [Local-MCP] mcp-suite :9200 — MCP tools (loopback-only)         │
└──────────────────────────────────────────────────────────────────┘
                              │ USB /30, no roam
┌─ device ────────────────────▼────────────────────────────────────┐
│  nginx :80  ──► :8888 Tiiny Server                               │
│               └► :8800 model service  (/v1/*, /api/v1/*)         │
│  containers: connectors :5005 · KB :5003 · upgrade :5555         │
│              compose-manager :8880 · history :8004               │
│  model instances :9083 :9087 :9096 …  (one port per loaded model)│
│  /data — LUKS2, detached header — EVERYTHING waits on this       │
└──────────────────────────────────────────────────────────────────┘
```

---

## Bring-up order

Each step depends on the one above it. This ordering *is* the troubleshooting
sequence.

### 1. Device: unlock `/data`

The device boots with `/data` (LUKS2) **locked**. `docker.service` has
`Requires=data-unlocked.target`, so **the entire backend is down** and every API
returns **502** until it's unlocked.

```bash
tiiny-unlock.sh      # POST /api/v1/account/unlock_with_auth_key
```

Auth key only — no decryption password. **Any reboot needs this.** There is no
user-facing cue; it looks broken rather than locked.

### 2. Device: containers start

Once `/data` mounts, the Docker Compose Manager (`:8880`) brings up the backend:
model service, connectors, knowledge base, history, upgrade service. Model
instances get their own ports as models load.

### 3. The bridge host

Three things, none of which the device knows about:

- **USB link** — plug the device in; the gadget enumerates automatically as
  `enx*` and the device serves the /30 by DHCP (the bridge host gets
  `172.20.19.90`). No host config needed.
- **dnsmasq** — `address=/tiiny/10.0.0.2` makes every `*.tiiny` name resolve
  to the bridge host. One line, because dnsmasq matches the suffix at any
  depth.
- **Caddy** — a site block for the 16 device vhost names, reverse-proxying to
  `172.20.19.89:80`. Names are listed explicitly because a **Caddy wildcard is
  single-label** and would miss `auth.api.tiiny`.

Deploy this however you manage the bridge host's config — the two pieces are a
dnsmasq `address=` line (above) and a Caddy site block. Whatever deployment
method you use, **gate it on the device answering over USB** before writing
anything: one probe proves link + boot + unlock + API in a single check.

### 4. Clients: point the resolver at the bridge host

`/etc/systemd/resolved.conf.d/lan.conf` → `DNS=10.0.0.2`. Without this a
host resolves nothing under `.tiiny`, no matter how healthy the bridge is.

Verify: `getent hosts auth.api.tiiny` → `10.0.0.2`.

### 5. The workstation: pcsvr, then the app

```bash
./tiiny-native.sh start    # pcsvr (Wine) → agent proxy → the app
```

`pcsvr` must be up **before** the app: it's the PC Service the app dials on
`127.0.0.1:60000`, and it owns the device token. It runs under a **patched
Wine** build (see below).

`tiiny-native.sh status` reports the whole chain, including an autostart-drift
check.

---

## Why patched Wine

`pcsvr` ships as a **Windows binary only** (`pcsvr.exe`); the "linux wrapper" in
the app bundle is an empty stub. It needs `wine-11.14` with two patches:

| patch | without it |
|---|---|
| `wine-sio-udp-netreset` | Go ≥1.23 calls `WSAIoctl(SIO_UDP_NETRESET)` on every UDP socket and treats failure as fatal → pcsvr cannot open **a single UDP socket** → no discovery, no DNS |
| `wine-flsgetvalue2` | WebView2 imports `FlsGetValue2` → `msedgewebview2.exe` exits 13 silently → no Tauri agent starts |

Neither is Tiiny-specific. Build recipe in [`../wine/README.md`](https://github.com/teaguesterling/TTt/blob/main/wine/README.md).

**This is why pcsvr is pinned to one machine.** Moving it to the always-on
bridge host means reproducing a Wine source build on the box that already runs
DNS and the reverse proxy, and importing the Wine prefix-rot failure class with
it. Parked, not rejected.

---

## Why the app runs on native Electron, not Wine

TiinyOS ships Windows-only and was originally run under Wine — which **rots**: a
prefix's graphics state white-screens the renderer even though the JS runs fine.
The durable fix is repackaging the same `app.asar` onto a native linux-x64
Electron runtime (same version, 37.4.0).

Two non-obvious details:

- **Only `sharp` needs a Linux binary.** The other native modules
  (`@napi-rs/system-ocr`, `registry-js`, `selection-hook`) already self-guard on
  Linux. Pin to the app's own `sharp@0.34.5`, not npm latest.
- **`app.isPackaged` keys off the executable name.** A bare `electron` binary
  takes the dev branch and fails with `ERR_FILE_NOT_FOUND` on every window.
  Rename it (`cp electron tiinyos`) and launch that.

---

## Design decisions worth knowing

**The bridge carries inbound only.** The device's default route is still
`wlan0`; `usb0` is link-scope with no default route. So the device's *outbound*
traffic — model downloads, cloud APIs — still rides its unreliable radio.
Measured mid-download: `wlan0 rx 53 MB/s`, `usb0 rx 0 KB/s`. Giving it outbound
over USB would need IP-forward + masquerade on the bridge host; deliberately
not done.

**DNS shims are retired but preserved.** The app used to get `*.tiiny`
resolution only from its launcher (`nss_wrapper` + `--host-resolver-rules`),
which broke in two ways: any launch path that bypassed the launcher got no
device DNS at all, and the renderer's rules were baked at launch so a DHCP change
stranded it. Real DNS makes both impossible. `TIINY_DNS_SHIM=1` brings the old
behaviour back.

**One gate for chat, no owner for residency.** The device is single-session — a
second connecting client silently drops the first — and a loaded chat model
serves one request at a time, so exactly one thing should gate *chat* traffic.
Residency is different: nothing can own it. woollamad, the TiinyOS app, and our
own CLI all load models, and the CLI has to, because woollama's chat path does
not serve the image, ASR or embedding endpoints. Anything caching residency must
treat its view as a hint the device corrects.

**Model residency is not single.** Several models run concurrently, bounded by
**NPU RAM**, each on its own port. `GET /models/{id}/unload_candidate` names the
eviction victim before you hit the ceiling. Don't confuse this with the
one-request-at-a-time limit above.

---

## woollamad pooling — validated 2026-08-16

Pooling (woollama v0.12.0) is **live on the workstation** and measured against
the real device. Not yet moved to the bridge host; the config below is what
runs today and is what should move.

**It gates the chat path — it does not own residency.** Two separate claims that
are easy to run together:

- **Request serialization: yes, single owner.** The device is single-session and
  a loaded chat model serves one request at a time, so exactly one thing should
  gate chat traffic. Everything else reaches the chat path through this router.
- **Model residency: no owner is possible.** At least three things load and
  unload models here — woollamad, the TiinyOS desktop app (whenever the user
  chats with the device), and our own CLI, since `ttt image` and `ttt embed`
  must POST `/models/{id}/start` directly for endpoints woollama's chat path
  doesn't serve. Exclusivity isn't merely unenforced, it's unachievable: any
  consumer needing image/ASR/embeddings has to reach past the router.

Anything caching residency must therefore treat its own view as a **hint that
the device corrects**, load-balancer style — never as a ledger. This is exactly
what woollama #26 gets wrong (below).

```toml
[inferencers.tiiny]
base_url            = "http://api.tiiny/v1"
management_url      = "http://api.tiiny"
management_protocol = "device"     # /api/v1/models/{running,start,stop}
api_key_env         = "TIINY_API_KEY"
parallel            = 1            # NON-NEGOTIABLE: concurrency wedges the chat model
queue_max           = 8            # 503 + Retry-After instead of hanging
queue_timeout       = 90           # cold load measured at 33s; the 30s default 503s on first use

  [inferencers.tiiny.virtual]
  default = "Qwen/Qwen3.6-35B-A3B-turbo"
```

Measured: **cold on-demand load 33 s, warm 0.65 s.** Before pooling, the device
503'd for any model that wasn't already resident — it does not auto-load.

`queue_timeout` must exceed the cold-load time. The 30 s default is *just* under
the 33 s measured here, so it 503s on the very first request and looks like a
broken config.

`pool_max` is deliberately **omitted**: woollama's `pool_max` counts models, but
the device's ceiling is **NPU RAM**. Setting `pool_max = 1` would evict a 0.7 GiB
reranker to load a 0.9 GiB embedder that would have fitted. (Confirmed: the
turbo, the embedder and the reranker are all co-resident right now.)
`unload_candidate` is the device-side signal that would inform a correct value —
though note it under-predicts: it named one 0.7 GiB victim for a load that
actually evicted all three models, 18.2 GiB.

### Version state: on v0.13.0

`cargo install woollama-server` → `~/.cargo/bin/woollamad`, running on
`127.0.0.1:47600`. A released build, not a commit. Requires `TIINY_API_KEY` in
its environment; without it every request 400s and the residency query 401s.

The two chat routes now hold **different** `virtual.default` values again —
`tiiny` → turbo, `tiiny-fast` → Instruct. Verified at migration: alternating
them ran 0.68–0.86s with device residency unchanged. The virtual entry is now
only consulted when nothing eligible is resident, so it means "what to load on
a cold device", which is what it should have meant all along.

The history below is kept because the intermediate state was a trap.

The sequence, because the intermediate state is a trap worth remembering:

**[#28](https://github.com/teaguesterling/woollama/pull/28)** fixed the
pool/device desync below. Both halves verified here (see the next two sections).
But its residency ordering was seeded by `HashMap` iteration order, which Rust
re-randomizes per process — 12 independent cold starts gave 3 chat-OK, 6
embedder 503, 3 reranker 503. A hash-seed lottery: **`default` failed ~75% of
the time** whenever non-chat models were resident, which here they normally are.

**[#29](https://github.com/teaguesterling/woollama/pull/29)** fixed it with two
deterministic rules — candidates restricted to the inferencer's `models` list,
then a resident `virtual.default` first and lexicographic after. Re-ran the same
12-trial loop against `2a81740`: **12/12 chat-OK, zero 503s.**

#### ⚠ The fail-open trap this exposed

If a route's `models` list contains **nothing currently resident**, rule 1 finds
no candidate and falls *open* to the unfiltered resident set — ordered
lexicographically. On this device that ordering always puts
`Qwen/Qwen3-Embedding-0.6B` first: the shared prefix `Qwen/Qwen3` is followed by
`-` (0x2D) in both 0.6B models versus `.` (0x2E) in
`Qwen3.6-35B-A3B-turbo`, and then `E` < `R`.

Measured: a route in that state returned **embedder 503 six times out of six,
deterministically**. Determinism made this route strictly worse than the
lottery — 100% failure instead of 67% — though far easier to diagnose.

**The trap is an id that looks right and isn't.** `Qwen/Qwen3.6-35B-A3B` and
`Qwen/Qwen3.6-35B-A3B-turbo` are different models; only the turbo is ever
resident here. A `models` list naming the former reads as correct and satisfies
nothing. **List every chat model that can actually be resident** so rule 1 is
satisfied and fail-open is never reached.

Real fix is capability filtering (#20) — the device already publishes
`capabilities: ["main"|"embedding"|"rerank"]` per resident, so fail-open could
open to chat-capable models rather than all of them.

**Confirmed in production, 2026-08-17.** A peer session testing on this device
loaded `zai-org/GLM-4.7-Flash`, which evicted the 35B turbo. Every `tiiny/*`
route began 503ing within seconds, because the `models` lists were all-Qwen and
nothing configured was resident any more. Nobody coordinated it and nobody did
anything wrong — residency is device-wide with several independent mutators.

The lesson is that **listing models is a treadmill**: keeping fail-open unreached
means enumerating every chat model *anyone* might load, including peers you
aren't talking to. Capability filtering is the only version that doesn't require
predicting other people. Until then, when a route starts 503ing on the embedder,
check what is actually resident before suspecting the config — it may have been
correct when written and stale a minute later.

**Fixed in v0.13.0**, which also warns once per inferencer when a route falls
open. Caveat found at migration: that warning also fires when the residency
query *fails* (e.g. a 401 from a missing `TIINY_API_KEY`), where it wrongly
tells you to fix your `models` list. If you see it, check the line below it for
an auth error before touching the config. Reported upstream.

### ⚠ `virtual.default` resolves against woollama's pool, not the device

woollama's docs say `default` resolves to whichever model is currently loaded,
using the table entry only as a fallback. It actually resolves against
woollamad's **own pool bookkeeping**, which starts empty and only records models
woollamad itself loaded. A freshly started woollamad facing a device with a model
already resident answers:

```
400 "model 'default' requested but no model is loaded and
     no 'virtual.default' fallback is configured for this inferencer"
```

So in practice **the fallback is what fires, every time**. Two consequences:

- **Always configure `virtual.default`.** Without it, `default` is a 400 until
  woollamad happens to load something itself.
- **Every route onto this device must name the SAME model.** Each inferencer
  keeps a separate pool, so two routes don't see each other's loads. With
  different entries, alternating between them swapped the device on *every call*
  (~30 s each way) — which is exactly what `ttt code` vs `ttt code --smart`
  does. Pointing both at one model id: 0.63–0.85 s alternating, no swap.

That is not much of a compromise — an ~18 GiB chat model on a 31 GiB device means
only one is resident anyway. Name a model explicitly to get the other one, and
accept the swap you asked for.

Filed as [woollama #26](https://github.com/teaguesterling/woollama/issues/26) and
confirmed at the code level: `passthrough_pooled` resolves against
`DeviceModelManager::snapshot()`, which reads local `entries` only — the device
query `list_loaded()` runs inside `ensure_loaded`, one step *after* resolution.
The suggested fix is to seed the pool from
`management_url` at startup (both the `device` and `ollama` protocols expose a
running/ps query), and to share pool state between inferencers with the same
`management_url` — which would also stop two routes from silently doubling the
in-flight concurrency that `parallel = 1` is there to cap.

### Routing this through a bridge host instead

If you run woollamad on a host that holds the USB link rather than on the
device's own network path, use the **direct USB address** for `base_url` —
`http://172.20.19.89:8800/v1` — not a `*.tiiny` name. That host has the USB
link, and the direct path also exposes the Ollama surface should it ever be
wanted. A name works for the `device` protocol and silently 404s for the
`ollama` one (see [`networking.md`](networking.md)).

### Consuming the MCP suite (validated with Local-MCP)

There will be **two** woollamads on the bridge host — this one for inference,
Local-MCP's for MCP tools. They're disjoint because woollamad cannot consume
MCP over HTTP until woollama #19 lands; once it does:

```json
{"mcpServers": {"suite": {
    "url": "http://127.0.0.1:9200/mcp",
    "headers": {"Authorization": "Bearer ${WOOLLAMA_TOKEN}"}}}}
```

Three things that are easy to get wrong here, all confirmed rather than assumed:

- **Loopback, not the vhost.** `:9200` is published
  `PublishPort=127.0.0.1:9200:9200` — loopback-only. `mcp.example.lan` is Caddy
  on **443 with `tls internal`**, so it is https and a different path entirely.
  Going out to Caddy and back for a same-host call adds a TLS hop and requires
  trusting the internal CA, for nothing.
- **Two different secrets, don't merge them.** Consuming the suite needs
  `woollama-token` (Local-MCP's, mounted as `WOOLLAMA_TOKEN`). Our own upstream
  auth uses `woollama-device-token`. Different jobs.
- **⚠️ If this router is containerized, `127.0.0.1` is its own netns**, not
  the bridge host's own loopback, and the config above fails with
  connection-refused. Use `Network=host` on the quadlet — the same pattern
  already used for Caddy's own container above.

Header values **fail closed at load**: an unset `${VAR}` makes woollamad refuse
to start, naming the server and header, rather than sending `Bearer ` with no
credential. So a wrong guess surfaces as a startup failure, not a 401.

---

## Where things live

| | |
|---|---|
| `~/tiiny-tools` | this repo — portable tools + docs |
| `~/.local/opt/wine-patched` | the patched Wine build (1.8 GB) |
| `~/.local/share/tiiny-pcsvr/` | pcsvr state, incl. `auth_data/<serial>.json` |
