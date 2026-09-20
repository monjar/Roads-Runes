"""The day's bounty and the days in a row."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import select

from app.core.geo import destination_point
from app.db.session import get_session_factory
from app.economy.models import UserStreak
from app.rides.models import Ride
from app.world_objects import service as world_objects
from tests.test_first_playable_journey import ORIGIN, seed_discoveries
from tests.test_world_objects import PACE_ONLY, line_trace, ride, set_methods, spawned


async def test_one_bounty_a_day_worth_double(explorer_client):
    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    assert (await c.get("/world/objects/bounty")).status_code == 404
    objects = await spawned(c)
    bounties = [o for o in objects if o["bounty"]]
    assert len(bounties) == 1, [o["name"] for o in objects]
    bounty = bounties[0]
    assert bounty["kind"] == "MONSTER"
    assert bounty["rewardAC"] == 2 * world_objects.load_ac_rules()["monster"][str(bounty["tier"])]
    assert bounty["expiresAt"].startswith((datetime.now(UTC).date() + timedelta(days=1)).isoformat()[:10])
    assert (await c.get("/world/objects/bounty")).json()["id"] == bounty["id"]

    # Looking again today does not conjure a second one, even after this one is beaten.
    world_objects.forget_checks()
    assert sum(1 for o in await spawned(c) if o["bounty"]) == 1
    await set_methods(bounty["id"], PACE_ONLY)
    here = (bounty["latitude"], bounty["longitude"])
    summary = await ride(c, line_trace(destination_point(*here, 180, 800), destination_point(*here, 0, 800), 8.0))
    assert any(line["kind"] == "BOUNTY" and line["ac"] == bounty["rewardAC"] for line in summary["acBreakdown"])
    world_objects.forget_checks()
    assert not [o for o in await spawned(c) if o["bounty"]]
    assert (await c.get("/world/objects/bounty")).status_code == 404


async def _ride_on(c, day: datetime, meters: float = 3000.0) -> dict:
    """An outing on a given day, long enough (or not) to count."""
    start = ORIGIN
    end = destination_point(*start, 90, meters / 2)
    pts = line_trace(start, end, 5.0)
    shift = day - datetime.fromisoformat(pts[0]["timestamp"])
    for p in pts:
        p["timestamp"] = (datetime.fromisoformat(p["timestamp"]) + shift).isoformat()
    return await ride(c, pts)


async def test_days_in_a_row_pay_and_reset(explorer_client):
    c = explorer_client
    # Yesterday and today, so the streak is still alive when the character card is read:
    # one whose last day is older than yesterday is over, whatever the row says.
    day1 = datetime.now(UTC).replace(hour=9, minute=0, second=0, microsecond=0) - timedelta(days=1)
    summary = await _ride_on(c, day1)
    assert summary["streak"] == {"days": 1, "longest": 1, "extended": True, "milestone": None, "bonusAC": 5}
    assert any(line["kind"] == "STREAK" and line["ac"] == 5 for line in summary["acBreakdown"])
    # The same day again adds nothing; the next day adds a day.
    assert (await _ride_on(c, day1 + timedelta(hours=3)))["streak"]["extended"] is False
    summary = await _ride_on(c, day1 + timedelta(days=1))
    assert summary["streak"]["days"] == 2 and summary["streak"]["bonusAC"] == 10
    card = (await c.get("/character")).json()
    assert card["streakDays"] == 2 and card["streakActiveToday"] is True
    # A short stroll does not count as a day.
    assert (await _ride_on(c, day1 + timedelta(days=2), meters=600))["streak"]["extended"] is False
    # A gap starts over; the longest is remembered.
    summary = await _ride_on(c, day1 + timedelta(days=5))
    assert summary["streak"]["days"] == 1 and summary["streak"]["longest"] == 2
    character = (await c.get("/character")).json()
    assert (character["streakDays"], character["longestStreakDays"]) == (1, 2)


async def test_the_seventh_day_has_a_purse(explorer_client):
    c = explorer_client
    me = (await c.get("/users/me")).json()
    async with get_session_factory()() as db:
        db.add(
            UserStreak(
                user_id=uuid.UUID(me["id"]),
                current_days=6,
                longest_days=6,
                last_activity_date=datetime(2026, 6, 6, tzinfo=UTC).date(),
            )
        )
        await db.commit()
    summary = await _ride_on(c, datetime(2026, 6, 7, 9, tzinfo=UTC))
    assert summary["streak"]["days"] == 7 and summary["streak"]["milestone"] == 7
    assert summary["streak"]["bonusAC"] == 35 + 100
    assert (await c.delete("/character")).status_code == 204
    async with get_session_factory()() as db:
        assert await db.scalar(select(UserStreak).where(UserStreak.user_id == uuid.UUID(me["id"]))) is None
        assert await db.scalar(select(Ride).where(Ride.user_id == uuid.UUID(me["id"]))) is not None
