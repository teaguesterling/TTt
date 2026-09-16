#!/usr/bin/env bash
# Unlock the Tiiny device's encrypted /data after a reboot / power-cycle.
#
# `ttt unlock` does the same thing and is the portable path — prefer it. This
# script stays for hosts where pcsvr keeps the key, and for scripting the
# unlock without the CLI.
#
# The device boots with /data (LUKS2, detached header) locked. Until it's
# unlocked, docker.service won't start (Requires=data-unlocked.target,
# ConditionPathIsMountPoint=/data) and the model API returns 502. This drives
# the same unlock the TiinyOS app uses:
#
#   POST /api/v1/account/unlock_with_auth_key  {auth_key}   -> data_state: unlocking
#   then poll /api/v1/connect until data_state == unlocked
#
# NOTE: unlock succeeds with the AUTH KEY ALONE — the main/decryption password
# is not required by this endpoint. Worth knowing when deciding where that key
# may be stored. If a password becomes required, set TIINY_MAIN_PASSWORD in the
# environment (never pass it as an argument) and this falls back to
# check_main_password first.
#
# Addressing: TIINY_IP forces a direct connection; otherwise the auth vhost
# (auth.api.tiiny) is used, which rides the bridge like everything else.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AUTH_DIR="${TIINY_AUTH_DIR:-$HOME/.local/share/tiiny-pcsvr/auth_data}"

if [ -n "${TIINY_IP:-}" ]; then
  BASE="http://$TIINY_IP/api/v1"
  H=(-H "Host: ${TIINY_AUTH_HOST:-auth.api.tiiny}")
else
  BASE="http://${TIINY_AUTH_HOST:-auth.api.tiiny}/api/v1"
  H=()
fi

# Key: the environment first, so this runs on hosts with no pcsvr; pcsvr's
# auth_data is the fallback, not the requirement.
KEY="${TIINY_AUTH_KEY:-}"
if [ -z "$KEY" ]; then
  KEY_JSON="$(ls -1 "$AUTH_DIR"/*.json 2>/dev/null | head -1 || true)"
  if [ -n "$KEY_JSON" ]; then
    KEY=$(python3 -c "
import json,sys
try: print(json.load(open(sys.argv[1]))['auth_key'])
except Exception: print('')" "$KEY_JSON" 2>/dev/null)
  fi
fi
if [ -z "$KEY" ]; then
  echo "no device token: set TIINY_AUTH_KEY, or run where pcsvr writes $AUTH_DIR" >&2
  exit 1
fi

# data_state needs no token, so it answers even when the key is wrong.
state() {
  timeout 8 curl -sS "${H[@]}" -X POST -H 'Content-Type: application/json' \
    -d '{"auth_key":""}' "$BASE/connect" 2>/dev/null \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("data_state","?"))
except Exception: print("?")' 2>/dev/null
}

cur=$(state)
echo "device data_state: $cur"
[ "$cur" = "unlocked" ] && { echo "already unlocked."; exit 0; }

# Optional password pre-check, only if one is provided via env (never an arg).
if [ -n "${TIINY_MAIN_PASSWORD:-}" ]; then
  echo "verifying main password…"
  timeout 15 curl -sS "${H[@]}" -X POST -H 'Content-Type: application/json' \
    -d "{\"main_password\":\"$TIINY_MAIN_PASSWORD\"}" \
    "$BASE/account/check_main_password" >/dev/null 2>&1 || true
fi

echo "requesting unlock…"
resp=$(timeout 40 curl -sS "${H[@]}" -X POST -H 'Content-Type: application/json' \
  -d "{\"auth_key\":\"$KEY\"}" "$BASE/account/unlock_with_auth_key" 2>/dev/null)
echo "  $(echo "$resp" | python3 -c 'import json,sys
try: d=json.load(sys.stdin); print("status:",d.get("status"),"data_state:",d.get("data_state"))
except Exception: print(sys.stdin.read()[:120])' 2>/dev/null)"

# data_state flips before the backend is ready, so wait on the model API too.
MODELS="${TIINY_IP:+http://$TIINY_IP/v1/models}"
MODELS="${MODELS:-http://${TIINY_HOST:-api.tiiny}/v1/models}"
echo "waiting for /data to mount and the backend to come up…"
for i in $(seq 1 45); do
  s=$(state)
  code=$(timeout 8 curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $KEY" "$MODELS" 2>/dev/null)
  if [ "$s" = "unlocked" ] && [ "$code" = "200" ]; then
    echo "  unlocked — model API ready (t+$((i*6))s)"; exit 0
  fi
  [ $((i % 3)) -eq 0 ] && echo "  t+$((i*6))s: data_state=$s model_api=$code"
  sleep 6
done
echo "unlock reported but the backend was not ready after ~4½ min — check 'ttt status'" >&2
exit 1
