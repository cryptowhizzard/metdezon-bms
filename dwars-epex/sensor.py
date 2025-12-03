from __future__ import annotations

from typing import Any

import async_timeout

from homeassistant.components.sensor import SensorEntity
from homeassistant.core import HomeAssistant
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.entity import DeviceInfo
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.helpers.typing import ConfigType, DiscoveryInfoType
from homeassistant.helpers.update_coordinator import (
    CoordinatorEntity,
    DataUpdateCoordinator,
)

from .const import API_URL, DOMAIN, LOGGER, SCAN_INTERVAL


async def async_setup_platform(
    hass: HomeAssistant,
    config: ConfigType,
    async_add_entities: AddEntitiesCallback,
    discovery_info: DiscoveryInfoType | None = None,
) -> None:
    """Set up the Dwars EPEX sensors from YAML."""
    coordinator = DwarsEpexCoordinator(hass)

    # Eerste fetch zodat we data hebben bij het toevoegen
    await coordinator.async_refresh()
    if not coordinator.last_update_success:
        LOGGER.warning("Dwars EPEX: initial fetch failed, sensor will update later")

    async_add_entities(
        [DwarsEpexAveragePriceSensor(coordinator)],
        update_before_add=False,
    )


class DwarsEpexCoordinator(DataUpdateCoordinator[dict[str, Any] | None]):
    """Coordinator die de API van dwarsenergie.nl ophaalt."""

    def __init__(self, hass: HomeAssistant) -> None:
        """Initialiseer de coordinator."""
        super().__init__(
            hass,
            LOGGER,
            name="Dwars EPEX day-ahead prices",
            update_interval=SCAN_INTERVAL,
        )
        self._session = async_get_clientsession(hass)

    async def _async_update_data(self) -> dict[str, Any] | None:
        """Haal data op van de API."""
        LOGGER.debug("Dwars EPEX: fetching data from %s", API_URL)

        async with async_timeout.timeout(10):
            response = await self._session.get(API_URL)
            response.raise_for_status()
            data = await response.json()

        LOGGER.debug("Dwars EPEX: received data %s", data)
        return data


class DwarsEpexAveragePriceSensor(CoordinatorEntity, SensorEntity):
    """Representatie van de gemiddelde day-ahead prijs NL."""

    _attr_name = "Day Ahead Price NL"
    _attr_icon = "mdi:flash"
    _attr_native_unit_of_measurement = "€/kWh"

    def __init__(self, coordinator: DwarsEpexCoordinator) -> None:
        """Initialiseer de sensor."""
        super().__init__(coordinator)
        self._attr_unique_id = "dwars_epex_day_ahead_price_nl"

    @property
    def native_value(self) -> float | None:
        """Return de gemiddelde prijs (avg)."""
        data = self.coordinator.data or {}
        try:
            return float(data.get("avg"))
        except (TypeError, ValueError):
            return None

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        """Geeft dezelfde extra attributen als je command_line sensor."""
        data = self.coordinator.data or {}
        attrs: dict[str, Any] = {}

        for key in ("date", "prices", "timestamps", "count", "data"):
            if key in data:
                attrs[key] = data[key]

        return attrs

    @property
    def device_info(self) -> DeviceInfo:
        """Groepering in het apparaat-overzicht."""
        return DeviceInfo(
            identifiers={(DOMAIN, "dwars_epex")},
            name="Dwars EPEX",
            manufacturer="dwarsenergie.nl",
        )

