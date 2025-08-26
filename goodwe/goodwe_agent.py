#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import time
import requests
import subprocess
import traceback

# ========================
# Env configuration
# ========================
API_KEY     = os.environ.get("API_KEY") or os.environ.get("api_key")
CLIENT_ID   = os.environ.get("CLIENT_ID") or os.environ.get("client_id")
API_URL     = os.environ.get("API_URL", "https://api.metdezon.nl/bms/api/next_action.php")
TEL_URL     = os.environ.get("TELEMETRY_URL", "https://api.metdezon.nl/bms/api/heartbeat.php")
INTERVAL    = int(os.environ.get("INTERVAL", "60"))
POWER       = int(os.environ.get("POWER", "2000"))
VERIFY_SSL  = os.environ.get("VERIFY_SSL", "true").lower() in ("1","true","yes")
DEBUG       = os.environ.get("DEBUG", "false").lower() in ("1","true","yes")

# Home Assistant entities
SOC_ENTITY  = os.environ.get("SOC_ENTITY", "sensor.battery_state_of_charge")
MODE_ENTITY = os.environ.get("MODE_ENTITY", "")

DEFAULT_HA_URL = "http://supervisor/core/api"
HA_URL_ENV = os.environ.get("HA_URL", DEFAULT_HA_URL)

DISABLE_HA = os.environ.get("DISABLE_HA", "false").lower() in ("1","true","yes")

# server → GoodWe
MODE_MAP = {7:1, 4:3, 1:1, 3:2}

HEADERS_EXT = {"X-API-Key": API_KEY} if API_KEY else {}

# ========================
# Helpers
# ========================

def log(msg: str):
    print(f"[GoodWe] {msg}", flush=True)

def ha_base_url() -> str:
    url = HA_URL_ENV.rstrip("/")
    if not url.endswith("/api"):
        url += "/api"
    return url

def get_ha_token() -> str | None:
    for k in ("SUPERVISOR_TOKEN", "HASSIO_TOKEN", "HOMEASSISTANT_TOKEN", "HA_TOKEN"):
        v = os.environ.get(k)
        if v:
            return v
    return None

def set_mode(mode: int, power: int = 0):
    cmd = (
        "bash -lc '"
        "source /config/ha/pymodbus/.venv/bin/activate && "
        f"python3 /config/ha/pymodbus/setmode.py {mode} {power}"
        "'"
    )
    if DEBUG: log(f"Executing: {cmd}")
    rc = subprocess.call(cmd, shell=True)
    if rc != 0:
        log(f"WARN: setmode.py exit code {rc}")

def ha_get_state(entity_id: str):
    if DISABLE_HA or not entity_id:
        return None
    token = get_ha_token()
    if not token:
        log("ERROR: no Home Assistant token in env (SUPERVISOR_TOKEN/HASSIO_TOKEN/HA_TOKEN).")
        log("If running outside Supervisor, export HA_URL and HA_TOKEN (Long-Lived Access Token).")
        return None
    url = f"{ha_base_url()}/states/{entity_id}"
    headers = {"Authorization": f"Bearer {token}"}
    try:
        r = requests.get(url, headers=headers, timeout=5)
        if r.status_code == 200:
            return r.json()
        else:
            if DEBUG: log(f"HA GET {entity_id} -> {r.status_code} {r.text[:200]}")
    except Exception as e:
        if DEBUG: log(f"HA GET {entity_id} error: {e}")
    return None

def read_from_home_assistant():
    out = {}
    soc = ha_get_state(SOC_ENTITY)
    if soc and "state" in soc:
        try:
            out["soc_pct"] = float(soc["state"])
        except Exception:
            pass
    md = ha_get_state(MODE_ENTITY) if MODE_ENTITY else None
    if md and "state" in md:
        try:
            out["mode"] = int(md["state"])
        except Exception:
            name = str(md["state"]).strip().lower()
            name_map = {"auto":1, "charge":2, "discharge":3, "standby":1}
            out["mode"] = name_map.get(name)
    return out

def upload_telemetry(payload: dict):
    if not TEL_URL:
        if DEBUG: log("No TELEMETRY_URL configured; skipping telemetry")
        return
    try:
        if DEBUG: log(f"POST {TEL_URL} -> {payload}")
        r = requests.post(TEL_URL, headers=HEADERS_EXT, json=payload, timeout=10, verify=VERIFY_SSL)
        if DEBUG: log(f"TEL HTTP {r.status_code} {r.text[:200]}")
        r.raise_for_status()
    except Exception as e:
        log(f"Telemetry upload error: {e}")

def fetch_next_action() -> tuple[int, int]:
    if DEBUG: log(f"HTTP GET {API_URL} (verify_ssl={VERIFY_SSL}) …")
    r = requests.get(API_URL, headers=HEADERS_EXT, timeout=10, verify=VERIFY_SSL)
    if DEBUG: log(f"HTTP {r.status_code}, len={len(r.content)}")
    r.raise_for_status()
    data = r.json()
    mode = int(str(data.get("mode", -1)))
    power_watt = int(str(data.get("power_watt", 0)))
    return mode, power_watt

# ========================
# Main loop
# ========================

def loop():
    token_present = bool(get_ha_token())
    log(f"Agent up. verify_ssl={VERIFY_SSL} debug={DEBUG}")
    log(f"HA_URL={ha_base_url()} token_present={token_present} disable_ha={DISABLE_HA}")

    while True:
        try:
            # 1) Get next action first, so we can both apply & report it
            server_mode, server_power = fetch_next_action()
            if DEBUG: log(f"server_mode={server_mode}, server_power={server_power}")

            if server_mode in MODE_MAP:
                gw_mode = MODE_MAP[server_mode]
                pwr = server_power if server_power > 0 else (POWER if gw_mode in (2,3) else 0)
                log(f"Set mode {gw_mode} with power {pwr}W")
                set_mode(gw_mode, pwr)
            else:
                log(f"Unknown server mode {server_mode}; nothing to do.")

            # 2) Read telemetry from HA (optional) and upload heartbeat
            tel = read_from_home_assistant() if not DISABLE_HA else {}
            if tel:
                if "soc_pct" in tel:
                    log(f"SOC from HA: {tel['soc_pct']}%")
                if "mode" in tel:
                    mode_names = {1:"Auto/Standby", 2:"Charge", 3:"Discharge"}
                    m = tel["mode"]
                    log(f"Mode from HA: {m} ({mode_names.get(m, 'Unknown')})")

            heartbeat = {
                "client_id": CLIENT_ID,
                "reported_at": int(time.time()),
                "soc": float(tel["soc_pct"]) if tel and "soc_pct" in tel else None,
                # IMPORTANT: store the policy/server mode so it's never NULL
                "battery_mode": server_mode
            }
            # drop None fields except battery_mode (keep it always)
            payload = {k: v for k, v in heartbeat.items() if v is not None or k == "battery_mode"}
            upload_telemetry(payload)

        except Exception as e:
            log(f"ERROR: {e}")
            if DEBUG:
                traceback.print_exc()

        time.sleep(INTERVAL)

if __name__ == "__main__":
    loop()

