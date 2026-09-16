# From scratch — a new machine to a working stack

The authoritative build order. Everything needed is in this repo.

**Only a desktop host needs all of this.** A headless host (an always-on bridge
host, say) needs step 0 and `bin/` alone — no Wine, no prefix, no Electron.
Skip to [Headless hosts](#headless-hosts).

Read [`architecture.md`](architecture.md) first if you want to know *why* the
stack is shaped this way. This file is the *how*.

---

## 0. What you must obtain yourself

Two artifacts are **not** in this repo and cannot be — they're vendor binaries:

| | where from |
|---|---|
| `TiinyOS-<version>-setup.exe` | the vendor's Windows installer |
| the device auth key | written by `pcsvr` into `~/.local/share/tiiny-pcsvr/auth_data/<serial>.json` once it has paired |

Everything else is either in this repo or built by the steps below.

---

## 1. Host requirements

**Wine ≥ 10 — this is a hard floor, not a recommendation.** Wine 9.0 (what
Ubuntu ships) cannot complete an outbound TCP connect from Node/libuv; it fails
with `connect UNKNOWN` and the app dies about 6 seconds in, with nothing useful
in the log. Verified working on `winehq-devel` 11.14. Install commands are in
[`linux-desktop.md`](linux-desktop.md#what-you-need-first).

`libnss-wrapper` is only needed if you intend to use the retired DNS shims
(`TIINY_DNS_SHIM=1`). With real DNS via the bridge host it is unused — but it
is cheap insurance on a host that may not always reach it.

## 2. Patched Wine — for `pcsvr` only

`pcsvr` is a Windows Go binary with no Linux build (the "linux wrapper" in the
app bundle is an empty stub), and stock Wine cannot run it usefully. Two
patches fix that, neither Tiiny-specific — see
[`linux-desktop.md`](linux-desktop.md#1-patched-wine-for-pcsvr-only) for what
each one fixes. Full build recipe: [`../wine/README.md`](https://github.com/teaguesterling/TTt/blob/main/wine/README.md).
It builds into `~/.local/opt/wine-patched` and leaves the system Wine alone;
the launchers auto-detect it and fall back to system `wine` if absent.

Budget ~1.8 GB and a long compile.

## 3. The Wine prefix

```bash
./wine/setup-wine-prefix.sh          # WINEPREFIX overridable
```

Three settings that each exist for a discovered reason, not by habit (`win10`
mode, `vcrun2022`, `fakechinese`) — see
[`linux-desktop.md`](linux-desktop.md#2-the-wine-prefix) for what each one
fixes.

## 4. Install the vendor package, extract `pcsvr`

Run the vendor `.exe` under the patched Wine in that prefix. What you need out
of it afterwards is `pcsvr.exe` and its support files; the Windows *app* is not
used (step 5 replaces it).

Start pcsvr once and let it pair with the device, so it writes
`auth_data/<serial>.json`. Every tool in `bin/` reads the key from there, or
from `TIINY_AUTH_KEY` if you set it explicitly.

## 5. The native Electron app tree

TiinyOS under Wine **rots** — a prefix's graphics state white-screens the
renderer while the JS runs fine. The durable answer is repackaging the same
`app.asar` onto a native linux-x64 Electron of the same version (37.4.0).

**One command:**

```bash
./launcher/build-native-linux.sh                 # auto-detects the Wine install
./launcher/build-native-linux.sh --target DIR --src WINE_INSTALL --force
```

It fetches the matching Electron, copies the app payload out of the Wine
install, installs the one native module that needs a Linux build, renames the
binary, drops the launcher in, and verifies all ten results. Idempotent — re-run
it to check or repair an existing tree.

The three things it does that are not obvious, and that cost hours when done by
hand, are detailed in
[`linux-desktop.md`](linux-desktop.md#4-build-the-native-electron-tree): only
`sharp` needs a Linux binary, and it must be the *main* `sharp` package (not
just the platform sub-package, which omits an undeclared runtime dependency);
and the Electron binary must be renamed so `app.isPackaged` takes the packaged
branch instead of dying with `ERR_FILE_NOT_FOUND`.

## 6. Networking

The device's WiFi is roam-unstable — see [`networking.md`](networking.md). The
stable path is the USB gadget on a fixed /30, bridged by an always-on bridge
host:

- point the host resolver at the bridge host (`DNS=10.0.0.2`), verify with
  `getent hosts auth.api.tiiny`
- on the bridge host, a dnsmasq `address=/tiiny/10.0.0.2` line answers the
  `.tiiny` names, and a Caddy `reverse_proxy` snippet forwards to the device
  over the USB /30

Without a resolver pointing at the bridge host, nothing under `.tiiny` resolves
no matter how healthy the bridge is — and the app reports that as a bare
`fetch failed`.

## 7. Start it

```bash
./launcher/tiiny-native.sh start     # pcsvr → agent proxy → app
./launcher/tiiny-native.sh status
```

Order matters: pcsvr must be up before the app, which dials it on
`127.0.0.1:60000` and depends on it for the device token.

Set `TIINY_HOME` / `TIINY_NATIVE_BUILD` if your layout differs from the
defaults in [`../launcher/README.md`](https://github.com/teaguesterling/TTt/blob/main/launcher/README.md#paths).

## 8. Optional: the woollama router

`woollamad` fronts the device with a queue and on-demand model loading, so
callers get `503 + Retry-After` instead of wedging it.

```bash
cargo install woollama-server            # >= 0.13.0
install -Dm644 deploy/woollamad.service ~/.config/systemd/user/woollamad.service
systemctl --user daemon-reload && systemctl --user enable --now woollamad
```

`bin/woollamad-run.sh` supplies the device key and **refuses to start on a
401** — without it the daemon starts happily and 400s every request, which
looks like a config problem and isn't.

## 9. Optional: the watcher

```bash
install -Dm644 deploy/tiiny-device-watch.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now tiiny-device-watch
```

See [`../deploy/README.md`](https://github.com/teaguesterling/TTt/blob/main/deploy/README.md) — especially the DEVICE × PATH
table, which is what tells a dead device apart from a dead bridge.

---

## Headless hosts

An always-on bridge host and similar need **none** of steps 1–5. No Wine, no
prefix, no Electron:

```bash
git clone https://github.com/teaguesterling/TTt.git ~/tiiny-tools
export TIINY_AUTH_KEY=...            # no pcsvr here to read auth_data from
~/tiiny-tools/bin/ttt status
```

Then steps 8 and 9 if that host should route inference or watch the device.
`TIINY_IP` is mandatory for the watcher on a bridged host — see
[`../deploy/README.md`](https://github.com/teaguesterling/TTt/blob/main/deploy/README.md).

**`tiiny-unlock.sh` is the one tool that cannot be made portable**: it needs the
device serial *and* key from pcsvr's `auth_data`, so it only runs where pcsvr
does.

---

## Wine gotchas that still apply

`pcsvr` still runs under Wine even though the app doesn't, so these remain live:

- **Never pipe the app's or pcsvr's stdio.** libuv misreads Wine pipe handles
  and Electron dies at startup with `Error: open EBADF`. The launchers redirect
  to files for this reason — don't "clean that up".
- **`xwininfo` lies.** It reports windows `IsViewable` with correct geometry
  while nothing is on screen. Confirm a plain X client (`xmessage`) is visible
  before concluding anything about Wine or the app.
- **WireGuard cannot work under Wine** (it needs the Wintun kernel driver). We
  run pcsvr with it disabled; discovery and the APIs are fine without it.
- **Don't close the app window** on a Wine-hosted build — it hides to a system
  tray that doesn't exist under Wine on Wayland and cannot be recovered. Use
  `tiiny-native.sh restart`. (Less relevant on the native build, but the habit
  is cheap.)

## When it doesn't work

[`troubleshooting.md`](troubleshooting.md) is ordered by what actually goes
wrong. The two that catch everyone:

- **everything 502s** → the device booted with `/data` locked. `tiiny-unlock.sh`.
  There is no user-facing cue and it looks like a dead device.
- **bare `fetch failed`** → DNS, nearly always. The client logs the same string
  for "cannot resolve", "device off" and "connection refused".
