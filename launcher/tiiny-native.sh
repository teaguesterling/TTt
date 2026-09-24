#!/usr/bin/env bash
# Native-Linux TiinyOS stack launcher.
# Runs the NATIVE linux-x64 Electron build of TiinyOS (no Wine app),
# reusing the patched-Wine pcsvr on 127.0.0.1:60000. Mirrors tiiny.sh's
# start/stop/restart/status contract so the .desktop launcher can call it.
set -uo pipefail

# --- layout ---------------------------------------------------------------
# This script is the canonical copy in TTt, but the things it drives cannot all
# live here: the Electron build tree is ~200 MB of binaries, and the Wine
# prefix is machine state. So paths are overridable and default to a single
# checkout at ~/tiiny-tools.
#
#   TIINY_HOME          where run-pcsvr.sh and the build tree live
#   TIINY_NATIVE_BUILD  the assembled linux-x64 Electron tree (see launcher/README)
#
# SELF is this script's own directory, so the helpers TTt *does* ship
# (agent-catalog-proxy.py, pick-device-ip.sh) are found next to it, falling
# back to TIINY_HOME only if this script is being run outside its own checkout.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERE="${TIINY_HOME:-$HOME/tiiny-tools}"
NB="${TIINY_NATIVE_BUILD:-$HERE/linux-native-build-1.0.1}"
NATIVE="$NB/run-tiinyos-linux.sh"

# Prefer a sibling copy, fall back to TIINY_HOME.
pick_file(){ for c in "$SELF/$1" "$SELF/../bin/$1" "$HERE/$1"; do [ -f "$c" ] && { printf '%s' "$c"; return; }; done; printf '%s' "$HERE/$1"; }
PCSVR_WINEPREFIX="$HOME/.local/share/wineprefixes/tiinyos-new"

# --- device DNS: WiFi/LAN is the DEFAULT; USB bridge is only the fallback ---
HOSTS_FILE="$HOME/.local/share/tiiny-pcsvr/hosts"
WIFI_STATE="$HOME/.local/share/tiiny-pcsvr/wifi-ip"   # last-known device WiFi IP

# --- agent-catalog proxy: makes linux-runnable agents (OpenCode, Hermes) pass the store OS filter ---
AGENT_PROXY_PORT="${TIINY_AGENT_PROXY_PORT:-60080}"
AGENT_PROXY="$(pick_file agent-catalog-proxy.py)"
AGENT_PROXY_APPS="${TIINY_LINUX_APPS:-opencode,Hermes Agent}"
export TIINY_AGENT_PROXY_PORT="$AGENT_PROXY_PORT"   # run-tiinyos-linux.sh routes agent-services via this
TIINY_NAMES="auth.api.tiiny.local api.tiiny.local api.tiiny agent.tiiny ai.tiiny mcp.main.tiiny agent-services.api.tiiny anthropic.api.tiiny chat-history.api.tiiny connector.api.tiiny hardware-upgrade.api.tiiny kb.api.tiiny ollama.api.tiiny openai.api.tiiny p8800.api.tiiny tts.api.tiiny wifi.api.tiiny"

log(){ printf '%s\n' "$*"; }
port_up(){ timeout 2 bash -c "echo > /dev/tcp/127.0.0.1/$1" 2>/dev/null; }
hosts_ip(){ awk '/tiiny/{print $1; exit}' "$HOSTS_FILE" 2>/dev/null; }

# --- pcsvr (patched Wine) on :60000 — the native app connects to it over loopback ---
ensure_pcsvr(){
  if port_up 60000; then log "pcsvr: up (127.0.0.1:60000)"; return 0; fi
  log "pcsvr: starting (Wine)…"
  RUN_PCSVR="$(pick_file run-pcsvr.sh)"
  # run-pcsvr.sh must run with CWD = TIINY_HOME: it resolves pcsvr.exe and the
  # device-IP helper relative to the working directory, not to its own path.
  ( cd "$HERE" && WINEPREFIX="$PCSVR_WINEPREFIX" setsid nohup "$RUN_PCSVR" >/tmp/pcsvr-native-launcher.log 2>&1 & )
  for _ in $(seq 1 20); do port_up 60000 && { log "pcsvr: up"; return 0; }; sleep 1; done
  log "pcsvr: WARN not reachable on :60000 (see /tmp/pcsvr-native-launcher.log)"; return 1
}

# --- pin *.tiiny to the device's WiFi/LAN address (the permanent default) ---
# run-pcsvr.sh's resolve-device-ip.py writes the USB bridge IP; this flips it to
# WiFi on every launch so a pcsvr restart can't revert us. Falls back to USB if
# the device isn't on WiFi and no last-known WiFi IP is reachable.
device_wifi_ip(){
  local probe lan
  # ask the device (via whatever IP we can currently reach) for its WiFi address
  for probe in "$(hosts_ip)" "$(cat "$WIFI_STATE" 2>/dev/null)"; do
    [ -n "$probe" ] || continue
    lan=$(timeout 6 curl -sS -H 'Host: wifi.api.tiiny' "http://$probe/api/v1/sys/wifi/connection_status" 2>/dev/null \
      | python3 -c 'import json,sys
try:
 d=json.load(sys.stdin); print(d.get("ipv4_address","") if d.get("is_connected") else "")
except Exception: print("")' 2>/dev/null)
    [ -n "$lan" ] && { printf '%s' "$lan"; return 0; }
  done
  return 1
}
# RETIRED 2026-08-16 — see the banner in linux-native-build-1.0.1/run-tiinyos-linux.sh.
# *.tiiny is real DNS now (the bridge host's dnsmasq -> its Caddy -> device over
# USB), so rewriting a private hosts file at every launch is both unnecessary
# and actively wrong: it pinned the app to the device's DHCP WiFi address,
# which drifts and which sits behind a radio that wedged twice in one day for
# ~19 minutes.
# Re-enable the old behaviour with TIINY_DNS_SHIM=1.
prefer_wifi(){
  if [ "${TIINY_DNS_SHIM:-0}" != "1" ]; then
    log "device DNS: real DNS via the bridge host (shim retired; TIINY_DNS_SHIM=1 to restore)"
    return 0
  fi
  local lan; lan=$(device_wifi_ip)
  if [ -n "$lan" ]; then
    printf '%s' "$lan" > "$WIFI_STATE"
    { echo "127.0.0.1 localhost"; echo "$lan $TIINY_NAMES"; } > "$HOSTS_FILE"
    log "device DNS: WiFi $lan (default)"
  else
    log "device DNS: WiFi not detected; using $(hosts_ip) (USB fallback)"
  fi
}

# --- make sure the OLD Wine TiinyOS.exe app is not holding the app API port (:3000) ---
ensure_proxy(){
  if port_up "$AGENT_PROXY_PORT"; then log "agent-proxy: up (127.0.0.1:$AGENT_PROXY_PORT)"; return 0; fi
  [ -f "$AGENT_PROXY" ] || { log "agent-proxy: script missing ($AGENT_PROXY) — agents stay OS-filtered"; return 1; }
  PROXY_PORT="$AGENT_PROXY_PORT" PROXY_LINUX_APPS="$AGENT_PROXY_APPS" \
    setsid nohup python3 "$AGENT_PROXY" >/tmp/agent-catalog-proxy.log 2>&1 &
  for _ in $(seq 1 12); do port_up "$AGENT_PROXY_PORT" && { log "agent-proxy: started (linux-enable: $AGENT_PROXY_APPS)"; return 0; }; sleep 0.5; done
  log "agent-proxy: WARN did not start (see /tmp/agent-catalog-proxy.log)"; return 1
}
stop_proxy(){
  local me=$$ n=0
  for p in $(pgrep -f 'agent-catalog-proxy\.py' 2>/dev/null); do [ "$p" = "$me" ] && continue; kill -9 "$p" 2>/dev/null && n=$((n+1)); done
  [ "$n" -gt 0 ] && log "agent-proxy: stopped $n process(es)"; return 0
}

stop_wine_app(){
  local me=$$ n=0
  for p in $(pgrep -f 'TiinyOS\.exe' 2>/dev/null); do
    [ "$p" = "$me" ] && continue
    kill -9 "$p" 2>/dev/null && n=$((n+1))
  done
  [ "$n" -gt 0 ] && log "stopped $n Wine TiinyOS.exe process(es) (freed :3000)"
  return 0
}

native_pids(){ local me=$$; for p in $(pgrep -f 'tiinyos-linux/tiinyos' 2>/dev/null); do [ "$p" = "$me" ] && continue; echo "$p"; done; }

ensure_display(){
  if [ -z "${DISPLAY:-}" ]; then
    local d
    for d in /tmp/.X11-unix/X*; do export DISPLAY=":${d##*/X}"; break; done
  fi
}

start_native(){
  if [ -n "$(native_pids)" ]; then log "TiinyOS (native): already running"; return 0; fi
  [ -x "$NATIVE" ] || { log "ERROR: $NATIVE not found/executable"; return 1; }
  ensure_display
  log "TiinyOS (native): launching (DISPLAY=${DISPLAY:-unset})…"
  ( cd "$NB" && setsid nohup "$NATIVE" >/dev/null 2>&1 & )
  for _ in $(seq 1 15); do [ -n "$(native_pids)" ] && { log "TiinyOS (native): started"; return 0; }; sleep 1; done
  log "TiinyOS (native): WARN did not appear (see $NB/tiinyos-linux.log)"; return 1
}

stop_native(){
  local n=0
  for p in $(native_pids); do kill -9 "$p" 2>/dev/null && n=$((n+1)); done
  log "TiinyOS (native): stopped $n process(es)"
}

stop_pcsvr(){
  local me=$$ n=0
  for p in $(pgrep -f 'pcsvr\.exe' 2>/dev/null); do
    [ "$p" = "$me" ] && continue
    kill -9 "$p" 2>/dev/null && n=$((n+1))
  done
  log "pcsvr: stopped $n process(es)"
}

case "${1:-start}" in
  start)   printf '\033[1mStarting TiinyOS (native) stack\033[0m\n'; ensure_pcsvr; prefer_wifi; ensure_proxy; stop_wine_app; start_native ;;
  stop)    printf '\033[1mStopping TiinyOS (native) + PC Service\033[0m\n'; stop_native; stop_proxy; stop_pcsvr ;;
  restart) printf '\033[1mRestarting TiinyOS (native) app\033[0m\n'; stop_native; sleep 2; ensure_pcsvr; prefer_wifi; ensure_proxy; stop_wine_app; start_native ;;
  status)
    printf '\033[1mTiinyOS (native) status\033[0m\n'
    port_up 60000 && log "  pcsvr   : 127.0.0.1:60000  up"   || log "  pcsvr   : down"
    # NOTE: the old ":3000 app API" check was a Wine-era leftover. The native
    # build binds NO listening TCP port at all (verified 2026-08-16: nothing on
    # 3000-3010, nothing anywhere), so that line reported "down" permanently and
    # trained us to ignore this output. Removed rather than left lying.
    port_up "$AGENT_PROXY_PORT" && log "  agent-proxy: 127.0.0.1:$AGENT_PROXY_PORT up (linux-enable: $AGENT_PROXY_APPS)" || log "  agent-proxy: down"
    # Report the path the app ACTUALLY uses. With the shims retired (the default)
    # that is real DNS, and the hosts file is irrelevant -- reporting it here said
    # "-> 10.0.0.50 (WiFi)" (the device's DHCP-assigned address) while every one
    # of the app's sockets was open to the bridge host. Only consult the hosts
    # file when the shim is what's in force.
    if [ "${TIINY_DNS_SHIM:-0}" = "1" ]; then
      log "  device  : *.tiiny -> $(hosts_ip) (nss_wrapper shim; TIINY_DNS_SHIM=1)"
    else
      _r=$(getent hosts api.tiiny 2>/dev/null | awk '{print $1; exit}')
      if [ -z "$_r" ]; then
        log "  device  : *.tiiny does NOT resolve -- app will fail with 'fetch failed'"
      else
        _n=$(ss -tn 2>/dev/null | grep -c "$_r:80")
        log "  device  : *.tiiny -> $_r (real DNS)${_n:+, $_n app conns}"
      fi
    fi
    c=$(native_pids | grep -c . 2>/dev/null || echo 0); log "  native app procs: $c"
    # Autostart drift check. On 2026-08-16 the 0.9.6 installer's autostart entry
    # pointed Exec= straight at the Electron binary instead of this script, so the
    # app launched with NO device DNS (no nss_wrapper, no --host-resolver-rules)
    # and every request failed as a bare "fetch failed" while the device was
    # perfectly healthy. Cost an hour to find. The installer may well rewrite that
    # file on the next upgrade, so check it every time we report status.
    AUTOSTART="$HOME/.config/autostart/tiiny-ai.desktop"
    if [ -f "$AUTOSTART" ]; then
      # Check against THIS script's own path, not a hardcoded one: the launcher
      # now has a canonical copy in TTt and a legacy copy in TIINY_HOME, and an
      # autostart pointing at the other one is still correct.
      _me="$SELF/$(basename "${BASH_SOURCE[0]}")"
      if grep -qE "Exec=(${_me//\//\\/}|${HERE//\//\\/}/tiiny-native\.sh)" "$AUTOSTART" 2>/dev/null; then
        log "  autostart: ok (-> tiiny-native.sh)"
      else
        log "  autostart: \033[1;31mDRIFTED\033[0m -- $AUTOSTART Exec= does not point at this script."
        log "             The app will start with NO device DNS. Fix:"
        log "             sed -i 's|^ *Exec=.*|  Exec=$_me start|' '$AUTOSTART'"
      fi
    else
      log "  autostart: absent (no login-start entry)"
    fi
    m=$(timeout 3 curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:47600/v1/models 2>/dev/null); log "  model (woollama :47600): ${m:-n/a}"
    ;;
  *) log "usage: $0 {start|stop|restart|status}"; exit 2 ;;
esac
