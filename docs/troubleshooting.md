# Troubleshooting

A runbook, ordered by what actually goes wrong. Every check here was used in
anger on 2026-08-16; the diagnostic sequences are the expensive part.

**The meta-rule, learned the hard way:** *"we lost the device" almost always
means the app or the path, not the device.* On the day this was written the
device was healthy for all but 19 minutes, while three separate things made it
look dead. Check in this order and you'll usually find it alive.

---

## "I can't reach the device"

### 1. Is it actually unreachable, or just unreachable *one way*?

```bash
tiiny models                                   # via names, through the bridge
ping -c3 10.0.0.50                             # its WiFi address (DHCP-assigned)
```

Those are two independent paths. If either answers, the device is up and you have
a *path* problem, not a device problem.

### 2. Distinguish DNS from unreachable

```bash
getent hosts auth.api.tiiny        # expect 10.0.0.2 (the bridge host)
dig +short auth.api.tiiny @10.0.0.2
```

**Nothing resolving?** Your resolver isn't pointing at the bridge host. Check
your resolver config (e.g. `/etc/systemd/resolved.conf.d/lan.conf`) for
`DNS=10.0.0.2`. Names resolving but connections failing is a *different*
problem — go to step 3.

Note `auth.api.tiiny` specifically: it's the two-label case that a single-label
wildcard would miss. If `api.tiiny` resolves and `auth.api.tiiny` doesn't, the
wildcard is wrong.

### 3. Device truly dark on every path?

Check whether it's a WiFi roam rather than a dead device:

```bash
ip neigh show 10.0.0.50            # FAILED = nothing answering at L2
```

**It self-heals in ~19 minutes.** Twice-observed, both times at that duration.
Be patient before blaming anything else — and note the device stays **up**
throughout: uptime unaffected, no reboot.

⚠️ **`signal_strength` is not a health metric.** It reads **100** during a
completely dead roam. Measure the path (ping), never the metric.

---

## "The app can't connect but the device is fine"

The single most expensive failure of the day, and it has a fingerprint.

**Symptom:** every request logs a bare `warn: fetch failed`, from the first
second, while `ping` and `curl` to the device succeed.

**Cause:** the app was launched without device name resolution. Confirm in 30
seconds:

```bash
P=$(pgrep -f 'tiinyos-linux/tiinyos --no-sandbox' | head -1)
tr '\0' '\n' < /proc/$P/environ | grep NSS_WRAPPER_HOSTS   # absent ⇒ this bug
ss -tnp | grep 10.0.0.50                                   # zero conns ⇒ never tried
```

**Read the log text — it discriminates:**

| log says | means |
|---|---|
| `fetch failed` | **DNS** — the name didn't resolve. The app never tried. |
| `Not Found` | reaching the device fine; that path isn't served |

Since `*.tiiny` became real DNS this is largely historical, but the fingerprint
is worth keeping: an app launched by any path that bypasses its launcher used to
get no device DNS at all.

---

## "Everything returns 502"

**The device boots with `/data` LUKS-locked.** `docker.service` requires
`data-unlocked.target`, so the whole backend and the model API return 502 until
someone unlocks it. There is **no user-facing cue** that unlocking is the fix —
it looks broken, not locked.

```bash
ttt unlock               # POST /api/v1/account/unlock_with_auth_key, then waits
                         # for the model API to answer (not just the flag)
tiiny-unlock.sh          # the same thing without the CLI
```

`ttt status` shows the lock state up front, and any `ttt` command that hits a
502 says so rather than printing the number.

Auth key only, no decryption password. Any reboot needs this afterwards.

---

## "A model won't load"

Not a single slot — a **memory-bounded pool**. Ask before you load:

```bash
curl -sSL -H "Authorization: Bearer $TIINY_AUTH_KEY" \
  "http://p8800.api.tiiny/api/v1/models/$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" 'Qwen/Qwen3-30B-A3B-Instruct')/unload_candidate"
```

```json
{"unload_required": true,
 "message": "Not enough NPU RAM available. Would you like to unload
             [Qwen/Qwen3-Reranker-0.6B] to make room for the model?",
 "target_model": {"npu_usage": 55}}
```

It names the victim, so you decide rather than discover. Several models run
concurrently (embedding + reranker + a 35B chat model, observed together); the
limit is NPU RAM, not model count.

**Never reboot to swap models.** Use stop/start.

---

## "An import or download is stuck"

**Watch the byte counter, not `status`** — the status field can disagree with
what the job is actually doing, so measure progress directly:

```bash
# poll twice, diff the bytes
curl -sS -H "Authorization: Bearer $TIINY_AUTH_KEY" \
  http://p8800.api.tiiny/api/v1/models/import/<id> | python3 -c \
  "import json,sys;d=json.load(sys.stdin);print(d['download_components']['hf_model']['downloaded_bytes'])"
```

If a download passes the same progress point more than once, it is restarting
rather than advancing — pause it.

**To find out why an import failed:** `POST /models/import/resume` and read the
**whole SSE stream it returns**. The terminal error appears there, not in the
polled job record.

**Reclaiming space after a failure:** `POST /import/{id}/cancel` releases the
failed import's cache.

---

## "MCP clients lost woollamad, but the daemon is healthy"

Someone ran `woollamad --help`, `--version` or `-V`. In v0.14.1 all three
**start a full daemon** instead of printing and exiting — they never exit at
all — and the damage lands on the daemon that was already running:

- the probe overwrites `/run/user/1000/woollama.addr` with its own ephemeral
  port, then dies. Clients that discover by addr file get a dead address.
- on exit the probe **unlinks `woollama.sock`, a path it did not create**. The
  live daemon stays bound to the now-orphaned inode, so `ss -xlnp` still shows
  it listening while `ls` shows no such file. Path-based clients get
  ECONNREFUSED.

Nothing errors on either side. The daemon logs nothing and reports healthy;
only an actual client connect reveals it. Confirm:

```bash
cat /run/user/1000/woollama.addr          # should match the live port (47600)
ls -l /run/user/1000/woollama.sock        # missing => unlinked by a probe
curl -sS --unix-socket /run/user/1000/woollama.sock http://localhost/v1/models
```

Fix — restart rewrites both discovery points:

```bash
systemctl --user restart woollamad
```

To read the version safely, use the installed-crate record instead of running
the binary:

```bash
cargo install --list | grep -A1 woollama-server
```

Reported upstream; the durable fix is for a non-serving invocation never to
touch the addr file or socket, and for shutdown to unlink only a socket the
process actually created.

---

## Quick reference — what each symptom usually is

| symptom | first suspect |
|---|---|
| `fetch failed` everywhere, device pings fine | app launched without DNS |
| `Not Found` on some endpoints | that path isn't served |
| everything 502 | `/data` locked after a reboot |
| device dark on all paths, uptime unaffected | WiFi roam; give it ~19 min |
| signal strength reads full but nothing works | measure the path, not the metric |
| import "paused" but disk is filling | trust the byte counter |
| download passes the same point twice | it's restarting; pause it |
| model load refused | NPU RAM; ask `unload_candidate` |
| two clients fighting | one session at a time; the first is dropped |
| chat model times out on everything | serialise requests; `parallel = 1` |
| MCP clients lost woollamad, daemon healthy | someone ran `woollamad --help`/`--version` |

See [`networking.md`](networking.md) for how the paths fit together.
