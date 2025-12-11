#!/usr/bin/env bash
set -euo pipefail

OPT_FILE=/data/options.json

API_URL=$(jq -r '.api_url' "$OPT_FILE")
TEL_URL=$(jq -r '.telemetry_url' "$OPT_FILE")
API_KEY=$(jq -r '.api_key' "$OPT_FILE")

TELEMETRY_URL=$(jq -r '.telemetry_url // empty' "$OPT_FILE")
SOC_ENTITY=$(jq -r '.soc_entity' "$OPT_FILE")
MODE_ENTITY=$(jq -r '.mode_entity // empty' "$OPT_FILE")
PV_ENTITY=$(jq -r '.pv_entity // "sensor.pv_power"' "$OPT_FILE")
GRID_ENTITY=$(jq -r '.grid_entity // "sensor.active_power"' "$OPT_FILE")

POLL_INTERVAL=$(jq -r '.poll_interval' "$OPT_FILE")
DEBUG=$(jq -r '.debug // 0' "$OPT_FILE")

# Optionele HA overrides
HA_URL=$(jq -r '.ha_url // empty' "$OPT_FILE")
HA_TOKEN=$(jq -r '.ha_token // empty' "$OPT_FILE")

# Enphase service namen uit opties (met defaults)
ENPHASE_CHARGE_SCRIPT=$(jq -r '.enphase_charge_script // "script.toggle_enphase_charge_from_grid"' "$OPT_FILE")
ENPHASE_DISCHARGE_SCRIPT=$(jq -r '.enphase_discharge_script // "script.toggle_enphase_discharge_to_grid"' "$OPT_FILE")
ENPHASE_RESTRICT_COMMAND=$(jq -r '.enphase_restrict_command // "rest_command.enphase_battery_restrict_discharge"' "$OPT_FILE")

# Export naar Python
export API_URL API_KEY TELEMETRY_URL
export SOC_ENTITY MODE_ENTITY
export PV_ENTITY GRID_ENTITY
export INTERVAL="$POLL_INTERVAL"
export DEBUG

export ENPHASE_CHARGE_SCRIPT ENPHASE_DISCHARGE_SCRIPT ENPHASE_RESTRICT_COMMAND

# HA vars indien ingevuld
[ -n "$HA_URL" ] && export HA_URL
[ -n "$HA_TOKEN" ] && export HA_TOKEN

TOKLEN=$(printf '%s' "${SUPERVISOR_TOKEN-}" | wc -c | tr -d '[:space:]')
echo "[Enphase] SUPERVISOR_TOKEN length: ${TOKLEN:-0}"

echo "[Enphase] Start agent: API_URL=$API_URL interval=${INTERVAL}s"
exec python3 /app/enphase_agent.py

