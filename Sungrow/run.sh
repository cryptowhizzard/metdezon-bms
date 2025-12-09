#!/usr/bin/env bash
set -euo pipefail

OPT_FILE=/data/options.json

API_URL=$(jq -r '.api_url' "$OPT_FILE")
API_KEY=$(jq -r '.api_key' "$OPT_FILE")
TELEMETRY_URL=$(jq -r '.telemetry_url // empty' "$OPT_FILE")

SOC_ENTITY=$(jq -r '.soc_entity' "$OPT_FILE")
MODE_ENTITY=$(jq -r '.mode_entity // empty' "$OPT_FILE")
PV_ENTITY=$(jq -r '.pv_entity // "sensor.total_dc_power"' "$OPT_FILE")
GRID_ENTITY=$(jq -r '.grid_entity // "sensor.meter_active_power"' "$OPT_FILE")

POLL_INTERVAL=$(jq -r '.poll_interval' "$OPT_FILE")
POWER_WATT=$(jq -r '.power_watt' "$OPT_FILE")
DEBUG=$(jq -r '.debug' "$OPT_FILE")

# optional HA overrides from options
HA_URL=$(jq -r '.ha_url // empty' "$OPT_FILE")
HA_TOKEN=$(jq -r '.ha_token // empty' "$OPT_FILE")

# Export environment expected by sungrow_agent.py
export API_URL API_KEY TELEMETRY_URL
export SOC_ENTITY MODE_ENTITY
export PV_ENTITY GRID_ENTITY
export INTERVAL="$POLL_INTERVAL"
export POWER="$POWER_WATT"
export DEBUG

# Export HA vars if provided
[ -n "$HA_URL" ] && export HA_URL
[ -n "$HA_TOKEN" ] && export HA_TOKEN

echo "[Sungrow] Start agent: API_URL=$API_URL interval=${INTERVAL}s power=${POWER}W"

exec python3 /app/sungrow_agent.py

