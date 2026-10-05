"""Treasure maps and buried treasure (docs/ROADMAP.md 0.8.0).

A treasure map, used, buries a chest 1 to 4 km away at a real place that has
something to say about it (water, high ground, a green place, something old),
and gives a clue made from those facts, never from a name: "Buried by water, in
a green place, about 2 km north-east of here." The chest is a world object with
status HIDDEN, which nothing that draws the map ever asks for. A journey that
passes within 40 m opens it: coins outside the per-journey cap and an item,
once, by the key `treasure:{id}`. One clue at a time.

Hot and cold (a tick that quickens as you near it) is not built.
"""

from __future__ import annotations

import math
import random
import uuid
from datetime import datetime, timedelta
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.characters.models import Character
from app.core.errors import Conflict
from app.core.geo import bearing_deg, haversine_m
from app.core.security import utcnow
from app.discoveries.sensitivity import is_sensitive
from app.discoveries.service import nearby
from app.exploration.cells import cell_for
from app.inventory import loot
from app.world_objects.models import HIDDEN, WorldObject

NAME = "Buried treasure"
# Something this near the spot counts as part of where it is ("by water").
BESIDE_M = 150.0
PLACE_LIMIT = 800
# A clue that is never found stays open; it does not run out.
KEEPS_DAYS = 365
FEATURES = ("WATER", "GREEN", "HIGH", "OLD")
PHRASES = {
    "WATER": "by water",
    "GREEN": "in a green place",
    "HIGH": "up on high ground",
    "OLD": "near something old",
}
COMPASS = ("north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west")
SEED_PREFIX = "treasure"
# The kinds of place that have something to say about where they are.
CATEGORIES = ("NATURE", "VIEWPOINT", "HISTORICAL", "TRAIL", "CULTURAL", "LANDMARK")


def rules() -> dict[str, Any]:
    return dict(loot.book()["treasureMap"])


# --- the clue, pure ---------------------------------------------------------------


def features_of(category: str | None, tags: dict[str, Any] | None) -> set[str]:
    """What a place says about where it is, from its kind and its tags."""
    tags = tags or {}
    natural, leisure, landuse = tags.get("natural"), tags.get("leisure"), tags.get("landuse")
    out: set[str] = set()
    if natural in ("water", "wetland", "beach", "spring") or tags.get("water") or tags.get("waterway"):
        out.add("WATER")
    if leisure == "marina":
        out.add("WATER")
    if (
        leisure in ("park", "garden", "nature_reserve", "common")
        or landuse in ("forest", "meadow", "grass", "recreation_ground")
        or natural in ("wood", "scrub", "heath", "grassland")
        or tags.get("tourism") == "picnic_site"
    ):
        out.add("GREEN")
    if category == "VIEWPOINT" or natural in ("peak", "ridge") or tags.get("tourism") == "viewpoint":
        out.add("HIGH")
    if category == "HISTORICAL" or tags.get("historic"):
        out.add("OLD")
    return out


def direction(bearing: float) -> str:
    return COMPASS[int(((bearing % 360) + 22.5) // 45) % 8]


def about_km(meters: float) -> str:
    """To the nearest half kilometre, and never under one: "about 2 km"."""
    km = max(1.0, round(meters / 500.0) / 2)
    return f"{km:g}"


def compose_clue(features: set[str], meters: float, bearing: float) -> str:
    """ "Buried by water, in a green place, about 2 km north-east of here." """
    said = [PHRASES[f] for f in FEATURES if f in features]
    where = ", ".join(said)
    return f"Buried {where}, about {about_km(meters)} km {direction(bearing)} of here."


# --- burying --------------------------------------------------------------------


async def open_treasure(db: AsyncSession, user_id: uuid.UUID) -> WorldObject | None:
    """The one clue still being followed, if there is one."""
    return await db.scalar(
        select(WorldObject)
        .where(WorldObject.user_id == user_id, WorldObject.kind == "CHEST", WorldObject.status == HIDDEN)
        .order_by(WorldObject.spawned_at.desc())
        .limit(1)
    )


async def open_clues(db: AsyncSession, user_id: uuid.UUID) -> list[WorldObject]:
    rows = await db.execute(
        select(WorldObject)
        .where(WorldObject.user_id == user_id, WorldObject.kind == "CHEST", WorldObject.status == HIDDEN)
        .order_by(WorldObject.spawned_at.desc())
    )
    return list(rows.scalars())


def clue_out(obj: WorldObject) -> dict[str, Any]:
    """An open clue for the Quests tab: what it says and where it was read. Never
    where the treasure is."""
    payload = obj.payload or {}
    return {
        "treasureId": obj.id,
        "clue": str(payload.get("clue") or ""),
        "buriedAt": obj.spawned_at,
        "fromLatitude": payload.get("fromLatitude"),
        "fromLongitude": payload.get("fromLongitude"),
    }


def _buckets(places: list[Any]) -> dict[tuple[int, int], list[tuple[Any, set[str]]]]:
    out: dict[tuple[int, int], list[tuple[Any, set[str]]]] = {}
    for p in places:
        found = features_of(p.category, p.tags)
        if found:
            out.setdefault((math.floor(p.latitude * 500), math.floor(p.longitude * 500)), []).append((p, found))
    return out


def _around(buckets: dict[tuple[int, int], list[tuple[Any, set[str]]]], place: Any) -> set[str]:
    """Everything said about a place and what lies beside it."""
    row, col = math.floor(place.latitude * 500), math.floor(place.longitude * 500)
    out = set(features_of(place.category, place.tags))
    for dr in (-1, 0, 1):
        for dc in (-1, 0, 1):
            for other, found in buckets.get((row + dr, col + dc), []):
                if haversine_m(place.latitude, place.longitude, other.latitude, other.longitude) <= BESIDE_M:
                    out |= found
    return out


async def bury(
    db: AsyncSession, settings: Any, character: Character, latitude: float, longitude: float
) -> dict[str, Any]:
    """Uses a treasure map here: buries the chest and returns the clue."""
    from app.inventory.service import take_consumable

    if await open_treasure(db, character.user_id) is not None:
        raise Conflict(
            "You already have a clue to follow. Find that treasure first, then use another map.",
            code="ONE_AT_A_TIME",
        )
    low, high = (float(m) for m in rules()["distanceMeters"])
    # By kind, so a city's cafés nearer in do not crowd out the parks further out.
    around = [
        d
        for category in CATEGORIES
        for d in await nearby(db, latitude, longitude, high + BESIDE_M, category=category, limit=PLACE_LIMIT)
        if not is_sensitive(d.name, d.tags)
    ]
    buckets = _buckets(around)
    spots = []
    for place in around:
        meters = haversine_m(latitude, longitude, place.latitude, place.longitude)
        if not low <= meters <= high:
            continue
        found = _around(buckets, place)
        if found:
            spots.append((place, found, meters))
    if not spots:
        raise Conflict(
            "There's nowhere good to bury treasure near here. Try the map somewhere else.",
            code="NO_PLACE_FOR_TREASURE",
        )
    buried_before = int(
        await db.scalar(
            select(func.count(WorldObject.id)).where(
                WorldObject.user_id == character.user_id, WorldObject.seed.like(f"{SEED_PREFIX}:%")
            )
        )
        or 0
    )
    rng = random.Random(f"{SEED_PREFIX}:{character.user_id}:{buried_before}")
    place, found, meters = rng.choice(sorted(spots, key=lambda s: str(s[0].id)))
    clue = compose_clue(found, meters, bearing_deg(latitude, longitude, place.latitude, place.longitude))
    now = utcnow()
    obj = WorldObject(
        user_id=character.user_id,
        kind="CHEST",
        status=HIDDEN,
        tier=int(rules()["rarityTier"]),
        anchor_discovery_id=place.id,
        latitude=place.latitude,
        longitude=place.longitude,
        h3_index=cell_for(place.latitude, place.longitude, settings.h3_resolution),
        seed=f"{SEED_PREFIX}:{buried_before}",
        bounty=False,
        reward_ac=int(rules()["coins"]),
        payload={
            "name": NAME,
            "treasure": True,
            "clue": clue,
            "features": sorted(found),
            "fromLatitude": latitude,
            "fromLongitude": longitude,
        },
        spawned_at=now,
        expires_at=now + timedelta(days=KEEPS_DAYS),
    )
    db.add(obj)
    await db.flush()
    await take_consumable(db, character, "TREASURE_MAP", why=f"treasure:{obj.id}")
    return {"consumable": "TREASURE_MAP", "clue": clue, "treasureId": obj.id}


# --- finding it ------------------------------------------------------------------


async def open_on_ride(
    db: AsyncSession,
    character: Character,
    ride: Any,
    coords: list[tuple[float, float]],
    ended: datetime,
) -> dict[str, Any] | None:
    """Buried treasure the journey passed within reach of: opened, and paid once.
    Returns the summary's `treasureFound`, or None."""
    from app.economy import service as economy
    from app.inventory import service as inventory
    from app.world_objects.claims import min_distance_to_path_m

    if len(coords) < 2:
        return None
    reach = float(rules()["openMeters"])
    for obj in await open_clues(db, character.user_id):
        if obj.spawned_at > ended:
            continue
        distance = min_distance_to_path_m(obj.latitude, obj.longitude, coords)
        if distance > reach:
            continue
        obj.status = "CLAIMED"
        obj.claimed_at = ended
        obj.claimed_ride_id = getattr(ride, "id", None)
        obj.claim_payload = {"method": "TREASURE", "distanceMeters": round(distance, 1)}
        key = f"treasure:{obj.id}"
        coins = 0
        item = None
        if await inventory.first_time(db, character.user_id, key):
            coins = int(obj.reward_ac or rules()["coins"])
            await economy.credit(
                db, character.user_id, coins, "TREASURE", ride_id=getattr(ride, "id", None),
                payload={"treasureId": str(obj.id), "name": NAME},
            )  # fmt: skip
            had = await inventory.legendaries_had(db, character.user_id)
            item = await inventory.give_item(
                db,
                character,
                "RARE",
                key=key,
                source="TREASURE",
                ride_id=getattr(ride, "id", None),
                from_name=NAME,
                item_id=loot.treasure_item(key, had),
            )
            db.add(
                inventory.note_paid(
                    character.user_id, "TREASURE", key, ride_id=getattr(ride, "id", None),
                    payload={"coins": coins, "item": item},
                )
            )  # fmt: skip
        await db.flush()
        return {
            "id": str(obj.id),
            "name": NAME,
            "clue": (obj.payload or {}).get("clue"),
            "coins": coins,
            "item": item,
            "line": "You found the buried treasure!",
        }
    return None
