"""Turning a place name in a ride request into a point on the map.

"A ride in Notting Hill with about 5 pubs" only works if `Notting Hill` becomes
coordinates. Photon answers first (it takes a plain lat/lon bias, which keeps
`Notting Hill` in London rather than Melbourne); Nominatim is the fallback, with
a bounded viewbox around the rider. Both are OpenStreetMap services under the
same fair-use expectations as Overpass: a real User-Agent, small queries, and a
cache so the same phrase is asked once.

A phrase that resolves to nothing is not a place — the parser guesses candidate
phrases loosely on purpose and lets this module be the judge.
"""

from __future__ import annotations

import math
import time
from dataclasses import dataclass
from typing import Any

import httpx

from app.core.config import Settings
from app.core.logging import get_logger

log = get_logger(__name__)

USER_AGENT = "RoadsAndRunes-backend/0.1 (https://roadsandrunes.fly.dev)"
CACHE_TTL_SECONDS = 24 * 3600
SEARCH_RADIUS_KM = 60.0
TIMEOUT_SECONDS = 8.0

_cache: dict[str, tuple[float, Area | None]] = {}


@dataclass(frozen=True)
class Area:
    name: str
    latitude: float
    longitude: float

    def to_dict(self) -> dict[str, Any]:
        return {"name": self.name, "latitude": self.latitude, "longitude": self.longitude}


async def resolve(
    settings: Settings,
    query: str,
    near_lat: float,
    near_lon: float,
    transport: httpx.AsyncBaseTransport | None = None,
) -> Area | None:
    """The place a rider named, or None if the phrase was not a place after all."""
    phrase = " ".join(query.split()).strip(" ,.")
    if not settings.geocoding_enabled or len(phrase) < 3:
        return None
    key = f"{phrase.lower()}|{round(near_lat, 1)},{round(near_lon, 1)}"
    hit = _cache.get(key)
    if hit and time.time() - hit[0] < CACHE_TTL_SECONDS:
        return hit[1]

    area = None
    async with httpx.AsyncClient(
        timeout=TIMEOUT_SECONDS, headers={"User-Agent": USER_AGENT}, transport=transport
    ) as client:
        for lookup in (_photon, _nominatim):
            try:
                area = await lookup(client, settings, phrase, near_lat, near_lon)
            except (httpx.HTTPError, ValueError, KeyError, IndexError, TypeError) as exc:
                log.warning("geocode_failed", service=lookup.__name__, query=phrase[:60], error=str(exc)[:120])
                continue
            if area is not None:
                break
    _cache[key] = (time.time(), area)
    return area


async def _photon(client: httpx.AsyncClient, settings: Settings, phrase: str, lat: float, lon: float) -> Area | None:
    response = await client.get(settings.photon_url, params={"q": phrase, "limit": 5, "lat": lat, "lon": lon})
    if response.status_code != 200:
        return None
    for feature in response.json().get("features", []):
        properties = feature.get("properties", {})
        longitude, latitude = feature["geometry"]["coordinates"][:2]
        if _within_reach(lat, lon, latitude, longitude):
            return Area(str(properties.get("name") or phrase), float(latitude), float(longitude))
    return None


async def _nominatim(client: httpx.AsyncClient, settings: Settings, phrase: str, lat: float, lon: float) -> Area | None:
    # A bounded viewbox keeps the answer near the rider; Nominatim has no lat/lon bias.
    span = SEARCH_RADIUS_KM / 111.0
    response = await client.get(
        settings.nominatim_url,
        params={
            "q": phrase,
            "format": "jsonv2",
            "limit": 3,
            "bounded": 1,
            "viewbox": f"{lon - span * 1.6},{lat + span},{lon + span * 1.6},{lat - span}",
        },
    )
    if response.status_code != 200:
        return None
    rows = response.json()
    if not isinstance(rows, list):  # an error envelope, not results
        return None
    for row in rows:
        latitude, longitude = float(row["lat"]), float(row["lon"])
        if _within_reach(lat, lon, latitude, longitude):
            name = str(row.get("name") or row.get("display_name", phrase)).split(",")[0]
            return Area(name, latitude, longitude)
    return None


def _within_reach(from_lat: float, from_lon: float, lat: float, lon: float) -> bool:
    """Keep answers a rider could plausibly ride to; a same-named place abroad is not one."""
    dlat = (lat - from_lat) * 111.0
    dlon = (lon - from_lon) * 111.0 * math.cos(math.radians(from_lat))
    return math.hypot(dlat, dlon) <= SEARCH_RADIUS_KM


def clear_cache() -> None:
    _cache.clear()
