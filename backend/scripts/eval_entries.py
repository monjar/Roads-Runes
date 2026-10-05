"""Ten model-written journal entries, for reading in one sitting (docs/ROADMAP.md
0.7.2, the model-written entry). Calls the real model: it costs a little money.

Usage:
    ANTHROPIC_API_KEY=... python scripts/eval_entries.py --sample
    ANTHROPIC_API_KEY=... python scripts/eval_entries.py --subject rider-1

`--sample` writes for ten made-up journeys (no database); otherwise the rider's
last ten processed journeys are read (read-only: nothing is stored). Each entry
is printed with the facts it was given, the composed entry beside it, and why
the check would refuse it, if it would. At the end: how many passed, and
whether any two share a first sentence (the eval asks that none do).
"""

from __future__ import annotations

import argparse
import asyncio
from typing import Any

from app.chronicle import written
from app.core.config import get_settings
from app.core.llm import build_llm

SAMPLES: list[tuple[str, float, dict[str, Any]]] = [
    ("RIDE", 4200, {"newCells": 0, "streak": {"days": 1}}),
    ("RIDE", 18400, {"newCells": 12, "streak": {"days": 3},
                     "worldObjects": {"fights": [{"speciesId": "fen-troll", "outcome": "SEEN_OFF"}]}}),
    ("RUN", 6100, {"newCells": 4, "streak": {"days": 7}, "worldObjects": {"claimed": [{"kind": "CHEST"}]}}),
    ("WALK", 2300, {"newCells": 0, "streak": {"days": 2}}),
    ("RIDE", 42000, {"newCells": 30, "questCompleted": True, "streak": {"days": 5}}),
    ("RIDE", 9000, {"newCells": 2, "streak": {"days": 1},
                    "worldObjects": {"fights": [{"speciesId": "hedge-dragon", "outcome": "LOOSENED"}]}}),
    ("RUN", 12000, {"newCells": 9, "streak": {"days": 12},
                    "worldObjects": {"claimed": [{"kind": "CHEST"}, {"kind": "CHEST"}]}}),
    ("RIDE", 65000, {"newCells": 44, "streak": {"days": 30},
                     "worldObjects": {"fights": [{"speciesId": "hill-wyvern", "outcome": "SEEN_OFF"},
                                                 {"speciesId": "stone-giant", "outcome": "LOOSENED"}]}}),
    ("WALK", 5200, {"newCells": 6, "streak": {"days": 4}, "questCompleted": True}),
    ("RIDE", 15000, {"newCells": 0, "streak": {"days": 9},
                     "worldObjects": {"fights": [{"speciesId": "tavern-brownie", "outcome": "SEEN_OFF"}]}}),
]  # fmt: skip


async def journeys(subject: str | None) -> list[tuple[str, float, dict[str, Any]]]:
    if subject is None:
        return SAMPLES
    from sqlalchemy import select

    import app.db.models  # noqa: F401  # register every mapper before the first query
    from app.db.session import get_session_factory
    from app.rides.models import Ride
    from app.users.models import User

    async with get_session_factory()() as db:
        user = await db.scalar(select(User).where(User.apple_subject.in_([f"dev:{subject}", subject])))
        if user is None:
            raise SystemExit("No such rider")
        rows = (
            await db.execute(
                select(Ride)
                .where(Ride.user_id == user.id, Ride.status == "PROCESSED")
                .order_by(Ride.started_at.desc())
                .limit(10)
            )
        ).scalars()
        return [(r.activity, float(r.distance_meters or 0), dict(r.processing_result or {})) for r in rows]


async def main(subject: str | None) -> None:
    llm = build_llm(get_settings())
    if not llm.enabled:
        raise SystemExit("No model: set ANTHROPIC_API_KEY")
    passed = 0
    firsts: list[str] = []
    for i, (activity, meters, summary) in enumerate(await journeys(subject), start=1):
        facts = written.facts_for(activity, meters, summary)
        text = await llm.write(written.SYSTEM, written.prompt_for(facts), max_tokens=written.MAX_TOKENS,
                               timeout=written.TIMEOUT_S)  # type: ignore[attr-defined]  # fmt: skip
        lines = written.sentences(text)
        wrong = written.problems(lines, facts) if lines else ["nothing written"]
        passed += not wrong
        if lines:
            firsts.append(lines[0])
        print(f"--- {i}. {facts}")
        if summary.get("entry"):
            print(f"composed: {summary['entry']}")
        print(f"model:    {' '.join(lines) or '(nothing)'}")
        print(f"check:    {'kept' if not wrong else '; '.join(wrong)}")
    repeated = len(firsts) - len(set(firsts))
    print(f"\n{passed} of 10 would be kept; {repeated} first sentence(s) repeated.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    who = parser.add_mutually_exclusive_group()
    who.add_argument("--sample", action="store_true", help="ten made-up journeys, no database")
    who.add_argument("--subject", help="the sign-in subject (dev riders: rider-1)")
    args = parser.parse_args()
    asyncio.run(main(None if args.sample or not args.subject else args.subject))
