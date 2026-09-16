#!/usr/bin/env bash
# tiiny-import-model.sh — import a HuggingFace model onto the Tiiny device via its
# management API (:8800), with the behaviors learned the hard way:
#
#   * inspect first; a GGUF-only repo (no config.json) fails TOOLKIT_NOT_FOUND —
#     you need a safetensors/transformers repo the toolkit matcher can identify.
#   * the import POST requires display_name == model_name (else INVALID_REQUEST).
#   * the ~18GB pull happens device-side over the device's (roam-prone) WiFi;
#     on a roam it dies with TOOLKIT_CATALOG_UNAVAILABLE / dns_error. A fresh
#     re-POST REUSES the HF-xet cache and resumes, so we just retry.
#   * reasoning/thinking defaults ON for Qwen3.5; pass --no-reasoning to flip it.
#   * re-importing the same name creates a "<name>-1" duplicate, not a replace.
#
# Usage:
#   tiiny-import-model.sh <hf_url> [options]
#
# Options:
#   --name NAME         model_name AND display_name (they must match); default: repo basename
#   --no-reasoning      import with reasoning_enabled=false (direct answers)
#   --reasoning         import with reasoning_enabled=true
#   --toolkit ID        force toolkit_id (e.g. qwen3.5-9b)
#   --base-model ID     force base_model_id (e.g. Qwen/Qwen3.5-9B)
#   --retries N         max import attempts on network failure (default 5)
#   --inspect-only      inspect and print support, then exit (no download)
#   --launch            launch (load onto NPU) after a successful import
#   --test "PROMPT"     after --launch, run one chat completion with PROMPT
#   --host IP           device IP (default: auto from pcsvr hosts file)
#
# Env: TIINY_KEY overrides the auth key; TIINY_MAXTOK sets test max_tokens (default 2000).
set -uo pipefail

# ---- args -------------------------------------------------------------------
HF_URL="${1:-}"; shift || true
[ -n "$HF_URL" ] || { grep -m1 '^# Usage' -A0 "$0"; sed -n '/^# Usage:/,/^# Env:/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

NAME=""; REASONING="__unset__"; TOOLKIT=""; BASE=""; RETRIES=5
INSPECT_ONLY=0; DO_LAUNCH=0; TEST_PROMPT=""; HOST_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name)        NAME="$2"; shift 2;;
    --no-reasoning) REASONING=false; shift;;
    --reasoning)   REASONING=true; shift;;
    --toolkit)     TOOLKIT="$2"; shift 2;;
    --base-model)  BASE="$2"; shift 2;;
    --retries)     RETRIES="$2"; shift 2;;
    --inspect-only) INSPECT_ONLY=1; shift;;
    --launch)      DO_LAUNCH=1; shift;;
    --test)        TEST_PROMPT="$2"; shift 2;;
    --host)        HOST_OVERRIDE="$2"; shift 2;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done
[ -n "$NAME" ] || NAME=$(basename "$HF_URL")

# ---- device + auth ----------------------------------------------------------
HERE="$(cd "$(dirname "$0")" && pwd)"
AUTH_DIR="$HOME/.local/share/tiiny-pcsvr/auth_data"
# Management API. Default is the NAME p8800.api.tiiny on :80 — the device's own
# nginx maps that vhost to its internal 8800, so it rides the bridge host's Caddy proxy.
# A literal <ip>:8800 does NOT: the bridge proxies :80 only.
# --host / HOST_OVERRIDE still forces a direct connection (off-LAN, the bridge host down).
if [ -n "${HOST_OVERRIDE:-}" ]; then
  IP="$HOST_OVERRIDE"; MGMT="http://$IP:8800/api/v1"
else
  IP="p8800.api.tiiny"; MGMT="${TIINY_MGMT:-http://p8800.api.tiiny/api/v1}"
fi

# Bearer: TIINY_AUTH_KEY (portable) > TIINY_KEY (legacy) > pcsvr auth_data (only on the host running pcsvr)
KEY="${TIINY_AUTH_KEY:-${TIINY_KEY:-$(python3 -c "import json,glob,os
m=glob.glob(os.path.expanduser('$AUTH_DIR/*.json'))
print(json.load(open(m[0]))['auth_key'] if m else '')" 2>/dev/null)}}"
[ -n "$KEY" ] || { echo "no device token: set TIINY_AUTH_KEY, or run ./reauth.sh on the pcsvr host" >&2; exit 1; }
AUTH=(-H "Authorization: Bearer $KEY")
say(){ printf '%s\n' "$*" >&2; }

# ---- build the JSON body (reused by inspect + import) -----------------------
body() {  # $1 = extra json fragment (or empty)
  python3 - "$HF_URL" "$NAME" "$TOOLKIT" "$BASE" "$REASONING" "$1" <<'PY'
import json,sys
hf,name,tk,base,reason,extra=sys.argv[1:7]
b={"hf_url":hf}
if extra=="import":
    b["display_name"]=name; b["model_name"]=name   # MUST match
if tk:   b["toolkit_id"]=tk
if base: b["base_model_id"]=base
if reason!="__unset__": b["reasoning_enabled"]=(reason=="true")
print(json.dumps(b))
PY
}

# ---- inspect ----------------------------------------------------------------
say "==> inspecting $HF_URL"
INSP=$(timeout 90 curl -s -X POST "$MGMT/models/import/inspect" "${AUTH[@]}" \
  -H 'Content-Type: application/json' -d "$(body inspect)")
echo "$INSP" | python3 -c "
import json,sys
d=json.load(sys.stdin); s=d.get('import_support',{}); m=d.get('model',{})
print('  status      :',d.get('status'))
print('  supported   :',s.get('supported'),'  reason:',s.get('reason_code'))
print('  toolkit/base:',s.get('toolkit_id'),'/',s.get('base_model_id'))
print('  size        :',m.get('size_display'),' format:',d.get('artifacts',{}).get('primary_format'))
print('  disk needed :',d.get('disk_space',{}).get('required_display'))
import sys as _s
_s.exit(0 if s.get('supported') else 3)
" >&2
SUP=$?
if [ "$INSPECT_ONLY" = 1 ]; then exit $SUP; fi
if [ "$SUP" != 0 ]; then
  say "!! not supported for import. If it's GGUF-only (no config.json), find a safetensors copy."
  say "   You can also force --toolkit/--base-model, but inspect ignores them for a bare-GGUF repo."
  exit 3
fi

# ---- import with retry-on-roam (fresh POST reuses the cache) ----------------
LOG=$(mktemp /tmp/tiiny-import.XXXXXX.log)
attempt=0
while :; do
  attempt=$((attempt+1))
  say "==> import attempt $attempt/$RETRIES  (name='$NAME', reasoning=$REASONING)"
  : > "$LOG"
  curl -sN -X POST "$MGMT/models/import" "${AUTH[@]}" \
    -H 'Content-Type: application/json' -d "$(body import)" >> "$LOG" 2>&1 &
  cpid=$!
  # stream the log until a terminal event
  result=""
  while kill -0 "$cpid" 2>/dev/null; do
    if grep -q '"event": "done"' "$LOG"; then result="done"; break; fi
    if grep -q '"event": "error"' "$LOG"; then result="error"; break; fi
    # progress heartbeat
    grep '^data: ' "$LOG" | tail -1 | sed 's/^data: //' | python3 -c "
import json,sys
try:
 d=json.load(sys.stdin); dl=d.get('downloaded_bytes',0); tot=d.get('total_bytes',0)
 print('   %-22s %5.1f%%  %.2f/%.2f GB' % (d.get('import_stage',''),(100*dl/tot if tot else 0),dl/1e9,tot/1e9))
except Exception: pass" >&2
    sleep 5
  done
  wait "$cpid" 2>/dev/null
  [ -n "$result" ] || { grep -q '"event": "done"' "$LOG" && result=done; grep -q '"event": "error"' "$LOG" && result=error; }

  if [ "$result" = "done" ]; then
    msg=$(grep '"event": "done"' "$LOG" | tail -1 | sed 's/^data: //' | python3 -c "import json,sys;print(json.load(sys.stdin).get('message',''))" 2>/dev/null)
    say "==> import OK: $msg"; break
  fi
  err=$(grep '"event": "error"' "$LOG" | tail -1 | sed 's/^data: //' | python3 -c "import json,sys;print(json.load(sys.stdin).get('error_code',''))" 2>/dev/null)
  say "!! import failed (${err:-stream-ended})"
  case "$err" in
    TOOLKIT_CATALOG_UNAVAILABLE|""|*NETWORK*|*DNS*|*CONNECT*)
      if [ "$attempt" -lt "$RETRIES" ]; then say "   likely a device-WiFi drop; retrying (cache is reused)…"; sleep 5; continue; fi ;;
  esac
  say "   giving up after $attempt attempts. Log: $LOG"; exit 4
done
rm -f "$LOG"

# ---- resolve the actual imported id (re-import may add a -N suffix) ---------
MID=$(timeout 10 curl -s "${AUTH[@]}" "$MGMT/models/" | python3 -c "
import json,sys
d=json.load(sys.stdin); ms=d if isinstance(d,list) else d.get('models',d.get('data',[]))
cands=[m['model_id'] for m in ms if isinstance(m,dict) and '$NAME'.split('/')[-1] in m.get('model_id','')]
print(sorted(cands)[-1] if cands else '')" 2>/dev/null)
say "==> imported model_id: $MID"
[ "$DO_LAUNCH" = 1 ] || { say "done (not launched). Launch with: $0 ... --launch"; echo "$MID"; exit 0; }

# ---- launch (load onto NPU) -------------------------------------------------
ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$MID")
say "==> launching $MID"
timeout 30 curl -s -X POST "$MGMT/models/$ENC/launch" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{}' >/dev/null
for _ in $(seq 1 120); do
  serving=$(timeout 6 curl -s "${AUTH[@]}" "http://$IP/v1/models" | python3 -c "import json,sys;print(any('$MID'==m.get('id') for m in json.load(sys.stdin).get('data',[])))" 2>/dev/null)
  [ "$serving" = "True" ] && { say "==> serving."; break; }
  sleep 3
done

# ---- optional test (generous max_tokens — Qwen3.5 thinks a lot) -------------
[ -n "$TEST_PROMPT" ] || { echo "$MID"; exit 0; }
say "==> test: $TEST_PROMPT"
timeout 180 curl -s -X POST "http://$IP/v1/chat/completions" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d "$(python3 -c "import json,sys;print(json.dumps({'model':sys.argv[1],'messages':[{'role':'user','content':sys.argv[2]}],'max_tokens':int('${TIINY_MAXTOK:-2000}'),'temperature':0.3}))" "$MID" "$TEST_PROMPT")" \
  | python3 -c "
import json,sys
d=json.load(sys.stdin); m=d['choices'][0]['message']
print('  answer   :',(m.get('content') or '').strip()[:600])
rc=(m.get('reasoning_content') or '').strip()
if rc: print('  (thought %d chars first)'%len(rc))
print('  finish   :',d['choices'][0]['finish_reason'],'| tokens:',d.get('usage',{}).get('completion_tokens'))
" >&2
echo "$MID"
