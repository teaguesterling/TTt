#!/usr/bin/env bash
# Start woollamad with the device bearer token in its environment.
#
# woollamad needs $TIINY_API_KEY (inferencers.toml sets api_key_env). Without
# it the daemon still starts and still listens, which is the trap: every chat
# request 400s and the residency query 401s, and on v0.13.0 the fail-open
# warning then reports "none of its configured models is loaded -- add the
# model you expect to your models list", pointing at a config that is fine.
# So the key is fetched here rather than being left to whoever starts it.
#
# Precedence matches the rest of TTt: an explicit TIINY_API_KEY wins, then
# pcsvr's auth_data. Nothing is written to disk.
set -euo pipefail

if [ -z "${TIINY_API_KEY:-}" ]; then
  AUTH_DIR="${TIINY_AUTH_DIR:-$HOME/.local/share/tiiny-pcsvr/auth_data}"
  KEY_JSON="$(ls -1 "$AUTH_DIR"/*.json 2>/dev/null | head -1 || true)"
  if [ -z "$KEY_JSON" ]; then
    echo "woollamad-run: no TIINY_API_KEY and no key file in $AUTH_DIR" >&2
    echo "  set TIINY_API_KEY, or start pcsvr so it writes auth_data/" >&2
    exit 1
  fi
  TIINY_API_KEY="$(python3 -c '
import json,sys
print(json.load(open(sys.argv[1]))["auth_key"])' "$KEY_JSON")"
fi
export TIINY_API_KEY

# Fail loudly if the key does not actually work, rather than starting a daemon
# that will answer every request with a 400. One cheap call against the
# management API the pool uses.
MGMT="${TIINY_MGMT:-http://p8800.api.tiiny/api/v1}"
code="$(curl -sSL -o /dev/null -w '%{http_code}' -m 10 \
        -H "Authorization: Bearer $TIINY_API_KEY" "$MGMT/models/running" 2>/dev/null || echo 000)"
case "$code" in
  200) : ;;
  401) echo "woollamad-run: device rejected the key (401). Refusing to start." >&2; exit 1 ;;
  000) echo "woollamad-run: device unreachable at $MGMT — starting anyway (it may come up)." >&2 ;;
  *)   echo "woollamad-run: device returned $code at $MGMT — starting anyway." >&2 ;;
esac

exec "${WOOLLAMAD_BIN:-$HOME/.cargo/bin/woollamad}" "$@"
