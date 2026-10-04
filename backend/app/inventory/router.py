"""Runes held, ranked and inscribed; the cuts on the map; deeds (0.7.0)."""

from __future__ import annotations

from datetime import datetime
from typing import Any

from fastapi import APIRouter
from pydantic import Field

from app.characters.service import get_character
from app.core.deps import CurrentUser, DBDep
from app.core.schemas import APIModel
from app.inventory import catalog, deeds, service
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
