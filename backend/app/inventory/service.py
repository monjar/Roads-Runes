"""The only code that changes what runes a character holds, their ranks, what is
inscribed, and the cuts on the map (docs/ROADMAP.md, 0.7.0); and, from 0.7.2, the
gear a character has and wears, the consumables in the bag, what drops, what the
stall sells and what each level pays. Every change is an `ItemEvent` keyed by
ride and object (or week, or level), so a rerun writes nothing twice.

Coins go through economy.service and nowhere else; items never touch the coin or
XP caps."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.characters.models import Character
from app.core.errors import Conflict, NotFound
from app.core.security import utcnow
from app.inventory import catalog, gear, loot
from app.inventory.models import InventoryItem, ItemEvent, Loadout, RuneCut, RuneHolding
from app.lore import catalog as lore

RUNE_SETS = ("RUNES", "GROUND")


async def _once(db: AsyncSession, user_id: uuid.UUID, key: str) -> bool:
    """True the first time a key is seen for this user."""
    seen = await db.scalar(select(ItemEvent.id).where(ItemEvent.user_id == user_id, ItemEvent.key == key))
    return seen is None


async def first_time(db: AsyncSession, user_id: uuid.UUID, key: str) -> bool:
    """True while nothing has been written under this ledger key (legends, lairs and
    buried treasure pay once by their keys, 0.8.0)."""
    return await _once(db, user_id, key)


def note_paid(
    user_id: uuid.UUID, kind: str, key: str, *, ride_id: uuid.UUID | None, payload: dict[str, Any]
) -> ItemEvent:
    """The ledger line that makes a key paid."""
    return ItemEvent(user_id=user_id, kind=kind, key=key, ride_id=ride_id, payload=payload)


async def holdings(db: AsyncSession, character: Character) -> dict[str, RuneHolding]:
    rows = await db.execute(select(RuneHolding).where(RuneHolding.character_id == character.id))
    return {h.rune_id: h for h in rows.scalars()}


async def loadout(db: AsyncSession, character: Character) -> Loadout:
    row = await db.scalar(select(Loadout).where(Loadout.character_id == character.id))
    if row is None:
        row = Loadout(
            user_id=character.user_id,
            character_id=character.id,
            inscriptions=[],
            repeats=0,
            gear={},
            consumables={},
            finishes_since_rare=0,
        )
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
        raise NotFound("You don't have that rune yet. Pick up one of its rune stones first.", code="RUNE_NOT_HELD")
    if holding.rank >= catalog.MAX_RANK:
        raise Conflict("That rune is already at its highest rank. Raise another rune instead.", code="RUNE_MAX_RANK")
    cost = catalog.rank_cost(holding.rank + 1) or {}
    if holding.shards < int(cost.get("shards", 0)):
        short = int(cost["shards"]) - holding.shards
        raise Conflict(
            f"Raising it needs {short} more rune stone{'s' if short != 1 else ''}. "
            "Find them on your journeys, then try again.",
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
    if await _recording(db, character.user_id):
        raise Conflict("Runes can't be changed during a journey. Change them when you're back.", code="LOADOUT_LOCKED")
    if len(set(runes)) != len(runes):
        raise Conflict("A rune can only go in one slot. Pick a different rune for the other.", code="RUNE_TWICE")
    slots = catalog.slots_for_level(character.overall_level)
    if len(runes) > slots:
        later = [at for at in catalog.book()["slotsAtLevel"] if at > character.overall_level]
        then = f" The next opens at level {later[0]}." if later else ""
        raise Conflict(f"You have {slots} rune slot{'s' if slots != 1 else ''} at your level.{then}", code="NO_SLOT")
    held = await holdings(db, character)
    missing = [r for r in runes if r not in held]
    if missing:
        raise Conflict(
            "You can only inscribe runes you have. Pick up their rune stones first.",
            code="RUNE_NOT_HELD",
            details={"runes": missing},
        )
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


async def _recording(db: AsyncSession, user_id: uuid.UUID) -> bool:
    """A journey is being recorded: what it carries was frozen when it began."""
    from app.rides.models import Ride

    found = await db.scalar(select(Ride.id).where(Ride.user_id == user_id, Ride.status == "RECORDING").limit(1))
    return found is not None


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


# --- gear and consumables (0.7.2) -------------------------------------------------


async def owned_items(db: AsyncSession, character: Character) -> list[InventoryItem]:
    """Gear held now (worn or in the bag), newest first."""
    rows = await db.execute(
        select(InventoryItem)
        .where(InventoryItem.character_id == character.id, InventoryItem.sold_at.is_(None))
        .order_by(InventoryItem.acquired_at.desc(), InventoryItem.id)
    )
    return list(rows.scalars())


async def _worn_rows(db: AsyncSession, character: Character) -> dict[str, InventoryItem]:
    """What is worn, by slot, as rows; whether or not the slot is open yet."""
    row = await db.scalar(select(Loadout).where(Loadout.character_id == character.id))
    ids = {slot: value for slot, value in ((row.gear if row else None) or {}).items() if value}
    if not ids:
        return {}
    wanted = []
    for value in ids.values():
        try:
            wanted.append(uuid.UUID(str(value)))
        except ValueError:
            continue
    rows = await db.execute(
        select(InventoryItem).where(
            InventoryItem.id.in_(wanted),
            InventoryItem.character_id == character.id,
            InventoryItem.sold_at.is_(None),
        )
    )
    by_id = {str(r.id): r for r in rows.scalars()}
    return {slot: by_id[str(value)] for slot, value in ids.items() if str(value) in by_id}


async def worn_items(db: AsyncSession, character: Character) -> dict[str, InventoryItem]:
    """What is worn, by slot, as rows (a slot not open yet included)."""
    return await _worn_rows(db, character)


async def worn(db: AsyncSession, character: Character | None) -> dict[str, str]:
    """The gear that counts: worn, in its own slot, in a slot the level has opened.
    Slot to catalogue item id, for the sheet."""
    if character is None:
        return {}
    rows = await _worn_rows(db, character)
    return gear.worn({slot: r.item_id for slot, r in rows.items()}, character.overall_level)


async def sheet_for(db: AsyncSession, character: Character | None) -> Any:
    """The character as it stands now: knacks, inscribed runes and worn gear."""
    from app.characters.sheet import build_sheet

    if character is None:
        return build_sheet(None)
    return build_sheet(character, await inscribed(db, character), await worn(db, character))


async def bag(db: AsyncSession, character: Character) -> list[InventoryItem]:
    """Gear held and not worn."""
    on = {str(r.id) for r in (await _worn_rows(db, character)).values()}
    return [r for r in await owned_items(db, character) if str(r.id) not in on]


async def legendaries_had(db: AsyncSession, user_id: uuid.UUID) -> set[str]:
    """Every Legendary this player has ever had: worn, in the bag, or sold."""
    rows = await db.execute(
        select(InventoryItem.item_id).where(
            InventoryItem.user_id == user_id, InventoryItem.item_id.in_(sorted(gear.legendaries()))
        )
    )
    return set(rows.scalars())


def item_found(
    *,
    source: str,
    item: InventoryItem | None = None,
    consumable: str | None = None,
    from_name: str | None = None,
) -> dict[str, Any]:
    """An ItemFoundOut: what a drop, a quest or a sealed chest gave."""
    if item is not None:
        entry = gear.by_id()[item.item_id]
        return {
            "kind": "GEAR",
            "inventoryItemId": str(item.id),
            "itemId": item.item_id,
            "consumable": None,
            "name": entry["name"],
            "icon": entry["icon"],
            "rarity": item.rarity,
            "slot": entry["slot"],
            "source": source,
            "fromName": from_name,
            "soldOnTheSpot": item.sold_at is not None,
            "soldFor": item.sold_for,
        }
    entry = gear.consumables_by_id()[str(consumable)]
    return {
        "kind": "CONSUMABLE",
        "inventoryItemId": None,
        "itemId": None,
        "consumable": consumable,
        "name": entry["name"],
        "icon": entry["icon"],
        "rarity": None,
        "slot": None,
        "source": source,
        "fromName": from_name,
        "soldOnTheSpot": False,
        "soldFor": None,
    }


async def add_gear(
    db: AsyncSession,
    character: Character,
    item_id: str,
    *,
    source: str,
    key: str,
    ride_id: uuid.UUID | None = None,
    sell_scale: float = 1.0,
) -> InventoryItem:
    """An item into the bag. Into a full bag it is sold on the spot, for its sell
    price, so a find is never lost and never turned away."""
    from app.economy import service as economy

    entry = gear.by_id()[item_id]
    now = utcnow()
    row = InventoryItem(
        user_id=character.user_id,
        character_id=character.id,
        item_id=item_id,
        rarity=entry["rarity"],
        source=source,
        source_key=key,
        ride_id=ride_id,
        acquired_at=now,
    )
    if len(await bag(db, character)) >= gear.bag_size():
        row.sold_at = now
        row.sold_for = gear.sell_price(entry["rarity"], sell_scale)
    db.add(row)
    await db.flush()
    if row.sold_for:
        await economy.credit(
            db,
            character.user_id,
            row.sold_for,
            "ITEM_SOLD",
            ride_id=ride_id,
            payload={"itemId": item_id, "inventoryItemId": str(row.id), "name": entry["name"], "onTheSpot": True},
        )
    return row


async def consumable_counts(db: AsyncSession, character: Character | None) -> dict[str, int]:
    """Every consumable, with how many are held (0 for none)."""
    counts = dict.fromkeys(gear.CONSUMABLES, 0)
    if character is None:
        return counts
    row = await db.scalar(select(Loadout).where(Loadout.character_id == character.id))
    for cid, n in ((row.consumables if row else None) or {}).items():
        if cid in counts:
            counts[cid] = max(0, int(n))
    return counts


async def add_consumables(db: AsyncSession, character: Character, counts: dict[str, int]) -> None:
    row = await loadout(db, character)
    held = dict(row.consumables or {})
    for cid, n in counts.items():
        if cid in gear.CONSUMABLES and n > 0:
            held[cid] = int(held.get(cid, 0)) + int(n)
    # Reassigned, not edited in place: the JSON column does not see edits.
    row.consumables = held
    await db.flush()


async def take_consumable(db: AsyncSession, character: Character, cid: str, *, why: str) -> bool:
    """Spends one, if there is one."""
    row = await loadout(db, character)
    held = dict(row.consumables or {})
    if int(held.get(cid, 0)) <= 0:
        return False
    held[cid] = int(held[cid]) - 1
    row.consumables = held
    db.add(
        ItemEvent(
            user_id=character.user_id,
            kind="USE",
            key=f"use:{cid}:{uuid.uuid4().hex}",
            payload={"consumable": cid, "why": why},
        )
    )
    await db.flush()
    return True


async def drop_for(
    db: AsyncSession,
    character: Character,
    obj: Any,
    *,
    sheet: Any = None,
    ride_id: uuid.UUID | None = None,
) -> dict[str, Any] | None:
    """What a creature defeated or a chest opened leaves, once (`drop:{objectId}`).
    Counts towards the pity rule either way. Returns an ItemFoundOut, or None."""
    from app.world_objects.variants import display_name

    if obj.kind not in ("MONSTER", "CHEST"):
        return None
    key = f"drop:{obj.id}"
    if not await _once(db, character.user_id, key):
        return None
    sheet = sheet if sheet is not None else await sheet_for(db, character)
    row = await loadout(db, character)
    payload = obj.payload or {}
    drop = loot.roll(
        str(obj.id),
        obj.kind,
        int(obj.tier or 1),
        bounty=bool(obj.bounty),
        grudge=bool(payload.get("grudge")),
        mossy=payload.get("variant") == "MOSSY",
        loot_find=float(getattr(sheet, "loot_find_pct", 0.0) or 0.0),
        pity_due=row.finishes_since_rare >= int(loot.book()["pityAfter"]),
        had_legendaries=await legendaries_had(db, character.user_id),
    )
    source = "BOUNTY" if obj.bounty else str(obj.kind)
    from_name = display_name(payload) or None
    found = None
    if drop is not None and drop.kind == "GEAR" and drop.item_id:
        item = await add_gear(
            db,
            character,
            drop.item_id,
            source=source,
            key=key,
            ride_id=ride_id,
            sell_scale=float(sheet.rules.get("SELL_SCALE", 1.0)),
        )
        found = item_found(source=source, item=item, from_name=from_name)
    elif drop is not None and drop.consumable:
        await add_consumables(db, character, {drop.consumable: 1})
        found = item_found(source=source, consumable=drop.consumable, from_name=from_name)
    row.finishes_since_rare = 0 if drop is not None and drop.rare_or_better else row.finishes_since_rare + 1
    db.add(
        ItemEvent(
            user_id=character.user_id,
            kind="DROP",
            key=key,
            ride_id=ride_id,
            payload=found or {"none": True},
        )
    )
    await db.flush()
    return found


async def give_item(
    db: AsyncSession,
    character: Character,
    rarity: str,
    *,
    key: str,
    source: str,
    ride_id: uuid.UUID | None = None,
    from_name: str | None = None,
    item_id: str | None = None,
) -> dict[str, Any]:
    """A guaranteed item (a legend's phase, a lair's great chest, buried treasure),
    of this rarity in a slot seeded by the key; a Legendary already had is the Rare
    of its slot. The caller pays it once by its key. Returns an ItemFoundOut."""
    sheet = await sheet_for(db, character)
    had = await legendaries_had(db, character.user_id)
    chosen = item_id or loot.sealed_item(key, rarity, had)
    item = await add_gear(
        db,
        character,
        chosen,
        source=source,
        key=key,
        ride_id=ride_id,
        sell_scale=float(sheet.rules.get("SELL_SCALE", 1.0)),
    )
    return item_found(source=source, item=item, from_name=from_name)


async def give_consumable(
    db: AsyncSession, character: Character, cid: str, *, source: str, from_name: str | None = None
) -> dict[str, Any]:
    """One consumable into the bag; the caller pays it once by its key."""
    await add_consumables(db, character, {cid: 1})
    return item_found(source=source, consumable=cid, from_name=from_name)


async def map_for(
    db: AsyncSession, character: Character, obj: Any, *, ride_id: uuid.UUID | None = None
) -> dict[str, Any] | None:
    """A treasure map from a tier-3 chest, three times in ten (0.8.0): seeded by the
    chest and given once (`map:{objectId}`). Returns an ItemFoundOut, or None."""
    if obj.kind != "CHEST" or not loot.treasure_map_drops(str(obj.id), obj.kind, int(obj.tier or 1)):
        return None
    key = f"map:{obj.id}"
    if not await _once(db, character.user_id, key):
        return None
    from app.world_objects.variants import display_name

    found = await give_consumable(
        db, character, "TREASURE_MAP", source="CHEST", from_name=display_name(obj.payload or {}) or None
    )
    db.add(ItemEvent(user_id=character.user_id, kind="DROP", key=key, ride_id=ride_id, payload=found))
    await db.flush()
    return found


async def grant_quest_items(
    db: AsyncSession, character: Character, quest: Any, *, ride_id: uuid.UUID | None = None
) -> list[dict[str, Any]]:
    """The items a finished quest offered (`rewards.items`), once (`quest-item:{questId}`).
    A Legendary already had is the Rare of its slot."""
    wanted = [i for i in ((quest.rewards or {}).get("items") or []) if gear.item(str(i.get("itemId") or ""))]
    if not wanted:
        return []
    key = f"quest-item:{quest.id}"
    if not await _once(db, character.user_id, key):
        return []
    sheet = await sheet_for(db, character)
    had = await legendaries_had(db, character.user_id)
    out = []
    for i, entry in enumerate(wanted):
        item_id = str(entry["itemId"])
        if item_id in had:
            item_id = gear.item_for(gear.by_id()[item_id]["slot"], "RARE")
        item = await add_gear(
            db,
            character,
            item_id,
            source="QUEST",
            key=f"{key}:{i}",
            ride_id=ride_id,
            sell_scale=float(sheet.rules.get("SELL_SCALE", 1.0)),
        )
        if gear.by_id()[item_id]["rarity"] == "LEGENDARY":
            had.add(item_id)
        out.append(item_found(source="QUEST", item=item, from_name=quest.title))
    db.add(ItemEvent(user_id=character.user_id, kind="QUEST_ITEM", key=key, ride_id=ride_id, payload={"items": out}))
    await db.flush()
    return out


def quest_reward_items(quest_id: Any, difficulty: str | None) -> list[dict[str, Any]]:
    """What a new quest offers (`rewards.items`), seeded by its id."""
    item = loot.quest_reward(str(quest_id), difficulty)
    return [item] if item else []


# --- every level pays (0.7.2) -----------------------------------------------------


async def _keys_like(db: AsyncSession, user_id: uuid.UUID, prefix: str) -> set[str]:
    rows = await db.execute(select(ItemEvent.key).where(ItemEvent.user_id == user_id, ItemEvent.key.like(f"{prefix}%")))
    return set(rows.scalars())


async def pay_level(
    db: AsyncSession, character: Character, level: int, *, paid: set[str] | None = None
) -> list[dict[str, Any]] | None:
    """Gives what a level pays (progression/levels.py), once (`level:{n}`). The
    slots, the stall and titles come with the level; only consumables are given.
    Returns the level's rewards, or None if it was already paid."""
    from app.progression import levels

    key = f"level:{level}"
    if paid is not None:
        if key in paid:
            return None
    elif not await _once(db, character.user_id, key):
        return None
    rewards = [{**r, "level": level} for r in levels.rewards_for_level(level)]
    counts = levels.consumables_for_level(level)
    if counts:
        await add_consumables(db, character, counts)
    db.add(ItemEvent(user_id=character.user_id, kind="LEVEL", key=key, payload={"level": level, "rewards": rewards}))
    await db.flush()
    if paid is not None:
        paid.add(key)
    return rewards


async def catch_up_levels(db: AsyncSession, character: Character) -> list[dict[str, Any]]:
    """Pays every level from 2 up to the character's that has not been paid: the
    levels reached before 0.7.2. Level 1 is where everyone starts, and pays nothing."""
    paid = await _keys_like(db, character.user_id, "level:")
    out: list[dict[str, Any]] = []
    for n in range(2, character.overall_level + 1):
        got = await pay_level(db, character, n, paid=paid)
        if got:
            out.extend(got)
    return out


# --- wearing, selling, using (0.7.2) ------------------------------------------------


async def _own_item(db: AsyncSession, character: Character, inventory_item_id: uuid.UUID) -> InventoryItem:
    item = await db.get(InventoryItem, inventory_item_id)
    if item is None or item.character_id != character.id or item.sold_at is not None:
        raise NotFound("We couldn't find that item in your bag. It may have been sold.", code="NO_SUCH_ITEM")
    return item


async def wear(db: AsyncSession, character: Character, slot: str, inventory_item_id: uuid.UUID | None) -> Loadout:
    """Puts an item in its slot (the one there goes back in the bag), or takes the
    slot's item off. Free, but not during a journey: it was started with what it
    carries."""
    if await _recording(db, character.user_id):
        raise Conflict("Gear can't be changed during a journey. Change it when you're back.", code="LOADOUT_LOCKED")
    if slot not in gear.SLOTS:
        raise Conflict("There's no slot by that name. Pick one of your five slots.", code="WRONG_SLOT")
    if not gear.slot_open(slot, character.overall_level):
        raise Conflict(
            f"That slot opens at level {gear.slot_opens_at(slot)}.",
            code="SLOT_LOCKED",
            details={"opensAtLevel": gear.slot_opens_at(slot)},
        )
    row = await loadout(db, character)
    current = {k: v for k, v in (row.gear or {}).items() if v}
    if inventory_item_id is None:
        if slot in current:
            if len(await bag(db, character)) >= gear.bag_size():
                raise Conflict("Your bag is full. Sell something first, then take this off.", code="BAG_FULL")
            current.pop(slot)
    else:
        item = await _own_item(db, character, inventory_item_id)
        home = gear.by_id()[item.item_id]["slot"]
        if home != slot:
            name = gear.slots_by_id()[home]["name"]
            raise Conflict(
                f"That goes in the {name} slot. Wear it there instead.", code="WRONG_SLOT", details={"slot": home}
            )
        current[slot] = str(item.id)
    row.gear = current
    db.add(
        ItemEvent(
            user_id=character.user_id,
            kind="WEAR",
            key=f"wear:{slot}:{utcnow().isoformat()}",
            payload={"slot": slot, "inventoryItemId": str(inventory_item_id) if inventory_item_id else None},
        )
    )
    await db.flush()
    return row


async def sell(db: AsyncSession, character: Character, inventory_item_id: uuid.UUID) -> int:
    """Sells an item from the bag for coins (more with a Tinker's Satchel worn)."""
    from app.economy import service as economy

    item = await _own_item(db, character, inventory_item_id)
    if str(item.id) in {str(r.id) for r in (await _worn_rows(db, character)).values()}:
        raise Conflict("Take it off before you sell it.", code="TAKE_OFF_FIRST")
    sheet = await sheet_for(db, character)
    price = gear.sell_price(item.rarity, float(sheet.rules.get("SELL_SCALE", 1.0)))
    item.sold_at = utcnow()
    item.sold_for = price
    if price > 0:
        await economy.credit(
            db,
            character.user_id,
            price,
            "ITEM_SOLD",
            payload={
                "itemId": item.item_id,
                "inventoryItemId": str(item.id),
                "name": gear.by_id()[item.item_id]["name"],
            },
        )
    db.add(
        ItemEvent(
            user_id=character.user_id,
            kind="SELL",
            key=f"sell:{item.id}",
            payload={"itemId": item.item_id, "soldFor": price},
        )
    )
    await db.flush()
    return price


def _none_left() -> Conflict:
    return Conflict("You don't have any of those. Find them on journeys or at the stall.", code="NONE_LEFT")


async def use_consumable(
    db: AsyncSession,
    settings: Any,
    character: Character,
    cid: str,
    *,
    latitude: float | None = None,
    longitude: float | None = None,
) -> dict[str, Any]:
    """Uses a map piece or a treasure map (0.8.0), or opens a sealed chest. A lamp is
    lit from the map and a rest token is used by itself, so neither is used here."""
    held = await consumable_counts(db, character)
    if held.get(cid, 0) <= 0:
        raise _none_left()
    if cid == "LAMP":
        raise Conflict("Lamps are lit from the map. Pick a place and light a lamp there.", code="NOT_USED_HERE")
    if cid == "REST_TOKEN":
        raise Conflict("A rest token is used by itself when you miss a day. Keep it in your bag.", code="NOT_USED_HERE")
    if cid == "MAP_FRAGMENT":
        if latitude is None or longitude is None:
            raise Conflict("A map piece needs to know where you are. Turn on your location and try again.",
                           code="NEEDS_LOCATION")  # fmt: skip
        return await _use_map_piece(db, settings, character, latitude, longitude)
    if cid == "TREASURE_MAP":
        from app.inventory import treasure

        if latitude is None or longitude is None:
            raise Conflict("A treasure map needs to know where you are. Turn on your location and try again.",
                           code="NEEDS_LOCATION")  # fmt: skip
        return await treasure.bury(db, settings, character, latitude, longitude)
    return await _open_sealed(db, character, cid)


async def _use_map_piece(
    db: AsyncSession, settings: Any, character: Character, latitude: float, longitude: float
) -> dict[str, Any]:
    """Reveals the tiles round the nearest hidden place within 5 km that still has
    unexplored tiles round it. Nothing is used when there is none."""
    import h3

    from app.discoveries.sensitivity import is_sensitive
    from app.discoveries.service import nearby, user_found
    from app.exploration.cells import cell_for
    from app.exploration.models import UserExplorationCell
    from app.exploration.service import reveal

    rules = loot.book()["mapPiece"]
    sheet = await sheet_for(db, character)
    rings = max(1, round(float(rules["rings"]) * float(sheet.rules.get("FRAGMENT_SCALE", 1.0))))
    places = [
        d
        for d in await nearby(db, latitude, longitude, float(rules["searchMeters"]), limit=200)
        if not is_sensitive(d.name, d.tags)
    ]
    found = await user_found(db, character.user_id, [d.id for d in places])
    chosen = None
    disk: list[str] = []
    for place in [d for d in places if d.id not in found][:50]:
        disk = sorted(h3.grid_disk(cell_for(place.latitude, place.longitude, settings.h3_resolution), rings))
        known = set(
            (
                await db.execute(
                    select(UserExplorationCell.h3_index).where(
                        UserExplorationCell.user_id == character.user_id, UserExplorationCell.h3_index.in_(disk)
                    )
                )
            ).scalars()
        )
        if any(cell not in known for cell in disk):
            chosen = place
            break
    if chosen is None:
        raise Conflict("No hidden places near here. Try it somewhere new.", code="NO_HIDDEN_PLACE")
    revealed = await reveal(db, character.user_id, disk, settings.h3_resolution, via="ITEM")
    await take_consumable(db, character, "MAP_FRAGMENT", why=f"place:{chosen.id}")
    return {
        "consumable": "MAP_FRAGMENT",
        "revealedTiles": revealed,
        "placeName": chosen.name,
        "latitude": chosen.latitude,
        "longitude": chosen.longitude,
    }


async def _open_sealed(db: AsyncSession, character: Character, cid: str) -> dict[str, Any]:
    """A sealed chest opened: one item of its rarity, seeded by the ledger key."""
    if await _recording(db, character.user_id):
        raise Conflict("Open it when your journey is over.", code="OPEN_LATER")
    if len(await bag(db, character)) >= gear.bag_size():
        raise Conflict("Your bag is full. Sell something first, then open it.", code="BAG_FULL")
    opened = await _keys_like(db, character.user_id, f"open:{cid}:")
    key = f"open:{cid}:{len(opened)}"
    item_id = loot.sealed_item(key, gear.SEALED[cid], await legendaries_had(db, character.user_id))
    await take_consumable(db, character, cid, why=key)
    item = await add_gear(db, character, item_id, source="SEALED_CHEST", key=key)
    found = item_found(source="CHEST", item=item, from_name=gear.consumables_by_id()[cid]["name"])
    db.add(ItemEvent(user_id=character.user_id, kind="OPEN", key=key, payload=found))
    await db.flush()
    return {"consumable": cid, "itemFound": found}


# --- the stall (0.7.2) --------------------------------------------------------------


def iso_week(now: datetime) -> str:
    year, week, _ = now.isocalendar()
    return f"{year}-W{week:02d}"


def week_resets_at(now: datetime) -> datetime:
    """Next Monday at midnight, UTC: when the stall has new things."""
    from datetime import UTC, timedelta

    start = now.astimezone(UTC).replace(hour=0, minute=0, second=0, microsecond=0)
    return start + timedelta(days=7 - start.weekday())


def stall_opens_at() -> int:
    return int(loot.book()["stall"]["opensAtLevel"])


async def stall(db: AsyncSession, character: Character, now: datetime | None = None) -> dict[str, Any]:
    """This week's four offers, computed on read; which have been bought."""
    now = now or utcnow()
    week = iso_week(now)
    bought = await _keys_like(db, character.user_id, f"stall:{week}:")
    offers = []
    for offer in loot.stall_offers(str(character.user_id), week):
        if offer["kind"] == "GEAR":
            entry = gear.by_id()[offer["itemId"]]
            shown = {"name": entry["name"], "icon": entry["icon"], "slot": entry["slot"], "text": entry["text"]}
        else:
            entry = gear.consumables_by_id()[offer["consumable"]]
            shown = {"name": entry["name"], "icon": entry["icon"], "text": entry["text"]}
        offers.append({**offer, **shown, "bought": f"stall:{week}:{offer['id']}" in bought})
    return {
        "open": character.overall_level >= stall_opens_at(),
        "opensAtLevel": stall_opens_at(),
        "week": week,
        "resetsAt": week_resets_at(now),
        "offers": offers,
    }


async def buy(db: AsyncSession, character: Character, offer_id: str, now: datetime | None = None) -> dict[str, Any]:
    """Buys one of this week's offers: the coins first, then the thing."""
    from app.economy import service as economy

    now = now or utcnow()
    if character.overall_level < stall_opens_at():
        raise Conflict(f"The stall opens at level {stall_opens_at()}.", code="STALL_CLOSED")
    week = iso_week(now)
    offer = next((o for o in loot.stall_offers(str(character.user_id), week) if o["id"] == offer_id), None)
    if offer is None:
        raise NotFound("That isn't at the stall this week. Look at what's there now.", code="NO_SUCH_OFFER")
    key = f"stall:{week}:{offer_id}"
    if not await _once(db, character.user_id, key):
        raise Conflict("You've already bought that this week. The stall has new things each Monday.",
                       code="ALREADY_BOUGHT")  # fmt: skip
    if offer["kind"] == "GEAR" and len(await bag(db, character)) >= gear.bag_size():
        raise Conflict("Your bag is full. Sell something first, then buy it.", code="BAG_FULL")
    await economy.debit(
        db,
        character.user_id,
        int(offer["price"]),
        "STALL",
        payload={
            "week": week,
            "offerId": offer_id,
            "itemId": offer.get("itemId"),
            "consumable": offer.get("consumable"),
        },
    )
    if offer["kind"] == "GEAR":
        item = await add_gear(db, character, offer["itemId"], source="STALL", key=key)
        found = item_found(source="STALL", item=item)
    else:
        await add_consumables(db, character, {offer["consumable"]: 1})
        found = item_found(source="STALL", consumable=offer["consumable"])
    db.add(ItemEvent(user_id=character.user_id, kind="STALL", key=key, payload={"price": offer["price"], **found}))
    await db.flush()
    return found
