#!/usr/bin/env bash
# Run the Tiiny PC Service (pcsvr.exe) under the PATCHED Wine.
#
# pcsvr is a Go binary. Go calls WSAIoctl(SIO_UDP_NETRESET) on every UDP socket
# and treats failure as fatal; stock Wine (incl. 11.14) and Proton do not
# implement that ioctl, so net.ListenUDP always fails with WSAEOPNOTSUPP
# (10045) -- no device discovery, no DNS server. wine-sio-udp-netreset.patch
# adds it; ~/.local/opt/wine-patched is a copy of /opt/wine-devel with the
# rebuilt ws2_32.dll. With it, pcsvr discovers the Tiiny Pocket normally.
#
# Config differs from the vendor default, deliberately:
#   Host/WebUI  0.0.0.0 -> 127.0.0.1  (vendor binds every interface)
#   WireGuard   disabled  (needs the Wintun kernel driver; impossible on Wine)
#   ConnectPage disabled  (wants ports 80/443; needs root -- see README)
#   AutoConfigureResolver off (cannot rewrite the Linux resolver from Wine)
set -uo pipefail

export WINEPREFIX="${WINEPREFIX:-$HOME/.local/share/wineprefixes/tiinyos}"
export WINEDEBUG="${WINEDEBUG:--all}"

WINE="${WINE:-$HOME/.local/opt/wine-patched/bin/wine}"
if [ ! -x "$WINE" ]; then
  echo "patched wine not found at $WINE" >&2
  echo "pcsvr WILL NOT discover devices under stock wine (SIO_UDP_NETRESET)" >&2
  WINE=wine
fi

# Resolve the device's CURRENT ip into DNS DefaultIPv4 (see the script for why
# we point *.tiiny.local at the device rather than binding local port 80).
# Non-fatal: pcsvr still serves /devices_list without it.
if [ -x "$(dirname "$0")/resolve-device-ip.py" ]; then
  "$(dirname "$0")/resolve-device-ip.py" || echo "(device not found; DNS may be stale)" >&2
fi

D="${PCSVR_DIR:-$HOME/.local/share/tiiny-pcsvr}"
[ -f "$D/pcsvr.exe" ] || { echo "pcsvr.exe not found in $D" >&2; exit 1; }
cd "$D" || exit 1   # it resolves etc/pcsvr-api.yaml and logs/ relative to cwd

exec "$WINE" "$D/pcsvr.exe" >/dev/null 2>&1 </dev/null
