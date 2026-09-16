# Wine patches for pcsvr

`pcsvr` ships as a Windows binary only. It runs under Wine, and needs both of
these — neither is Tiiny-specific.

| Patch | Without it |
|---|---|
| `wine-sio-udp-netreset.patch` | Go ≥1.23 calls `WSAIoctl(SIO_UDP_NETRESET)` on every UDP socket and treats failure as fatal. Wine doesn't implement it → pcsvr cannot open a single UDP socket → no device discovery, no DNS. |
| `wine-flsgetvalue2.patch` | Edge/WebView2 151 imports `FlsGetValue2` (Windows 11) → `msedgewebview2.exe` exits 13 silently → no Tauri-based agent starts. |

## Build

Into a private tree, leaving the system Wine alone:

```bash
git clone --depth 1 --branch wine-11.14 https://gitlab.winehq.org/wine/wine.git
cd wine && git apply ../wine-sio-udp-netreset.patch ../wine-flsgetvalue2.patch
mkdir build && cd build && ../configure --enable-win64
make -j$(nproc) dlls/ws2_32/x86_64-windows/ws2_32.dll \
                dlls/kernelbase/x86_64-windows/kernelbase.dll
cp -a /opt/wine-devel ~/.local/opt/wine-patched
cp dlls/ws2_32/x86_64-windows/ws2_32.dll \
   dlls/kernelbase/x86_64-windows/kernelbase.dll \
   ~/.local/opt/wine-patched/lib/wine/x86_64-windows/
```

Launchers auto-detect `~/.local/opt/wine-patched` and fall back to system wine.

Current build on the workstation: **wine-11.14**, 1.8 GB at
`~/.local/opt/wine-patched`.

## Why this blocks moving pcsvr

Running pcsvr on another host means reproducing this build there. That is the
"confusing bit of work" — a Wine source build on an 8 GB always-on box that
serves DNS/Caddy/NFS, plus the Wine prefix-rot failure class that has already
cost real debugging time on the workstation.
