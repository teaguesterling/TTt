#!/usr/bin/env bash
# pick-device-ip.sh — choose the LIVE Tiiny device IP and write the pcsvr hosts
# file so launchers (nss_wrapper + Chromium --host-resolver-rules) target it.
#
# Preference order (as of 2026-08-15):
#   1. USB link  172.20.19.89  — fixed /30, low-latency, does NOT roam. Preferred.
#   2. WiFi      (TIINY_IP if you set it, else UDP discovery) — fallback.
#
# Rationale: we pin to USB for stability while it's plugged, but USB de-enumerates
# when unplugged/suspended and the app then dials a dead address. This probes what
# is actually reachable at launch instead of trusting whatever discovery last wrote.
#
# Echoes the chosen IP on stdout; logs the choice on stderr. Exit 1 if neither is up.
set -uo pipefail

USB_IP="172.20.19.89"
HOSTS="$HOME/.local/share/tiiny-pcsvr/hosts"
PCSVR_YAML="$HOME/.local/share/tiiny-pcsvr/etc/pcsvr-api.yaml"
HERE="$(cd "$(dirname "$0")" && pwd)"
NAMES="auth.api.tiiny auth.api.tiiny.local api.tiiny.local api.tiiny agent.tiiny ai.tiiny mcp.main.tiiny agent-services.api.tiiny anthropic.api.tiiny chat-history.api.tiiny connector.api.tiiny hardware-upgrade.api.tiiny kb.api.tiiny ollama.api.tiiny openai.api.tiiny p8800.api.tiiny tts.api.tiiny wifi.api.tiiny"

# quick TCP reachability check on the device HTTP port (:80), 2s budget
up() { timeout 2 bash -c "exec 3<>/dev/tcp/$1/80" 2>/dev/null; }

wifi_ip() {
  # 1) an address you set explicitly (authoritative, no discovery needed)
  local w="${TIINY_IP:-}"
  if [ -n "$w" ] && up "$w"; then echo "$w"; return 0; fi
  # 2) fall back to UDP discovery (writes the hosts file as a side effect)
  [ -x "$HERE/resolve-device-ip.py" ] && "$HERE/resolve-device-ip.py" >/dev/null 2>&1 || true
  local d; d=$(awk '/tiiny/{print $1; exit}' "$HOSTS" 2>/dev/null)
  if [ -n "$d" ] && [ "$d" != "$USB_IP" ] && up "$d"; then echo "$d"; return 0; fi
  return 1
}

# Collect ALL reachable device IPs, USB first (preference), so the app's main
# process gets both A records and fails over automatically ("track both").
IPS=()
up "$USB_IP" && IPS+=("$USB_IP")
WIFI="$(wifi_ip || true)"
[ -n "$WIFI" ] && [ "$WIFI" != "$USB_IP" ] && IPS+=("$WIFI")

if [ "${#IPS[@]}" -eq 0 ]; then
  echo "pick-device-ip: device not reachable on USB ($USB_IP) or WiFi" >&2
  exit 1
fi
IP="${IPS[0]}"                 # primary (first reachable) — for renderer HRR
[ "$IP" = "$USB_IP" ] && SRC="USB(+$(( ${#IPS[@]} - 1 )) more)" || SRC="WiFi"

# write the hosts file atomically: one A record per (IP, name), USB first.
tmp="$(mktemp)"
{ echo "127.0.0.1 localhost"; for ip in "${IPS[@]}"; do echo "$ip $NAMES"; done; } > "$tmp"
mv "$tmp" "$HOSTS"

# keep pcsvr's DNS DefaultIPv4 in sync (best-effort; harmless if absent)
[ -f "$PCSVR_YAML" ] && sed -i -E "s/^([[:space:]]*DefaultIPv4:[[:space:]]*).*/\1$IP/" "$PCSVR_YAML" 2>/dev/null || true

echo "pick-device-ip: device @ $IP ($SRC) -> $HOSTS" >&2
echo "$IP"
