# Fronting the device with woollama

The device is usable directly — `http://api.tiiny/v1` speaks the OpenAI API. But
it has three habits that make a bare endpoint painful to share between tools:

- **It serves one request at a time.** Two concurrent chat calls wedge the
  loaded model; every request then times out until it is restarted.
- **It does not auto-load.** Ask for a model that isn't resident and you get a
  503, not a load.
- **Residency is device-wide and has several owners.** The desktop app, any CLI
  and any other client on the LAN can load or evict a model out from under you.

[woollama](https://github.com/teaguesterling/woollama) is a small router that
absorbs all three. It is an independent open-source project (Rust daemon,
`woollamad`), not Tiiny-specific — docs at
[woollama.readthedocs.io](https://woollama.readthedocs.io/).

## What it is

An OpenAI-compatible server and MCP server in one process. Clients point at it
instead of at a backend, and it routes each request by `<provider>/<model>` to
whatever serves that model: a local Ollama, a hosted API, any OpenAI-compatible
endpoint — including this device.

For our purposes the interesting part is its **pool**: a route can be given a
management URL, and woollamad will then check what the backend currently has
loaded, load the requested model if it is missing, and hold requests in a queue
while that happens.

## Why use it here

```
your tools ──► woollamad :47600 ──► queue (parallel = 1) ──► device /v1
                    │
                    └─ management: /api/v1/models/{running,start,stop}
                       load on demand, evict when the device says so
```

- **One gate in front of a single-session device.** `parallel = 1` means one
  in-flight request no matter how many clients call.
- **On-demand loading.** Ask for any listed model and it is loaded if needed.
  Measured on this hardware: **33 s cold, 0.65 s warm.**
- **Honest backpressure.** A full queue returns `503` with `Retry-After`
  instead of hanging.
- **A stable local endpoint.** Tools point at `127.0.0.1:47600` and stop caring
  which model is resident or where the device is on the network.

What it does **not** do is own residency. Other clients still load and evict
models; the pool treats its own view as a hint the device corrects. Anything
that caches residency should do the same.

## Install

```bash
cargo install woollama-server        # ≥ 0.13.0; current release 0.16.x
# binary lands at ~/.cargo/bin/woollamad
```

## Configuration

`inferencers.toml` — one chat route is the safe shape:

```toml
[inferencers.tiiny]
base_url            = "http://api.tiiny/v1"     # or http://<device-ip>:8800/v1
management_url      = "http://api.tiiny"
management_protocol = "device"   # /api/v1/models/{running,start,stop}
api_key_env         = "TIINY_API_KEY"
parallel            = 1          # the device serves ONE request at a time
queue_max           = 8          # 503 + Retry-After instead of hanging
queue_timeout       = 90         # must exceed the cold-load time

models = [
  # EVERY chat model that could be resident, not just the ones you load
  "Qwen/Qwen3.6-35B-A3B-turbo",
  "Qwen/Qwen3-Coder-30B-A3B-Instruct",
  "Qwen/Qwen3-30B-A3B-Instruct",
  "Qwen/Qwen3-8B",
  "default",
]

  [inferencers.tiiny.virtual]
  default = "Qwen/Qwen3.6-35B-A3B-turbo"   # what to load on a cold device
```

Four settings worth understanding, each learned the hard way:

- **`queue_timeout` must exceed the cold load.** The 30 s default sits just
  under the 33 s measured here, so the very first request 503s and it looks
  like a broken config.
- **List every chat model that could be resident.** If a route's `models`
  contains nothing currently loaded, it falls open to the unfiltered resident
  set in lexicographic order — which puts the embedder first, and chat requests
  to an embedder 503. This bites when *another* client loads something you
  didn't list.
- **Leave `pool_max` unset.** It counts models, but the device's ceiling is NPU
  memory. Capping the count evicts a 0.7 GiB reranker to load a 0.9 GiB
  embedder that would have fitted alongside it.
- **One chat route, not several.** `parallel` is enforced per route, so two
  pooled routes against one device permit two in-flight requests — exactly the
  concurrency that wedges it.

`virtual.default` only decides what to load when nothing eligible is resident;
whichever chat model is already loaded serves the route.

## Running it

woollamad needs the device token in its environment (`api_key_env`). Without
it, the daemon still starts and still listens — then every chat request 400s
and the residency query 401s, which reads like a config error and isn't. Start
it through a wrapper that fetches the key and refuses to start on a 401; see
[`../bin/woollamad-run.sh`](https://github.com/teaguesterling/TTt/blob/main/bin/woollamad-run.sh) and
[`../deploy/woollamad.service`](https://github.com/teaguesterling/TTt/blob/main/deploy/woollamad.service).

```bash
cargo install woollama-server
install -Dm644 deploy/woollamad.service ~/.config/systemd/user/woollamad.service
systemctl --user daemon-reload && systemctl --user enable --now woollamad
curl -s localhost:47600/v1/models | head
```

## When not to bother

Single-tool, single-user, one model, always the same one: the device's own
endpoint is fine and one less moving part. The router earns its place as soon
as two things share the device, or you want a model loaded on demand rather
than by hand.
