"""Deeds: a record of what a character has done, not points to spend (docs/ROADMAP.md,
0.7.0). Five lifetime counts, each with five thresholds that give a deed title and
a crest frame, and three records that are not speed.

Totals are read from the processed outings, so a rerun counts nothing twice and
nothing is stored that could drift; only the highest threshold reached and the
records are kept, on `character_deeds`.
"""

from __future__ import annotations

import uuid
from collections import Counter
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.characters.models import Character
from app.core.geo import haversine_m
from app.inventory.models import CharacterDeed, RuneCut

DEEDS: tuple[dict[str, Any], ...] = (
    {
        "id": "LEGS",
        "name": "Legs",
        "unit": "km",
        "what": "Distance, in all",
        "tiers": [50, 250, 1000, 2500, 5000],
        "titles": ["Out and About", "Well Travelled", "Long in the Leg", "Road-Worn", "The Long Way Round"],
    },
    {
        "id": "LUNGS",
        "name": "Lungs",
        "unit": "m",
        "what": "Height climbed, in all",
        "tiers": [1000, 5000, 10000, 25000, 50000],
        "titles": ["Up and Over", "Hill-Minded", "Thin Air", "Above It All", "Cloud-Footed"],
    },
    {
        "id": "EYES",
        "name": "Eyes",
        "unit": "patches",
        "what": "New ground read, in all",
        "tiers": [100, 500, 1500, 4000, 10000],
        "titles": ["Looker", "Watcher", "Reader", "Close Reader", "Reads Everything"],
    },
    {
        "id": "HAND",
        "name": "Hand",
        "unit": "runes",
        "what": "Runes cut with your track",
        "tiers": [1, 5, 15, 40, 100],
        "titles": ["First Cut", "Steady Hand", "Cutter's Hand", "Sure Hand", "The Knife"],
    },
    {
        "id": "INK",
        "name": "Ink",
        "unit": "words",
        "what": "Words written out there",
        "tiers": [1, 10, 30, 75, 200],
        "titles": ["First Word", "Note-Taker", "Margin-Writer", "Ink-Stained", "The Record"],
    },
)
RECORDS: tuple[dict[str, str], ...] = (
    {"id": "RECORD_FURTHEST", "name": "Furthest from where you usually start", "unit": "km"},
    {"id": "RECORD_NEW_GROUND", "name": "Most new ground on one outing", "unit": "patches"},
    {"id": "RECORD_HIGHEST", "name": "Highest point reached", "unit": "m"},
)


def title_slug(deed_id: str, tier: int) -> str:
    return f"deed-{deed_id.lower()}-{tier}"


def frame_id(deed_id: str, tier: int) -> str:
    return f"{deed_id.lower()}-{tier}"


def tier_for(deed: dict[str, Any], value: float) -> int:
    return sum(1 for at in deed["tiers"] if value >= at)


async def totals(db: AsyncSession, user_id: uuid.UUID) -> dict[str, float]:
    """The five counts from the outings and the cuts."""
    from app.rides.models import Ride

    rides = (
        await db.execute(
            select(
                Ride.distance_meters,
                Ride.elevation_gain_meters,
                Ride.processing_result,
                Ride.encounter_events,
                Ride.objective_events,
            ).where(Ride.user_id == user_id, Ride.status == "PROCESSED")
        )
    ).all()
    legs = sum(float(r.distance_meters or 0) for r in rides) / 1000
    lungs = sum(float(r.elevation_gain_meters or 0) for r in rides)
    eyes = sum(int((r.processing_result or {}).get("newCells") or 0) for r in rides)
    ink = sum(
        1
        for r in rides
        for e in [*(r.encounter_events or []), *(r.objective_events or [])]
        if len(str((e or {}).get("note") or "").strip()) >= 12
    )
    hand = int(await db.scalar(select(func.count(RuneCut.id)).where(RuneCut.user_id == user_id)) or 0)
    return {"LEGS": legs, "LUNGS": lungs, "EYES": float(eyes), "HAND": float(hand), "INK": float(ink)}


async def _row(db: AsyncSession, character: Character, deed_id: str) -> CharacterDeed:
    row = await db.scalar(
        select(CharacterDeed).where(CharacterDeed.character_id == character.id, CharacterDeed.deed_id == deed_id)
    )
    if row is None:
        row = CharacterDeed(user_id=character.user_id, character_id=character.id, deed_id=deed_id, value=0.0, tier=0)
        db.add(row)
    return row


async def usual_start(db: AsyncSession, user_id: uuid.UUID) -> tuple[float, float] | None:
    """Where outings usually begin: the most common start, to about a kilometre."""
    from app.rides.models import Ride, RidePoint

    first_points = (
        await db.execute(
            select(RidePoint.latitude, RidePoint.longitude)
            .join(Ride, Ride.id == RidePoint.ride_id)
            .where(Ride.user_id == user_id, Ride.status == "PROCESSED", RidePoint.sequence == 0)
        )
    ).all()
    if not first_points:
        return None
    buckets = Counter((round(p.latitude, 2), round(p.longitude, 2)) for p in first_points)
    (lat, lon), _ = buckets.most_common(1)[0]
    return lat, lon


async def update(
    db: AsyncSession, character: Character, *, ride: Any, points: list[Any], new_cells: int
) -> dict[str, Any]:
    """After an outing: the counts recomputed, any threshold newly reached paid as a
    deed title, and the records beaten. Returns what changed, for the reckoning."""
    from app.progression.service import award_title

    reached: list[dict[str, Any]] = []
    counts = await totals(db, character.user_id)
    for deed in DEEDS:
        row = await _row(db, character, deed["id"])
        row.value = round(counts[deed["id"]], 2)
        tier = tier_for(deed, row.value)
        while row.tier < tier:
            row.tier += 1
            name = await award_title(db, character, title_slug(deed["id"], row.tier), ride_id=ride.id)
            reached.append(
                {
                    "deed": deed["id"],
                    "name": deed["name"],
                    "tier": row.tier,
                    "title": name,
                    "frame": frame_id(deed["id"], row.tier),
                }
            )
    records: list[dict[str, Any]] = []
    candidates: dict[str, float] = {"RECORD_NEW_GROUND": float(new_cells)}
    altitudes = [p.altitude for p in points if getattr(p, "altitude", None) is not None]
    if altitudes:
        candidates["RECORD_HIGHEST"] = float(max(altitudes))
    home = await usual_start(db, character.user_id)
    if home is not None and points:
        candidates["RECORD_FURTHEST"] = (
            max(haversine_m(home[0], home[1], p.latitude, p.longitude) for p in points) / 1000
        )
    for record in RECORDS:
        value = candidates.get(record["id"])
        if value is None or value <= 0:
            continue
        row = await _row(db, character, record["id"])
        if value > row.value:
            beaten = row.value > 0
            row.value = round(value, 2)
            row.ride_id = ride.id
            if beaten:
                records.append(
                    {"record": record["id"], "name": record["name"], "value": row.value, "unit": record["unit"]}
                )
    await db.flush()
    return {"reached": reached, "records": records}


async def standing(db: AsyncSession, character: Character) -> dict[str, Any]:
    """Every deed and record as it stands, for the sheet."""
    rows = {
        r.deed_id: r
        for r in (await db.execute(select(CharacterDeed).where(CharacterDeed.character_id == character.id))).scalars()
    }
    deeds = []
    for deed in DEEDS:
        row = rows.get(deed["id"])
        value = row.value if row else 0.0
        tier = row.tier if row else 0
        deeds.append(
            {
                "id": deed["id"],
                "name": deed["name"],
                "what": deed["what"],
                "unit": deed["unit"],
                "value": value,
                "tier": tier,
                "next": deed["tiers"][tier] if tier < len(deed["tiers"]) else None,
                "title": deed["titles"][tier - 1] if tier else None,
                "frame": frame_id(deed["id"], tier) if tier else None,
            }
        )
    records = [
        {"id": r["id"], "name": r["name"], "unit": r["unit"], "value": rows[r["id"]].value if r["id"] in rows else None}
        for r in RECORDS
    ]
    return {"deeds": deeds, "records": records}
