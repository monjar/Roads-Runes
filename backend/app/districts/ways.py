"""The honest % (0.9.0): a district's tiles with a road or path in them, fetched once
per district from Overpass when a journey first enters it (job `districts_fetch_ways`).

Every `way[highway]` in the bbox of the district's tiles is fetched, except
motorways and trunk roads (and their links) and private ways; each is turned into
the tiles it passes (sampled every 50 m) and only the district's own tiles are
kept. Until that has succeeded the district shows a count of tiles, never a %.
A failed fetch is tried again after RETRY_AFTER, on a later journey.
"""

from __future__ import annotations

import uuid
from collections.abc import Awaitable, Callable
from datetime import timedelta
from typing import Any

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.core.logging import get_logger
from app.core.security import utcnow
from app.districts import geo
from app.districts.models import Region, UserRegion
from app.districts.service import catchment, refresh_places, user_cells_among

log = get_logger(__name__)

BBox = tuple[float, float, float, float]
Way = list[tuple[float, float]]
WaysFetcher = Callable[[BBox], Awaitable[list[Way]]]
RETRY_AFTER = timedelta(hours=1)
EXCLUDED = ("motorway", "trunk", "motorway_link", "trunk_link")
USER_AGENT = "RoadsAndRunes-backend/0.1"


def ways_query(bbox: BBox) -> str:
    south, west, north, east = bbox
    return f"""[out:json][timeout:60][bbox:{south},{west},{north},{east}];
way[highway][highway!~"^({"|".join(EXCLUDED)})$"][access!=private];
out geom;"""


def parse_ways(elements: list[dict[str, Any]]) -> list[Way]:
    out: list[Way] = []
    for element in elements:
        tags = element.get("tags") or {}
        if element.get("type") != "way" or not tags.get("highway"):
            continue
        if tags["highway"] in EXCLUDED or tags.get("access") == "private":
            continue
        geometry = [(float(p["lat"]), float(p["lon"])) for p in element.get("geometry") or [] if "lat" in p]
        if geometry:
            out.append(geometry)
    return out


def overpass_ways_fetcher(settings: Settings) -> WaysFetcher:
    urls = [u.strip() for u in settings.overpass_urls.split(",") if u.strip()]

    async def fetch(bbox: BBox) -> list[Way]:
        query = ways_query(bbox)
        failure = "no Overpass endpoint configured"
        async with httpx.AsyncClient(timeout=90.0, headers={"User-Agent": USER_AGENT}) as client:
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
                if not payload.get("elements") and payload.get("remark"):
                    failure = f"{url}: {str(payload['remark'])[:120]}"
                    continue
                return parse_ways(payload.get("elements", []))
        raise RuntimeError(failure)

    return fetch


def due(region: Region) -> bool:
    """Not fetched yet, and not tried in the last hour."""
    if region.way_cells is not None:
        return False
    return region.way_cells_fetched_at is None or utcnow() - region.way_cells_fetched_at > RETRY_AFTER


async def fetch_ways(
    db: AsyncSession, settings: Settings, region_id: uuid.UUID, *, fetch: WaysFetcher | None = None
) -> int | None:
    """Fetches a district's ways once and stores its way tiles; brings every player's
    count of them up to date, and its title. Returns how many way tiles it has, or
    None when there was nothing to do or the fetch failed (tried again later)."""
    region = await db.get(Region, region_id)
    if region is None or not due(region):
        return None
    resolution = settings.h3_resolution
    tiles = await catchment(db, region, resolution)
    box = geo.bbox(tiles)
    if box is None:
        return None
    fetch = fetch or overpass_ways_fetcher(settings)
    try:
        ways = await fetch(box)
    except Exception as exc:  # noqa: BLE001 - tried again on a later journey
        log.warning("district_ways_failed", region=str(region_id), error=str(exc)[:200])
        region.way_cells_fetched_at = utcnow()
        await db.flush()
        return None
    cells = geo.way_cells_along(ways, resolution) & tiles
    region.way_cells = sorted(cells)
    region.way_cells_fetched_at = utcnow()
    for row in (await db.execute(select(UserRegion).where(UserRegion.region_id == region.id))).scalars():
        have = await user_cells_among(db, row.user_id, tiles)
        row.explored_cells = max(row.explored_cells or 0, len(have))
        row.way_cells_explored = max(row.way_cells_explored or 0, len(have & cells))
    # More of the map may be imported now than when it was first entered.
    await refresh_places(db, region, tiles, resolution)
    await db.flush()
    log.info("district_ways_done", region=str(region_id), name=region.name, way_tiles=len(cells))
    return len(cells)


async def due_for(db: AsyncSession, region_ids: list[str]) -> list[str]:
    """Of these districts, the ones whose ways should be fetched now."""
    ids = []
    for rid in region_ids:
        try:
            ids.append(uuid.UUID(str(rid)))
        except ValueError:
            continue
    if not ids:
        return []
    rows = (await db.execute(select(Region).where(Region.id.in_(ids)))).scalars()
    return [str(r.id) for r in rows if due(r)]
