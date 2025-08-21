#!/usr/bin/env bash
set -e

echo "[GoodWe] === Installation started ==="

# 1. Directories
ADDON_DIR="/addons/goodwe-agent"
PYMODBUS_DIR="/config/ha/pymodbus"
mkdir -p "$ADDON_DIR" "$PYMODBUS_DIR"

# 2. Ask user for settings
read -p "Enter API key: " API_KEY
read -p "Enter API URL [default: https://api.metdezon.nl/bms/api/next_action.php]: " API_URL
API_URL=${API_URL:-https://api.metdezon.nl/bms/api/next_action.php}
read -p "Polling interval in seconds [default: 60]: " INTERVAL
INTERVAL=${INTERVAL:-60}
read -p "Charge/Discharge power (W) [default: 2000]: " POWER
POWER=${POWER:-2000}

# 3. config.json
cat > "$ADDON_DIR/config.json" <<EOF
{
  "name": "GoodWe Agent",
  "version": "1.0.1",
  "slug": "goodwe_agent",
  "description": "Bridge server mode -> GoodWe battery mode",
  "startup": "application",
  "boot": "auto",
  "options": {
    "api_key": "$API_KEY",
    "api_url": "$API_URL",
    "interval": $INTERVAL,
    "power": $POWER,
    "verify_ssl": true,
    "debug": false
  },
  "schema": {
    "api_key": "str",
    "api_url": "str?",
    "interval": "int?",
    "power": "int?",
    "verify_ssl": "bool?",
    "debug": "bool?"
  }
}
EOF

# 4. Dockerfile
cat > "$ADDON_DIR/Dockerfile" <<'EOF'
ARG BUILD_FROM
FROM $BUILD_FROM

RUN apk add --no-cache python3 py3-pip bash

WORKDIR /usr/src/app

COPY run.sh /run.sh
COPY goodwe_agent.py /goodwe_agent.py

RUN chmod +x /run.sh

CMD [ "/run.sh" ]
EOF

# 5. run.sh
cat > "$ADDON_DIR/run.sh" <<'EOF'
#!/usr/bin/env bash
echo "[GoodWe] Starting agent..."
python3 /goodwe_agent.py
EOF
chmod +x "$ADDON_DIR/run.sh"

# 6. goodwe_agent.py
cat > "$ADDON_DIR/goodwe_agent.py" <<'EOF'
import os, time, requests, subprocess

api_key = os.environ.get("API_KEY") or os.environ.get("api_key")
api_url = os.environ.get("API_URL", "https://api.metdezon.nl/bms/api/next_action.php")
interval = int(os.environ.get("INTERVAL", "60"))
power = int(os.environ.get("POWER", "2000"))
verify_ssl = os.environ.get("VERIFY_SSL", "true").lower() in ("1","true","yes")
debug = os.environ.get("DEBUG", "false").lower() in ("1","true","yes")

print(f"[GoodWe] Start agent: API_URL={api_url} interval={interval}s power={power}")
print(f"[GoodWe] Agent up. verify_ssl={verify_ssl} debug={debug}")

headers = {"X-API-Key": api_key} if api_key else {}

# Server → GoodWe mode mapping
mode_map = {
    7: 1,  # Auto
    3: 2,  # Charge
    4: 3,  # Discharge
    1: 1   # Auto (fallback)
}

def set_mode(mode, power=0):
    cmd = f"bash -lc 'source /config/ha/pymodbus/.venv/bin/activate && python3 /config/ha/pymodbus/setmode.py {mode} {power}'"
    if debug:
        print(f"[GoodWe] Executing: {cmd}")
    rc = subprocess.call(cmd, shell=True)
    if rc != 0:
        print(f"[GoodWe] WARN: setmode.py exit code {rc}")

while True:
    try:
        print(f"[GoodWe] HTTP GET {api_url} (verify_ssl={verify_ssl}) …")
        r = requests.get(api_url, headers=headers, timeout=10, verify=verify_ssl)
        r.raise_for_status()
        data = r.json()
        server_mode = int(data.get("mode", -1))
        if debug:
            print(f"[GoodWe] Server response: {data}")

        if server_mode in mode_map:
            gw_mode = mode_map[server_mode]
            set_mode(gw_mode, power if gw_mode in [2,3] else 0)
        else:
            print("[GoodWe] Unknown server mode, skipping…")

    except Exception as e:
        print(f"[GoodWe] Error: {e}")

    time.sleep(interval)
EOF

# 7. setmode.py (inside pymodbus dir)
cat > "$PYMODBUS_DIR/setmode.py" <<'EOF'
import sys
from pymodbus.client import ModbusSerialClient

if len(sys.argv) < 2:
    print("Usage: python3 setmode.py [mode] [power]")
    sys.exit(1)

mode = int(sys.argv[1])
power = int(sys.argv[2]) if len(sys.argv) >= 3 else 0

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

if mode in [2,3] and power > 0:
    client.write_register(address=47512, value=power, slave=247)

client.close()

print(f"Set mode {mode} {'with power ' + str(power) + 'W' if power else ''}")
EOF

# 8. Setup Python venv with pymodbus + pyserial
python3 -m venv "$PYMODBUS_DIR/.venv"
source "$PYMODBUS_DIR/.venv/bin/activate"
pip install --upgrade pip
pip install pymodbus==3.1.2 pyserial
deactivate

echo "[GoodWe] === Installation complete! ==="
echo "Go to Supervisor → Add-ons → Local Add-ons and install 'GoodWe Agent'."
