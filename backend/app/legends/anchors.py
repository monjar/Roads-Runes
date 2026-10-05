"""Where a legend lives (docs/ROADMAP.md 0.8.0): somewhere 2 to 8 km from where the
player usually starts, that the routing engine can reach for how they move, and
never at a sensitive place.

* The Fog Dragon: the H3 tiles in that ring the player has not explored, grouped
  into connected blocks. It lies at the edge of the biggest block: the block's
  tile next to explored ground that is nearest the block's middle.
* The others: a real place from the places already known, by its kind and tags
  (legends.json `home`): water with a trail within 200 m, the highest viewpoint
  (by its `ele` tag, else any viewpoint), a trail (a named route first), an old place.

The grouping and ordering are pure; only the reads and the reach test touch the
database and the engine.
"""

from __future__ import annotations

import uuid
from collections.abc import Iterable
from dataclasses import dataclass
from typing import Any

import h3
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.activity import is_foot, normalise
from app.core.geo import haversine_m
from app.core.logging import get_logger
from app.discoveries.sensitivity import is_sensitive
from app.discoveries.service import nearby
from app.exploration.cells import cell_center, cells_in_radius
from app.exploration.service import known_cells
from app.legends import catalog
from app.routing.engine import EngineRequest, RoutingEngine

log = get_logger(__name__)

# A legend moved once does not come back to the same spot.
MOVE_AWAY_M = 500.0
# Nothing sensitive this near a tile's middle, for the Fog Dragon.
FOG_CLEAR_M = 120.0
# A Fog Dragon is named after the nearest ordinary place this near it.
FOG_NAME_M = 400.0
PLACE_LIMIT = 2000


@dataclass
class Budget:
    """How many more reach tests one waking may ask the engine for, across legends."""

    left: int


@dataclass(frozen=True)
class Spot:
    latitude: float
    longitude: float
    name: str | None = None
    discovery_id: str | None = None


# --- the fog, pure ---------------------------------------------------------------


def ring_cells(centre: tuple[float, float], resolution: int) -> set[str]:
    """Tiles whose middle lies within the ring round the centre."""
    low, high = (float(m) for m in catalog.book()["ringMeters"])
    return {
        c
        for c in cells_in_radius(centre[0], centre[1], high, resolution)
        if haversine_m(centre[0], centre[1], *cell_center(c)) >= low
    }


def blocks(cells: set[str]) -> list[set[str]]:
    """The connected blocks a set of tiles makes, biggest first (ties by a stable key)."""
    left = set(cells)
    out: list[set[str]] = []
    while left:
        seed = min(left)
        block = {seed}
        frontier = [seed]
        left.discard(seed)
        while frontier:
            here = frontier.pop()
            for n in h3.grid_disk(here, 1):
                if n in left:
                    left.discard(n)
                    block.add(n)
                    frontier.append(n)
        out.append(block)
    return sorted(out, key=lambda b: (-len(b), min(b)))


def middle(block: Iterable[str]) -> tuple[float, float]:
    centres = [cell_center(c) for c in block]
    return sum(c[0] for c in centres) / len(centres), sum(c[1] for c in centres) / len(centres)


def fog_candidates(ring: set[str], explored: set[str]) -> list[str]:
    """Where the Fog Dragon may lie, best first: the biggest unexplored block's tiles
    next to explored ground, nearest its middle first; then the rest of that block's
    tiles, nearest the middle first (a block with no explored ground beside it)."""
    fog = {c for c in ring if c not in explored}
    found = blocks(fog)
    if not found:
        return []
    biggest = found[0]
    mid = middle(biggest)

    def near_mid(c: str) -> float:
        return haversine_m(mid[0], mid[1], *cell_center(c))

    edge = sorted((c for c in biggest if any(n in explored for n in h3.grid_disk(c, 1) if n != c)), key=near_mid)
    rest = sorted((c for c in biggest if c not in set(edge)), key=near_mid)
    return edge + rest


# --- places, pure ----------------------------------------------------------------


def _tag_match(spec: dict[str, list[str]], tags: dict[str, Any]) -> bool:
    for key, wanted in spec.items():
        if key in tags and ("*" in wanted or str(tags[key]) in wanted):
            return True
    return False


def _number(value: Any) -> float | None:
    try:
        return float(str(value).replace("m", "").strip())
    except (TypeError, ValueError):
        return None


def order_places(home: dict[str, Any], places: list[Any], centre: tuple[float, float]) -> list[Any]:
    """The places a legend may live at, best first (pure; `places` already in the ring,
    of the right categories, and not sensitive)."""
    wanted = home.get("tags")
    kept = [p for p in places if not wanted or _tag_match(wanted, dict(p.tags or {}))]

    def far(p: Any) -> float:
        return haversine_m(centre[0], centre[1], p.latitude, p.longitude)

    highest = home.get("highestTag")
    if highest:
        # The highest first; those that do not say how high come after, nearest first.
        return sorted(
            kept,
            key=lambda p: (
                _number((p.tags or {}).get(highest)) is None,
                -(_number((p.tags or {}).get(highest)) or 0.0),
                far(p),
            ),
        )
    prefer = home.get("preferTags")
    if prefer:
        return sorted(kept, key=lambda p: (not _tag_match(prefer, dict(p.tags or {})), far(p)))
    return sorted(kept, key=far)


# --- reads and the reach test ------------------------------------------------------


async def reachable(engine: RoutingEngine, start: tuple[float, float], end: tuple[float, float], activity: str) -> bool:
    """Whether the engine finds a way from the start to the spot for how the player
    moves, ending near it (an engine snaps a point off its roads to the nearest one)."""
    activity = normalise(activity)
    request = EngineRequest(
        points=[start, end],
        profile="foot" if is_foot(activity) else "hybrid",
        activity=activity,
        details=False,
    )
    try:
        routes = await engine.route(request)
    except Exception as exc:  # noqa: BLE001 - an engine that fails cannot reach it
        log.info("legend_anchor_unreachable", error=str(exc)[:160])
        return False
    if not routes or not routes[0].coordinates:
        return False
    last = routes[0].coordinates[-1]
    return haversine_m(float(last[1]), float(last[0]), end[0], end[1]) <= float(catalog.book()["routeEndMeters"])


async def _places_in_ring(
    db: AsyncSession, centre: tuple[float, float], categories: list[str], extra_m: float = 0.0
) -> list[Any]:
    low, high = (float(m) for m in catalog.book()["ringMeters"])
    out: list[Any] = []
    for category in categories:
        for d in await nearby(db, centre[0], centre[1], high + extra_m, category=category, limit=PLACE_LIMIT):
            if not is_sensitive(d.name, d.tags) and haversine_m(centre[0], centre[1], d.latitude, d.longitude) >= (
                low - extra_m
            ):
                out.append(d)
    return out


async def _place_spots(db: AsyncSession, home: dict[str, Any], centre: tuple[float, float]) -> list[Spot]:
    low, high = (float(m) for m in catalog.book()["ringMeters"])
    places = [
        p
        for p in await _places_in_ring(db, centre, list(home.get("categories") or []))
        if low <= haversine_m(centre[0], centre[1], p.latitude, p.longitude) <= high
        and (not home.get("tags") or _tag_match(home["tags"], dict(p.tags or {})))
    ]
    near = home.get("near")
    if near:
        # Water with a path beside it: a place of the named kind within so many metres.
        beside = await _places_in_ring(db, centre, list(near["categories"]), extra_m=float(near["meters"]))
        reach = float(near["meters"])
        places = [
            p
            for p in places
            if any(haversine_m(p.latitude, p.longitude, b.latitude, b.longitude) <= reach for b in beside)
        ]
    return [Spot(p.latitude, p.longitude, p.name[:160], str(p.id)) for p in order_places(home, places, centre)]


async def _fog_spots(
    db: AsyncSession, user_id: uuid.UUID, centre: tuple[float, float], resolution: int, limit: int
) -> list[Spot]:
    explored = set(await known_cells(db, user_id))
    out: list[Spot] = []
    for cell in fog_candidates(ring_cells(centre, resolution), explored)[: limit * 2]:
        lat, lon = cell_center(cell)
        around = await nearby(db, lat, lon, FOG_NAME_M, limit=40)
        if any(
            is_sensitive(d.name, d.tags) and haversine_m(lat, lon, d.latitude, d.longitude) <= FOG_CLEAR_M
            for d in around
        ):
            continue
        name = next((d.name for d in around if not is_sensitive(d.name, d.tags)), None)
        out.append(Spot(lat, lon, f"Near {name}"[:160] if name else None))
        if len(out) >= limit:
            break
    return out


async def find(
    db: AsyncSession,
    engine: RoutingEngine,
    *,
    user_id: uuid.UUID,
    species_id: str,
    centre: tuple[float, float],
    activity: str,
    resolution: int,
    avoid: tuple[float, float] | None = None,
    budget: Budget | None = None,
) -> Spot | None:
    """The first spot this legend may live at that the engine can reach, or None.
    At most `anchorTries` spots are tested, and no more than the budget allows."""
    home = catalog.legend(species_id)["home"]
    tries = int(catalog.book()["anchorTries"])
    if home["rule"] == "FOG":
        spots = await _fog_spots(db, user_id, centre, resolution, limit=tries * 3)
    else:
        spots = await _place_spots(db, home, centre)
    if avoid is not None:
        spots = [s for s in spots if haversine_m(avoid[0], avoid[1], s.latitude, s.longitude) > MOVE_AWAY_M]
    for spot in spots[:tries]:
        if budget is not None:
            if budget.left <= 0:
                return None
            budget.left -= 1
        if await reachable(engine, centre, (spot.latitude, spot.longitude), activity):
            return spot
    return None
