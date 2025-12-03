from __future__ import annotations

from datetime import timedelta
import logging

DOMAIN = "dwars_epex"
LOGGER = logging.getLogger(__package__)

API_URL = "https://ems.dwarsenergie.nl/dayahead.php?range=2"

# Zelfde interval als je command_line sensor: 3600 sec
SCAN_INTERVAL = timedelta(hours=1)

