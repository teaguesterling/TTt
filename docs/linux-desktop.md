# Running the TiinyOS desktop app on Linux

TiinyOS ships as a Windows installer. It runs on Linux, and this is the recipe
— it has been running daily on a Linux workstation since August 2026.

![TiinyOS running natively on Linux: the dashboard with weekly token usage, and the Model Management panel listing loaded models](images/tiinyos-linux-native.jpg)

The stack ends up half native, half Wine, because the two halves have different
answers:

| piece | how it runs | why |
|---|---|---|
| **The app** (Electron) | **native linux-x64 Electron** | Wine runs it, but the prefix rots: a prefix's graphics state white-screens the renderer while the JavaScript underneath runs fine. Repackaging onto native Electron removes that whole failure class. |
| **pcsvr** (the PC Service) | **patched Wine** | It's a Windows Go binary with no Linux build — the "linux wrapper" in the bundle is an empty stub. It cannot be repackaged. |

The two talk over loopback (`127.0.0.1:60000`), so this split costs nothing at
runtime.

## What you need first

- The vendor's Windows installer, `TiinyOS-<version>-setup.exe`.
- **Wine ≥ 10.** This is a hard floor. Wine 9.0 (what Ubuntu ships) cannot
  complete an outbound TCP connect from Node, fails with `connect UNKNOWN`, and
  the app dies about six seconds in with nothing useful in the log. Verified on
  `winehq-devel` 11.14.

```bash
sudo dpkg --add-architecture i386 && sudo mkdir -pm755 /etc/apt/keyrings
sudo wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
sudo wget -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/ubuntu/dists/noble/winehq-noble.sources
sudo apt update && sudo apt install --install-recommends winehq-devel
sudo apt install winetricks libnss-wrapper
```

## 1. Patched Wine, for pcsvr only

Stock Wine cannot run pcsvr usefully. Two patches, neither Tiiny-specific —
any similar app would hit both:

| patch | without it |
|---|---|
| `wine-sio-udp-netreset` | Go ≥ 1.23 calls `WSAIoctl(SIO_UDP_NETRESET)` on every UDP socket and treats failure as fatal. Wine doesn't implement it, so pcsvr cannot open **a single UDP socket**: no device discovery, no DNS. |
| `wine-flsgetvalue2` | Edge/WebView2 imports `FlsGetValue2` (Windows 11). Without it `msedgewebview2.exe` exits 13 **silently** and no Tauri-based agent starts. |

Both patches and the build recipe are in [`../wine/README.md`](https://github.com/teaguesterling/TTt/blob/main/wine/README.md).
It builds into `~/.local/opt/wine-patched` and leaves the system Wine alone.
Budget about 1.8 GB and a long compile.

## 2. The Wine prefix

```bash
./wine/setup-wine-prefix.sh          # WINEPREFIX overridable
```

Three settings, each for a discovered reason:

- **`win10` mode** — Chromium 138 refuses to start if the prefix reports win7.
- **`vcrun2022`** — otherwise the installer downloads and runs
  `vc_redist.x64.exe` as an interactive modal. Pre-seeding the same runtime
  makes the installer detect it and skip the dialog.
- **`fakechinese`** — the app bundles no fonts and the PC Service sub-installer
  asks for SimSun / Microsoft YaHei; without aliases its wizard is tofu boxes.

## 3. Install the vendor package, keep pcsvr

Run the vendor `.exe` under the patched Wine in that prefix. What you need
afterwards is `pcsvr.exe` and its support files; the Windows app itself is
replaced in the next step.

Start pcsvr once and let it pair with the device. It writes
`~/.local/share/tiiny-pcsvr/auth_data/<serial>.json`, which holds the device
token every other tool reads.

## 4. Build the native Electron tree

```bash
./launcher/build-native-linux.sh                 # auto-detects the Wine install
./launcher/build-native-linux.sh --target DIR --src WINE_INSTALL --force
```

It fetches Electron **37.4.0** (must match the app's own version), copies the
app payload out of the Wine install, installs the one native module that needs
a Linux build, renames the binary, drops the launcher into the tree and
verifies the result. It is idempotent: re-run it to check or repair a tree.

Three things it handles that each cost hours by hand:

- **Only `sharp` needs a Linux binary.** The app's other native modules
  (`@napi-rs/system-ocr`, `registry-js`, `selection-hook`) already self-guard on
  Linux and return benign values. Pin the app's own `sharp@0.34.5`, never npm
  latest.
- **Install the *main* `sharp` package, not just `@img/sharp-linux-x64`.** The
  platform sub-package omits `@img/colour`, which sharp 0.34.x needs at runtime
  and does not declare. Installing only the platform binary yields a tree that
  looks complete and fails the first time sharp is used.
- **Rename the Electron binary** (`cp electron tiinyos`). `app.isPackaged` keys
  off the executable name; a bare `electron` takes the dev branch and every
  window dies with `ERR_FILE_NOT_FOUND`.

If you'd rather not use the script: unpack `app.asar` and point the native
Electron binary at the extracted directory. Node then resolves modules off the
filesystem, so the only fix needed is dropping the Linux `sharp` into
`node_modules/@img/`.

## 5. Name resolution

The app talks to the device over a fake `.tiiny` TLD (`api.tiiny`,
`auth.api.tiiny`, and a dozen more). Two ways to make those resolve:

- **Real DNS (recommended).** Point `*.tiiny` at the device — one dnsmasq line,
  `address=/tiiny/<address>`, matches every name at any depth. Survives the app
  being launched by something other than your launcher.
- **Per-process shims.** `TIINY_DNS_SHIM=1` restores `nss_wrapper` for the main
  process and Chromium `--host-resolver-rules` for the renderer. Two known
  weaknesses: anything that launches the app directly gets no device DNS at all
  (the installer's own autostart entry does exactly this, and every request then
  fails as a bare `fetch failed`), and the renderer's rules are fixed at launch,
  so a device address change strands the app until restart.

One resolver rule survives either way, and Linux agents disappear from the
store without it:

```
MAP agent-services.api.tiiny 127.0.0.1:60080
```

## 6. Start it

```bash
./launcher/tiiny-native.sh start     # pcsvr → agent proxy → app
./launcher/tiiny-native.sh status
```

**Order matters:** pcsvr first. The app dials it on `127.0.0.1:60000` and gets
the device token from it.

`status` also checks `~/.config/autostart/tiiny-ai.desktop` every run, because
the installer rewrites it on upgrade to point straight at the Electron binary.
If it reports `DRIFTED`, fix it — the failure mode is a perfectly healthy device
that looks dead.

## Gotchas that still apply

pcsvr still runs under Wine even though the app doesn't, so these stay live:

- **Never pipe the app's or pcsvr's stdio.** Wine's pipe handles confuse libuv
  and Electron dies at startup with `Error: open EBADF`. The launchers redirect
  to files deliberately.
- **`xwininfo` lies.** It reports windows as viewable with correct geometry
  while nothing is on screen. Confirm a plain X client is visible before
  concluding anything about Wine or the app.
- **WireGuard cannot work under Wine** (it needs the Wintun kernel driver). Run
  pcsvr with it disabled; discovery and the APIs are fine without it.
- **Don't close the app window** on a Wine-hosted build: it hides to a system
  tray that doesn't exist under Wine on Wayland, and cannot be recovered. Use
  `tiiny-native.sh restart`.

## When it doesn't work

- **Everything returns 502** → the device booted with `/data` locked. Unlock it
  (`bin/tiiny-unlock.sh`). There is no user-facing cue, and it looks like a dead
  device.
- **A bare `fetch failed`** → name resolution, nearly always. The app logs the
  same string for "cannot resolve", "device off" and "connection refused".
- **A white window** → you are on the Wine-hosted app, not the native build.
  That is the rot this whole page exists to avoid.
