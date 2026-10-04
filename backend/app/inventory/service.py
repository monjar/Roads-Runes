"""The only code that changes what runes a character holds, their ranks, what is
inscribed, and the cuts on the map (docs/ROADMAP.md, 0.7.0). Every change is an
`ItemEvent` keyed by ride and object, so a rerun writes nothing twice."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.characters.models import Character
from app.core.errors import Conflict, NotFound
from app.core.security import utcnow
from app.inventory import catalog
from app.inventory.models import ItemEvent, Loadout, RuneCut, RuneHolding
from app.lore import catalog as lore

RUNE_SETS = ("RUNES", "GROUND")


async def _once(db: AsyncSession, user_id: uuid.UUID, key: str) -> bool:
    """True the first time a key is seen for this user."""
    seen = await db.scalar(select(ItemEvent.id).where(ItemEvent.user_id == user_id, ItemEvent.key == key))
    return seen is None


async def holdings(db: AsyncSession, character: Character) -> dict[str, RuneHolding]:
    rows = await db.execute(select(RuneHolding).where(RuneHolding.character_id == character.id))
    return {h.rune_id: h for h in rows.scalars()}


async def loadout(db: AsyncSession, character: Character) -> Loadout:
    row = await db.scalar(select(Loadout).where(Loadout.character_id == character.id))
    if row is None:
        row = Loadout(user_id=character.user_id, character_id=character.id, inscriptions=[], repeats=0)
        db.add(row)
        await db.flush()
    return row


async def inscribed(db: AsyncSession, character: Character | None) -> dict[str, int]:
    """The runes acting now, with their ranks: inscribed, held, and within the
    slots the character's level has opened."""
    if character is None:
        return {}
    held = await holdings(db, character)
    row = await db.scalar(select(Loadout).where(Loadout.character_id == character.id))
    names = list((row.inscriptions if row else None) or [])[: catalog.slots_for_level(character.overall_level)]
    return {r: held[r].rank for r in names if r in held and catalog.holdable(r)}


def rune_of_piece(payload: dict[str, Any] | None) -> str | None:
    """The rune a picked-up stone is, if it is one."""
    payload = payload or {}
    if payload.get("setId") not in RUNE_SETS:
        return None
    rune = lore.rune_by_name(str(payload.get("piece") or ""))
    return rune["id"] if rune and catalog.holdable(rune["id"]) else None


async def add_stone(
    db: AsyncSession, character: Character, rune_id: str, *, key: str, ride_id: uuid.UUID | None = None
) -> dict[str, Any] | None:
    """A rune stone found: the rune is held from its first stone; after that each
    stone is a shard towards the next rank. Returns what it did, or None when this
    stone was already counted."""
    if not catalog.holdable(rune_id) or not await _once(db, character.user_id, key):
        return None
    held = await holdings(db, character)
    row = await loadout(db, character)
    holding = held.get(rune_id)
    if holding is None:
        db.add(
            RuneHolding(
                user_id=character.user_id,
                character_id=character.id,
                rune_id=rune_id,
                rank=1,
                shards=0,
                first_found_at=utcnow(),
            )
        )
        row.repeats = 0
        result = {"rune": rune_id, "new": True, "rank": 1, "shards": 0}
    else:
        holding.shards += 1
        row.repeats += 1
        result = {"rune": rune_id, "new": False, "rank": holding.rank, "shards": holding.shards}
    db.add(
        ItemEvent(user_id=character.user_id, kind="STONE", key=key, rune_id=rune_id, ride_id=ride_id, payload=result)
    )
    await db.flush()
    return result


async def give_rune(
    db: AsyncSession, character: Character, rune_id: str, *, key: str, ride_id: uuid.UUID | None = None
) -> dict[str, Any] | None:
    """A rune given, by a chapter's ending: held at rank I, or a stone towards the
    next rank if it already is."""
    return await add_stone(db, character, rune_id, key=key, ride_id=ride_id)


async def raise_rank(db: AsyncSession, character: Character, rune_id: str) -> RuneHolding:
    from app.economy import service as economy

    holding = (await holdings(db, character)).get(rune_id)
    if holding is None:
        raise NotFound("That rune is not held", code="RUNE_NOT_HELD")
    if holding.rank >= catalog.MAX_RANK:
        raise Conflict("That rune is as deep as it goes", code="RUNE_MAX_RANK")
    cost = catalog.rank_cost(holding.rank + 1) or {}
    if holding.shards < int(cost.get("shards", 0)):
        raise Conflict(
            f"Raising it needs {cost['shards']} more stones of it",
            code="RUNE_NEEDS_STONES",
            details={"shards": holding.shards, "needed": cost.get("shards")},
        )
    if cost.get("coins"):
        await economy.debit(
            db, character.user_id, int(cost["coins"]), "RUNE_RANK", payload={"rune": rune_id, "rank": holding.rank + 1}
        )
    holding.shards -= int(cost.get("shards", 0))
    holding.rank += 1
    db.add(
        ItemEvent(
            user_id=character.user_id,
            kind="RANK",
            key=f"rank:{rune_id}:{holding.rank}",
            rune_id=rune_id,
            payload={"rank": holding.rank},
        )
    )
    await db.flush()
    return holding


async def inscribe(db: AsyncSession, character: Character, runes: list[str]) -> Loadout:
    """Puts runes in the slots. Free to change, but not during an outing: the ride
    was started with what it carries."""
    from app.rides.models import Ride

    recording = await db.scalar(
        select(Ride.id).where(Ride.user_id == character.user_id, Ride.status == "RECORDING").limit(1)
    )
    if recording is not None:
        raise Conflict("Not while you are out. Change them when you are back.", code="LOADOUT_LOCKED")
    if len(set(runes)) != len(runes):
        raise Conflict("A rune goes in one slot", code="RUNE_TWICE")
    slots = catalog.slots_for_level(character.overall_level)
    if len(runes) > slots:
        raise Conflict(f"{slots} slot{'s' if slots != 1 else ''} open at your level", code="NO_SLOT")
    held = await holdings(db, character)
    missing = [r for r in runes if r not in held]
    if missing:
        raise Conflict("Only runes you hold can be inscribed", code="RUNE_NOT_HELD", details={"runes": missing})
    row = await loadout(db, character)
    row.inscriptions = list(runes)
    db.add(
        ItemEvent(
            user_id=character.user_id,
            kind="INSCRIBE",
            key=f"inscribe:{utcnow().isoformat()}",
            payload={"runes": list(runes)},
        )
    )
    await db.flush()
    return row


async def record_cut(
    db: AsyncSession,
    user_id: uuid.UUID,
    *,
    ride_id: uuid.UUID | None,
    rune_id: str,
    latitude: float,
    longitude: float,
    source: str,
    woke: bool = False,
    place_name: str | None = None,
    at: datetime | None = None,
) -> RuneCut | None:
    """A rune cut, once per ride, rune and source."""
    existing = await db.scalar(
        select(RuneCut).where(RuneCut.ride_id == ride_id, RuneCut.rune_id == rune_id, RuneCut.source == source)
    )
    if existing is not None:
        return None
    cut = RuneCut(
        user_id=user_id,
        ride_id=ride_id,
        rune_id=rune_id,
        latitude=latitude,
        longitude=longitude,
        source=source,
        woke=woke,
        place_name=place_name,
        cut_at=at or utcnow(),
    )
    db.add(cut)
    await db.flush()
    return cut


async def cuts(db: AsyncSession, user_id: uuid.UUID, limit: int = 500) -> list[RuneCut]:
    rows = await db.execute(
        select(RuneCut).where(RuneCut.user_id == user_id).order_by(RuneCut.cut_at.desc()).limit(limit)
    )
    return list(rows.scalars())


async def spawn_hint(db: AsyncSession, user_id: uuid.UUID) -> dict[str, Any]:
    """What the spawner needs to place rune stones fairly: the runes held, whether
    the pity rule is due, and the Arcane Sight knack."""
    from app.characters.service import ability_map, maybe_character

    character = await maybe_character(db, user_id)
    if character is None:
        return {"held": set(), "pity": False, "arcaneSight": 0.0}
    held = set(await holdings(db, character))
    row = await db.scalar(select(Loadout).where(Loadout.character_id == character.id))
    from app.characters import catalog as abilities

    return {
        "held": held,
        "pity": bool(row and row.repeats >= int(catalog.book()["pityAfterRepeats"])),
        "arcaneSight": abilities.effect_total(ability_map(character), "RUNE_STONE_CHANCE"),
    }
