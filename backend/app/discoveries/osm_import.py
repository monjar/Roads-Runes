"""Discoveries from OpenStreetMap, imported per area the first time it is used.

Quests and route stops are built from Discovery rows. Rather than importing
the planet, the world is split into 0.1° tiles, and a tile's places
(viewpoints, parks, castles, museums, cafés, pubs, bike shops) are fetched
from Overpass the first time a rider generates quests or plans a ride there.
The tile is recorded in `poi_import_areas` so it is fetched once; a failed
fetch is retried after RETRY_AFTER. Overpass is a shared public service, so
each query is small and capped and the configured mirrors are tried in turn.
"""

from __future__ import annotations

import asyncio
import math
from collections.abc import Awaitable, Callable, Coroutine
from datetime import timedelta
from typing import Any

import httpx
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.core.config import Settings
from app.core.geo import haversine_m
from app.core.logging import get_logger
from app.core.security import utcnow
from app.db.session import get_session_factory
from app.discoveries.models import Discovery, PoiImportArea
from app.exploration.cells import cell_for

log = get_logger(__name__)

TILES_PER_DEGREE = 10
# Part of every tile key. Bump it when the query learns a new kind of place, and
# tiles imported under the old query are read again on the next visit; `store`
# skips what is already known, so the second pass only adds the new kinds.
TILE_VERSION = "v2"
RETRY_AFTER = timedelta(minutes=15)
# Quest generation waits this long for the tile the rider is in; the import carries on after.
FIRST_TILE_WAIT_SECONDS = 15.0
# A ride to a place crosses tiles the rider has never stood in; sample the leg this often.
CORRIDOR_SAMPLE_M = 8000.0
USER_AGENT = "RoadsAndRunes-backend/0.1"
# What kind of place it is, and what little OpenStreetMap says about how good it
# is: a café with a website, opening hours and no brand is somebody's café, and a
# `wikidata` entry means the world considers it worth an article.
KEEP_TAGS = (
    "tourism",
    "historic",
    "leisure",
    "natural",
    "amenity",
    "shop",
    "water",
    "waterway",
    "wikidata",
    "wikipedia",
    "website",
    "opening_hours",
    "brand",
    "cuisine",
    "outdoor_seating",
    "stars",
    "route",
)

BBox = tuple[float, float, float, float]  # (south, west, north, east)
Fetcher = Callable[[BBox], Awaitable[list[dict[str, Any]]]]

_running: dict[str, asyncio.Task[int]] = {}
_background: set[asyncio.Task[None]] = set()


def tile_key(lat: float, lon: float) -> str:
    return f"{TILE_VERSION}:{math.floor(lat * TILES_PER_DEGREE)}:{math.floor(lon * TILES_PER_DEGREE)}"


def tile_bbox(key: str) -> BBox:
    row, col = (int(part) for part in key.split(":")[-2:])
    step = 1 / TILES_PER_DEGREE
    return (
        max(-90.0, round(row * step, 6)),
        max(-180.0, round(col * step, 6)),
        min(90.0, round((row + 1) * step, 6)),
        min(180.0, round((col + 1) * step, 6)),
    )


def tiles_around(lat: float, lon: float) -> list[str]:
    """The tile under the point first, then its eight neighbours."""
    row, col = math.floor(lat * TILES_PER_DEGREE), math.floor(lon * TILES_PER_DEGREE)
    ring = [(dr, dc) for dr in (-1, 0, 1) for dc in (-1, 0, 1) if (dr, dc) != (0, 0)]
    return [f"{TILE_VERSION}:{row}:{col}", *(f"{TILE_VERSION}:{row + dr}:{col + dc}" for dr, dc in ring)]


def tiles_along(lat1: float, lon1: float, lat2: float, lon2: float, *, every_m: float = CORRIDOR_SAMPLE_M) -> list[str]:
    """The tiles a straight leg crosses: both ends and a sample every `every_m`, in order."""
    steps = max(1, math.ceil(haversine_m(lat1, lon1, lat2, lon2) / every_m))
    keys: list[str] = []
    for i in range(steps + 1):
        fraction = i / steps
        key = tile_key(lat1 + (lat2 - lat1) * fraction, lon1 + (lon2 - lon1) * fraction)
        if key not in keys:
            keys.append(key)
    return keys


def overpass_query(bbox: BBox) -> str:
    """Named sights and nature, then cafés, pubs and bike shops, each set capped separately
    so a city's hundreds of cafés cannot crowd out its parks."""
    south, west, north, east = bbox
    return f"""[out:json][timeout:25][bbox:{south},{west},{north},{east}];
(
  node[tourism~"^(viewpoint|attraction|museum|artwork|picnic_site)$"][name];
  way[tourism~"^(viewpoint|attraction|museum)$"][name];
  node[historic~"^(castle|monument|memorial|ruins|ship|fort|archaeological_site|manor)$"][name];
  way[historic~"^(castle|ruins|fort|manor)$"][name];
  way[leisure~"^(park|nature_reserve|garden)$"][name];
  relation[leisure~"^(park|nature_reserve)$"][name];
  node[natural~"^(peak|spring|beach|cave_entrance)$"][name];
  way[natural~"^(water|beach)$"][name];
)->.sights;
.sights out center tags 250;
(
  node[amenity~"^(cafe|pub|biergarten)$"][name];
  node[shop=bicycle][name];
)->.stops;
.stops out center tags 120;
(
  node[amenity~"^(restaurant|fast_food|food_court|ice_cream)$"][name];
  node[shop~"^(bakery|deli)$"][name];
)->.food;
.food out center tags 120;
(
  way[highway~"^(path|track|bridleway)$"][name];
  relation[route~"^(bicycle|mtb|hiking|foot)$"][name];
)->.trails;
.trails out center tags 120;"""


def category_for(tags: dict[str, str]) -> str | None:
    tourism, amenity = tags.get("tourism"), tags.get("amenity")
    if tourism == "viewpoint" or tags.get("natural") == "peak":
        return "VIEWPOINT"
    if tags.get("historic"):
        return "HISTORICAL"
    if tourism in ("museum", "artwork"):
        return "CULTURAL"
    if tourism == "attraction":
        return "LANDMARK"
    if tags.get("leisure") in ("park", "nature_reserve", "garden") or tags.get("natural") or tourism == "picnic_site":
        return "NATURE"
    if amenity == "cafe":
        return "CAFE"
    if amenity in ("pub", "biergarten"):
        return "PUB"
    if amenity in ("restaurant", "fast_food", "food_court", "ice_cream") or tags.get("shop") in ("bakery", "deli"):
        return "FOOD"
    if tags.get("shop") == "bicycle":
        return "CYCLING"
    if tags.get("route") in ("bicycle", "mtb", "hiking", "foot") or tags.get("highway") in (
        "path",
        "track",
        "bridleway",
    ):
        return "TRAIL"
    return None


def parse_elements(elements: list[dict[str, Any]], resolution: int) -> list[dict[str, Any]]:
    """Overpass elements as Discovery fields; unnamed or unsupported places are dropped."""
    places = []
    trails_seen: set[str] = set()
    for element in elements:
        tags = element.get("tags") or {}
        name = str(tags.get("name", "")).strip()
        category = category_for(tags)
        if not name or category is None:
            continue
        if category == "TRAIL":
            # A named path is dozens of OSM ways; the rider wants the path once.
            if name.lower() in trails_seen:
                continue
            trails_seen.add(name.lower())
        if "lat" in element:
            lat, lon = float(element["lat"]), float(element["lon"])
        elif "center" in element:
            lat, lon = float(element["center"]["lat"]), float(element["center"]["lon"])
        else:
            continue
        places.append(
            {
                "osm_id": f"{str(element.get('type', 'n'))[0]}{element['id']}",
                "name": name[:160],
                "category": category,
                "latitude": lat,
                "longitude": lon,
                "description": (str(tags["description"])[:2000] if tags.get("description") else None),
                "tags": {k: tags[k] for k in KEEP_TAGS if k in tags},
                "h3_index": cell_for(lat, lon, resolution),
            }
        )
    return places


async def store(db: AsyncSession, places: list[dict[str, Any]]) -> int:
    """Adds the places not already known by OSM id; returns how many were new."""
    ids = list({p["osm_id"] for p in places})
    known: set[str] = set()
    for start in range(0, len(ids), 500):
        chunk = ids[start : start + 500]
        known.update(
            o for o in (await db.execute(select(Discovery.osm_id).where(Discovery.osm_id.in_(chunk)))).scalars() if o
        )
    added = 0
    for place in places:
        if place["osm_id"] in known:
            continue
        known.add(place["osm_id"])
        db.add(Discovery(source="OSM", moderation_status="APPROVED", cycling_accessible=True, **place))
        added += 1
    await db.flush()
    return added


async def import_tile(db: AsyncSession, key: str, fetch: Fetcher, resolution: int) -> int:
    """Fetches and stores one tile's places and records the attempt; the caller commits."""
    try:
        added = await store(db, parse_elements(await fetch(tile_bbox(key)), resolution))
        status = "OK"
    except Exception as exc:  # noqa: BLE001 - a failed area is retried later, never fatal
        await db.rollback()
        log.warning("poi_import_failed", tile=key, error=str(exc)[:200])
        added, status = 0, "FAILED"
    area = await db.get(PoiImportArea, key)
    if area is None:
        area = PoiImportArea(key=key)
        db.add(area)
    area.status, area.poi_count, area.imported_at = status, added, utcnow()
    await db.flush()
    log.info("poi_import_done", tile=key, status=status, added=added)
    return added


async def due_tiles(db: AsyncSession, keys: list[str]) -> list[str]:
    """Tiles never imported, or whose last attempt failed more than RETRY_AFTER ago."""
    cutoff = utcnow() - RETRY_AFTER
    fresh = set(
        (
            await db.execute(
                select(PoiImportArea.key).where(
                    PoiImportArea.key.in_(keys),
                    or_(PoiImportArea.status == "OK", PoiImportArea.imported_at > cutoff),
                )
            )
        ).scalars()
    )
    return [k for k in keys if k not in fresh]


async def ensure_pois(
    settings: Settings,
    latitude: float,
    longitude: float,
    *,
    wait: bool = True,
    fetch: Fetcher | None = None,
    session_factory: async_sessionmaker[AsyncSession] | None = None,
) -> None:
    """Imports the places around a point if the area is new.

    With `wait`, the tile under the point is awaited for up to
    FIRST_TILE_WAIT_SECONDS (quest generation needs it); the eight neighbours
    follow in the background, one at a time.
    """
    if not settings.poi_import_enabled:
        return
    factory = session_factory or get_session_factory()
    fetch = fetch or overpass_fetcher(settings)
    keys = tiles_around(latitude, longitude)
    async with factory() as db:
        due = await due_tiles(db, keys)
    if not due:
        return
    first = _start(keys[0], factory, fetch, settings.h3_resolution) if keys[0] in due else _running.get(keys[0])
    rest = [k for k in due if k != keys[0]]
    if rest:
        _in_background(_import_in_turn(rest, first, factory, fetch, settings.h3_resolution))
    if wait and first is not None:
        try:
            await asyncio.wait_for(asyncio.shield(first), FIRST_TILE_WAIT_SECONDS)
        except TimeoutError:
            log.info("poi_import_still_running", tile=keys[0])


async def ensure_pois_along(
    settings: Settings,
    lat1: float,
    lon1: float,
    lat2: float,
    lon2: float,
    *,
    budget_s: float = 25.0,
    fetch: Fetcher | None = None,
    session_factory: async_sessionmaker[AsyncSession] | None = None,
) -> None:
    """Imports the tiles a leg crosses, one after another, for up to `budget_s`.

    Called when a ride to a place asked for stops and too few were found: the
    middle of a 20 km ride is usually somewhere the rider has never planned from.
    Tiles already imported cost nothing; whatever the budget does not cover carries
    on in the background for the next plan.
    """
    if not settings.poi_import_enabled:
        return
    factory = session_factory or get_session_factory()
    fetch = fetch or overpass_fetcher(settings)
    keys = tiles_along(lat1, lon1, lat2, lon2)
    async with factory() as db:
        due = await due_tiles(db, keys)
    deadline = asyncio.get_running_loop().time() + budget_s
    for index, key in enumerate(due):
        task = _start(key, factory, fetch, settings.h3_resolution)
        remaining = deadline - asyncio.get_running_loop().time()
        try:
            if remaining <= 0:
                raise TimeoutError
            await asyncio.wait_for(asyncio.shield(task), remaining)
        except TimeoutError:
            log.info("poi_corridor_import_timeout", tile=key, remaining=len(due) - index - 1)
            rest = due[index + 1 :]
            if rest:
                _in_background(_import_in_turn(rest, task, factory, fetch, settings.h3_resolution))
            return


async def drain() -> None:
    """Waits for the imports in flight (tests, shutdown)."""
    while _background or _running:
        await asyncio.gather(*_background, *_running.values(), return_exceptions=True)
        await asyncio.sleep(0)


def cancel_all() -> None:
    """Stops the imports in flight (shutdown); their tiles are fetched again later."""
    for task in [*_background, *_running.values()]:
        task.cancel()


def overpass_fetcher(settings: Settings) -> Fetcher:
    urls = [u.strip() for u in settings.overpass_urls.split(",") if u.strip()]

    async def fetch(bbox: BBox) -> list[dict[str, Any]]:
        query = overpass_query(bbox)
        failure = "no Overpass endpoint configured"
        async with httpx.AsyncClient(timeout=40.0, headers={"User-Agent": USER_AGENT}) as client:
            for url in urls:
                try:
                    response = await client.post(url, data={"data": query})
                    payload = response.json() if response.status_code == 200 else None
                except (httpx.HTTPError, ValueError) as exc:
                    failure = f"{url}: {exc}"
                    continue
                if payload is None:
                    failure = f"{url}: HTTP {response.status_code}"
                    continue
                elements = payload.get("elements", [])
                if not elements and payload.get("remark"):  # e.g. "runtime error: Query timed out"
                    failure = f"{url}: {str(payload['remark'])[:120]}"
                    continue
                return elements
        raise RuntimeError(failure)

    return fetch


def _start(key: str, factory: async_sessionmaker[AsyncSession], fetch: Fetcher, resolution: int) -> asyncio.Task[int]:
    task = _running.get(key)
    if task is None or task.done():
        task = asyncio.create_task(_run_tile(key, factory, fetch, resolution))
        _running[key] = task
        task.add_done_callback(lambda t, k=key: _running.pop(k) if _running.get(k) is t else None)
    return task


async def _run_tile(key: str, factory: async_sessionmaker[AsyncSession], fetch: Fetcher, resolution: int) -> int:
    async with factory() as db:
        if not await due_tiles(db, [key]):  # another request imported it meanwhile
            return 0
        added = await import_tile(db, key, fetch, resolution)
        await db.commit()
        return added


async def _import_in_turn(
    keys: list[str],
    first: asyncio.Task[int] | None,
    factory: async_sessionmaker[AsyncSession],
    fetch: Fetcher,
    resolution: int,
) -> None:
    if first is not None:
        await asyncio.wait([first])  # the neighbours queue behind the tile the rider is in
    for key in keys:
        try:
            await _start(key, factory, fetch, resolution)
        except Exception as exc:  # noqa: BLE001
            log.warning("poi_import_failed", tile=key, error=str(exc)[:200])


def _in_background(coro: Coroutine[Any, Any, None]) -> None:
    task = asyncio.create_task(coro)
    _background.add(task)
    task.add_done_callback(_background.discard)
