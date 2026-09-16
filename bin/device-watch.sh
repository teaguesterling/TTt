#!/usr/bin/env bash
# device-watch.sh — watch the Tiiny device AND the path clients take to reach it.
#
# Logs STATE TRANSITIONS (not every probe) so the log stays readable over hours.
#
# "I can't connect to the Tiiny" has at least three independent causes, and they
# look identical from the app (a bare "fetch failed"). This tells them apart:
#
#   DEVICE — is the device itself answering, probed at its own address?
#   PATH   — does the name clients actually dial (api.tiiny) resolve, and does
#            that address answer? On a host reached through a bridge host this
#            is dnsmasq + Caddy + the USB link, none of which the device knows
#            about. DEVICE up + PATH down = the bridge broke, not the device.
#   APP    — is the TiinyOS process still alive? (Skipped on headless hosts.)
#
# Runs on both roles:
#   the workstation (desktop) — all three dimensions
#   the bridge host (headless, always-on) — DEVICE + PATH; APP reports n/a
#                             rather than a permanent false "gone"
#
# Observe-only: it never restarts anything. Stop with:
#   kill $(cat <this dir>/device-watch.pid)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOSTS="$HOME/.local/share/tiiny-pcsvr/hosts"       # pcsvr's file; absent off the workstation
LOG="$HERE/device-watch.log"
PIDFILE="$HERE/device-watch.pid"
INTERVAL="${DEVICE_WATCH_INTERVAL:-15}"
HEARTBEAT_SECS="${DEVICE_WATCH_HEARTBEAT:-1800}"   # periodic "still fine" line
PATH_NAME="${DEVICE_WATCH_NAME:-api.tiiny}"        # the name clients dial

echo $$ > "$PIDFILE"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }

up()      { timeout 2 bash -c "exec 3<>/dev/tcp/$1/80" 2>/dev/null; }
dns_ip()  { getent hosts "$PATH_NAME" 2>/dev/null | awk '{print $1; exit}'; }
hosts_ip(){ awk '/tiiny/{print $1; exit}' "$HOSTS" 2>/dev/null; }

# The device's OWN address, deliberately NOT the bridge's. Explicit override
# first, then pcsvr's pin, then discovery. We do not fall back to the api.tiiny
# name here: on a bridged host that name resolves to the bridge host, and
# probing the bridge host would report the device as "up" whenever the bridge
# is up, which is the exact conflation this script exists to break.
device_ip() {
  if [ -n "${TIINY_IP:-}" ]; then printf '%s' "$TIINY_IP"; return; fi
  local h; h="$(hosts_ip)"
  if [ -n "$h" ]; then printf '%s' "$h"; return; fi
  "$HERE/pick-device-ip.sh" 2>/dev/null | tail -1
}

app_pid() { pgrep -f 'tiinyos-linux/tiinyos --no-sandbox' 2>/dev/null | head -1; }

# LEGACY, shim mode only: with TIINY_DNS_SHIM=1 the app bakes
# --host-resolver-rules at LAUNCH, so a DHCP change strands the renderer until
# the app is restarted. With the shims retired (the default since 2026-08-16)
# the app follows real DNS and there is no baked address to go stale, so this
# returns empty and the drift check below is correctly skipped rather than
# silently reporting "no drift" because it had nothing to compare.
app_ip() {
  local p="$1" cl
  [ -n "$p" ] || return 1
  cl=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || return 1
  printf '%s' "$cl" | grep -oP 'MAP auth\.api\.tiiny \K[0-9.]+' | head -1
}

# Is a desktop app even expected here? Checked once: on a headless host a
# permanent "APP gone" is noise that trains you to ignore the log.
#
# Two ways to answer yes: the app is running right now, or a native Electron
# build tree exists on this host. Point TIINY_NATIVE_BUILD at that tree (the
# same variable launcher/build-native-linux.sh and tiiny-native.sh use) if
# yours lives somewhere other than the default below.
APP_EXPECTED=no
[ -n "$(app_pid)" ] && APP_EXPECTED=yes
[ -d "${TIINY_NATIVE_BUILD:-$HOME/tiiny-tools/linux-native-build-0.9.6}" ] && APP_EXPECTED=yes

prev_dev=""; prev_path=""; prev_app=""; prev_drift=""; last_hb=0
say "watch: started (interval ${INTERVAL}s, pid $$, name $PATH_NAME, app_expected=$APP_EXPECTED)"

while :; do
  ip="$(device_ip)"
  pid="$(app_pid)"
  aip="$(app_ip "$pid" 2>/dev/null)"

  # --- DEVICE: the hardware itself ---
  if [ -n "$ip" ] && up "$ip"; then
    dev="up"; dev_ip="$ip"
  else
    dev="down"; dev_ip="$ip"
    found="$("$HERE/pick-device-ip.sh" 2>/dev/null | tail -1)"
    if [ -n "$found" ] && [ "$found" != "$ip" ]; then
      dev="moved"; dev_ip="$found"
    elif [ -n "$found" ]; then
      dev="up"; dev_ip="$found"      # transient blip, same address
    fi
  fi

  # --- PATH: the route clients actually take ---
  pip="$(dns_ip)"
  if   [ -z "$pip" ];   then pth="unresolved"
  elif up "$pip";       then pth="up"
  else                       pth="down"
  fi

  # --- APP ---
  if   [ "$APP_EXPECTED" = "no" ]; then app="n/a"
  elif [ -n "$pid" ];              then app="alive"
  else                                  app="gone"
  fi

  # --- DRIFT: shim mode only (see app_ip) ---
  if [ -n "$aip" ] && [ -n "$dev_ip" ] && [ "$aip" != "$dev_ip" ]; then
    drift="yes"
  elif [ -n "$aip" ]; then
    drift="no"
  else
    drift="n/a"
  fi

  # --- report transitions only ---
  if [ "$dev" != "$prev_dev" ]; then
    case "$dev" in
      up)    say "DEVICE up      @ $dev_ip" ;;
      down)  say "DEVICE DOWN    @ ${dev_ip:-?} (no TCP :80; rediscovery found nothing)" ;;
      moved) say "DEVICE MOVED   $ip -> $dev_ip (re-pinned by pick-device-ip)" ;;
    esac
    prev_dev="$dev"
  fi

  if [ "$pth" != "$prev_path" ]; then
    case "$pth" in
      up)         say "PATH up        $PATH_NAME -> $pip" ;;
      down)       say "PATH DOWN      $PATH_NAME -> $pip resolves but does not answer :80 — bridge/Caddy, not the device (DEVICE is $dev)" ;;
      unresolved) say "PATH UNRESOLVED $PATH_NAME does not resolve — DNS. Clients will report a bare 'fetch failed'" ;;
    esac
    prev_path="$pth"
  fi

  if [ "$app" != "$prev_app" ] && [ "$app" != "n/a" ]; then
    [ "$app" = "gone" ] && say "APP GONE       (no tiinyos process — window closed or crashed)" \
                        || say "APP alive      (pid $pid${aip:+, shim-dialing $aip})"
    prev_app="$app"
  fi

  if [ "$drift" != "$prev_drift" ] && [ "$drift" != "n/a" ]; then
    [ "$drift" = "yes" ] && say "DRIFT          app dials $aip but device is at $dev_ip — RESTART REQUIRED (./tiiny-native.sh restart)" \
                         || say "DRIFT cleared  app and device agree on ${dev_ip:-?}"
    prev_drift="$drift"
  fi

  now=$(date +%s)
  if [ $((now - last_hb)) -ge "$HEARTBEAT_SECS" ]; then
    say "heartbeat: device=$dev@${dev_ip:-?} path=$pth@${pip:-?} app=$app drift=$drift"
    last_hb=$now
  fi

  sleep "$INTERVAL"
done
