"""Turning a place name in a ride request into a point on the map.

"A ride in Notting Hill with about 5 pubs" only works if `Notting Hill` becomes
coordinates. Photon answers first (it takes a plain lat/lon bias, which keeps
`Notting Hill` in London rather than Melbourne); Nominatim is the fallback, with
a bounded viewbox around the rider. Both are OpenStreetMap services under the
same fair-use expectations as Overpass: a real User-Agent, small queries, and a
cache so the same phrase is asked once.

A phrase that resolves to nothing is not a place — the parser guesses candidate
phrases loosely on purpose and lets this module be the judge.

Two kinds of answer, because a rider means two different things:

* `AREA` — somewhere to ride *in*. A neighbourhood, a park, a village. The whole
  ride moves there, so a wrong answer wastes the ride: only the OSM keys that
  describe a piece of ground qualify.
* `POINT` — something to ride *to*. A tower, a bridge, a pub, a station. Almost
  anything named qualifies, so the guard is the name instead: the answer has to
  be called what the rider called it.
"""

from __future__ import annotations

import math
import re
import time
from dataclasses import dataclass
from typing import Any, Literal

import httpx

from app.core.config import Settings
from app.core.logging import get_logger

log = get_logger(__name__)

USER_AGENT = "RoadsAndRunes-backend/0.1 (https://roadsandrunes.fly.dev)"
CACHE_TTL_SECONDS = 24 * 3600
SEARCH_RADIUS_KM = 60.0
TIMEOUT_SECONDS = 8.0

Kind = Literal["area", "point"]

# Only answers that are somewhere to ride: a neighbourhood, a park, a village.
# Without this, a loose phrase like "quiet" matches a shop or a street name.
PLACE_KEYS = {"place", "boundary", "leisure", "natural", "landuse", "tourism"}
NOMINATIM_PLACE_CATEGORIES = PLACE_KEYS | {"amenity"}

# Something a rider can ride *to* and know they have arrived: a building with a
# name, a tower, a bridge, a pier, a pub, a station. Streets are deliberately
# absent — "go to Aragon Tower" means the tower, and a road of the same name
# would put the finish line anywhere along a kilometre of tarmac.
POINT_KEYS = PLACE_KEYS | {
    "amenity",
    "building",
    "man_made",
    "historic",
    "shop",
    "railway",
    "aeroway",
    "bridge",
    "waterway",
    "aerialway",
    "office",
    "club",
    "craft",
    "military",
    "attraction",
}

# Words that carry no identity, so they neither have to match nor count against one.
FILLER = {"the", "a", "an", "of", "at", "in", "on", "to", "st", "saint"}

_cache: dict[str, tuple[float, Area | None]] = {}


@dataclass(frozen=True)
class Area:
    name: str
    latitude: float
    longitude: float

    def to_dict(self) -> dict[str, Any]:
        return {"name": self.name, "latitude": self.latitude, "longitude": self.longitude}


def _words(text: str) -> list[str]:
    return [w for w in re.findall(r"[a-z0-9'’]+", text.lower()) if w not in FILLER]


def _is_named(query: str, candidate: str | None) -> bool:
    """Is this answer called what the rider called it?

    The phrase handed in is a guess pulled out of a sentence, and a point search
    will answer almost anything — ask Photon for "the way home" near London and
    it will find a shop. Requiring the words back is what separates "Aragon
    Tower" from a lucky match on a sentence fragment.
    """
    wanted, got = _words(query), _words(candidate or "")
    if not wanted or not got:
        return False
    matched = sum(1 for word in wanted if any(word == g or (len(word) > 4 and word in g) for g in got))
    return matched >= max(1, len(wanted) - (1 if len(wanted) > 2 else 0))


async def resolve(
    settings: Settings,
    query: str,
    near_lat: float,
    near_lon: float,
    transport: httpx.AsyncBaseTransport | None = None,
    kind: Kind = "area",
) -> Area | None:
    """The place a rider named, or None if the phrase was not a place after all."""
    phrase = " ".join(query.split()).strip(" ,.")
    if not settings.geocoding_enabled or len(phrase) < 3:
        return None
    key = f"{kind}|{phrase.lower()}|{round(near_lat, 1)},{round(near_lon, 1)}"
    hit = _cache.get(key)
    if hit and time.time() - hit[0] < CACHE_TTL_SECONDS:
        return hit[1]

    area = None
    async with httpx.AsyncClient(
        timeout=TIMEOUT_SECONDS, headers={"User-Agent": USER_AGENT}, transport=transport
    ) as client:
        for lookup in (_photon, _nominatim):
            try:
                area = await lookup(client, settings, phrase, near_lat, near_lon, kind)
            except (httpx.HTTPError, ValueError, KeyError, IndexError, TypeError) as exc:
                log.warning("geocode_failed", service=lookup.__name__, query=phrase[:60], error=str(exc)[:120])
                continue
            if area is not None:
                break
    _cache[key] = (time.time(), area)
    return area


async def _photon(
    client: httpx.AsyncClient, settings: Settings, phrase: str, lat: float, lon: float, kind: Kind
) -> Area | None:
    response = await client.get(settings.photon_url, params={"q": phrase, "limit": 8, "lat": lat, "lon": lon})
    if response.status_code != 200:
        return None
    keys = POINT_KEYS if kind == "point" else PLACE_KEYS
    for feature in response.json().get("features", []):
        properties = feature.get("properties", {})
        if properties.get("osm_key") not in keys:
            continue
        name = properties.get("name")
        if kind == "point" and not _is_named(phrase, name):
            continue
        longitude, latitude = feature["geometry"]["coordinates"][:2]
        if _within_reach(lat, lon, latitude, longitude):
            return Area(str(name or phrase), float(latitude), float(longitude))
    return None


async def _nominatim(
    client: httpx.AsyncClient, settings: Settings, phrase: str, lat: float, lon: float, kind: Kind
) -> Area | None:
    # A bounded viewbox keeps the answer near the rider; Nominatim has no lat/lon bias.
    span = SEARCH_RADIUS_KM / 111.0
    response = await client.get(
        settings.nominatim_url,
        params={
            "q": phrase,
            "format": "jsonv2",
            "limit": 5 if kind == "point" else 3,
            "bounded": 1,
            "viewbox": f"{lon - span * 1.6},{lat + span},{lon + span * 1.6},{lat - span}",
        },
    )
    if response.status_code != 200:
        return None
    rows = response.json()
    if not isinstance(rows, list):  # an error envelope, not results
        return None
    categories = POINT_KEYS if kind == "point" else NOMINATIM_PLACE_CATEGORIES
    for row in rows:
        if row.get("category") and row["category"] not in categories:
            continue
        name = str(row.get("name") or row.get("display_name", phrase)).split(",")[0]
        if kind == "point" and not _is_named(phrase, name):
            continue
        latitude, longitude = float(row["lat"]), float(row["lon"])
        if _within_reach(lat, lon, latitude, longitude):
            return Area(name, latitude, longitude)
    return None


def _within_reach(from_lat: float, from_lon: float, lat: float, lon: float) -> bool:
    """Keep answers a rider could plausibly ride to; a same-named place abroad is not one."""
    dlat = (lat - from_lat) * 111.0
    dlon = (lon - from_lon) * 111.0 * math.cos(math.radians(from_lat))
    return math.hypot(dlat, dlon) <= SEARCH_RADIUS_KM


def clear_cache() -> None:
    _cache.clear()
