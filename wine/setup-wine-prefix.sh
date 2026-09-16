#!/usr/bin/env bash
# Wine prefix for TiinyOS 0.9.0 (Electron 37.4.0 / Chromium 138 / Node 22)
#
# REQUIRES WINE >= 10. Verified on winehq-devel 11.14 (Ubuntu's wine 9.0 is
# NOT sufficient -- its Node/libuv sockets cannot complete an outbound TCP
# connect, so TiinyOS exits code 3 after ~6s. See run-tiinyos.sh for evidence.)
#
#   sudo dpkg --add-architecture i386 && sudo mkdir -pm755 /etc/apt/keyrings
#   sudo wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
#   sudo wget -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/ubuntu/dists/noble/winehq-noble.sources
#   sudo apt update && sudo apt install --install-recommends winehq-devel
#
# KNOWN LIMITATION: the Tiiny PC Service (pcsvr.exe, Go) cannot discover devices
# under any Wine version. Go >=1.23 calls WSAIoctl(SIO_UDP_NETRESET) on every
# UDP socket and treats failure as fatal; Wine 11.14 does not implement that
# ioctl ("unimplemented ioctl _WSAIOW(IOC_VENDOR, 15)" = 0x9800000F), so
# net.ListenUDP always fails with WSAEOPNOTSUPP (10045).
set -euo pipefail

export WINEPREFIX="${WINEPREFIX:-$HOME/.local/share/wineprefixes/tiinyos}"
export WINEARCH=win64                        # payload is x64-only
export WINEDLLOVERRIDES="mscoree,mshtml="    # skip Mono/Gecko install prompts
export WINEDEBUG="${WINEDEBUG:--all}"

echo "==> Creating prefix at $WINEPREFIX"
mkdir -p "$(dirname "$WINEPREFIX")"
wineboot --init

# Chromium 138 refuses to start when the prefix reports win7.
echo "==> Setting Windows 10 mode"
winetricks -q win10

# The NSIS installer downloads and runs vc_redist.x64.exe (14.44.35211) via
# INetC.dll. That works under Wine, but it is an interactive modal. Pre-seeding
# the identical runtime set makes Burn detect it as present and skip the dialog.
echo "==> Installing VC++ 2015-2022 runtime"
winetricks -q vcrun2022

# TiinyOS bundles NO fonts. The Tiiny PC Service sub-installer requests SimSun /
# Microsoft YaHei -- stock Windows fonts Wine cannot ship. Without aliases its
# wizard renders as tofu boxes.
echo "==> Installing CJK font aliases"
winetricks -q fakechinese

echo
echo "==> Done. Prefix ready at $WINEPREFIX"
