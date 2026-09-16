# launcher — running TiinyOS natively on Linux

The desktop stack. Captured here because it is the hardest part of this project
to reconstruct, not because every host needs it — **the bridge host doesn't run
any of this** (it's headless and only needs the tools in [`../bin`](../bin)).

For the full step-by-step recipe (Wine setup, assembling the build, running
it), see [`../docs/linux-desktop.md`](../docs/linux-desktop.md); this page
documents the launcher scripts themselves.

TiinyOS ships Windows-only. Running it on Linux means two separate tricks:

- the **app** is repackaged onto a native linux-x64 Electron runtime, escaping
  Wine's prefix-rot white-screen entirely
- **pcsvr** cannot be repackaged — it's a Windows Go binary with no Linux build
  and an empty stub where the "Linux wrapper" should be — so it stays under a
  **patched** Wine (see [`../wine`](../wine))

So the stack is half-native, half-Wine, and the two halves talk over loopback.

## The five pieces

| file | what it does |
|---|---|
| `build-native-linux.sh` | **builds the tree** from the Wine install — run this first |
| `tiiny-native.sh` | the orchestrator: `start` / `stop` / `restart` / `status` |
| `run-pcsvr.sh` | pcsvr under patched Wine on `127.0.0.1:60000` |
| `run-tiinyos-linux.sh` | launches the native Electron app; **lives inside the build tree** |
| `agent-catalog-proxy.py` | rewrites the store's OS filter so Linux agents appear |

Start order matters: **pcsvr first**. It's the PC Service the app dials on
`127.0.0.1:60000`, and it owns the device auth token. `tiiny-native.sh start`
sequences this for you.

## What is NOT here, and why

**The assembled Electron build tree** (`linux-native-build-0.9.6/`) — ~200 MB of
binaries. It's built, not authored. `run-tiinyos-linux.sh` is the one file in
that tree worth versioning, so it's kept here as the canonical copy and
**installed into** the tree, which is also why it self-roots via
`dirname "$BASH_SOURCE"` rather than taking a path.

**The Wine prefix** — machine state, rebuilt from [`../wine`](../wine).

## Assembling the build tree

```bash
./build-native-linux.sh                  # auto-detects the Wine install
./build-native-linux.sh --target DIR --src WINE_INSTALL --force
```

Fetches Electron 37.4.0, copies the app payload out of the Wine install,
installs the Linux `sharp`, renames the binary, drops this launcher in the tree
root, and verifies ten results. Idempotent — safe to re-run against an existing
tree to check or repair it.

Three non-obvious things it handles, each of which cost hours by hand:

- **Only `sharp` needs a Linux binary.** `@napi-rs/system-ocr`, `registry-js`
  and `selection-hook` already self-guard on Linux.
- **The *main* `sharp` package, not just `@img/sharp-linux-x64`.** The platform
  sub-package omits `@img/colour`, which sharp 0.34.x needs at runtime and does
  not declare. `@img/colour` is pinned as well — npm drifts it otherwise.
- **`cp electron tiinyos`.** `app.isPackaged` keys off the executable name; a
  bare `electron` takes the dev branch and every window dies with
  `ERR_FILE_NOT_FOUND`.

Overridable: `ELECTRON_VER`, `SHARP_VER`, `COLOUR_VER`, `TIINY_NATIVE_BUILD`.

## Paths

These default to a single checkout at `~/tiiny-tools`; override any of them to
match your own layout.

| env | default | |
|---|---|---|
| `TIINY_HOME` | `~/tiiny-tools` | where `run-pcsvr.sh` and the build tree live |
| `TIINY_NATIVE_BUILD` | `$TIINY_HOME/linux-native-build-0.9.6` | assembled Electron tree |
| `TIINY_TTT` | `~/tiiny-tools` | this checkout, for helper lookup |
| `TIINY_AGENT_PROXY_PORT` | `60080` | agent-catalog proxy |
| `TIINY_LINUX_APPS` | `opencode,Hermes Agent` | agents to unhide |
| `TIINY_DNS_SHIM` | `0` | see below |

`tiiny-native.sh` looks for helpers next to itself first, then in `../bin`,
then under `TIINY_HOME`.

## `TIINY_DNS_SHIM` — retired, kept

The app used to get `*.tiiny` resolution only from its launcher, via
`nss_wrapper` (`LD_PRELOAD`) plus Chromium's `--host-resolver-rules`. That broke
in two ways:

- any launch path that bypassed the launcher got **no device DNS at all** — the
  0.9.6 installer's autostart entry pointed `Exec=` straight at the Electron
  binary, and every request failed as a bare `fetch failed` while the device was
  perfectly healthy
- the renderer's rules were baked at **launch**, so a DHCP change stranded the
  app until it was restarted

Real DNS (a dnsmasq entry on the bridge host) makes both impossible, so the
shims are off by default. `TIINY_DNS_SHIM=1` restores the old behaviour, which
is worth keeping for a host with no route to the bridge host.

**The one rule that survives the shims** is the agent-proxy mapping — with
shims off, `--host-resolver-rules` still carries exactly:

```
MAP agent-services.api.tiiny 127.0.0.1:60080
```

If that disappears, Linux agents vanish from the store again.

## Autostart

`tiiny-native.sh status` checks `~/.config/autostart/tiiny-ai.desktop` on every
run, because **the installer rewrites it on upgrade**. It accepts an `Exec=`
pointing at either this copy or the legacy `TIINY_HOME` one. If it reports
`DRIFTED`, it prints the exact `sed` to fix it — do fix it, since the failure
mode is a healthy device that looks dead.
