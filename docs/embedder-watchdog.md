# tiiny-embedder-watchdog

A small, dependency-free watchdog that detects a **wedged NPU model server** on a Tiiny
device and recovers it automatically. Written during a multi-day, ~2.4-million-page
embedding run; shared because the failure mode is real, silent, and trivially
recoverable *once you know the trick*.

---

## The failure mode

Under sustained NPU load, the model server can **wedge**: every inference request times
out or hangs forever, while the device otherwise looks completely healthy —

- CPU load is *low* (it's hung, not busy)
- the container is running, the management API answers normally
- `dmesg` shows nothing
- the model still appears in the running-models list

From the outside it reads as "the device got slow." It hasn't; it has stopped serving.

## What doesn't fix it

**Restarting just the affected model** (stop + start of that one model) does **not**
reliably clear the wedge. Neither does waiting.

## What does fix it

**Stop *all* running models — releasing the NPU — then start the target model again.**

That's the whole trick, and it's what this watchdog automates.

---

## How well it works

Measured over a multi-day embedding workload (Qwen3-Embedding-0.6B, batches of
16–48, ~16 pages/sec):

| | |
|---|--:|
| Detections recovered | **all of them** |
| Failed recoveries | **0** |
| Transient blips correctly left alone | 3 |
| Recovery time | **6 s** typically, **48 s** at worst |

The job ran to completion with no human intervention. Run it with `WD_DRY_RUN=1`
first to see whether your own workload needs it at all.

---

## Install (on-device)

```sh
sudo install -m 755 bin/tiiny-embedder-watchdog.sh /usr/local/bin/tiiny-embedder-watchdog.sh
sudo install -m 600 deploy/tiiny-embedder-watchdog.env.example /etc/tiiny-embedder-watchdog.env
sudo $EDITOR /etc/tiiny-embedder-watchdog.env     # set endpoints + model (+ token)

sudo install -m 644 deploy/tiiny-embedder-watchdog.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now tiiny-embedder-watchdog
journalctl -u tiiny-embedder-watchdog -f
```

Running from a host instead of on the device works identically — just point
`TIINY_MGMT` / `TIINY_EMBED_URL` at the device.

## Try it safely first

```sh
# one probe, report, exit (exit 0 = healthy)
bin/tiiny-embedder-watchdog.sh --once

# watch and log wedges, but never stop or start anything
WD_DRY_RUN=1 bin/tiiny-embedder-watchdog.sh
```

`WD_DRY_RUN=1` is the recommended way to observe how often *your* workload wedges before
you let anything restart models.

---

## Configuration

Everything is environment-driven; see `deploy/tiiny-embedder-watchdog.env.example`.

| Variable | Default | Purpose |
|---|---|---|
| `TIINY_MGMT` | `http://p8800.api.tiiny/api/v1` | Management API base (start/stop/running) |
| `TIINY_EMBED_URL` | `http://api.tiiny/v1/embeddings` | Endpoint to probe |
| `TIINY_MODEL` | `Qwen/Qwen3-Embedding-0.6B` | Model to keep alive |
| `TIINY_TOKEN` / `TIINY_TOKEN_FILE` | — | Bearer auth; prefer the file (keeps it out of `ps`) |
| `WD_INTERVAL` | `30` | Seconds between probes |
| `WD_FAILMAX` | `3` | Consecutive failures before declaring a wedge |
| `WD_PROBE_TIMEOUT` | `12` | Per-probe timeout (s) |
| `WD_STOP_ALL` | `1` | **1 = stop all models (the actual fix)**; 0 = only the target |
| `WD_COOLDOWN` | `120` | Minimum seconds between recovery attempts |
| `WD_MAX_PER_HOUR` | `6` | Thrash guard — above this, log loudly and stop trying |
| `WD_REQUIRE_MGMT` | `1` | **Only recover if the device itself still answers** (see below) |
| `WD_MGMT_TIMEOUT` | `8` | Reachability-check timeout (s) |
| `WD_DRY_RUN` | `0` | 1 = detect and log only |
| `WD_HEARTBEAT` | `3600` | Seconds between summary lines |

### A wedged model is not the same as an unreachable device

A failing inference endpoint has (at least) two very different causes, and they look
identical from a probe:

- the **model wedged** — the device is fine, the model server stopped serving; **restart it**
- the **path broke** — network, DNS, the USB/bridge link, a reverse proxy; the device and
  model are perfectly healthy and **restarting models would be destructive and useless**

So before it touches anything, the watchdog asks the device directly: *does the management
API answer?* **Any** HTTP response — including `401`/`404` — proves the path works; only a
connection failure or timeout means unreachable.

| inference endpoint | management API | verdict |
|---|---|---|
| failing | **answers** | wedge → stop all models, restart the target |
| failing | unreachable | **path problem → log it, change nothing** |

The path case is logged once on transition (not once per probe) and counted as
`path_skips` in the summary, so a long outage stays readable. Disable with
`WD_REQUIRE_MGMT=0` only if your device has no management API.

> This distinction is borrowed from `device-watch.sh` in this repo, which exists precisely
> to tell DEVICE from PATH from APP. Probing a gateway hostname rather than the device's own
> address is exactly how a watchdog ends up "recovering" hardware that was never broken.

### Notes

- **Use the API gateway hostname, not a raw model port.** The model server's own port can
  change on every restart; the gateway is stable. But point `TIINY_MGMT` somewhere that
  genuinely proves *the device* is up — if both URLs terminate at the same proxy, the
  path check above can't do its job.
- **`WD_MAX_PER_HOUR` is deliberate.** If the device wedges faster than it can be
  recovered, restarting harder won't help — the watchdog says so loudly and stops, so the
  condition surfaces instead of being masked.
- **No dependencies.** POSIX-ish bash + `curl`. Uses `jq` or `python3` for JSON if
  present, and falls back to `sed` if neither is.
- **No secrets in the script.** Token comes from the environment or a `600` file.
