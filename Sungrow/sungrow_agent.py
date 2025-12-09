#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import time
import requests
import traceback

# ========================
# Env configuration
# ========================
API_KEY     = os.environ.get("API_KEY") or os.environ.get("api_key")
CLIENT_ID   = os.environ.get("CLIENT_ID") or os.environ.get("client_id")
API_URL     = os.environ.get("API_URL", "https://api.metdezon.nl/bms/api/next_action.php")
# default to telemetry.php; env TELEMETRY_URL from run.sh will override
TEL_URL     = os.environ.get("TELEMETRY_URL", "https://api.metdezon.nl/bms/api/telemetry.php")
INTERVAL    = int(os.environ.get("INTERVAL", "60"))
POWER       = int(os.environ.get("POWER", "2000"))
VERIFY_SSL  = os.environ.get("VERIFY_SSL", "true").lower() in ("1", "true", "yes")
DEBUG       = os.environ.get("DEBUG", "false").lower() in ("1", "true", "yes")

# Home Assistant entities (defaults chosen for modbus_sungrow.yaml)
SOC_ENTITY  = os.environ.get("SOC_ENTITY", "sensor.battery_level")
MODE_ENTITY = os.environ.get("MODE_ENTITY", "")
PV_ENTITY   = os.environ.get("PV_ENTITY", "sensor.total_dc_power")
GRID_ENTITY = os.environ.get("GRID_ENTITY", "sensor.meter_active_power")

DEFAULT_HA_URL = "http://supervisor/core/api"
HA_URL_ENV     = os.environ.get("HA_URL", DEFAULT_HA_URL)

DISABLE_HA = os.environ.get("DISABLE_HA", "false").lower() in ("1", "true", "yes")

# Entities / scripts from modbus_sungrow.yaml we use to control the inverter
FORCED_POWER_ENTITY = os.environ.get("FORCED_POWER_ENTITY", "input_number.set_sg_forced_charge_discharge_power")
EMS_MODE_INPUT      = os.environ.get("EMS_MODE_INPUT", "input_select.set_sg_ems_mode")
FORCE_CMD_INPUT     = os.environ.get("FORCE_CMD_INPUT", "input_select.set_sg_battery_forced_charge_discharge_cmd")

SCRIPT_FORCE_CHARGE = os.environ.get("SCRIPT_FORCE_CHARGE", "script.sg_set_forced_charge_battery_mode")
SCRIPT_FORCE_DISCH  = os.environ.get("SCRIPT_FORCE_DISCH", "script.sg_set_forced_discharge_battery_mode")
SCRIPT_SELF_CONS    = os.environ.get("SCRIPT_SELF_CONS", "script.sg_set_self_consumption_mode")

HEADERS_EXT = {"X-API-Key": API_KEY} if API_KEY else {}

# ========================
# Helpers
# ========================

def log(msg: str):
    print(f"[Sungrow] {msg}", flush=True)

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
            if DEBUG:
                log(f"HA GET {entity_id} -> {r.status_code} {r.text[:200]}")
    except Exception as e:
        if DEBUG:
            log(f"HA GET {entity_id} error: {e}")
    return None

def ha_call_service(domain: str, service: str, data: dict):
    if DISABLE_HA:
        if DEBUG:
            log(f"DISABLE_HA=1, not calling {domain}.{service}")
        return

    token = get_ha_token()
    if not token:
        log("ERROR: cannot call HA service; no token present.")
        return

    url = f"{ha_base_url()}/services/{domain}/{service}"
    headers = {"Authorization": f"Bearer {token}"}

    try:
        if DEBUG:
            log(f"HA service {domain}.{service} data={data}")
        r = requests.post(url, headers=headers, json=data, timeout=10)
        if DEBUG:
            log(f"HA service -> {r.status_code} {r.text[:200]}")
        r.raise_for_status()
    except Exception as e:
        log(f"HA service {domain}.{service} error: {e}")

def read_from_home_assistant():
    out: dict = {}

    # SOC
    soc = ha_get_state(SOC_ENTITY)
    if soc and "state" in soc:
        try:
            out["soc_pct"] = float(soc["state"])
        except Exception:
            pass

    # Optional numeric mode sensor (if user defines one)
    md = ha_get_state(MODE_ENTITY) if MODE_ENTITY else None
    if md and "state" in md:
        try:
            out["mode"] = int(md["state"])
        except Exception:
            try:
                # allow "charge", "discharge", "auto" textual modes
                name = str(md["state"]).strip().lower()
                name_map = {"auto": 1, "charge": 2, "discharge": 3, "standby": 1}
                out["mode"] = name_map.get(name)
            except Exception:
                pass

    # PV power
    pv = ha_get_state(PV_ENTITY)
    if pv and "state" in pv:
        try:
            out["pv_power_w"] = int(float(pv["state"]))
        except Exception:
            pass

    # GRID power
    grid = ha_get_state(GRID_ENTITY)
    if grid and "state" in grid:
        try:
            out["grid_power_w"] = int(float(grid["state"]))
        except Exception:
            pass

    return out

def upload_telemetry(payload: dict):
    if not TEL_URL:
        if DEBUG:
            log("No TELEMETRY_URL configured; skipping telemetry")
        return
    try:
        if DEBUG:
            log(f"POST {TEL_URL} -> {payload}")
        r = requests.post(TEL_URL, headers=HEADERS_EXT, json=payload, timeout=10, verify=VERIFY_SSL)
        if DEBUG:
            log(f"TEL HTTP {r.status_code} {r.text[:200]}")
        r.raise_for_status()
    except Exception as e:
        log(f"Telemetry upload error: {e}")

def fetch_next_action() -> tuple[int, int]:
    if DEBUG:
        log(f"HTTP GET {API_URL} (verify_ssl={VERIFY_SSL}) …")
    r = requests.get(API_URL, headers=HEADERS_EXT, timeout=10, verify=VERIFY_SSL)
    if DEBUG:
        log(f"HTTP {r.status_code}, len={len(r.content)}")
    r.raise_for_status()
    data = r.json()
    mode = int(str(data.get("mode", -1)))
    power_watt = int(str(data.get("power_watt", 0)))
    return mode, power_watt

# ========================
# Control logic for Sungrow
# ========================

def apply_server_mode(server_mode: int, server_power: int):
    # Meaning of server_mode is kept consistent with the GoodWe agent:
    #   1 = standby / idle (self-consumption)
    #   3 = charge
    #   4 = discharge / export
    #   7 = auto / self-consumption

    # If HA integration is disabled we cannot control the inverter.
    if DISABLE_HA:
        log("DISABLE_HA=1, skipping inverter control")
        return

    effective_power = server_power if server_power > 0 else POWER

    if server_mode in (1, 7):
        # self consumption: let Sungrow manage on its own
        log("Set Sungrow to self-consumption mode")
        if SCRIPT_SELF_CONS:
            ha_call_service("script", "turn_on", {"entity_id": SCRIPT_SELF_CONS})
        else:
            # Fallback to direct input_select control
            if EMS_MODE_INPUT:
                ha_call_service(
                    "input_select",
                    "select_option",
                    {"entity_id": EMS_MODE_INPUT, "option": "Self-consumption mode (default)"},
                )
            if FORCE_CMD_INPUT:
                ha_call_service(
                    "input_select",
                    "select_option",
                    {"entity_id": FORCE_CMD_INPUT, "option": "Stop (default)"},
                )

    elif server_mode == 3:
        # forced charge
        if effective_power <= 0:
            log("Charge mode requested but no power_watt > 0 supplied; skipping change.")
            return
        log(f"Set Sungrow to forced charge at {effective_power} W")

        if FORCED_POWER_ENTITY:
            ha_call_service(
                "input_number",
                "set_value",
                {"entity_id": FORCED_POWER_ENTITY, "value": effective_power},
            )

        if SCRIPT_FORCE_CHARGE:
            ha_call_service("script", "turn_on", {"entity_id": SCRIPT_FORCE_CHARGE})
        else:
            if EMS_MODE_INPUT:
                ha_call_service(
                    "input_select",
                    "select_option",
                    {"entity_id": EMS_MODE_INPUT, "option": "Forced mode"},
                )
            if FORCE_CMD_INPUT:
                ha_call_service(
                    "input_select",
                    "select_option",
                    {"entity_id": FORCE_CMD_INPUT, "option": "Forced charge"},
                )

    elif server_mode == 4:
        # forced discharge / export
        if effective_power <= 0:
            log("Discharge mode requested but no power_watt > 0 supplied; skipping change.")
            return
        log(f"Set Sungrow to forced discharge at {effective_power} W")

        if FORCED_POWER_ENTITY:
            ha_call_service(
                "input_number",
                "set_value",
                {"entity_id": FORCED_POWER_ENTITY, "value": effective_power},
            )

        if SCRIPT_FORCE_DISCH:
            ha_call_service("script", "turn_on", {"entity_id": SCRIPT_FORCE_DISCH})
        else:
            if EMS_MODE_INPUT:
                ha_call_service(
                    "input_select",
                    "select_option",
                    {"entity_id": EMS_MODE_INPUT, "option": "Forced mode"},
                )
            if FORCE_CMD_INPUT:
                ha_call_service(
                    "input_select",
                    "select_option",
                    {"entity_id": FORCE_CMD_INPUT, "option": "Forced discharge"},
                )

    else:
        log(f"Unknown server mode {server_mode}; not changing Sungrow mode.")

# ========================
# Main loop
# ========================

def loop():
    token_present = bool(get_ha_token())
    log(f"Agent up. verify_ssl={VERIFY_SSL} debug={DEBUG}")
    log(f"HA_URL={ha_base_url()} token_present={token_present} disable_ha={DISABLE_HA}")

    while True:
        try:
            # 1) Get next action from EMS
            server_mode, server_power = fetch_next_action()
            if DEBUG:
                log(f"server_mode={server_mode}, server_power={server_power}")

            apply_server_mode(server_mode, server_power)

            # 2) Read telemetry from HA and upload heartbeat
            tel = read_from_home_assistant() if not DISABLE_HA else {}
            if tel:
                if "soc_pct" in tel:
                    log(f"SOC from HA: {tel['soc_pct']}%")
                if "mode" in tel:
                    mode_names = {1: "Auto/Standby", 2: "Charge", 3: "Discharge"}
                    m = tel["mode"]
                    log(f"Mode from HA: {m} ({mode_names.get(m, 'Unknown')})")
                if "pv_power_w" in tel:
                    log(f"PV power from HA: {tel['pv_power_w']} W")
                if "grid_power_w" in tel:
                    log(f"Grid power from HA: {tel['grid_power_w']} W")

            heartbeat = {
                "client_id": CLIENT_ID,
                "reported_at": int(time.time()),
                "soc": float(tel["soc_pct"]) if tel and "soc_pct" in tel else None,
                # keep policy mode from server so DB never gets NULL
                "battery_mode": server_mode,
                "pv_power_w": tel.get("pv_power_w") if tel else None,
                "grid_power_w": tel.get("grid_power_w") if tel else None,
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

