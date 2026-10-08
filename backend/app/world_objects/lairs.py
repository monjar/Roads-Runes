"""Lairs (docs/ROADMAP.md 0.8.0): seven tiles round a park to visit.

A lair is a world object of kind LAIR at a park, garden or other green place 2 to
6 km from where the player usually starts, offered from level 8: its own tile
and the six around it. Visiting five of the seven within 14 days (entering a
tile counts, not metres inside it) opens its great chest: coins outside the
per-journey cap, a Rare item, a Rare sealed chest, and Ingwaz the first time.
One at a time, and one a fortnight. Paid once, by `lair:{id}`.
"""

from __future__ import annotations

import random
import uuid
from datetime import datetime, timedelta
from typing import Any

import h3
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.characters.models import Character
from app.core.geo import haversine_m
from app.core.logging import get_logger
from app.core.security import utcnow
from app.discoveries.sensitivity import is_sensitive
from app.discoveries.service import nearby
from app.exploration.cells import cell_center, cell_for
from app.world_objects.models import WorldObject

log = get_logger(__name__)

LAIR = "LAIR"
CHEST_NAME = "Great chest"
NAME_WIDTH = 160
SEED_PREFIX = "lair"


def config() -> dict[str, Any]:
    from app.world_objects.service import load_config

    return dict(load_config()["lairs"])


def lair_out(obj: WorldObject) -> dict[str, Any]:
    """WorldObjectOut.lair: its tiles' middles, which have been visited (by index),
    how many it needs, and when it ends."""
    payload = obj.payload or {}
    cells = list(payload.get("cells") or [])
    visited = set(payload.get("visited") or [])
    return {
        "cells": [list(cell_center(c)) for c in cells],
        "visited": [i for i, c in enumerate(cells) if c in visited],
        "need": int(payload.get("need") or config()["need"]),
        "endsAt": obj.expires_at,
    }


async def live_lair(db: AsyncSession, user_id: uuid.UUID, now: datetime | None = None) -> WorldObject | None:
    now = now or utcnow()
    return await db.scalar(
        select(WorldObject).where(
            WorldObject.user_id == user_id,
            WorldObject.kind == LAIR,
            WorldObject.status == "SPAWNED",
            WorldObject.expires_at >= now,
        )
    )


def _green(category: str | None, tags: dict[str, Any] | None, wanted: dict[str, list[str]]) -> bool:
    tags = tags or {}
    return any(key in tags and ("*" in values or str(tags[key]) in values) for key, values in wanted.items())


async def ensure_offered(
    db: AsyncSession,
    settings: Any,
    character: Character,
    near: tuple[float, float] | None = None,
    now: datetime | None = None,
) -> WorldObject | None:
    """The lair on offer: the live one, or a new one if the character is level 8 or
    more, none is live and the last was offered a fortnight or more ago."""
    from app.inventory.deeds import usual_start

    rules = config()
    now = now or utcnow()
    if character.overall_level < int(rules["minLevel"]):
        return None
    live = await live_lair(db, character.user_id, now)
    if live is not None:
        return live
    rows = (
        await db.execute(
            select(WorldObject.spawned_at, WorldObject.anchor_discovery_id).where(
                WorldObject.user_id == character.user_id, WorldObject.kind == LAIR
            )
        )
    ).all()
    if rows and max(r.spawned_at for r in rows) + timedelta(days=float(rules["everyDays"])) > now:
        return None
    centre = await usual_start(db, character.user_id) or near
    if centre is None:
        return None
    low, high = (float(m) for m in rules["ringMeters"])
    used = {r.anchor_discovery_id for r in rows if r.anchor_discovery_id}
    places = []
    for category in rules["categories"]:
        for d in await nearby(db, centre[0], centre[1], high, category=category, limit=1000):
            if d.id in used or is_sensitive(d.name, d.tags) or not _green(d.category, d.tags, rules["tags"]):
                continue
            if low <= haversine_m(centre[0], centre[1], d.latitude, d.longitude) <= high:
                places.append(d)
    if not places:
        return None
    rng = random.Random(f"{SEED_PREFIX}:{character.user_id}:{len(rows)}")
    place = rng.choice(sorted(places, key=lambda d: str(d.id)))
    home = cell_for(place.latitude, place.longitude, settings.h3_resolution)
    cells = [home, *sorted(set(h3.grid_disk(home, 1)) - {home})]
    ends = now + timedelta(days=float(rules["lifeDays"]))
    obj = WorldObject(
        user_id=character.user_id,
        kind=LAIR,
        status="SPAWNED",
        tier=1,
        anchor_discovery_id=place.id,
        latitude=place.latitude,
        longitude=place.longitude,
        h3_index=home,
        seed=f"{SEED_PREFIX}:{len(rows)}",
        bounty=False,
        reward_ac=int(rules["coins"]),
        payload={
            "name": f"The lair at {place.name}"[:NAME_WIDTH],
            "anchorName": place.name,
            "cells": cells,
            "visited": [],
            "need": int(rules["need"]),
            "endsAt": ends.isoformat(),
        },
        spawned_at=now,
        expires_at=ends,
    )
    try:
        async with db.begin_nested():
            db.add(obj)
            await db.flush()
    except IntegrityError:
        # Offered a moment ago by another request.
        return await live_lair(db, character.user_id, now)
    log.info("lair_offered", user=str(character.user_id), place=place.name)
    return obj


async def progress_on_ride(
    db: AsyncSession,
    character: Character,
    ride: Any,
    entered: set[str],
    started: datetime,
    ended: datetime,
) -> dict[str, Any] | None:
    """The lair's tiles this journey entered, added to those visited; at five its
    great chest opens. Returns the summary's `lair`, or None if no lair's tile was
    entered."""
    rows = (
        await db.execute(
            select(WorldObject).where(
                WorldObject.user_id == character.user_id,
                WorldObject.kind == LAIR,
                WorldObject.status.in_(["SPAWNED", "CLAIMED"]),
                WorldObject.spawned_at <= ended,
                WorldObject.expires_at >= started,
            )
        )
    ).scalars()
    for obj in rows:
        payload = dict(obj.payload or {})
        cells = list(payload.get("cells") or [])
        if not entered & set(cells):
            continue
        if obj.status == "CLAIMED" and obj.claimed_ride_id != getattr(ride, "id", None):
            continue
        visited = list(payload.get("visited") or [])
        new = [c for c in cells if c in entered and c not in visited]
        visited += new
        need = int(payload.get("need") or config()["need"])
        # Reassigned, not edited in place: the JSON column does not see edits.
        obj.payload = {**payload, "visited": visited}
        done = len(visited) >= need
        rewards = None
        if done and obj.status == "SPAWNED":
            obj.status = "CLAIMED"
            obj.claimed_at = ended
            obj.claimed_ride_id = getattr(ride, "id", None)
            obj.claim_payload = {"method": "LAIR", "visited": len(visited)}
        if done:
            rewards = await _open_great_chest(db, character, obj, getattr(ride, "id", None))
        await db.flush()
        count = min(len(visited), len(cells))
        return {
            "id": str(obj.id),
            "name": str(payload.get("name") or "The lair"),
            "visited": count,
            "need": need,
            "tiles": len(cells),
            "newTiles": len(new),
            "done": done,
            "endsAt": obj.expires_at.isoformat(),
            "rewards": rewards,
            "line": (
                f"You visited {count} of the lair's {len(cells)} tiles. The great chest is yours!"
                if done
                else f"{count} / {need} of the lair's tiles visited."
            ),
        }
    return None


async def _open_great_chest(
    db: AsyncSession, character: Character, obj: WorldObject, ride_id: uuid.UUID | None
) -> dict[str, Any] | None:
    """What the great chest holds, paid once (`lair:{id}`): None when it was paid."""
    from app.economy import service as economy
    from app.inventory import catalog as runes
    from app.inventory import service as inventory

    key = f"lair:{obj.id}"
    if not await inventory.first_time(db, character.user_id, key):
        return None
    rules = config()
    coins = int(obj.reward_ac or rules["coins"])
    await economy.credit(
        db, character.user_id, coins, "LAIR", ride_id=ride_id, payload={"lair": str(obj.payload.get("name"))}
    )
    items = [
        await inventory.give_item(db, character, "RARE", key=key, source="LAIR", ride_id=ride_id, from_name=CHEST_NAME),
        await inventory.give_consumable(db, character, "SEALED_CHEST_RARE", source="LAIR", from_name=CHEST_NAME),
    ]
    # The first great chest ever holds Ingwaz.
    rune = await inventory.give_rune(db, character, str(rules["rune"]), key="lair:first-rune", ride_id=ride_id)
    if rune is not None:
        rune = {**rune, "name": runes.name(rune["rune"])}
    rewards = {"coins": coins, "xp": 0, "items": items, "rune": rune, "title": None}
    db.add(inventory.note_paid(character.user_id, "LAIR", key, ride_id=ride_id, payload=rewards))
    await db.flush()
    return rewards


async def lairs_offered(db: AsyncSession, user_id: uuid.UUID) -> int:
    return int(
        await db.scalar(
            select(func.count(WorldObject.id)).where(WorldObject.user_id == user_id, WorldObject.kind == LAIR)
        )
        or 0
    )
