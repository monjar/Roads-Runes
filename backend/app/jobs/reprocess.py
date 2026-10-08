"""Run a ride's processing again after it failed.

    fly ssh console -C "python -m app.jobs.reprocess <ride-id>"
    fly ssh console -C "python -m app.jobs.reprocess --list"

`process_ride_job` writes a ride off when processing throws: it rolls back, marks
the ride FLAGGED with PROCESSING_ERROR and pays nothing, and `process_ride` then
refuses it for good. That turns one bug into a lost outing. Only such a ride is
taken here. Its first run rolled back, so nothing it would have granted exists
yet, and running it again pays it once. A ride that processed cleanly is never
rerun: the XP and coin writers have no per-ride guard, and it would be paid twice.

This lives under app/ because the Fly image ships only app/ and alembic/.
"""

from __future__ import annotations

import argparse
import asyncio
import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import NotFound, RideInvalidState
from app.core.logging import get_logger
from app.db.session import get_session_factory
from app.jobs.handlers import process_ride_job
from app.rides.models import Ride

log = get_logger(__name__)

FAILED_FLAG = "PROCESSING_ERROR"


async def failed_rides(db: AsyncSession, limit: int = 50) -> list[Ride]:
    rows = (
        (await db.execute(select(Ride).where(Ride.status == "FLAGGED").order_by(Ride.created_at.desc()).limit(500)))
        .scalars()
        .all()
    )
    return [r for r in rows if FAILED_FLAG in (r.flags or [])][:limit]


async def reset_for_reprocess(db: AsyncSession, ride_id: uuid.UUID) -> Ride:
    """Puts a written-off ride back where processing can take it."""
    ride = await db.get(Ride, ride_id)
    if ride is None:
        raise NotFound("Ride not found")
    if ride.status != "FLAGGED" or FAILED_FLAG not in (ride.flags or []):
        raise RideInvalidState(f"Ride is {ride.status} with flags {ride.flags}; only a failed processing is rerun")
    ride.flags = [f for f in ride.flags if f != FAILED_FLAG]
    ride.status = "UPLOADED"
    ride.processing_result = None
    await db.flush()
    return ride


async def reprocess(ride_id: uuid.UUID) -> None:
    async with get_session_factory()() as db:
        await reset_for_reprocess(db, ride_id)
        await db.commit()
    log.info("ride_reprocess_started", ride_id=str(ride_id))
    await process_ride_job({"rideId": str(ride_id)})
    log.info("ride_reprocessed", ride_id=str(ride_id))


async def _list() -> None:
    async with get_session_factory()() as db:
        for ride in await failed_rides(db):
            error = (ride.processing_result or {}).get("error", "")
            print(f"{ride.id}  {ride.ended_at or ride.created_at:%Y-%m-%d %H:%M}  {error[:100]}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("ride_id", nargs="?", help="the ride to run again")
    parser.add_argument("--list", action="store_true", help="list rides whose processing failed")
    args = parser.parse_args()
    if args.list or not args.ride_id:
        asyncio.run(_list())
        return
    asyncio.run(reprocess(uuid.UUID(args.ride_id)))


if __name__ == "__main__":
    main()
