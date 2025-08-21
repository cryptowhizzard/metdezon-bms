#!/bin/bash
set -euo pipefail

# ── Prompts ──────────────────────────────────────────────────────────────────
read -rp "API key: " API_KEY
read -rp "IP adres omvormer (bv 192.168.1.166): " INV_IP
read -rp "Interval in seconden [60]: " INTERVAL
INTERVAL=${INTERVAL:-60}

ADDONS_DIR="/addons"
SLUG_DIR="solaredge-bms"                 # mapnaam
SLUG_JSON="solaredge_bms"                # slug in config.json
ADDON_PATH="$ADDONS_DIR/$SLUG_DIR"

echo "[+] Maak add-on map: $ADDON_PATH"
mkdir -p "$ADDON_PATH"

# ── config.json ──────────────────────────────────────────────────────────────
cat >"$ADDON_PATH/config.json" <<'JSON'
{
  "name": "SolarEdge BMS Control",
  "version": "1.0.0",
  "slug": "solaredge_bms",
  "description": "Battery control for SolarEdge via local Modbus and central API.",
  "startup": "services",
  "boot": "auto",
  "stage": "experimental",
  "arch": ["amd64","aarch64","armv7","armhf","i386"],
  "init": false,
  "host_network": true,
  "map": ["config:rw"],
  "options": {
    "api_key": "",
    "inv_ip": "192.168.1.100",
    "interval_sec": 60,
    "debug": 0
  },
  "schema": {
    "api_key": "str",
    "inv_ip": "str",
    "interval_sec": "int",
    "debug": "int"
  }
}
JSON

# ── Dockerfile ───────────────────────────────────────────────────────────────
cat >"$ADDON_PATH/Dockerfile" <<'DOCKER'
ARG BUILD_FROM
FROM ${BUILD_FROM}

# Basis tools (alpine)
RUN apk add --no-cache bash python3 py3-pip py3-virtualenv jq curl git

# Add-on files
WORKDIR /app
COPY run.sh /app/run.sh
COPY se-agent-bms.sh /app/se-agent-bms.sh

# S6 overlay gebruikt /app/run.sh als entrypoint via "init": false + startup:services
CMD [ "/bin/bash", "/app/run.sh" ]
DOCKER

# ── run.sh (leest opties en start agent) ─────────────────────────────────────
cat >"$ADDON_PATH/run.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

OPT_FILE="/data/options.json"
# Lees opties uit Supervisor (via jq)
API_KEY=$(jq -r '.api_key // empty' "$OPT_FILE")
INV_IP=$(jq -r '.inv_ip // empty' "$OPT_FILE")
INTERVAL_SEC=$(jq -r '.interval_sec // 60' "$OPT_FILE")
DEBUG=$(jq -r '.debug // 0' "$OPT_FILE")

if [[ -z "$API_KEY" || -z "$INV_IP" ]]; then
  echo "[BMS] ERROR: Configureer eerst api_key en inv_ip in de add-on opties."
  sleep 10
  exit 1
fi

export API_KEY INV_IP INTERVAL_SEC DEBUG
export CTRL_DIR="/config/ha/solaredge-battery-control"

# Zorg dat control dir bestaat
mkdir -p "$CTRL_DIR"

# Clone repo indien se_battery_control.py ontbreekt (runtime, zodat build arch-onafhankelijk blijft)
if [[ ! -f "$CTRL_DIR/se_battery_control.py" ]]; then
  echo "[BMS] Repo ontbreken → clonen naar $CTRL_DIR…"
  apk add --no-cache git >/dev/null 2>&1 || true
  git clone --depth 1 https://github.com/milkotodorov/solaredge-battery-control "$CTRL_DIR"
fi

# Start de agent (self-healing venv binnen het script)
exec /bin/bash /app/se-agent-bms.sh
BASH
chmod +x "$ADDON_PATH/run.sh"

# ── se-agent-bms.sh (jouw bewezen, self-healing variant) ─────────────────────
cat >"$ADDON_PATH/se-agent-bms.sh" <<'BASH'
#!/bin/bash
# se-agent-bms.sh — SolarEdge BMS agent (self-healing venv)

API_KEY="${API_KEY:-}"
INV_IP="${INV_IP:-}"
CTRL_DIR="${CTRL_DIR:-/config/ha/solaredge-battery-control}"
INTERVAL_SEC="${INTERVAL_SEC:-60}"
DEBUG="${DEBUG:-0}"

VENV="$CTRL_DIR/venv"
PYTHON="$VENV/bin/python"
PIP="$PYTHON -m pip"
SCRIPT="$CTRL_DIR/se_battery_control.py"
INFO_SNAPSHOT="$CTRL_DIR/last_info.json"

log(){ echo "[BMS] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

apk add --no-cache jq >/dev/null 2>&1 || true
log "Start met interval ${INTERVAL_SEC}s (inv_ip=${INV_IP}, ctrl_dir=${CTRL_DIR})"

if [ -z "$API_KEY" ] || [ -z "$INV_IP" ]; then
  log "ERROR: API_KEY en/of INV_IP niet gezet."; exit 1;
fi

# venv aanwezig?
if [ ! -d "$VENV" ]; then
  log "INFO: venv ontbreekt → aanmaken…"
  python3 -m venv "$VENV"
fi

# pip bruikbaar?
if $PYTHON -m pip --version >/dev/null 2>&1; then
  [ "$DEBUG" = "1" ] && log "DEBUG: pip is al aanwezig in venv"
else
  log "INFO: pip ontbreekt in venv → probeer ensurepip…"
  $PYTHON -m ensurepip --upgrade >/dev/null 2>&1 || true
  $PYTHON -m pip --version >/dev/null 2>&1 || {
    if [ -f "$CTRL_DIR/get-pip.py" ]; then
      log "INFO: fallback get-pip.py → installeer pip in venv…"
      ( cd "$CTRL_DIR" && $PYTHON get-pip.py >/dev/null 2>&1 ) || true
    fi
  }
fi

# deps aanwezig?
if $PYTHON - <<'PY' >/dev/null 2>&1; then
import pymodbus
PY
  [ "$DEBUG" = "1" ] && log "DEBUG: venv dependencies OK"
else
  log "INFO: installing venv dependencies…"
  $PIP install --upgrade pip setuptools wheel >/dev/null 2>&1 || true
  # gebruik requirements.txt als die aanwezig is, anders val terug op basispakket
  if [ -f "$CTRL_DIR/requirements.txt" ]; then
    $PIP install -r "$CTRL_DIR/requirements.txt" >/dev/null 2>&1 || true
  else
    $PIP install pymodbus requests PyYAML >/dev/null 2>&1 || true
  fi
fi

# helper zodat config.yaml wordt gevonden
run_ctrl() {
  ( cd "$CTRL_DIR" && $PYTHON "$SCRIPT" "$@" )
}

# ===== main loop =====
while true; do
  [ "$DEBUG" = "1" ] && log "DEBUG: running: cd $CTRL_DIR && $PYTHON $SCRIPT --info $INV_IP"
  SOC_RAW=$(run_ctrl --info "$INV_IP" 2>&1)
  RC=$?
  printf '%s\n' "$SOC_RAW" > "$INFO_SNAPSHOT" 2>/dev/null || true

  if [ $RC -ne 0 ] || ! echo "$SOC_RAW" | jq -e '.' >/dev/null 2>&1; then
    log "ERROR: --info failed (rc=$RC). Zie $INFO_SNAPSHOT"
    sleep "$INTERVAL_SEC"
    continue
  fi

  SOC_VAL=$(echo "$SOC_RAW" | jq -r '.batteries.Battery1.soe // empty')
  if [ -z "$SOC_VAL" ]; then SOC="?"; else SOC=$(printf "%.0f" "$SOC_VAL"); fi

  MODE=$(echo "$SOC_RAW" | jq -r '.storage.rc_cmd_mode // .storage.storage_control_mode // .storage.storage_default_mode // "?"')

  # Alleen 7 labelen; rest neutraal (zoals jij wilde)
  case "$MODE" in
    7) MODE_NAME="Maximize Self-Consumption (MSC)" ;;
    "?") MODE_NAME="Unknown" ;;
    *) MODE_NAME="Mode $MODE" ;;
  esac

  if [ "$SOC" = "?" ]; then
    log "Local inverter: SOC=?, mode=${MODE} (${MODE_NAME})"
  else
    log "Local inverter: SOC=${SOC}%, mode=${MODE} (${MODE_NAME})"
  fi

  ACTION=$(curl -sk -H "X-API-Key: $API_KEY" https://api.metdezon.nl/bms/api/next_action.php)
  if [ -z "$ACTION" ]; then
    log "ERROR: Geen actie van API"
    sleep "$INTERVAL_SEC"
    continue
  fi
  [ "$DEBUG" = "1" ] && log "DEBUG: next_action raw=$ACTION"

  MODE_NEW=$(echo "$ACTION" | jq -r '.mode // empty')
  PWR=$(echo "$ACTION" | jq -r '.power_watt // empty')
  REASON=$(echo "$ACTION" | jq -r '.reason // empty')

  if [ -n "$MODE_NEW" ]; then
    run_ctrl --enable_storage_remote_control_mode "$INV_IP" >/dev/null 2>&1
    run_ctrl --set_storage_default_mode "$MODE_NEW" "$INV_IP" >/devnull 2>&1
    if [ -n "$PWR" ]; then
      run_ctrl --set_storage_charge_discharge_limit "$PWR" "$INV_IP" >/dev/null 2>&1
    fi
    log "Action result ok (mode=$MODE_NEW, power=${PWR:-N/A}W, reason=$REASON)"
  else
    log "No valid mode in API response, skip"
  fi

  sleep "$INTERVAL_SEC"
done
BASH
chmod +x "$ADDON_PATH/se-agent-bms.sh"

# ── Optionele README ─────────────────────────────────────────────────────────
cat >"$ADDON_PATH/README.md" <<'MD'
# SolarEdge BMS Control (Local Add-on)

- Stel in de Add-on UI je **API key**, **inverter IP** en **interval**.
- Logs: Supervisor → Add-ons → deze add-on → **Log**.

MD

# ── Build & (re)install via Supervisor CLI ───────────────────────────────────
echo "[+] Probeer local build & install via Supervisor…"
if command -v ha >/dev/null 2>&1; then
  # Build (rebuild) de lokale add-on
  ha addons rebuild "local_${SLUG_JSON}" || true
  # Install, of update als al aanwezig
  ha addons install "local_${SLUG_JSON}" || true
  # Zet opties via de UI; automatisch starten:
  ha addons start "local_${SLUG_JSON}" || true

  echo ""
  echo "✅ Add-on geplaatst als: local_${SLUG_JSON}"
  echo "Open Home Assistant → Settings → Add-ons → 'SolarEdge BMS Control'"
  echo "Vul daar API key, inv_ip (${INV_IP}) en interval (${INTERVAL}) in en start/Herstart."
else
  echo "ℹ️ Geen 'ha' CLI gevonden. Open de Home Assistant UI → Settings → Add-ons"
  echo "→ 'Add-on Store' → drie puntjes → Repositories → 'Local add-ons' verschijnt automatisch."
  echo "Selecteer 'SolarEdge BMS Control' en installeer. Stel opties in en start."
fi

echo "Klaar."
