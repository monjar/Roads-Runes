"""How the game is being played, across every rider: what /admin shows. Read-only.

scripts/play_report.py answers the same questions for one rider from the terminal;
this is the whole of the database, over the last N days (UTC calendar days, today
included) beside the N days before them.

Rides in the two windows are read as a few columns each and counted here, which is
portable across PostgreSQL and SQLite and fine for tens of thousands of rides.
Everything else is counted by the database.
"""

from __future__ import annotations

from collections import Counter
from datetime import UTC, date, datetime, time, timedelta

from sqlalchemy import case, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.characters.models import Character
from app.db.base import utcnow
from app.economy.models import Wallet, WalletTransaction
from app.exploration.models import UserExplorationCell
from app.integrations.models import StravaConnection
from app.quests.models import QuestInstance
from app.rides.models import Ride
from app.users.models import User
from app.world_objects.models import WorldObject

# An outing is a ride that went through processing (play_report.py counts the same).
OUTING_STATUSES = ("PROCESSED", "FLAGGED")
PROCESSING_STATUSES = ("UPLOADED", "PROCESSING")
QUEST_ENDINGS = ("COMPLETED", "FAILED", "ABANDONED", "EXPIRED")
STUCK_AFTER = timedelta(hours=1)
UNFINISHED_AFTER = timedelta(hours=24)


async def _count(db: AsyncSession, stmt) -> int:
    return int(await db.scalar(stmt) or 0)


def _window(days: int, now: datetime) -> tuple[list[date], datetime, datetime]:
    first = now.date() - timedelta(days=days - 1)
    since = datetime.combine(first, time.min, tzinfo=UTC)
    return [first + timedelta(days=i) for i in range(days)], since, since - timedelta(days=days)


async def collect(db: AsyncSession, days: int, now: datetime | None = None) -> dict:
    now = now or utcnow()
    dates, since, before = _window(days, now)

    # Riders
    users_total = await _count(db, select(func.count()).select_from(User).where(User.deleted_at.is_(None)))
    signups = (await db.execute(select(User.created_at).where(User.created_at >= before))).scalars().all()
    classes = dict(
        (await db.execute(select(Character.character_class, func.count()).group_by(Character.character_class))).all()
    )
    strava = await _count(db, select(func.count()).select_from(StravaConnection))

    # Rides: both windows in one read, counted here.
    rides = (
        await db.execute(
            select(
                Ride.user_id,
                Ride.status,
                Ride.activity,
                Ride.started_at,
                Ride.distance_meters,
                Ride.moving_seconds,
                Ride.flags,
            ).where(Ride.started_at >= before)
        )
    ).all()
    current = [r for r in rides if r.started_at >= since]
    previous = [r for r in rides if r.started_at < since]
    outings = [r for r in current if r.status in OUTING_STATUSES]
    outings_before = [r for r in previous if r.status in OUTING_STATUSES]
    riders = {r.user_id for r in outings}
    riders_before = {r.user_id for r in outings_before}

    by_day: dict[date, list] = {d: [] for d in dates}
    for r in outings:
        by_day.setdefault(r.started_at.date(), []).append(r)
    signups_by_day = Counter(s.date() for s in signups if s >= since)
    daily = [
        {
            "date": d.isoformat(),
            "outings": len(by_day[d]),
            "riders": len({r.user_id for r in by_day[d]}),
            "km": round(sum(r.distance_meters for r in by_day[d]) / 1000, 1),
            "signups": signups_by_day.get(d, 0),
        }
        for d in dates
    ]

    stuck = await _count(
        db,
        select(func.count())
        .select_from(Ride)
        .where(Ride.status.in_(PROCESSING_STATUSES), Ride.updated_at < now - STUCK_AFTER),
    )
    unfinished = await _count(
        db,
        select(func.count())
        .select_from(Ride)
        .where(Ride.status == "RECORDING", Ride.started_at < now - UNFINISHED_AFTER),
    )

    # Exploration
    new_cells = await _count(
        db, select(func.count()).select_from(UserExplorationCell).where(UserExplorationCell.first_visited_at >= since)
    )
    new_cells_before = await _count(
        db,
        select(func.count())
        .select_from(UserExplorationCell)
        .where(UserExplorationCell.first_visited_at >= before, UserExplorationCell.first_visited_at < since),
    )

    # Quests: accepted in the window, and how the ones that ended in it ended.
    accepted = await _count(
        db, select(func.count()).select_from(QuestInstance).where(QuestInstance.accepted_at >= since)
    )
    ended = dict(
        (
            await db.execute(
                select(QuestInstance.status, func.count())
                .where(
                    QuestInstance.status.in_(QUEST_ENDINGS),
                    func.coalesce(QuestInstance.completed_at, QuestInstance.updated_at) >= since,
                )
                .group_by(QuestInstance.status)
            )
        ).all()
    )
    story_steps = await _count(
        db,
        select(func.count())
        .select_from(QuestInstance)
        .where(
            QuestInstance.status == "COMPLETED",
            QuestInstance.completed_at >= since,
            QuestInstance.story_quest_id.is_not(None),
        ),
    )
    ended_total = sum(ended.values())

    # Coins
    earned, spent = (
        await db.execute(
            select(
                func.coalesce(func.sum(case((WalletTransaction.amount > 0, WalletTransaction.amount), else_=0)), 0),
                func.coalesce(func.sum(case((WalletTransaction.amount < 0, -WalletTransaction.amount), else_=0)), 0),
            ).where(WalletTransaction.created_at >= since)
        )
    ).one()
    coin_kinds = (
        await db.execute(
            select(WalletTransaction.kind, func.sum(WalletTransaction.amount), func.count())
            .where(WalletTransaction.created_at >= since)
            .group_by(WalletTransaction.kind)
            .order_by(func.sum(WalletTransaction.amount).desc())
        )
    ).all()
    balances = await _count(db, select(func.coalesce(func.sum(Wallet.balance), 0)))

    # The world: what was placed in the window, and how much of it a ride claimed.
    placed = (
        await db.execute(
            select(
                WorldObject.kind,
                func.count(),
                func.coalesce(func.sum(case((WorldObject.status == "CLAIMED", 1), else_=0)), 0),
            )
            .where(WorldObject.spawned_at >= since)
            .group_by(WorldObject.kind)
            .order_by(WorldObject.kind)
        )
    ).all()

    return {
        "days": days,
        "since": since.isoformat(),
        "generatedAt": now.isoformat(),
        "riders": {
            "total": users_total,
            "new": sum(1 for s in signups if s >= since),
            "newBefore": sum(1 for s in signups if s < since),
            "active": len(riders),
            "activeBefore": len(riders_before),
            "returning": len(riders & riders_before),
            "classes": dict(sorted(classes.items(), key=lambda kv: -kv[1])),
            "strava": strava,
        },
        "rides": {
            "outings": len(outings),
            "outingsBefore": len(outings_before),
            "km": round(sum(r.distance_meters for r in outings) / 1000, 1),
            "kmBefore": round(sum(r.distance_meters for r in outings_before) / 1000, 1),
            "movingHours": round(sum(r.moving_seconds for r in outings) / 3600, 1),
            "byActivity": dict(Counter(r.activity for r in outings).most_common()),
            "byStatus": dict(Counter(r.status for r in current).most_common()),
            "failed": sum(1 for r in outings if "PROCESSING_ERROR" in (r.flags or [])),
            "stuck": stuck,
            "unfinished": unfinished,
        },
        "exploration": {"newCells": new_cells, "newCellsBefore": new_cells_before},
        "quests": {
            "accepted": accepted,
            "ended": {status: ended.get(status, 0) for status in QUEST_ENDINGS},
            "storySteps": story_steps,
            "completionRate": round(ended.get("COMPLETED", 0) / ended_total, 3) if ended_total else None,
        },
        "coins": {
            "earned": int(earned),
            "spent": int(spent),
            "balances": balances,
            "byKind": [{"kind": k, "amount": int(a), "count": n} for k, a, n in coin_kinds],
        },
        "world": [
            {"kind": k, "placed": n, "claimed": int(c), "rate": round(int(c) / n, 3) if n else None}
            for k, n, c in placed
        ],
        "daily": daily,
    }
