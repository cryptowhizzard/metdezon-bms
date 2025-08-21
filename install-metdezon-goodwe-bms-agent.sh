#!/usr/bin/env bash
set -e

echo "[GoodWe] 🚀 Starting installation..."

# 1. Add-on directory
ADDON_DIR="/addons/goodwe-agent"
mkdir -p "$ADDON_DIR"

# 2. config.json
cat > "$ADDON_DIR/config.json" <<'EOF'
{
  "name": "GoodWe Agent",
  "version": "1.0.1",
  "slug": "goodwe_agent",
  "description": "Bridge server mode -> GoodWe battery mode",
  "startup": "application",
  "boot": "auto",
  "options": {
    "api_key": "",
    "api_url": "https://api.metdezon.nl/bms/api/next_action.php",
    "interval": 60,
    "power": 2000,
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

# 3. Dockerfile
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

# 4. run.sh
cat > "$ADDON_DIR/run.sh" <<'EOF'
#!/usr/bin/env bash
echo "[GoodWe] Starting agent..."
python3 /goodwe_agent.py
EOF
chmod +x "$ADDON_DIR/run.sh"

# 5. goodwe_agent.py
cat > "$ADDON_DIR/goodwe_agent.py" <<'EOF'
import os, time, requests, subprocess

api_key    = os.environ.get("API_KEY", "")
api_url    = os.environ.get("API_URL", "https://api.metdezon.nl/bms/api/next_action.php")
interval   = int(os.environ.get("INTERVAL", "60"))
power      = int(os.environ.get("POWER", "2000"))
verify_ssl = os.environ.get("VERIFY_SSL", "true").lower() in ("1","true","yes")
debug      = os.environ.get("DEBUG", "false").lower() in ("1","true","yes")

print(f"[GoodWe] Start agent: API_URL={api_url} interval={interval}s power={power}")
print(f"[GoodWe] Agent up. verify_ssl={verify_ssl} debug={int(debug)}")

headers = {}
if api_key:
    headers["X-API-Key"] = api_key

# Map server → GoodWe modes
mode_map = {
    7: 1,  # Auto (MSC)
    4: 2,  # Charge
    3: 3,  # Discharge
    1: 1   # Fallback → Auto
}

def set_mode(mode, power=0):
    cmd = f"bash -lc 'source /config/ha/pymodbus/.venv/bin/activate && python3 /config/ha/pymodbus/setmode.py {mode} {power}'"
    print(f"[GoodWe] set_mode: mode={mode} power={power} -> {cmd}")
    rc = subprocess.call(cmd, shell=True)
    if rc != 0:
        print(f"[GoodWe] WARN: setmode.py exit code {rc}")

while True:
    try:
        print(f"[GoodWe] HTTP GET {api_url} (verify_ssl={verify_ssl}) …")
        r = requests.get(api_url, headers=headers, timeout=10, verify=verify_ssl)
        r.raise_for_status()
        data = r.json()
        print(f"[GoodWe] HTTP {r.status_code}, len={len(r.text)}")

        server_mode = int(data.get("mode", -1))
        if server_mode in mode_map:
            gw_mode = mode_map[server_mode]
            set_mode(gw_mode, power if gw_mode in [2,3] else 0)
        else:
            print("[GoodWe] Unknown server mode, skipping…")

    except Exception as e:
        print(f"[GoodWe] ERROR: {e}")

    time.sleep(interval)
EOF

# 6. pymodbus helper dir + setmode.py
mkdir -p /config/ha/pymodbus

cat > /config/ha/pymodbus/setmode.py <<'EOF'
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

# 7. venv + pymodbus + pyserial
python3 -m venv /config/ha/pymodbus/.venv
source /config/ha/pymodbus/.venv/bin/activate
pip install --upgrade pip
pip install pymodbus==3.1.2 pyserial

echo "[GoodWe] ✅ Installation done!"
echo "Now refresh Supervisor → Add-ons → Local Add-ons and install 'GoodWe Agent'."
