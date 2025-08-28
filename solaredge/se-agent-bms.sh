cat se-agent-bms.sh 
#!/bin/bash
# se-agent-bms.sh — SolarEdge BMS agent (Posts SOC → asks action → applies; verbose logs)

set -euo pipefail

# -------- Read env (from run.sh) --------
API_KEY="${API_KEY:-}"
CLIENT_ID="${CLIENT_ID:-0}"

API_URL="${API_URL:-https://api.metdezon.nl/bms/api/next_action.php}"
TEL_URL="${TEL_URL:-https://api.metdezon.nl/bms/api/heartbeat.php}"

INV_IP="${INV_IP:-192.168.1.166}"
CTRL_DIR="${CTRL_DIR:-/config/ha/solaredge-battery-control}"

INTERVAL="${INTERVAL:-60}"
DEBUG="${DEBUG:-0}"
VERIFY_SSL="${VERIFY_SSL:-true}"

VENV="$CTRL_DIR/venv"
PYTHON="$VENV/bin/python"
PIP="$PYTHON -m pip"
SCRIPT="$CTRL_DIR/se_battery_control.py"
INFO_SNAPSHOT="$CTRL_DIR/last_info.json"

CURL_TLS=()
[ "${VERIFY_SSL,,}" = "true" ] || CURL_TLS+=(-k)   # allow insecure if verify_ssl=false

log(){ echo "[BMS] $(date '+%F %T') $*"; }

# jq for JSON parsing (idempotent)
apk add --no-cache jq >/dev/null 2>&1 || true

# --- Ensure control dir and venv exist ---
if [ ! -d "$CTRL_DIR" ]; then
  log "ERROR: Control dir $CTRL_DIR not found"
  exit 1
fi
if [ ! -d "$VENV" ]; then
  log "INFO: venv ontbreekt → aanmaken…"
  python3 -m venv "$VENV"
fi

# --- Ensure pip in venv ---
if ! $PYTHON -m pip --version >/dev/null 2>&1; then
  log "INFO: pip ontbreekt in venv → ensurepip…"
  $PYTHON -m ensurepip --upgrade >/dev/null 2>&1 || true
fi

# --- Ensure dependencies for the control script (if it has requirements.txt) ---
if [ -f "$CTRL_DIR/requirements.txt" ]; then
  $PIP install --upgrade pip setuptools wheel >/dev/null 2>&1 || true
  $PIP install -r "$CTRL_DIR/requirements.txt" >/dev/null 2>&1 || true
fi

# --- Helper to run se_battery_control.py in its folder (so config.yaml is found) ---
run_ctrl() {
  ( cd "$CTRL_DIR" && $PYTHON "$SCRIPT" "$@" )
}

# ================= 1) Read local inverter state =================
[ "$DEBUG" = "1" ] && log "DEBUG: reading inverter: $SCRIPT --info --timeout 30 $INV_IP"
SOC_RAW="$( run_ctrl --info --timeout 30 "$INV_IP" 2>&1 || true )"
printf '%s\n' "$SOC_RAW" > "$INFO_SNAPSHOT" 2>/dev/null || true

if ! echo "$SOC_RAW" | jq -e '.' >/dev/null 2>&1; then
  log "ERROR: --info returned no/invalid JSON. See $INFO_SNAPSHOT"
  exit 0
fi

# Parse SOC and (best-effort) current mode
SOC_VAL="$(echo "$SOC_RAW" | jq -r '.batteries.Battery1.soe // empty')"
if [ -z "$SOC_VAL" ] || [ "$SOC_VAL" = "null" ]; then
  SOC_SHOW="?"
else
  SOC_SHOW="$(printf '%.1f' "$SOC_VAL")"
fi

MODE="$(echo "$SOC_RAW" | jq -r '
  .storage.rc_cmd_mode // .storage.storage_control_mode // .storage.storage_default_mode // empty
')"
[ -z "$MODE" ] && MODE="?"

case "$MODE" in
  7) MODE_NAME="Maximize Self-Consumption (MSC)";;
  4) MODE_NAME="Maximize Export";;
  3) MODE_NAME="Charge PV+AC";;
  2) MODE_NAME="Charge PV";;
  5) MODE_NAME="Discharge to match load";;
  0) MODE_NAME="Off";;
  *) MODE_NAME="Mode $MODE";;
esac

# ====== NEW: derive PV and GRID powers (scaled) ======
# pv_ac_w  = inverter AC output power in W (scaled by power_ac_scale)
# pv_dc_w  = inverter DC input power in W (scaled by power_dc_scale)
# grid_w   = site net power from Meter1 in W (negative = export, positive = import)
PV_AC_W="$( echo "$SOC_RAW" | jq -r 'if (.power_ac==null) then empty else (.power_ac * (pow(10; (.power_ac_scale // 0)))) end' || true )"
PV_DC_W="$( echo "$SOC_RAW" | jq -r 'if (.power_dc==null) then empty else (.power_dc * (pow(10; (.power_dc_scale // 0)))) end' || true )"
GRID_W="$(  echo "$SOC_RAW" | jq -r 'if (.meters.Meter1.power==null) then empty else (.meters.Meter1.power * (pow(10; (.meters.Meter1.power_scale // 0)))) end' || true )"

# Round a bit for pretty logs (do not alter payload precision)
PV_AC_SHOW="$( [ -n "${PV_AC_W:-}" ] && printf '%.1f' "$PV_AC_W" || echo 'n/a' )"
PV_DC_SHOW="$( [ -n "${PV_DC_W:-}" ] && printf '%.1f' "$PV_DC_W" || echo 'n/a' )"
GRID_SHOW="$(  [ -n "${GRID_W:-}"  ] && printf '%.1f' "$GRID_W"  || echo 'n/a' )"

log "Local inverter: SOC=${SOC_SHOW}% mode=${MODE} (${MODE_NAME}) PV_AC=${PV_AC_SHOW}W PV_DC=${PV_DC_SHOW}W GRID=${GRID_SHOW}W (neg=export,pos=import)"

# ================= 2) Post heartbeat (telemetry) =================
# battery_mode in the DB should reflect the *policy* we are/just were using.
# If you prefer to store the *current local mode*, set BM="$MODE". For server policy, overwrite later.
BM="$MODE"

HB_JSON="$(jq -n \
  --argjson cid "$CLIENT_ID" \
  --argjson ts "$(date +%s)" \
  --arg soc "${SOC_VAL:-}" \
  --arg bm "$BM" \
  --arg pvac "${PV_AC_W:-}" \
  --arg pvdc "${PV_DC_W:-}" \
  --arg grid "${GRID_W:-}" \
  '
  {
    client_id: $cid,
    reported_at: $ts,
    soc: ( ($soc|tonumber?) ),
    battery_mode: ( ($bm|tonumber?) ),
    pv_power_w: ( ($pvac|tonumber?) ),
    grid_power_w:  ( ($grid|tonumber?) )
  }
  '
)"

[ "$DEBUG" = "1" ] && log "DEBUG: heartbeat payload: $HB_JSON"

CURL_ARGS=(-sS "${CURL_TLS[@]}" -H "Content-Type: application/json")
[ -n "$API_KEY" ] && CURL_ARGS+=(-H "X-API-Key: $API_KEY")

HTTP_TEL=$(curl -o /tmp/hb.out -w '%{http_code}' -X POST "${CURL_ARGS[@]}" -d "$HB_JSON" "$TEL_URL" || true)
OUT_TEL="$(cat /tmp/hb.out 2>/dev/null || true)"

if [[ "$HTTP_TEL" =~ ^2 ]]; then
  log "Heartbeat OK ($HTTP_TEL)"
else
  log "WARN: Heartbeat HTTP $HTTP_TEL body=$(echo "$OUT_TEL" | head -c 200)"
fi

# ================= 3) Fetch next action from server =================
HTTP_ACT=$(curl -o /tmp/act.out -w '%{http_code}' -sS "${CURL_TLS[@]}" \
  -H "Accept: application/json" ${API_KEY:+-H "X-API-Key: $API_KEY"} "$API_URL" || true)
ACT_RAW="$(cat /tmp/act.out 2>/dev/null || true)"

if ! [[ "$HTTP_ACT" =~ ^2 ]]; then
  log "ERROR: next_action HTTP $HTTP_ACT body=$(echo "$ACT_RAW" | head -c 200)"
  exit 0
fi
[ "$DEBUG" = "1" ] && log "DEBUG: next_action: $ACT_RAW"

MODE_NEW="$(echo "$ACT_RAW" | jq -r '.mode // empty')"
PWR_NEW="$(echo "$ACT_RAW" | jq -r '.power_watt // empty')"
REASON="$(echo "$ACT_RAW" | jq -r '.reason // empty')"

if [ -z "$MODE_NEW" ] || [ "$MODE_NEW" = "null" ]; then
  log "No valid mode in action response; skip apply."
  exit 0
fi

# ================= 4) Apply action to inverter =================
run_ctrl --enable_storage_remote_control_mode --timeout 30 "$INV_IP" >/dev/null 2>&1 || true
run_ctrl --set_storage_default_mode "$MODE_NEW" --timeout 30 "$INV_IP" >/dev/null 2>&1 || true

if [ -n "$PWR_NEW" ] && [ "$PWR_NEW" != "null" ]; then
  run_ctrl --set_storage_charge_discharge_limit "$PWR_NEW" --timeout 30 "$INV_IP" >/dev/null 2>&1 || true
fi

log "Applied policy: mode=$MODE_NEW power=${PWR_NEW:-N/A}W reason=${REASON:-n/a}"

# ================= 5) (Optional) post a second heartbeat with policy mode =================
HB2_JSON="$(jq -n \
  --argjson cid "$CLIENT_ID" \
  --argjson ts "$(date +%s)" \
  --arg soc "${SOC_VAL:-}" \
  --arg bm "$MODE_NEW" \
  --arg pvac "${PV_AC_W:-}" \
  --arg pvdc "${PV_DC_W:-}" \
  --arg grid "${GRID_W:-}" \
  '
  {
    client_id: $cid,
    reported_at: $ts,
    soc: ( ($soc|tonumber?) ),
    battery_mode: ( ($bm|tonumber?) ),
    pv_ac_w: ( ($pvac|tonumber?) ),
    pv_dc_w: ( ($pvdc|tonumber?) ),
    grid_w:  ( ($grid|tonumber?) )
  }
  '
)"
HTTP_TEL2=$(curl -o /tmp/hb2.out -w '%{http_code}' -X POST "${CURL_ARGS[@]}" -d "$HB2_JSON" "$TEL_URL" || true)
if [[ "$HTTP_TEL2" =~ ^2 ]]; then
  log "Heartbeat(policy) OK ($HTTP_TEL2)"
else
  log "WARN: Heartbeat(policy) HTTP $HTTP_TEL2 body=$(head -c 200 /tmp/hb2.out)"
fi

[core-ssh metdezon-bms]$ 
