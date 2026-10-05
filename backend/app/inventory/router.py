"""Runes held, ranked and inscribed; the cuts on the map; deeds (0.7.0). Gear, the
bag, consumables, the stall and what each level pays (0.7.2)."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from fastapi import APIRouter
from pydantic import Field

from app.characters.service import get_character
from app.core.deps import CurrentUser, DBDep, SettingsDep
from app.core.schemas import APIModel
from app.economy import service as economy
from app.inventory import catalog, deeds, gear, service
from app.inventory.schemas import (
    ConsumableOut,
    ConsumableUseOut,
    GearItemOut,
    InventoryOut,
    LevelOut,
    LevelRewardOut,
    SlotOut,
    StallOfferOut,
    StallOut,
    TreasureClueOut,
    UseIn,
    WearIn,
)
from app.lore import catalog as lore

router = APIRouter(tags=["runes"])


class RuneOut(APIModel):
    id: str
    name: str
    six: str
    gloss: str | None = None
    roadForm: str | None = None
    held: bool
    rank: int = 0
    shards: int = 0
    inscribed: bool = False
    # What it does inscribed, at its rank (or at rank I, for one not yet held).
    rule: str
    # The next rank's cost, if there is one: {"shards": 2, "coins": 100}.
    nextRank: dict[str, int] | None = None


class RunesOut(APIModel):
    runes: list[RuneOut]
    inscribed: list[str]
    slots: int
    # The levels the slots open at: [1, 10, 25].
    slotsAtLevel: list[int]


class InscribeIn(APIModel):
    runes: list[str] = Field(max_length=3)


class RuneCutOut(APIModel):
    runeId: str
    name: str
    latitude: float
    longitude: float
    woke: bool
    source: str
    placeName: str | None = None
    cutAt: datetime
    rideId: str | None = None


async def _runes_out(db: Any, character: Any) -> RunesOut:
    held = await service.holdings(db, character)
    row = await service.loadout(db, character)
    acting = await service.inscribed(db, character)
    out = []
    for entry in catalog.book()["runes"]:
        rune = lore.runes_by_id()[entry["id"]]
        holding = held.get(entry["id"])
        rank = holding.rank if holding else 0
        out.append(
            RuneOut(
                id=entry["id"],
                name=rune["name"],
                six=entry["six"],
                gloss=rune.get("gloss"),
                roadForm=rune.get("roadForm"),
                held=holding is not None,
                rank=rank,
                shards=holding.shards if holding else 0,
                inscribed=entry["id"] in acting,
                rule=catalog.rule_text(entry["id"], max(1, rank)),
                nextRank=catalog.rank_cost(rank + 1) if holding and rank < catalog.MAX_RANK else None,
            )
        )
    return RunesOut(
        runes=out,
        inscribed=list(row.inscriptions or []),
        slots=catalog.slots_for_level(character.overall_level),
        slotsAtLevel=list(catalog.book()["slotsAtLevel"]),
    )


@router.get("/runes", response_model=RunesOut)
async def runes(user: CurrentUser, db: DBDep) -> RunesOut:
    """The runes that can be held, which are, their ranks, and what is inscribed."""
    return await _runes_out(db, await get_character(db, user))


@router.post("/runes/{rune_id}/rank", response_model=RunesOut)
async def raise_rank(rune_id: str, user: CurrentUser, db: DBDep) -> RunesOut:
    """Two more stones and some coins take a held rune a rank deeper."""
    character = await get_character(db, user)
    await service.raise_rank(db, character, rune_id)
    return await _runes_out(db, character)


@router.put("/runes/inscribed", response_model=RunesOut)
async def inscribe(payload: InscribeIn, user: CurrentUser, db: DBDep) -> RunesOut:
    """Which held runes go in the slots. Free, but not during an outing."""
    character = await get_character(db, user)
    await service.inscribe(db, character, payload.runes)
    return await _runes_out(db, character)


@router.get("/runes/cuts", response_model=list[RuneCutOut])
async def cuts(user: CurrentUser, db: DBDep) -> list[RuneCutOut]:
    """Every rune cut with a track, for the marks on the maps."""
    return [
        RuneCutOut(
            runeId=c.rune_id,
            name=catalog.name(c.rune_id),
            latitude=c.latitude,
            longitude=c.longitude,
            woke=c.woke,
            source=c.source,
            placeName=c.place_name,
            cutAt=c.cut_at,
            rideId=str(c.ride_id) if c.ride_id else None,
        )
        for c in await service.cuts(db, user.id)
    ]


@router.get("/character/deeds")
async def character_deeds(user: CurrentUser, db: DBDep) -> dict[str, Any]:
    """The five deeds (a record, not points) and the three records."""
    return await deeds.standing(db, await get_character(db, user))


# --- gear, the bag, consumables, the stall, levels (0.7.2) -------------------------


def _item_out(row: Any, *, equipped: bool, sell_scale: float) -> GearItemOut:
    entry = gear.by_id()[row.item_id]
    return GearItemOut(
        id=row.id,
        itemId=row.item_id,
        name=entry["name"],
        slot=entry["slot"],
        rarity=row.rarity,
        icon=entry["icon"],
        text=entry["text"],
        sellPrice=gear.sell_price(row.rarity, sell_scale),
        equipped=equipped,
        acquiredAt=row.acquired_at,
        source=row.source,
    )


async def inventory_out(
    db: Any, character: Any, *, paid: list[dict[str, Any]] | None = None, sold_for: int | None = None
) -> InventoryOut:
    sheet = await service.sheet_for(db, character)
    scale = float(sheet.rules.get("SELL_SCALE", 1.0))
    on = await service.worn_items(db, character)
    worn_ids = {str(r.id) for r in on.values()}
    slots = [
        SlotOut(
            slot=slot["id"],
            name=slot["name"],
            opensAtLevel=int(slot["opensAtLevel"]),
            open=gear.slot_open(slot["id"], character.overall_level),
            item=_item_out(on[slot["id"]], equipped=True, sell_scale=scale) if slot["id"] in on else None,
        )
        for slot in gear.book()["slots"]
    ]
    bag = [
        _item_out(r, equipped=False, sell_scale=scale)
        for r in await service.owned_items(db, character)
        if str(r.id) not in worn_ids
    ]
    counts = await service.consumable_counts(db, character)
    row = await service.loadout(db, character)
    return InventoryOut(
        slots=slots,
        bag=bag,
        bagSize=gear.bag_size(),
        consumables=[
            ConsumableOut(id=c["id"], name=c["name"], icon=c["icon"], text=c["text"], count=counts.get(c["id"], 0))
            for c in gear.book()["consumables"]
        ],
        finishesSinceRare=row.finishes_since_rare,
        levelRewardsPaid=[LevelRewardOut(**r) for r in paid or []],
        soldFor=sold_for,
        walletBalance=await economy.balance(db, character.user_id) if sold_for is not None else None,
    )


@router.get("/inventory", response_model=InventoryOut, tags=["inventory"])
async def inventory(user: CurrentUser, db: DBDep) -> InventoryOut:
    """Gear worn and in the bag, the consumables, and the pity count. The first
    call pays the levels reached before 0.7.2, once (`levelRewardsPaid`)."""
    character = await get_character(db, user)
    paid = await service.catch_up_levels(db, character)
    return await inventory_out(db, character, paid=paid)


@router.put("/inventory/gear", response_model=InventoryOut, tags=["inventory"])
async def wear(payload: WearIn, user: CurrentUser, db: DBDep) -> InventoryOut:
    """Wears an item from the bag in its slot, or (itemId null) takes the slot's off.
    409 WRONG_SLOT, SLOT_LOCKED, LOADOUT_LOCKED (during a journey), BAG_FULL."""
    character = await get_character(db, user)
    await service.wear(db, character, payload.slot, payload.itemId)
    return await inventory_out(db, character)


@router.post("/inventory/items/{item_id}/sell", response_model=InventoryOut, tags=["inventory"])
async def sell(item_id: uuid.UUID, user: CurrentUser, db: DBDep) -> InventoryOut:
    """Sells an item from the bag for coins. 409 TAKE_OFF_FIRST when it is worn."""
    character = await get_character(db, user)
    price = await service.sell(db, character, item_id)
    return await inventory_out(db, character, sold_for=price)


@router.post("/inventory/consumables/{consumable_id}/use", response_model=ConsumableUseOut, tags=["inventory"])
async def use(
    consumable_id: str, user: CurrentUser, db: DBDep, settings: SettingsDep, payload: UseIn | None = None
) -> ConsumableUseOut:
    """Uses a map piece or a treasure map (both need where you are) or opens a sealed
    chest. 409 NONE_LEFT, NO_HIDDEN_PLACE, OPEN_LATER (during a journey), BAG_FULL,
    NOT_USED_HERE (a lamp or a rest token), NEEDS_LOCATION; a treasure map also
    ONE_AT_A_TIME (a clue is still open) and NO_PLACE_FOR_TREASURE."""
    character = await get_character(db, user)
    result = await service.use_consumable(
        db,
        settings,
        character,
        consumable_id,
        latitude=payload.latitude if payload else None,
        longitude=payload.longitude if payload else None,
    )
    return ConsumableUseOut(**result, inventory=await inventory_out(db, character))


@router.get("/inventory/treasure", response_model=list[TreasureClueOut], tags=["inventory"])
async def treasure(user: CurrentUser, db: DBDep) -> list[TreasureClueOut]:
    """The open treasure clues (0.8.0): one at a time, so empty or one. A clue is
    never a place on the map."""
    from app.inventory import treasure as buried

    await get_character(db, user)
    return [TreasureClueOut(**buried.clue_out(o)) for o in await buried.open_clues(db, user.id)]


@router.get("/inventory/stall", response_model=StallOut, tags=["inventory"])
async def stall(user: CurrentUser, db: DBDep) -> StallOut:
    """This week's four offers (computed on read, new each Monday) and which are bought."""
    found = await service.stall(db, await get_character(db, user))
    return StallOut(**{**found, "offers": [StallOfferOut(**o) for o in found["offers"]]})


@router.post("/inventory/stall/{offer_id}/buy", response_model=InventoryOut, tags=["inventory"])
async def buy(offer_id: str, user: CurrentUser, db: DBDep) -> InventoryOut:
    """Buys an offer. 409 STALL_CLOSED (under level 3), ALREADY_BOUGHT, BAG_FULL,
    INSUFFICIENT_AC; 404 NO_SUCH_OFFER."""
    character = await get_character(db, user)
    await service.buy(db, character, offer_id)
    return await inventory_out(db, character)


@router.get("/inventory/levels", response_model=list[LevelOut], tags=["inventory"])
async def levels(user: CurrentUser, db: DBDep) -> list[LevelOut]:
    """What each level from 1 to 50 pays, and which are reached."""
    from app.progression import levels as level_table

    character = await get_character(db, user)
    return [
        LevelOut(
            level=row["level"],
            reached=character.overall_level >= row["level"],
            rewards=[LevelRewardOut(**r) for r in row["rewards"]],
        )
        for row in level_table.table()
    ]
