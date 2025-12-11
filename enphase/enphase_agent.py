#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import time
import requests
import traceback

# ========================
# Env configuration
# ========================

API_KEY = os.environ.get("API_KEY") or os.environ.get("api_key")
CLIENT_ID = (
    os.environ.get("CLIENT_ID")
    or os.environ.get("client_id")
    or "enphase_agent"
)

# Default naar dezelfde endpoints als GoodWe
API_URL = os.environ.get(
    "API_URL",
    "https://api.metdezon.nl/bms/api/next_action.php",
)
# default naar telemetry.php; env TELEMETRY_URL uit run.sh override’t dit
TEL_URL = os.environ.get(
    "TELEMETRY_URL",
    "https://api.metdezon.nl/bms/api/telemetry.php",
)

INTERVAL = int(os.environ.get("INTERVAL", "60"))
VERIFY_SSL = os.environ.get("VERIFY_SSL", "true").lower() in ("1", "true", "yes")
DEBUG = os.environ.get("DEBUG", "false").lower() in ("1", "true", "yes")

# Home Assistant entities (kun je via de add-on opties aanpassen)
SOC_ENTITY = os.environ.get("SOC_ENTITY", "sensor.battery_state_of_charge")
MODE_ENTITY = os.environ.get("MODE_ENTITY", "")
PV_ENTITY = os.environ.get("PV_ENTITY", "sensor.pv_power")
GRID_ENTITY = os.environ.get("GRID_ENTITY", "sensor.active_power")

DEFAULT_HA_URL = "http://supervisor/core/api"
HA_URL_ENV = os.environ.get("HA_URL") or DEFAULT_HA_URL

DISABLE_HA = os.environ.get("DISABLE_HA", "false").lower() in ("1", "true", "yes")

# Enphase via HA-services / rest_command
# Dit sluit aan op de namen uit de GitHub-handleiding.
ENPHASE_CHARGE_SCRIPT = os.environ.get(
    "ENPHASE_CHARGE_SCRIPT",
    "script.toggle_enphase_charge_from_grid",
)
ENPHASE_DISCHARGE_SCRIPT = os.environ.get(
    "ENPHASE_DISCHARGE_SCRIPT",
    "script.toggle_enphase_discharge_to_grid",
)
ENPHASE_RESTRICT_COMMAND = os.environ.get(
    "ENPHASE_RESTRICT_COMMAND",
    "rest_command.enphase_battery_restrict_discharge",
)

# X-API-Key voor MetDeZon backend
HEADERS_EXT = {"X-API-Key": API_KEY} if API_KEY else {}

# Voor logging / debug
MODE_NAMES = {
    1: "Standby / hold",
    3: "Charge (netladen)",
    4: "Discharge (naar net)",
    7: "Idle / zelfconsumptie",
}

# ========================
# Helpers
# ========================


def log(msg: str) -> None:
    print(f"[Enphase] {msg}", flush=True)


def ha_base_url() -> str:
    url = (HA_URL_ENV or DEFAULT_HA_URL).rstrip("/")
    if not url.endswith("/api"):
        url += "/api"
    return url


def get_ha_token():
    """Zoek naar een token dat Supervisor/HA injecteert of via env is gezet."""
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
        log("ERROR: geen Home Assistant token (SUPERVISOR_TOKEN/HASSIO_TOKEN/HA_TOKEN).")
        log("Als je buiten Supervisor draait, zet dan HA_URL en HA_TOKEN in de env.")
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


def ha_call_service(domain: str, service: str, data: dict | None = None) -> bool:
    """Call HA service via REST API."""
    if DISABLE_HA:
        if DEBUG:
            log(f"HA disabled, skip service call {domain}.{service}")
        return False

    token = get_ha_token()
    if not token:
        log("ERROR: geen Home Assistant token om services aan te roepen.")
        return False

    url = f"{ha_base_url()}/services/{domain}/{service}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }

    try:
        if DEBUG:
            log(f"HA POST {domain}.{service} data={data}")
        r = requests.post(url, headers=headers, json=data or {}, timeout=10)
        if DEBUG:
            log(f"HA service resp: {r.status_code} {r.text[:200]}")
        return r.status_code in (200, 201)
    except Exception as e:
        log(f"HA service error {domain}.{service}: {e}")
        if DEBUG:
            traceback.print_exc()
        return False


def ha_call_service_name(full_name: str, data: dict | None = None) -> bool:
    """Convenience: 'domain.service' string uit env/schema."""
    if not full_name:
        return False
    if "." not in full_name:
        log(f"Invalid HA service '{full_name}' (expected 'domain.service')")
        return False
    domain, service = full_name.split(".", 1)
    return ha_call_service(domain, service, data)


# ========================
# Telemetry uit Home Assistant
# ========================


def read_from_home_assistant() -> dict:
    out: dict = {}

    # SOC
    soc = ha_get_state(SOC_ENTITY)
    if soc and "state" in soc:
        try:
            out["soc_pct"] = float(soc["state"])
        except Exception:
            pass

    # Mode (optioneel)
    md = ha_get_state(MODE_ENTITY) if MODE_ENTITY else None
    if md and "state" in md:
        try:
            out["mode"] = int(md["state"])
        except Exception:
            name = str(md["state"]).strip().lower()
            name_map = {
                "auto": 7,
                "idle": 7,
                "selfconsumption": 7,
                "self-consumption": 7,
                "charge": 3,
                "charging": 3,
                "discharge": 4,
                "discharging": 4,
                "standby": 1,
            }
            out["mode"] = name_map.get(name)

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


# ========================
# MetDeZon API helpers
# ========================


def upload_telemetry(payload: dict) -> None:
    if not TEL_URL:
        if DEBUG:
            log("Geen TELEMETRY_URL geconfigureerd; skip telemetry")
        return
    try:
        if DEBUG:
            log(f"POST {TEL_URL} -> {payload}")
        r = requests.post(
            TEL_URL,
            headers=HEADERS_EXT,
            json=payload,
            timeout=10,
            verify=VERIFY_SSL,
        )
        if DEBUG:
            log(f"TEL HTTP {r.status_code} {r.text[:200]}")
        r.raise_for_status()
    except Exception as e:
        log(f"Telemetry upload error: {e}")
        if DEBUG:
            traceback.print_exc()


def fetch_next_action() -> tuple[int, int]:
    """Vraag de volgende actie op bij de MetDeZon backend."""
    if not API_URL:
        return -1, 0

    if DEBUG:
        log(f"HTTP GET {API_URL} (verify_ssl={VERIFY_SSL}) …")

    r = requests.get(API_URL, headers=HEADERS_EXT, timeout=10, verify=VERIFY_SSL)
    if DEBUG:
        log(f"HTTP {r.status_code}, len={len(r.content)}")
    r.raise_for_status()

    try:
        data = r.json()
    except Exception as e:
        log(f"JSON decode error: {e}")
        if DEBUG:
            traceback.print_exc()
        return -1, 0

    try:
        mode = int(str(data.get("mode", -1)))
    except Exception:
        mode = -1

    try:
        power_watt = int(str(data.get("power_watt", 0)))
    except Exception:
        power_watt = 0

    return mode, power_watt


# ========================
# Enphase mode mapping
# ========================

def apply_enphase_mode(server_mode: int, server_power: int) -> None:
    """
    Vertaal MetDeZon policy -> Enphase battery mode via Home Assistant.

    Belangrijk:
      * Idle (7) = zelfconsumptie:
        - geen laden uit net
        - geen ontladen naar net
        - batterij mag eigen verbruik dekken
      * power (server_power) wordt nu alleen gelogd, Enphase krijgt geen hard limiet.
    """
    name = MODE_NAMES.get(server_mode, "Unknown")
    log(f"Apply policy mode {server_mode} ({name}), power={server_power}W")

    # We gaan uit van de scripts zoals in de handleiding:
    # - script.toggle_enphase_charge_from_grid(charge: bool)
    # - script.toggle_enphase_discharge_to_grid(discharge: bool)
    # - rest_command.enphase_battery_restrict_discharge(restrict: bool)

    if server_mode == 7:
        # IDLE = zelfconsumptie: geen netladen, geen ontladen naar net
        ha_call_service_name(ENPHASE_CHARGE_SCRIPT, {"charge": False})
        ha_call_service_name(ENPHASE_DISCHARGE_SCRIPT, {"discharge": False})
        if ENPHASE_RESTRICT_COMMAND:
            # mag wel ontladen naar eigen load
            ha_call_service_name(ENPHASE_RESTRICT_COMMAND, {"restrict": False})

    elif server_mode == 3:
        # Forceer laden (netladen aan, niet ontladen naar net)
        ha_call_service_name(ENPHASE_CHARGE_SCRIPT, {"charge": True})
        ha_call_service_name(ENPHASE_DISCHARGE_SCRIPT, {"discharge": False})
        if ENPHASE_RESTRICT_COMMAND:
            ha_call_service_name(ENPHASE_RESTRICT_COMMAND, {"restrict": False})

    elif server_mode == 4:
        # Forceer ontladen naar net (discharge_to_grid aan)
        ha_call_service_name(ENPHASE_CHARGE_SCRIPT, {"charge": False})
        ha_call_service_name(ENPHASE_DISCHARGE_SCRIPT, {"discharge": True})
        if ENPHASE_RESTRICT_COMMAND:
            ha_call_service_name(ENPHASE_RESTRICT_COMMAND, {"restrict": False})

    elif server_mode == 1:
        # Standby / batterij vasthouden: niet laden, niet ontladen
        ha_call_service_name(ENPHASE_CHARGE_SCRIPT, {"charge": False})
        ha_call_service_name(ENPHASE_DISCHARGE_SCRIPT, {"discharge": False})
        if ENPHASE_RESTRICT_COMMAND:
            ha_call_service_name(ENPHASE_RESTRICT_COMMAND, {"restrict": True})

    else:
        log(f"Onbekende server_mode {server_mode}; geen Enphase-actie.")


# ========================
# Main loop
# ========================

def loop() -> None:
    token_present = bool(get_ha_token())
    log(f"Agent up. verify_ssl={VERIFY_SSL} debug={DEBUG}")
    log(f"HA_URL={ha_base_url()} token_present={token_present} disable_ha={DISABLE_HA}")

    while True:
        try:
            # 1) Vraag volgende actie op
            server_mode, server_power = fetch_next_action()
            if DEBUG:
                log(f"server_mode={server_mode}, server_power={server_power}")

            if server_mode > 0:
                apply_enphase_mode(server_mode, server_power)
            else:
                log(f"Geen geldige server mode ({server_mode}); skip set_mode.")

            # 2) Telemetry uit HA lezen & heartbeat sturen
            tel = read_from_home_assistant() if not DISABLE_HA else {}
            if tel:
                if "soc_pct" in tel:
                    log(f"SOC uit HA: {tel['soc_pct']}%")
                if "mode" in tel:
                    m = tel["mode"]
                    log(f"Mode uit HA: {m} ({MODE_NAMES.get(m, 'Unknown')})")
                if "pv_power_w" in tel:
                    log(f"PV power uit HA: {tel['pv_power_w']} W")
                if "grid_power_w" in tel:
                    log(f"Grid power uit HA: {tel['grid_power_w']} W")

            heartbeat = {
                "client_id": CLIENT_ID,
                "reported_at": int(time.time()),
                "soc": float(tel["soc_pct"]) if tel and "soc_pct" in tel else None,
                # policy mode van server altijd loggen
                "battery_mode": server_mode,
                "pv_power_w": tel.get("pv_power_w") if tel else None,
                "grid_power_w": tel.get("grid_power_w") if tel else None,
            }

            # None-velden eruit, behalve battery_mode
            payload = {
                k: v
                for k, v in heartbeat.items()
                if v is not None or k == "battery_mode"
            }
            upload_telemetry(payload)

        except Exception as e:
            log(f"ERROR: {e}")
            if DEBUG:
                traceback.print_exc()

        time.sleep(INTERVAL)


if __name__ == "__main__":
    loop()

