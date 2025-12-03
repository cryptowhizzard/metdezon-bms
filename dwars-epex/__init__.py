from __future__ import annotations

from homeassistant.core import HomeAssistant
from homeassistant.helpers.typing import ConfigType

from .const import DOMAIN, LOGGER


async def async_setup(hass: HomeAssistant, config: ConfigType) -> bool:
    """Set up the Dwars EPEX integration from YAML."""
    LOGGER.debug("Setting up Dwars EPEX via YAML")
    # Niks speciaals nodig, sensor-platform regelt de rest.
    return True

