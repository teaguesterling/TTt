#!/usr/bin/env bash
# Native-linux launcher for TiinyOS 0.9.6, repackaged onto Electron 37.4.0.
# Same recipe as the 0.9.0 port: identical Electron version, identical native-
# module set, identical sharp pins (0.34.5 / libvips 1.2.4) and unpack scope.
# Assembled by the linux-native-build smoke test; mirrors run-tiinyos.sh's
# flags/networking approach but targets the native linux-x64 Electron binary
# instead of Wine.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELECTRON="$HERE/tiinyos-linux/tiinyos"
LOG="${TIINY_LOG:-$HERE/tiinyos-linux.log}"

[ -x "$ELECTRON" ] || { echo "electron binary not found at $ELECTRON" >&2; exit 1; }

# ============================================================================
# DNS SHIMS — RETIRED 2026-08-16, kept behind TIINY_DNS_SHIM=1
# ============================================================================
# *.tiiny is now REAL DNS: the bridge host's dnsmasq answers
# `address=/tiiny/10.0.0.2` and its Caddy proxies to the device over the USB
# /30 (172.20.19.89). Verified from the workstation with no shim of any kind:
# all *.tiiny names resolve and http://wifi.api.tiiny/... returns 200.
#
# Why retire them rather than keep them:
#   - The renderer rules were BAKED AT LAUNCH, so a device DHCP change stranded
#     the renderer until a full app restart (the device's WiFi address is
#     DHCP-assigned and drifts).
#   - Any launch path that missed this script got NO device DNS at all and every
#     request failed as a bare "fetch failed" — which is exactly what the 0.9.6
#     installer's autostart entry did on 2026-08-16, costing an hour.
#   Real DNS makes both of those structurally impossible.
#
# TO BRING THEM BACK — one variable, e.g. the bridge host is down or you're
# running off-LAN:
#   TIINY_DNS_SHIM=1 ./run-tiinyos-linux.sh
# ============================================================================
TIINY_DNS_SHIM="${TIINY_DNS_SHIM:-0}"

NSS_HOSTS="$HOME/.local/share/tiiny-pcsvr/hosts"

if [ "$TIINY_DNS_SHIM" = "1" ]; then
  # --- Main-process DNS (Node/libuv -> glibc getaddrinfo) ---
  # nss_wrapper per-process LD_PRELOAD, sourced from the same hosts file
  # resolve-device-ip.py maintains. Generic glibc NSS shimming, not Wine-specific.
  NSSW=/usr/lib/x86_64-linux-gnu/libnss_wrapper.so
  if [ -f "$NSSW" ] && [ -f "$NSS_HOSTS" ]; then
    export LD_PRELOAD="$NSSW${LD_PRELOAD:+:$LD_PRELOAD}"
    export NSS_WRAPPER_HOSTS="$NSS_HOSTS"
  fi
fi

# --- Renderer DNS (Chromium's own async resolver, does NOT go through glibc) ---
# Same *.tiiny / *.tiiny.local NAMES list as resolve-device-ip.py, mapped to
# the same IP as the current hosts file, via Chromium's --host-resolver-rules
# switch (applied ahead of any resolver backend, works for .tiiny/.local both).
# Pick live device IP(s) at launch: USB preferred, WiFi fallback, BOTH tracked
# (nss_wrapper returns both A records -> main process fails over automatically).
if [ "$TIINY_DNS_SHIM" = "1" ]; then
  # This script lives INSIDE the build tree, so the helper is normally one level
  # up in TIINY_HOME. Also look in a TTt checkout, which is where it is now
  # maintained, so a build tree assembled anywhere still finds it.
  PICK=""
  for _c in "$HERE/../pick-device-ip.sh" \
            "${TIINY_TTT:-$HOME/tiiny-tools}/bin/pick-device-ip.sh" \
            "$HOME/tiiny-tools/pick-device-ip.sh"; do
    [ -x "$_c" ] && { PICK="$_c"; break; }
  done
  [ -n "$PICK" ] && "$PICK" >/dev/null 2>&1 || true
  DEVICE_IP="$(awk '/auth\.api\.tiiny\.local/{print $1; exit}' "$NSS_HOSTS" 2>/dev/null)"
else
  DEVICE_IP=""   # retired: the renderer uses real DNS like everything else
fi
# 0.9.6 moved the connect URL to the BARE host (auth.api.tiiny); the .local
# form still appears once in the bundle, so map BOTH rather than swapping.
NAMES="auth.api.tiiny auth.api.tiiny.local api.tiiny.local api.tiiny agent.tiiny ai.tiiny mcp.main.tiiny agent-services.api.tiiny anthropic.api.tiiny chat-history.api.tiiny connector.api.tiiny hardware-upgrade.api.tiiny kb.api.tiiny ollama.api.tiiny openai.api.tiiny p8800.api.tiiny tts.api.tiiny wifi.api.tiiny"
# If TIINY_AGENT_PROXY_PORT is set, route ONLY agent-services.api.tiiny through the
# local catalog-rewrite proxy (so linux-runnable agents pass the store's OS filter);
# everything else still resolves straight to the device.
HRR=""
if [ -n "$DEVICE_IP" ]; then
  # LEGACY (TIINY_DNS_SHIM=1): map every name straight at the device.
  for n in $NAMES; do
    if [ -n "${TIINY_AGENT_PROXY_PORT:-}" ] && [ "$n" = "agent-services.api.tiiny" ]; then
      HRR="${HRR}MAP $n 127.0.0.1:${TIINY_AGENT_PROXY_PORT},"
    else
      HRR="${HRR}MAP $n $DEVICE_IP,"
    fi
  done
  HRR="${HRR%,}"
elif [ -n "${TIINY_AGENT_PROXY_PORT:-}" ]; then
  # RETIRED PATH. Real DNS resolves every *.tiiny name via the bridge host, so no device
  # mappings are needed — but the agent-catalog proxy is NOT a DNS shim and must
  # survive the retirement. It deliberately INTERCEPTS one name to rewrite the
  # store's OS filter so linux-runnable agents (OpenCode, Hermes) appear.
  # Retiring the resolver rules wholesale would have silently disabled it.
  HRR="MAP agent-services.api.tiiny 127.0.0.1:${TIINY_AGENT_PROXY_PORT}"
fi

ARGS=(--no-sandbox --disable-gpu)
[ -n "$HRR" ] && ARGS+=(--host-resolver-rules="$HRR")

exec "$ELECTRON" "${ARGS[@]}" "$@" >>"$LOG" 2>&1 </dev/null
