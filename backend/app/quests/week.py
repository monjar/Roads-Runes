"""The week's notice: one goal a week, pinned by Ada Pym (docs/ROADMAP.md, 0.6.2).

Worked out from the date, with no scheduler: the ISO week picks the notice, by
seed per player, and its target is fixed. Progress is read from the week's
processed outings. It pays once, through the single writers, keyed by week.
"""

from __future__ import annotations

import hashlib
import uuid
from datetime import UTC, date, datetime, timedelta
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

NOTICES: tuple[dict[str, Any], ...] = (
    {"kind": "OUTINGS", "title": "Three outings this week.", "target": 3, "unit": "outings"},
    {"kind": "NEW_GROUND", "title": "Forty patches of new ground this week.", "target": 40, "unit": "patches"},
    {"kind": "PLACES", "title": "Three places you have not found, this week.", "target": 3, "unit": "places"},
    {"kind": "SEEN_OFF", "title": "Two things seen off this week.", "target": 2, "unit": "things"},
)
PAY_COINS = 150
PAY_XP = 200
NOTICE_LINES = (
    "Pinned Monday. Comes down Sunday night.",
    "One for the week. No hurry until Saturday.",
    "Posted early. Somebody will want it done.",
)


def week_of(day: date) -> str:
    year, week, _ = day.isocalendar()
    return f"{year}-W{week:02d}"


def week_bounds(day: date) -> tuple[datetime, datetime]:
    start = datetime.combine(day - timedelta(days=day.isocalendar()[2] - 1), datetime.min.time(), tzinfo=UTC)
    return start, start + timedelta(days=7)


def notice_for(user_id: uuid.UUID, day: date) -> dict[str, Any]:
    week = week_of(day)
    digest = int(hashlib.sha256(f"{user_id}:{week}".encode()).hexdigest()[:8], 16)
    notice = dict(NOTICES[digest % len(NOTICES)])
    start, end = week_bounds(day)
    return {
        **notice,
        "week": week,
        "startsAt": start,
        "endsAt": end,
        "line": NOTICE_LINES[digest % len(NOTICE_LINES)],
        "postedBy": "Ada Pym",
        "coins": PAY_COINS,
        "xp": PAY_XP,
    }


def _count(kind: str, summary: dict[str, Any]) -> int:
    if kind == "OUTINGS":
        return 1
    if kind == "NEW_GROUND":
        return int(summary.get("newCells") or 0)
    if kind == "PLACES":
        return len(summary.get("discoveries") or [])
    if kind == "SEEN_OFF":
        claimed = (summary.get("worldObjects") or {}).get("claimed") or []
        return sum(1 for c in claimed if c.get("kind") == "MONSTER")
    return 0


async def standing(db: AsyncSession, user_id: uuid.UUID, day: date) -> dict[str, Any]:
    """This week's notice and how far along it is: the week's processed outings,
    counted, and whether it has been paid."""
    from app.progression.models import RewardEvent
    from app.rides.models import Ride

    notice = notice_for(user_id, day)
    rides = (
        await db.execute(
            select(Ride).where(
                Ride.user_id == user_id,
                Ride.status == "PROCESSED",
                Ride.started_at >= notice["startsAt"],
                Ride.started_at < notice["endsAt"],
            )
        )
    ).scalars()
    progress = 0
    for ride in rides:
        summary = ride.processing_result or {}
        # An outing that went nowhere does not count as one.
        if notice["kind"] == "OUTINGS" and (ride.distance_meters or 0) < 1000:
            continue
        progress += _count(notice["kind"], summary)
    paid = any(
        (r.payload or {}).get("week") == notice["week"]
        for r in (
            await db.execute(
                select(RewardEvent).where(RewardEvent.user_id == user_id, RewardEvent.reward_type == "WEEK_NOTICE")
            )
        ).scalars()
    )
    return {**notice, "progress": min(progress, notice["target"]), "done": progress >= notice["target"], "paid": paid}


async def settle(db: AsyncSession, user_id: uuid.UUID, day: date, *, ride_id: uuid.UUID | None = None) -> dict | None:
    """Pays the week's notice once, the first time its target is met. Returns
    the notice when this call paid it."""
    from app.characters.service import maybe_character
    from app.economy import service as economy
    from app.progression.engine import XPLine
    from app.progression.models import RewardEvent
    from app.progression.service import grant

    state = await standing(db, user_id, day)
    if not state["done"] or state["paid"]:
        return None
    character = await maybe_character(db, user_id)
    if character is None:
        return None
    db.add(
        RewardEvent(
            user_id=user_id,
            character_id=character.id,
            reward_type="WEEK_NOTICE",
            ride_id=ride_id,
            payload={"week": state["week"], "kind": state["kind"]},
        )
    )
    await economy.credit(db, user_id, PAY_COINS, "WEEK_NOTICE", ride_id=ride_id, payload={"week": state["week"]})
    await grant(db, character, [XPLine("WEEK_NOTICE", PAY_XP, {"week": state["week"]})], ride_id=ride_id)
    await db.flush()
    return {**state, "paid": True}
