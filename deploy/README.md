# deploy

Unit files for running TTt tooling as a service. Both are **user** units — no
sudo — but they need `loginctl enable-linger <user>` to start without a login.
Check before assuming it on a new host: `loginctl show-user $USER -p Linger`.

| unit | what it runs | where |
|---|---|---|
| `tiiny-device-watch.service` | the device/bridge watcher | an always-on host with the USB link (the bridge host) |
| `woollamad.service` | the woollama router on `:47600` | wherever inference is routed from (e.g. the workstation) |

Install either with:

```bash
install -Dm644 deploy/<unit> ~/.config/systemd/user/<unit>
systemctl --user daemon-reload && systemctl --user enable --now <unit>
```

## `woollamad.service` — the router

Runs [`../bin/woollamad-run.sh`](../bin/woollamad-run.sh), which fetches the
device bearer token (explicit `TIINY_API_KEY`, else pcsvr's `auth_data`) and
**refuses to start on a 401**. That check exists because the failure it prevents
is misleading: without a key woollamad starts happily and listens, then 400s
every request while its residency query 401s — and the fail-open warning then
tells you to fix a `models` list that is perfectly correct.

Needs `~/.cargo/bin/woollamad` (`cargo install woollama-server`, >= 0.13.0).
Override with `WOOLLAMAD_BIN`.

Note `StartLimitBurst=5` / `StartLimitIntervalSec=300`: restart it more than
five times in five minutes and systemd silently refuses, which during testing
looks exactly like the daemon crashing on startup. `systemctl --user
reset-failed woollamad` clears it.

## `tiiny-device-watch.service` — the watcher, on the bridge host

Runs [`../bin/device-watch.sh`](../bin/device-watch.sh) continuously and logs
state transitions to `~/tiiny-tools/bin/device-watch.log`.

**Install (an always-on host with the USB link):**

```bash
git clone https://github.com/teaguesterling/TTt.git ~/tiiny-tools
install -Dm644 ~/tiiny-tools/deploy/tiiny-device-watch.service \
  ~/.config/systemd/user/tiiny-device-watch.service
systemctl --user daemon-reload
systemctl --user enable --now tiiny-device-watch.service
```

No sudo: it's a **user** unit, but the host needs `loginctl enable-linger`
set for it to start at boot without anyone logging in. Verify with
`loginctl show-user $USER -p Linger` before assuming that on a new host.

**Why an always-on host.** A workstation sleeps, and a watcher that sleeps
isn't watching — and this host also needs to hold the USB link to the device.
A watcher on a machine that suspends can't distinguish "the device went away"
from "I went away."

### Read the log like this

Three dimensions, deliberately independent, because "I can't connect to the
Tiiny" presents as a bare `fetch failed` for at least three unrelated causes:

| DEVICE | PATH | means |
|---|---|---|
| up | up | healthy |
| up | down | **the bridge broke**, not the device — dnsmasq, Caddy, or the USB link |
| up | unresolved | **DNS** — the client won't resolve `api.tiiny` at all |
| down | up | Caddy is answering but the device behind it isn't — check unlock (`tiiny-unlock.sh`) |
| down | down | device genuinely gone, or the USB cable |

`DEVICE up + PATH down` is the row worth internalising. It is invisible from the
app, and every instinct says "reboot the device," which is exactly wrong.

### `TIINY_IP` is not optional here

The unit pins `TIINY_IP=172.20.19.89` — the device's own USB /30 address. On
the bridge host, `api.tiiny` resolves to **the bridge host itself**, so
without the pin the DEVICE probe would fall through to that name and report
the device up whenever Caddy is up. That collapses the two dimensions into one
and destroys the only thing the table above is good for.

### Knobs

| env | default | |
|---|---|---|
| `TIINY_IP` | discovery | the device's own address; **set this on a bridged host** |
| `DEVICE_WATCH_NAME` | `api.tiiny` | the name clients dial, probed as PATH |
| `DEVICE_WATCH_INTERVAL` | `15` | seconds between probes |
| `DEVICE_WATCH_HEARTBEAT` | `1800` | seconds between "still fine" lines |

`APP` reports `n/a` on a headless host rather than a permanent false `gone`.
`DRIFT` applies only in legacy shim mode (`TIINY_DNS_SHIM=1`) and reports `n/a`
otherwise — it used to report `no` when it had nothing to compare, which is a
check that cannot fail.
