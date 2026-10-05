"""Districts (0.9.0 "The parish"): progress on a journey, completion, "yours" and its
weekly pay, the ledger, and what the API says. The only writer of `user_regions`.

Explored % is honest: only a district's tiles with a road or path in them count
(`regions.way_cells`, fetched once per district by districts/ways.py), and until
those are known there is no % at all, only a count of tiles. Every tile the player
has (passed, or shown by a skill or a map piece) counts as explored, as on the map.
Cells never regress, so neither does a district; lapsing changes a word, nothing
else.
"""

from __future__ import annotations

import uuid
from datetime import date, datetime, timedelta
from typing import Any

from sqlalchemy import and_, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.characters.models import Character
from app.core.logging import get_logger
from app.discoveries.models import Discovery
from app.districts import geo, titles
from app.districts.models import Region, UserRegion
from app.exploration.cells import cell_center, cell_for
from app.exploration.models import UserExplorationCell

log = get_logger(__name__)

YOURS_AT = 50.0
COMPLETE_AT = 90.0
KEEP_DAYS = 30
WEEKLY_COINS = 5
MAX_PAID = 10
COMPLETE_COINS = 200


# --- pure rules -------------------------------------------------------------------


def percent_of(region: Region, row: UserRegion | None) -> float | None:
    """Explored %, 0–100, of the tiles with a road or path; None until those are known."""
    ways = region.way_cells
    if not ways:
        return None
    explored = row.way_cells_explored if row is not None else 0
    return round(min(100.0, 100.0 * explored / len(ways)), 1)


def keep_days(rules: dict[str, float] | None) -> int:
    """How long a district stays yours after the last visit: 30, or Othala's."""
    return int((rules or {}).get("DISTRICT_KEEP_DAYS") or KEEP_DAYS)


def weekly_coins(rules: dict[str, float] | None) -> int:
    """What a district that is yours pays a week: 5, and Fehu's more."""
    return WEEKLY_COINS + int((rules or {}).get("DISTRICT_PAY_EXTRA") or 0)


def is_yours(pct: float | None, last_passed: datetime | None, now: datetime, days: int = KEEP_DAYS) -> bool:
    """At 50% or more and passed through in the last `days` days."""
    if pct is None or pct < YOURS_AT or last_passed is None:
        return False
    return now - last_passed <= timedelta(days=days)


# --- loading ------------------------------------------------------------------------


def node_of(region: Region) -> geo.Node:
    return geo.Node(str(region.id), region.latitude, region.longitude, region.osm_id)


async def regions_in_tiles(db: AsyncSession, tiles: set[str]) -> list[Region]:
    if not tiles:
        return []
    out: list[Region] = []
    ordered = sorted(tiles)
    for start in range(0, len(ordered), 400):
        chunk = ordered[start : start + 400]
        out += list((await db.execute(select(Region).where(Region.tile.in_(chunk)))).scalars())
    return out


async def assigner_for(db: AsyncSession, points: list[tuple[float, float]]) -> tuple[geo.Assigner, dict[str, Region]]:
    """An assigner with every district within reach of these points."""
    tiles: set[str] = set()
    for lat, lon in points:
        tiles.update(geo.tiles_near(lat, lon))
    regions = await regions_in_tiles(db, tiles)
    return geo.Assigner(node_of(r) for r in regions), {str(r.id): r for r in regions}


async def assigner_for_cells(db: AsyncSession, cells: set[str]) -> tuple[geo.Assigner, dict[str, Region]]:
    seen: dict[str, tuple[float, float]] = {}
    for cell in cells:
        lat, lon = cell_center(cell)
        seen.setdefault(geo.tile_of(lat, lon), (lat, lon))
    return await assigner_for(db, list(seen.values()))


async def catchment(db: AsyncSession, region: Region, resolution: int) -> set[str]:
    """Every tile of a district."""
    assigner, _ = await assigner_for(db, [(region.latitude, region.longitude)])
    return assigner.catchment(node_of(region), resolution)


async def user_cells_among(db: AsyncSession, user_id: uuid.UUID, cells: set[str]) -> set[str]:
    """Which of these tiles the player has (any state)."""
    out: set[str] = set()
    ordered = sorted(cells)
    for start in range(0, len(ordered), 500):
        chunk = ordered[start : start + 500]
        out.update(
            (
                await db.execute(
                    select(UserExplorationCell.h3_index).where(
                        UserExplorationCell.user_id == user_id, UserExplorationCell.h3_index.in_(chunk)
                    )
                )
            ).scalars()
        )
    return out


async def refresh_places(db: AsyncSession, region: Region, cells: set[str], resolution: int) -> None:
    """Counts the district's places (discoveries in its tiles) and works out its title."""
    box = geo.bbox(cells)
    if box is None:
        return
    south, west, north, east = box
    rows = (
        await db.execute(
            select(Discovery.name, Discovery.category, Discovery.tags, Discovery.latitude, Discovery.longitude).where(
                Discovery.latitude.between(south, north),
                Discovery.longitude.between(west, east),
                Discovery.moderation_status == "APPROVED",
            )
        )
    ).all()
    inside = [(r.name, r.category, r.tags) for r in rows if cell_for(r.latitude, r.longitude, resolution) in cells]
    region.place_counts = titles.count_places(inside)
    region.epithet = titles.title_for(region.place_counts)
    await db.flush()


# --- a journey ---------------------------------------------------------------------


async def progress_on_ride(
    db: AsyncSession,
    character: Character,
    ride: Any,
    *,
    cells: set[str],
    new_cells: set[str],
    resolution: int,
    ended: datetime,
    rules: dict[str, float] | None = None,
) -> dict[str, Any] | None:
    """Every district the journey's tiles were in: its counts brought up to date, and
    whether it became yours or was completed on this journey. A completion pays its
    purse (200 coins, outside the cap) and its title here, once; its XP is the
    journey's (`REGION_COMPLETED`, through the reward input). Returns
    {"districts": [...], "completed": [names], "coins": n, "titles": [...],
    "regionIds": [...]}, or None when the journey was in no district."""
    from app.economy import service as economy
    from app.progression.service import award_title
    from app.progression.titles import district_title

    if not cells:
        return None
    assigner, regions = await assigner_for_cells(db, cells)
    touched = assigner.group(cells)
    if not touched:
        return None
    rows = {
        str(r.region_id): r
        for r in (
            await db.execute(
                select(UserRegion).where(
                    UserRegion.user_id == character.user_id,
                    UserRegion.region_id.in_([uuid.UUID(rid) for rid in touched]),
                )
            )
        ).scalars()
    }
    days = keep_days(rules)
    out: list[dict[str, Any]] = []
    completed: list[Region] = []
    for rid in touched:
        region = regions[rid]
        tiles = assigner.catchment(node_of(region), resolution)
        have = await user_cells_among(db, character.user_id, tiles)
        row = rows.get(rid)
        before_pct = percent_of(region, row)
        # Yours already, and said so: a district whose roads came in at 50% or more since
        # the last journey becomes yours on this one, with the line to say so.
        was_yours = (
            row is not None and row.yours_since is not None and is_yours(before_pct, row.last_passed_at, ended, days)
        )
        if row is None:
            row = UserRegion(
                user_id=character.user_id,
                region_id=region.id,
                explored_cells=0,
                way_cells_explored=0,
                first_passed_at=ended,
                last_passed_at=ended,
            )
            db.add(row)
        row.explored_cells = max(row.explored_cells or 0, len(have))
        if region.way_cells:
            row.way_cells_explored = max(row.way_cells_explored or 0, len(have & set(region.way_cells)))
        if row.last_passed_at is None or ended > row.last_passed_at:
            row.last_passed_at = ended
        if not region.place_counts:
            await refresh_places(db, region, tiles, resolution)
        pct = percent_of(region, row)
        became = not was_yours and is_yours(pct, row.last_passed_at, ended, days)
        if became:
            row.yours_since = ended
        done_now = pct is not None and pct >= COMPLETE_AT and row.completed_at is None
        if done_now:
            row.completed_at = ended
            completed.append(region)
        out.append(
            {
                "id": rid,
                "name": region.name,
                "title": titles.shown_title(region.epithet, pct),
                "displayName": titles.display_name(region.name, region.epithet, pct),
                "percent": pct,
                "exploredTiles": row.explored_cells,
                "newTiles": len(new_cells & tiles),
                "becameYours": became,
                "completed": done_now,
                # For the quest objectives only; taken out of the summary.
                "_firstPassedAt": row.first_passed_at,
            }
        )
    await db.flush()
    coins = 0
    titles_earned: list[str] = []
    ride_id = getattr(ride, "id", None)
    for region in completed:
        await economy.credit(
            db,
            character.user_id,
            COMPLETE_COINS,
            "DISTRICT",
            ride_id=ride_id,
            payload={"district": region.name, "regionId": str(region.id)},
        )
        coins += COMPLETE_COINS
        entry = district_title(region.id, region.name)
        name = await award_title(db, character, entry["slug"], ride_id=ride_id, entry=entry)
        if name:
            titles_earned.append(name)
    out.sort(key=lambda d: (-d["newTiles"], d["name"]))
    return {
        "districts": out,
        "completed": [r.name for r in completed],
        "coins": coins,
        "titles": titles_earned,
        "regionIds": list(touched),
    }


async def pay_week(
    db: AsyncSession,
    character: Character,
    ride: Any,
    *,
    day: date,
    ended: datetime,
    rules: dict[str, float] | None = None,
    south: bool = False,
) -> dict[str, Any] | None:
    """The week's pay for the districts that are yours: on the first journey of an
    ISO week that has one, 5 coins each (Fehu adds), at most ten, doubled in the
    three days round a festival. Keyed `district-pay:{week}`, so it is paid once a
    week; outside the per-journey cap. Returns {"coins", "districts", "doubled",
    "week"}, or None."""
    from app.economy import service as economy
    from app.inventory import service as inventory
    from app.quests import seasons
    from app.quests.week import week_of

    week = week_of(day)
    key = f"district-pay:{week}"
    if not await inventory.first_time(db, character.user_id, key):
        return None
    days = keep_days(rules)
    yours: list[tuple[float, Region, UserRegion]] = []
    for row, region in (
        await db.execute(
            select(UserRegion, Region)
            .join(Region, Region.id == UserRegion.region_id)
            .where(UserRegion.user_id == character.user_id)
        )
    ).all():
        pct = percent_of(region, row)
        if is_yours(pct, row.last_passed_at, ended, days):
            yours.append((pct or 0.0, region, row))
    if not yours:
        return None
    yours.sort(key=lambda t: (-t[0], t[1].name))
    paid = yours[:MAX_PAID]
    doubled = seasons.pay_doubled(day, south=south)
    each = weekly_coins(rules) * (2 if doubled else 1)
    coins = each * len(paid)
    names = [region.name for _, region, _ in paid]
    ride_id = getattr(ride, "id", None)
    await economy.credit(
        db,
        character.user_id,
        coins,
        "DISTRICT_PAY",
        ride_id=ride_id,
        payload={"week": week, "districts": names, "doubled": doubled},
    )
    for _, _, row in paid:
        row.last_paid_week = week
    db.add(
        inventory.note_paid(
            character.user_id, "DISTRICT_PAY", key, ride_id=ride_id, payload={"coins": coins, "districts": names}
        )
    )
    await db.flush()
    return {"coins": coins, "districts": names, "doubled": doubled, "week": week}


# --- what the API says ---------------------------------------------------------------


def district_out(
    region: Region, row: UserRegion | None, now: datetime, rules: dict[str, float] | None = None
) -> dict[str, Any]:
    pct = percent_of(region, row)
    yours = row is not None and is_yours(pct, row.last_passed_at, now, keep_days(rules))
    return {
        "id": str(region.id),
        "name": region.name,
        "kind": region.kind,
        "title": titles.shown_title(region.epithet, pct),
        "displayName": titles.display_name(region.name, region.epithet, pct),
        "percent": pct,
        "exploredTiles": row.explored_cells if row is not None else 0,
        "wayTiles": len(region.way_cells) if region.way_cells is not None else None,
        "yours": yours,
        "wasYours": bool(row is not None and row.yours_since is not None and not yours),
        "completed": bool(row is not None and row.completed_at is not None),
        "weeklyCoins": weekly_coins(rules),
        "latitude": region.latitude,
        "longitude": region.longitude,
        "firstPassed": row.first_passed_at if row is not None else None,
        "lastPassed": row.last_passed_at if row is not None else None,
    }


async def passed(db: AsyncSession, user_id: uuid.UUID) -> list[tuple[Region, UserRegion]]:
    """The districts the player has passed through, last passed first."""
    rows = (
        await db.execute(
            select(Region, UserRegion)
            .join(UserRegion, UserRegion.region_id == Region.id)
            .where(UserRegion.user_id == user_id)
            .order_by(UserRegion.last_passed_at.desc(), Region.name)
        )
    ).all()
    return [(region, row) for region, row in rows]


async def row_for(db: AsyncSession, user_id: uuid.UUID, region_id: uuid.UUID) -> UserRegion | None:
    return await db.scalar(select(UserRegion).where(UserRegion.user_id == user_id, UserRegion.region_id == region_id))


async def here(db: AsyncSession, latitude: float, longitude: float, resolution: int) -> Region | None:
    """The district a point is in."""
    assigner, regions = await assigner_for(db, [(latitude, longitude)])
    rid = assigner.region_of(cell_for(latitude, longitude, resolution))
    return regions.get(rid) if rid else None


def _inside(cells: set[str], resolution: int, lat: float | None, lon: float | None) -> bool:
    return lat is not None and lon is not None and cell_for(lat, lon, resolution) in cells


async def ledger(
    db: AsyncSession, user_id: uuid.UUID, region: Region, row: UserRegion | None, resolution: int
) -> dict[str, Any]:
    """What the player has done within the district's tiles, counted from what is
    already kept: places found, creatures (and legends) defeated, runes cut, quests
    done (where their objectives were, or where the quest was set)."""
    from app.discoveries.models import UserDiscovery
    from app.inventory.models import RuneCut
    from app.legends.models import DEFEATED, OldOne
    from app.quests.models import QuestInstance, QuestObjective
    from app.world_objects.models import WorldObject

    cells = await catchment(db, region, resolution)
    box = geo.bbox(cells)
    empty = {
        "placesFound": 0,
        "creaturesDefeated": 0,
        "runesCut": 0,
        "questsDone": 0,
        "firstPassed": row.first_passed_at if row is not None else None,
        "lastPassed": row.last_passed_at if row is not None else None,
    }
    if box is None:
        return empty
    south, west, north, east = box

    def within(lat_col: Any, lon_col: Any) -> Any:
        return and_(lat_col.between(south, north), lon_col.between(west, east))

    places = (
        await db.execute(
            select(Discovery.latitude, Discovery.longitude)
            .join(UserDiscovery, UserDiscovery.discovery_id == Discovery.id)
            .where(UserDiscovery.user_id == user_id, within(Discovery.latitude, Discovery.longitude))
        )
    ).all()
    creatures = (
        await db.execute(
            select(WorldObject.latitude, WorldObject.longitude).where(
                WorldObject.user_id == user_id,
                WorldObject.kind == "MONSTER",
                WorldObject.status == "CLAIMED",
                within(WorldObject.latitude, WorldObject.longitude),
            )
        )
    ).all()
    legends = (
        await db.execute(
            select(OldOne.latitude, OldOne.longitude).where(
                OldOne.user_id == user_id, OldOne.status == DEFEATED, within(OldOne.latitude, OldOne.longitude)
            )
        )
    ).all()
    cuts = (
        await db.execute(
            select(RuneCut.latitude, RuneCut.longitude).where(
                RuneCut.user_id == user_id, within(RuneCut.latitude, RuneCut.longitude)
            )
        )
    ).all()
    done = (
        await db.execute(
            select(QuestInstance.id, QuestInstance.latitude, QuestInstance.longitude).where(
                QuestInstance.user_id == user_id, QuestInstance.status == "COMPLETED"
            )
        )
    ).all()
    quests = 0
    if done:
        spots: dict[uuid.UUID, list[tuple[float, float]]] = {}
        ids = [q.id for q in done]
        for start in range(0, len(ids), 500):
            for oid, lat, lon in (
                await db.execute(
                    select(QuestObjective.quest_id, QuestObjective.latitude, QuestObjective.longitude).where(
                        QuestObjective.quest_id.in_(ids[start : start + 500]),
                        QuestObjective.latitude.is_not(None),
                    )
                )
            ).all():
                spots.setdefault(oid, []).append((lat, lon))
        for q in done:
            where = spots.get(q.id) or [(q.latitude, q.longitude)]
            if any(_inside(cells, resolution, lat, lon) for lat, lon in where):
                quests += 1
    return {
        **empty,
        "placesFound": sum(1 for p in places if _inside(cells, resolution, p.latitude, p.longitude)),
        "creaturesDefeated": sum(1 for c in [*creatures, *legends] if _inside(cells, resolution, c[0], c[1])),
        "runesCut": sum(1 for c in cuts if _inside(cells, resolution, c.latitude, c.longitude)),
        "questsDone": quests,
    }


async def edge_shares(db: AsyncSession, cells: set[str], resolution: int) -> dict[str, dict[str, Any]]:
    """How much of each district's edge a journey's tiles touched (Beating the Bounds):
    an edge tile counts when the journey passed it or a tile beside it. Where its roads
    are known, the edge is its edge tiles with a road or path, so a loop is never asked
    to cross a river."""
    if not cells:
        return {}
    assigner, regions = await assigner_for_cells(db, cells)
    out: dict[str, dict[str, Any]] = {}
    for rid in assigner.group(cells):
        region = regions[rid]
        edge = geo.edge_cells(assigner.catchment(node_of(region), resolution))
        if region.way_cells:
            on_roads = edge & set(region.way_cells)
            edge = on_roads or edge
        out[rid] = {"name": region.name, "share": round(geo.touched_share(cells, edge), 3)}
    return out


async def count_yours(db: AsyncSession, user_id: uuid.UUID, now: datetime, rules: dict[str, float] | None) -> int:
    return sum(
        1
        for region, row in await passed(db, user_id)
        if is_yours(percent_of(region, row), row.last_passed_at, now, keep_days(rules))
    )


async def most_visited(db: AsyncSession, user_id: uuid.UUID) -> Region | None:
    """The district with the most of the player's tiles: "home" for Act IV."""
    row = (
        await db.execute(
            select(Region)
            .join(UserRegion, UserRegion.region_id == Region.id)
            .where(UserRegion.user_id == user_id)
            .order_by(UserRegion.explored_cells.desc(), UserRegion.first_passed_at)
            .limit(1)
        )
    ).scalar_one_or_none()
    return row


async def total_passed(db: AsyncSession, user_id: uuid.UUID) -> int:
    return int(await db.scalar(select(func.count(UserRegion.id)).where(UserRegion.user_id == user_id)) or 0)
