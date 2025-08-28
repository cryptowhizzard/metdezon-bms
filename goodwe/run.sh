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
POWER_WATT=$(jq -r '.power_watt' "$OPT_FILE")
SERIAL_PORT=$(jq -r '.serial_port' "$OPT_FILE")
SERIAL_BAUD=$(jq -r '.serial_baud' "$OPT_FILE")
SERIAL_SLAVE=$(jq -r '.serial_slave' "$OPT_FILE")
DEBUG=$(jq -r '.debug' "$OPT_FILE")

# NEW: optional HA overrides from options
HA_URL=$(jq -r '.ha_url // empty' "$OPT_FILE")
HA_TOKEN=$(jq -r '.ha_token // empty' "$OPT_FILE")

# Export names the Python expects
export API_URL API_KEY TELEMETRY_URL
export SOC_ENTITY MODE_ENTITY
export PV_ENTITY GRID_ENTITY
export INTERVAL="$POLL_INTERVAL"
export POWER="$POWER_WATT"
export DEBUG

# Export HA vars if provided
[ -n "$HA_URL" ] && export HA_URL
[ -n "$HA_TOKEN" ] && export HA_TOKEN

# Zorg dat host-pad bestaat (mount via "map": ["config:rw"])
CTRL_DIR="/config/ha/pymodbus"
VENV="$CTRL_DIR/.venv"
mkdir -p "$CTRL_DIR"

# (leave your setmode.py creation + venv/pip bits unchanged)

echo "[GoodWe] Start agent: API_URL=$API_URL interval=${INTERVAL}s power=${POWER}"

# Optional diagnostics: show whether Supervisor injected a token (may be 0 — that's fine now)
TOKLEN=$(printf '%s' "${SUPERVISOR_TOKEN-}" | wc -c | tr -d '[:space:]')
echo "[GoodWe] SUPERVISOR_TOKEN length: ${TOKLEN:-0}"

# setmode.py aanmaken/overlaten
if [ ! -f "$CTRL_DIR/setmode.py" ]; then
  cat > "$CTRL_DIR/setmode.py" <<'PY'
import sys
from pymodbus.client import ModbusSerialClient

if len(sys.argv) < 2:
    print("Usage: python3 setmode.py [mode] [power]")
    print("Modes: 1=Auto, 2=Charge, 3=Discharge")
    sys.exit(1)

mode = int(sys.argv[1])
power = int(sys.argv[2]) if len(sys.argv) >= 3 else 0

# Seriële instellingen (houden we in dit script fixed; de agent bepaalt power/mode)
client = ModbusSerialClient(
    port='/dev/ttyUSB0',
    baudrate=9600,
    stopbits=1,
    bytesize=8,
    parity='N',
    timeout=1
)

client.connect()
client.write_register(address=47511, value=mode, slave=247)

if mode in [2, 3] and power > 0:
    client.write_register(address=47512, value=power, slave=247)

client.close()
print(f"Set mode {mode} {'with power ' + str(power) + 'W' if power else ''}")
PY
fi
chmod +x "$CTRL_DIR/setmode.py"

# venv + pymodbus==3.1.2 (self-heal)
if [ ! -d "$VENV" ]; then
  python3 -m venv "$VENV"
fi

if ! "$VENV/bin/python" -m pip --version >/dev/null 2>&1; then
  "$VENV/bin/python" -m ensurepip --upgrade || true
fi

"$VENV/bin/python" -m pip install --upgrade pip setuptools wheel >/dev/null 2>&1 || true
# gefixeerde versie die bij jou werkt
"$VENV/bin/python" -m pip install "pymodbus==3.1.2"

echo "[GoodWe] Start agent: API_URL=$API_URL interval=${POLL_INTERVAL}s power=$POWER_WATT"
exec python3 /app/goodwe_agent.py
