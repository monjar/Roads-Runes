"""How the game is being played, read from the database. Read-only.

Usage: python scripts/play_report.py [--subject rider-1 | --user <uuid>] [--weeks 8]

Each release in docs/ROADMAP.md ends with an "it worked if" question about what
the rider does differently. This answers them from the rider's own data rather
than from memory: outings a week, how far and how much of it new, what was seen
off and what got away, coins in and out, quests and story steps finished.

Point DATABASE_URL at the database to read. For the hosted one, open a tunnel
first (`fly proxy 5433:5432 -a roadsandrunes-db`) and use that port. Nothing is
written.
"""

from __future__ import annotations

import argparse
import asyncio
import uuid
from collections import Counter, defaultdict
from datetime import UTC, datetime, timedelta

from sqlalchemy import select

import app.db.models  # noqa: F401  # register every mapper before the first query
from app.db.session import get_session_factory
from app.economy.models import WalletTransaction
from app.quests.models import QuestInstance
from app.rides.models import Ride
from app.users.models import User
from app.world_objects.models import WorldObject


def week_of(moment: datetime) -> str:
    year, week, _ = moment.isocalendar()
    return f"{year}-W{week:02d}"


async def find_user(db, subject: str | None, user_id: str | None) -> User:
    if user_id:
        user = await db.get(User, uuid.UUID(user_id))
    else:
        # Developer sign-in stores its subject as "dev:<subject>"; Apple's is used as is.
        user = await db.scalar(select(User).where(User.apple_subject.in_([f"dev:{subject}", subject])))
    if user is None:
        raise SystemExit("No such rider")
    return user


async def report(subject: str | None, user_id: str | None, weeks: int) -> None:
    since = datetime.now(UTC) - timedelta(weeks=weeks)
    async with get_session_factory()() as db:
        user = await find_user(db, subject, user_id)
        rides = (
            (
                await db.execute(
                    select(Ride)
                    .where(Ride.user_id == user.id, Ride.started_at >= since, Ride.status.in_(["PROCESSED", "FLAGGED"]))
                    .order_by(Ride.started_at)
                )
            )
            .scalars()
            .all()
        )
        objects = (
            (
                await db.execute(
                    select(WorldObject).where(WorldObject.user_id == user.id, WorldObject.spawned_at >= since)
                )
            )
            .scalars()
            .all()
        )
        coins = (
            (
                await db.execute(
                    select(WalletTransaction).where(
                        WalletTransaction.user_id == user.id, WalletTransaction.created_at >= since
                    )
                )
            )
            .scalars()
            .all()
        )
        quests = (
            (
                await db.execute(
                    select(QuestInstance).where(
                        QuestInstance.user_id == user.id,
                        QuestInstance.status == "COMPLETED",
                        QuestInstance.completed_at >= since,
                    )
                )
            )
            .scalars()
            .all()
        )

    print(f"Rider {user.display_name or user.id} — the last {weeks} weeks\n")

    by_week: dict[str, list[Ride]] = defaultdict(list)
    for ride in rides:
        by_week[week_of(ride.started_at)].append(ride)
    print("Outings a week")
    print(f"  {'week':<9} {'outings':>7} {'km':>7} {'new km':>7} {'XP':>6} {'failed':>6}")
    for week in sorted(by_week):
        group = by_week[week]
        km = sum(r.distance_meters for r in group) / 1000
        new_km = sum((r.processing_result or {}).get("newTerritoryMeters", 0) for r in group) / 1000
        xp = sum((r.processing_result or {}).get("xpAwarded", 0) for r in group)
        failed = sum(1 for r in group if "PROCESSING_ERROR" in (r.flags or []))
        print(f"  {week:<9} {len(group):>7} {km:>7.1f} {new_km:>7.1f} {xp:>6} {failed:>6}")

    print("\nThe world")
    monsters = [o for o in objects if o.kind == "MONSTER"]
    seen_off = [o for o in monsters if o.status == "CLAIMED"]
    loosened = [o for o in monsters if (o.payload or {}).get("wounds") and o.status != "CLAIMED"]
    print(f"  creatures placed {len(monsters)}, seen off {len(seen_off)}, loosened and left {len(loosened)}")
    chests = [o for o in objects if o.kind == "CHEST"]
    pieces = [o for o in objects if o.kind == "COLLECTABLE"]
    print(f"  boxes opened {sum(o.status == 'CLAIMED' for o in chests)} of {len(chests)}")
    print(f"  pieces picked up {sum(o.status == 'CLAIMED' for o in pieces)} of {len(pieces)}")
    species = Counter((o.payload or {}).get("speciesId") or (o.payload or {}).get("name") for o in seen_off)
    if species:
        print("  seen off: " + ", ".join(f"{name} ×{n}" for name, n in species.most_common()))

    print("\nCoins")
    earned = sum(t.amount for t in coins if t.amount > 0)
    spent = -sum(t.amount for t in coins if t.amount < 0)
    print(f"  in {earned}, out {spent}")
    kinds = Counter()
    for t in coins:
        kinds[t.kind] += t.amount
    for kind, amount in kinds.most_common():
        print(f"    {kind:<18} {amount:>6}")

    print("\nQuests")
    story = [q for q in quests if q.story_quest_id]
    print(f"  finished {len(quests)}, of which story steps {len(story)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--subject", default="rider-1", help="the sign-in subject (developer sign-in: rider-1)")
    parser.add_argument("--user", help="a user id, instead of the subject")
    parser.add_argument("--weeks", type=int, default=8)
    args = parser.parse_args()
    asyncio.run(report(args.subject, args.user, args.weeks))


if __name__ == "__main__":
    main()
