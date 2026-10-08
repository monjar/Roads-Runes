"""Days in a row with an outing that counted. Coins for keeping it up. One missed
day is forgiven by a rest token from the bag (0.7.2), spent here automatically."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import date, timedelta
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.economy.models import UserStreak
from app.economy.rules import ACLine, load_ac_rules


@dataclass
class StreakOutcome:
    days: int
    longest: int
    extended: bool
    milestone: int | None = None
    bonus_ac: int = 0
    # A rest token carried the streak over one missed day (0.7.2).
    rest_token_used: bool = False

    def to_dict(self) -> dict[str, Any]:
        return {
            "days": self.days,
            "longest": self.longest,
            "extended": self.extended,
            "milestone": self.milestone,
            "bonusAC": self.bonus_ac,
            "restTokenUsed": self.rest_token_used,
        }


async def get_streak(db: AsyncSession, user_id: uuid.UUID) -> UserStreak | None:
    return await db.scalar(select(UserStreak).where(UserStreak.user_id == user_id))


async def update_streak(db: AsyncSession, user_id: uuid.UUID, day: date, distance_meters: float) -> StreakOutcome:
    """Counts today if the outing was long enough: yesterday's streak grows, an older one starts again."""
    rules = load_ac_rules()["streak"]
    streak = await get_streak(db, user_id)
    if streak is None:
        streak = UserStreak(user_id=user_id, current_days=0, longest_days=0, last_activity_date=None)
        db.add(streak)
    if distance_meters < float(rules["minDistanceMeters"]):
        return StreakOutcome(streak.current_days, streak.longest_days, extended=False)
    if streak.last_activity_date == day:
        return StreakOutcome(streak.current_days, streak.longest_days, extended=False)
    rested = False
    if streak.last_activity_date == day - timedelta(days=1):
        streak.current_days += 1
    elif streak.last_activity_date == day - timedelta(days=2) and await _spend_rest_token(db, user_id, day):
        # One day missed and a rest token in the bag: the streak carries on.
        streak.current_days += 1
        rested = True
    else:
        streak.current_days = 1
    streak.last_activity_date = day
    streak.longest_days = max(streak.longest_days, streak.current_days)
    await db.flush()
    milestone = streak.current_days if str(streak.current_days) in rules["milestones"] else None
    return StreakOutcome(
        streak.current_days, streak.longest_days, extended=True, milestone=milestone, rest_token_used=rested
    )


async def _spend_rest_token(db: AsyncSession, user_id: uuid.UUID, day: date) -> bool:
    """Spends a rest token, if the player holds one (inventory.service is the writer)."""
    from app.characters.models import Character
    from app.inventory import service as inventory

    character = await db.scalar(select(Character).where(Character.user_id == user_id))
    if character is None:
        return False
    return await inventory.take_consumable(db, character, "REST_TOKEN", why=f"streak:{day.isoformat()}")


def streak_lines(outcome: StreakOutcome) -> list[ACLine]:
    """Coins for the day, capped per outing, plus the milestone's purse."""
    if not outcome.extended:
        return []
    rules = load_ac_rules()["streak"]
    lines = [
        ACLine(
            "STREAK",
            min(int(rules["maxPerRide"]), int(rules["perDay"]) * outcome.days),
            {"days": outcome.days},
        )
    ]
    if outcome.milestone is not None:
        lines.append(
            ACLine("STREAK", int(rules["milestones"][str(outcome.milestone)]), {"milestone": outcome.milestone})
        )
    outcome.bonus_ac = sum(line.ac for line in lines)
    return lines
