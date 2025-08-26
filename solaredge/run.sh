#!/usr/bin/env bash
set -euo pipefail

# Lees opties van de add-on
OPT=/data/options.json

API_KEY="$(jq -r '.api_key // empty' "$OPT")"
CLIENT_ID="$(jq -r '.client_id' "$OPT")"

API_URL="$(jq -r '.api_url' "$OPT")"
TEL_URL="$(jq -r '.telemetry_url' "$OPT")"

INV_IP="$(jq -r '.inv_ip' "$OPT")"
CTRL_DIR="$(jq -r '.ctrl_dir' "$OPT")"
INTERVAL="$(jq -r '.interval_sec' "$OPT")"

DEBUG="$(jq -r '.debug' "$OPT")"
VERIFY_SSL="$(jq -r '.verify_ssl' "$OPT")"

export API_KEY CLIENT_ID
export API_URL TEL_URL
export INV_IP CTRL_DIR
export INTERVAL DEBUG VERIFY_SSL

echo "[BMS] Start: api_url=$API_URL tel_url=$TEL_URL interval=${INTERVAL}s inv_ip=${INV_IP} ctrl_dir=${CTRL_DIR} debug=${DEBUG} verify_ssl=${VERIFY_SSL}"

# Main loop; agent does one full cycle then sleeps INTERVAL
while true; do
  /app/se-agent-bms.sh || echo "[BMS] se-agent-bms.sh exit code=$?"
  sleep "${INTERVAL}"
done

