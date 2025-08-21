#!/usr/bin/env bash
set -e

echo "[GoodWe] Installatie gestart..."

# 1. Add-on directory maken
ADDON_DIR="/addons/goodwe-agent"
mkdir -p $ADDON_DIR

# 2. config.json
cat > $ADDON_DIR/config.json <<'EOF'
{
  "name": "GoodWe Agent",
  "version": "1.0",
  "slug": "goodwe_agent",
  "description": "Bridge server mode -> GoodWe battery mode",
  "startup": "application",
  "boot": "auto",
  "options": {
    "server_url": "http://api.metdezon.nl/bms_mode"
  },
  "schema": {
    "server_url": "str"
  }
}
EOF

# 3. Dockerfile
cat > $ADDON_DIR/Dockerfile <<'EOF'
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
cat > $ADDON_DIR/run.sh <<'EOF'
#!/usr/bin/env bash
echo "[GoodWe] Starting agent..."
python3 /goodwe_agent.py
EOF
chmod +x $ADDON_DIR/run.sh

# 5. goodwe_agent.py
cat > $ADDON_DIR/goodwe_agent.py <<'EOF'
import os, time, requests, subprocess

server_url = os.environ.get("SERVER_URL", "http://api.metdezon.nl/bms_mode")

# Correcte mapping server → GoodWe
mode_map = {
    7: 1,  # server Auto → GoodWe Auto
    4: 2,  # server Charge → GoodWe Charge
    1: 1,  # server Auto → GoodWe Auto
    3: 3,  # server Discharge → GoodWe Discharge
}

def set_mode(mode, power=0):
    cmd = f"bash -c 'source /config/ha/pymodbus/.venv/bin/activate && python3 /config/ha/pymodbus/setmode.py {mode} {power}'"
    print(f"[GoodWe] Executing: {cmd}")
    subprocess.call(cmd, shell=True)

while True:
    try:
        r = requests.get(server_url, timeout=5)
        data = r.json()
        server_mode = int(data.get("mode", -1))
        print(f"[GoodWe] Server mode = {server_mode}")

        if server_mode in mode_map:
            gw_mode = mode_map[server_mode]
            set_mode(gw_mode, 5000 if gw_mode in [2,3] else 0)
        else:
            print("[GoodWe] Unknown server mode, skipping...")

    except Exception as e:
        print(f"[GoodWe] Error: {e}")

    time.sleep(60)
EOF

# 6. pymodbus directory + setmode.py
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

# 7. Install venv + juiste pymodbus versie
python3 -m venv /config/ha/pymodbus/.venv
source /config/ha/pymodbus/.venv/bin/activate
pip install --upgrade pip
pip install "pymodbus==3.1.2"

echo "[GoodWe] ✅ Installatie klaar!"
echo "Ga nu in Supervisor → Add-ons → Local Add-ons en installeer 'GoodWe Agent'."
