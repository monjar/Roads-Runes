"""The codex for one player: the fixed pages, and what they have met.

Nothing is stored. What a player has met is read from their own world objects
(every creature ever placed for them, every piece picked up), the way set
progress is, so there is no second record to drift from the first.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.core.feature_flags import is_enabled
from app.lore import catalog
from app.lore.schemas import (
    CodexCounts,
    CodexEntryOut,
    CodexOut,
    CreatureOut,
    ElderOut,
    PersonOut,
    RuneOut,
    SigilOut,
    SixOut,
)
from app.world_objects.models import WorldObject


class _Tally:
    def __init__(self) -> None:
        self.seen = 0
        self.seen_off = 0
        self.loosened = 0
        self.tiers: set[int] = set()
        self.first_seen: datetime | None = None
        self.last_seen_off: datetime | None = None


async def creature_tallies(db: AsyncSession, user_id: uuid.UUID) -> dict[str, _Tally]:
    rows = await db.execute(
        select(
            WorldObject.payload, WorldObject.status, WorldObject.tier, WorldObject.spawned_at, WorldObject.claimed_at
        ).where(WorldObject.user_id == user_id, WorldObject.kind == "MONSTER")
    )
    tallies: dict[str, _Tally] = {}
    for payload, status, tier, spawned_at, claimed_at in rows:
        species_id = catalog.species_of(payload)
        if species_id is None:
            continue
        t = tallies.setdefault(species_id, _Tally())
        t.seen += 1
        t.tiers.add(int(tier or 1))
        if t.first_seen is None or spawned_at < t.first_seen:
            t.first_seen = spawned_at
        if status == "CLAIMED":
            t.seen_off += 1
            if claimed_at and (t.last_seen_off is None or claimed_at > t.last_seen_off):
                t.last_seen_off = claimed_at
        elif (payload or {}).get("wounds"):
            t.loosened += 1
    return tallies


async def runes_found(db: AsyncSession, user_id: uuid.UUID) -> dict[str, int]:
    """How many of each rune-stone the player has picked up, by rune id."""
    rows = await db.execute(
        select(WorldObject.payload).where(
            WorldObject.user_id == user_id, WorldObject.kind == "COLLECTABLE", WorldObject.status == "CLAIMED"
        )
    )
    found: dict[str, int] = {}
    for (payload,) in rows:
        payload = payload or {}
        if payload.get("setId") != "RUNES":
            continue
        rune = catalog.rune_by_name(str(payload.get("piece") or ""))
        if rune is not None:
            found[rune["id"]] = found.get(rune["id"], 0) + 1
    return found


def _entry(e: dict[str, Any]) -> CodexEntryOut:
    author = catalog.cast_by_id()[e["by"]]
    return CodexEntryOut(
        id=e["id"],
        chapter=e["chapter"],
        title=e["title"],
        body=list(e["body"]),
        by=e["by"],
        byName=author["name"],
        characterClass=e.get("trade"),
    )


def _state(t: _Tally | None) -> str:
    if t is None or t.seen == 0:
        return "UNSEEN"
    return "MET" if (t.seen_off or t.loosened) else "SEEN"


async def codex(db: AsyncSession, settings: Settings, user_id: uuid.UUID) -> CodexOut:
    book = catalog.codex_book()
    entries = [_entry(e) for e in book["entries"] if not e.get("flag") or is_enabled(settings, e["flag"])]
    tallies = await creature_tallies(db, user_id)
    creatures = []
    for s in catalog.species():
        t = tallies.get(s["id"])
        creatures.append(
            CreatureOut(
                id=s["id"],
                name=s["name"],
                family=s["family"],
                flavour=s["flavour"],
                hint=s["hint"],
                page=s["page"],
                leaves=s["leaves"],
                wants=list(s["wants"]),
                minds=list(s["minds"]),
                rune=s.get("rune"),
                elders=[
                    ElderOut(
                        tier=e["tier"], name=e["name"], flavour=e["flavour"], seen=bool(t and e["tier"] in t.tiers)
                    )
                    for e in s["elders"]
                ],
                sigil=SigilOut(**s["sigil"]),
                state=_state(t),
                seenCount=t.seen if t else 0,
                seenOffCount=t.seen_off if t else 0,
                firstSeenAt=t.first_seen if t else None,
                lastSeenOffAt=t.last_seen_off if t else None,
            )
        )
    found = await runes_found(db, user_id)
    runes = [
        RuneOut(
            id=r["id"],
            name=r["name"],
            order=r["order"],
            six=r["six"],
            gloss=r["gloss"],
            lends=r["lends"],
            roadForm=r.get("roadForm"),
            state="HELD" if found.get(r["id"]) else "NOT_FOUND",
            found=found.get(r["id"], 0),
        )
        for r in catalog.runes()
    ]
    sixes = [SixOut(id=six, name=info["name"], how=info["how"]) for six, info in catalog.rune_book()["sixes"].items()]
    people = [
        PersonOut(
            id=p["id"],
            name=p["name"],
            role=p["role"],
            posts=p["posts"],
            page=p["page"],
            pageBy=p["pageBy"],
            lines=list(p["lines"]),
        )
        for p in catalog.cast()
    ]
    counts = CodexCounts(
        creaturesSeenOff=sum(1 for c in creatures if c.seenOffCount),
        creaturesSeen=sum(1 for c in creatures if c.state != "UNSEEN"),
        creaturesTotal=len(creatures),
        runesHeld=sum(1 for r in runes if r.state == "HELD"),
        runesTotal=len(runes),
    )
    return CodexOut(
        chapters=list(book["chapters"]),
        entries=entries,
        creatures=creatures,
        runes=runes,
        sixes=sixes,
        people=people,
        counts=counts,
    )
