#!/usr/bin/env bash
#
# tiiny-embedder-watchdog — detect and recover a wedged Tiiny NPU inference server.
#
# THE FAILURE MODE
#   Under sustained load, the NPU model server can "wedge": every request times out
#   or hangs, while the device otherwise looks perfectly healthy — low CPU load, no
#   dmesg errors, container running, API reachable. It is hung, not busy.
#
# WHAT DOES NOT FIX IT
#   Restarting the affected model alone (stop + start of just that model) does NOT
#   reliably clear the wedge.
#
# WHAT DOES
#   Stop ALL running models — which releases the NPU — then start the target model
#   again. This watchdog automates exactly that.
#
# Runs on-device or from a host. Configure entirely via environment variables.
# No secrets are baked in; the API token is read from the environment or a file.
#
# Usage:
#   ./tiiny-embedder-watchdog.sh            # run forever (systemd-friendly)
#   ./tiiny-embedder-watchdog.sh --once     # single probe, report, exit
#   WD_DRY_RUN=1 ./tiiny-embedder-watchdog.sh   # detect + log, never mutate
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration (all env-overridable; see .env.example)
# ---------------------------------------------------------------------------
# Endpoints. On-device, point these at localhost; from a host, at the device.
: "${TIINY_MGMT:=http://p8800.api.tiiny/api/v1}"        # management API base
: "${TIINY_EMBED_URL:=http://api.tiiny/v1/embeddings}"  # endpoint to probe
: "${TIINY_MODEL:=Qwen/Qwen3-Embedding-0.6B}"           # model to keep alive

# Auth: either TIINY_TOKEN, or TIINY_TOKEN_FILE (recommended; chmod 600).
: "${TIINY_TOKEN:=}"
: "${TIINY_TOKEN_FILE:=}"

# Probe / detection
: "${WD_INTERVAL:=30}"          # seconds between probes
: "${WD_FAILMAX:=3}"            # consecutive failures before declaring a wedge
: "${WD_PROBE_TIMEOUT:=12}"     # per-probe timeout (s)

# Recovery
: "${WD_STOP_ALL:=1}"           # 1 = stop ALL models (the fix); 0 = only the target
: "${WD_SETTLE:=5}"             # pause after stopping, before starting (s)
: "${WD_RECOVER_TRIES:=25}"     # health polls after restart
: "${WD_RECOVER_WAIT:=6}"       # seconds between health polls
: "${WD_COOLDOWN:=120}"         # min seconds between recovery attempts
: "${WD_MAX_PER_HOUR:=6}"       # thrash guard; 0 disables

# Safety: never stop models just because the *path to the device* broke.
# A failing inference endpoint means "wedge" only if the device is still
# reachable. If the management API is unreachable too, the fault is the
# network/bridge/DNS between you and the device — restarting models would be a
# destructive false positive. Set to 0 only if you have no management API.
: "${WD_REQUIRE_MGMT:=1}"
: "${WD_MGMT_TIMEOUT:=8}"       # reachability-check timeout (s)

# Behavior
: "${WD_DRY_RUN:=0}"            # 1 = detect and log only, never stop/start
: "${WD_HEARTBEAT:=3600}"       # seconds between summary lines (0 disables)
: "${WD_LOG_FILE:=}"            # optional; default stdout (journald captures it)

# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------
PROBES=0; FAILS=0; WEDGES=0; RECOVERED=0; RECOVER_FAILED=0; SELF_CLEARED=0
PATH_SKIPS=0; PATH_DOWN=0
LAST_RECOVERY=0; RECENT=()   # epoch times of recent recoveries (rate limiting)
RUNNING=1

log() {
  local line
  line="[$(date '+%F %T')] $*"
  if [ -n "$WD_LOG_FILE" ]; then printf '%s\n' "$line" >>"$WD_LOG_FILE"; fi
  printf '%s\n' "$line"
}

# Load token from file if given (file wins; keeps secrets out of the process list)
if [ -n "$TIINY_TOKEN_FILE" ] && [ -r "$TIINY_TOKEN_FILE" ]; then
  TIINY_TOKEN="$(tr -d '\r\n' <"$TIINY_TOKEN_FILE")"
fi

# curl helper that never leaks the token into logs
_curl() {
  if [ -n "$TIINY_TOKEN" ]; then
    curl -s -H "Authorization: Bearer $TIINY_TOKEN" "$@"
  else
    curl -s "$@"
  fi
}

# Probe the inference endpoint. Echoes the HTTP status ("000" on timeout).
probe() {
  _curl -m "$WD_PROBE_TIMEOUT" -o /dev/null -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' \
    -d "{\"model\":\"$TIINY_MODEL\",\"input\":\"ping\"}" \
    "$TIINY_EMBED_URL" 2>/dev/null
}

# List currently-running model ids, one per line. Tries jq, then python3, then sed.
running_models() {
  local body
  body="$(_curl -m 10 "$TIINY_MGMT/models/running" 2>/dev/null)" || return 0
  [ -z "$body" ] && return 0
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$body" | jq -r '.running[]? // empty' 2>/dev/null && return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$body" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
r=d.get("running", d if isinstance(d,list) else [])
for m in r: print(m if isinstance(m,str) else m.get("id",""))' 2>/dev/null && return 0
  fi
  printf '%s' "$body" | tr ',' '\n' | sed -n 's/.*"\([^"]*\/[^"]*\)".*/\1/p'
}

stop_model()  { _curl -m 30 -X POST "$TIINY_MGMT/models/$1/stop"  >/dev/null 2>&1; }
start_model() { _curl -m 30 -X POST "$TIINY_MGMT/models/$1/start" >/dev/null 2>&1; }

# Is the device itself still reachable? ANY HTTP response proves the path works
# — even 401/403/404. Only a connection failure or timeout (curl reports "000")
# means we cannot reach it. This is what separates "the model wedged" from
# "the bridge/DNS/network between us and the device went down".
mgmt_reachable() {
  local code
  code="$(_curl -m "$WD_MGMT_TIMEOUT" -o /dev/null -w '%{http_code}' \
          "$TIINY_MGMT/models/running" 2>/dev/null)"
  [ -n "$code" ] && [ "$code" != "000" ]
}

# Rate-limit guard: how many recoveries in the last hour
recent_count() {
  local now cutoff keep=() t
  now=$(date +%s); cutoff=$((now - 3600))
  for t in ${RECENT+"${RECENT[@]}"}; do [ "$t" -ge "$cutoff" ] && keep+=("$t"); done
  RECENT=(${keep+"${keep[@]}"})
  printf '%s' "${#RECENT[@]}"
}

recover() {
  local now models m ok=0 i
  now=$(date +%s)

  # --- Is this actually a wedge, or did the path to the device break? --------
  if [ "$WD_REQUIRE_MGMT" = "1" ]; then
    if mgmt_reachable; then
      if [ "$PATH_DOWN" = "1" ]; then
        log "  path restored — management API is answering again"
        PATH_DOWN=0
      fi
    else
      PATH_SKIPS=$((PATH_SKIPS + 1))
      if [ "$PATH_DOWN" != "1" ]; then
        PATH_DOWN=1
        log "  PATH PROBLEM (not a wedge): inference is failing AND the management"
        log "  API at $TIINY_MGMT is unreachable. That points at the network/bridge/DNS"
        log "  between here and the device, not at the model. Leaving models alone."
        log "  (override with WD_REQUIRE_MGMT=0 if this device has no management API)"
      fi
      return 1
    fi
  fi

  # Confirmed: the device answers, but it is not serving inference.
  WEDGES=$((WEDGES + 1))
  log "  WEDGE CONFIRMED: device reachable but not serving — stopping all models to release the NPU"

  if [ $((now - LAST_RECOVERY)) -lt "$WD_COOLDOWN" ]; then
    log "  cooldown active ($((WD_COOLDOWN - (now - LAST_RECOVERY)))s left) — deferring recovery"
    return 1
  fi
  if [ "$WD_MAX_PER_HOUR" -gt 0 ] && [ "$(recent_count)" -ge "$WD_MAX_PER_HOUR" ]; then
    log "  !! RATE LIMIT: ${WD_MAX_PER_HOUR} recoveries in the last hour."
    log "  !! The device is wedging faster than it can be recovered — needs a human."
    return 1
  fi

  # Record the attempt BEFORE the dry-run early-return, so a dry run faithfully
  # models real cadence (cooldown + rate limit) instead of over-reporting.
  LAST_RECOVERY=$now; RECENT+=("$now")

  if [ "$WD_DRY_RUN" = "1" ]; then
    log "  DRY RUN: would stop all models and restart '$TIINY_MODEL' (no action taken)"
    return 0
  fi

  if [ "$WD_STOP_ALL" = "1" ]; then
    models="$(running_models)"
    if [ -n "$models" ]; then
      while IFS= read -r m; do
        [ -z "$m" ] && continue
        stop_model "$m"; log "  stopped $m"
      done <<<"$models"
    else
      log "  (no running models reported; stopping target anyway)"
      stop_model "$TIINY_MODEL"
    fi
  else
    stop_model "$TIINY_MODEL"; log "  stopped $TIINY_MODEL"
  fi

  sleep "$WD_SETTLE"
  start_model "$TIINY_MODEL"
  log "  starting $TIINY_MODEL ..."

  for ((i = 1; i <= WD_RECOVER_TRIES; i++)); do
    sleep "$WD_RECOVER_WAIT"
    if [ "$(probe)" = "200" ]; then
      log "  RECOVERED: healthy again (t+$((i * WD_RECOVER_WAIT))s)"
      ok=1; break
    fi
  done

  if [ "$ok" = 1 ]; then
    RECOVERED=$((RECOVERED + 1)); return 0
  fi
  RECOVER_FAILED=$((RECOVER_FAILED + 1))
  log "  !! STILL NOT HEALTHY after $((WD_RECOVER_TRIES * WD_RECOVER_WAIT))s — manual intervention likely needed"
  return 1
}

summary() {
  log "summary: probes=$PROBES wedges=$WEDGES recovered=$RECOVERED failed=$RECOVER_FAILED self_cleared=$SELF_CLEARED path_skips=$PATH_SKIPS"
}

shutdown() { RUNNING=0; log "shutting down (signal)"; summary; exit 0; }
trap shutdown TERM INT

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--once" ]; then
  code="$(probe)"
  log "single probe -> ${code:-timeout}"
  [ "$code" = "200" ] && exit 0 || exit 1
fi

log "watchdog START  endpoint=$TIINY_EMBED_URL model=$TIINY_MODEL"
log "  interval=${WD_INTERVAL}s failmax=$WD_FAILMAX probe_timeout=${WD_PROBE_TIMEOUT}s stop_all=$WD_STOP_ALL dry_run=$WD_DRY_RUN"
[ -z "$TIINY_TOKEN" ] && log "  (no auth token set — fine if your API is open)"

fails=0; last_beat=$(date +%s)
while [ "$RUNNING" = 1 ]; do
  code="$(probe)"; PROBES=$((PROBES + 1))

  if [ "$code" = "200" ]; then
    if [ "$fails" -gt 0 ]; then
      log "recovered on its own: probe 200 after $fails fail(s)"
      SELF_CLEARED=$((SELF_CLEARED + 1))
    fi
    if [ "$PATH_DOWN" = "1" ]; then
      log "path restored — inference endpoint reachable again"
      PATH_DOWN=0
    fi
    fails=0
  else
    fails=$((fails + 1)); FAILS=$((FAILS + 1))
    log "probe FAIL (code=${code:-timeout}) ${fails}/${WD_FAILMAX}"
    if [ "$fails" -ge "$WD_FAILMAX" ]; then
      log "$WD_FAILMAX consecutive failures -> assessing (wedged model vs unreachable device)"
      recover
      fails=0
    fi
  fi

  if [ "$WD_HEARTBEAT" -gt 0 ]; then
    now=$(date +%s)
    if [ $((now - last_beat)) -ge "$WD_HEARTBEAT" ]; then summary; last_beat=$now; fi
  fi

  sleep "$WD_INTERVAL"
done
