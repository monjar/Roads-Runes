"""What a rider earns in coins a week, read from the coin ledger, beside what the
stall asks. Read-only.

Usage: python scripts/price_check.py [--subject rider-1 | --user <uuid>] [--weeks 8]

The stall's prices (app/inventory/config/loot.json) are starting values. They
should come from the real sum of the ledger, not from estimates: this prints the
average coins earned a week (spending left out), the kinds they came from, and
how many weeks of earning each stall offer costs.

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
from app.inventory import loot
from app.inventory.service import iso_week as week_of
from app.users.models import User

# Coins that are not earned by playing: a correction, or an item sold back.
NOT_EARNED = {"ADJUSTMENT", "ITEM_SOLD"}


async def find_user(db, subject: str | None, user_id: str | None) -> User:
    if user_id:
        user = await db.get(User, uuid.UUID(user_id))
    else:
        # Developer sign-in stores its subject as "dev:<subject>"; Apple's is used as is.
        user = await db.scalar(select(User).where(User.apple_subject.in_([f"dev:{subject}", subject])))
    if user is None:
        raise SystemExit("No such rider")
    return user


def weekly(rows: list[tuple[datetime, int, str]], weeks: int, now: datetime) -> dict[str, object]:
    """Pure: the ledger rows (when, amount, kind) to a weekly average and its sources."""
    since = now - timedelta(weeks=weeks)
    earned: dict[str, int] = defaultdict(int)
    kinds: Counter[str] = Counter()
    spent = 0
    for when, amount, kind in rows:
        if when < since:
            continue
        if amount < 0:
            spent += -amount
        elif kind not in NOT_EARNED:
            earned[week_of(when)] += amount
            kinds[kind] += amount
    total = sum(earned.values())
    return {
        "weeks": weeks,
        "earned": total,
        "perWeek": round(total / max(1, weeks), 1),
        "spent": spent,
        "byWeek": dict(sorted(earned.items())),
        "byKind": dict(kinds.most_common()),
    }


async def check(subject: str | None, user_id: str | None, weeks: int) -> None:
    now = datetime.now(UTC)
    async with get_session_factory()() as db:
        user = await find_user(db, subject, user_id)
        rows = (
            await db.execute(
                select(WalletTransaction.created_at, WalletTransaction.amount, WalletTransaction.kind).where(
                    WalletTransaction.user_id == user.id
                )
            )
        ).all()
    found = weekly([(w if w.tzinfo else w.replace(tzinfo=UTC), a, k) for w, a, k in rows], weeks, now)
    print(f"{user.display_name}: {found['earned']} coins earned in {weeks} weeks, {found['perWeek']} a week")
    print(f"  spent {found['spent']}")
    for week, coins in found["byWeek"].items():  # type: ignore[union-attr]
        print(f"  {week}: {coins}")
    print("  from:")
    for kind, coins in found["byKind"].items():  # type: ignore[union-attr]
        print(f"    {kind:<16} {coins}")
    per_week = float(found["perWeek"]) or 1.0  # type: ignore[arg-type]
    print("  the stall, in weeks of earning:")
    for offer, price in loot.book()["stall"]["prices"].items():
        print(f"    {offer:<20} {price:>4} coins  {price / per_week:.1f} weeks")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    who = parser.add_mutually_exclusive_group()
    who.add_argument("--subject", default="rider-1", help="the sign-in subject (dev riders: rider-1)")
    who.add_argument("--user", help="the user id")
    parser.add_argument("--weeks", type=int, default=8)
    args = parser.parse_args()
    asyncio.run(check(None if args.user else args.subject, args.user, args.weeks))


if __name__ == "__main__":
    main()
