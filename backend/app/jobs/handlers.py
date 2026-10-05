"""Background job handlers. Each opens its own DB session."""

from __future__ import annotations

import uuid
from typing import Any

from app.core.config import get_settings
from app.core.feature_flags import is_enabled
from app.core.logging import EVENT_RIDE_UPLOAD_FAILED, EVENT_STRAVA_UPLOAD_FAILED, get_logger
from app.db.session import get_session_factory

log = get_logger(__name__)


async def process_ride_job(payload: dict[str, Any]) -> None:
    from app.integrations.strava import upload_after_processing
    from app.rides.processing import process_ride

    settings = get_settings()
    async with get_session_factory()() as db:
        try:
            await process_ride(db, settings, uuid.UUID(payload["rideId"]))
            await db.commit()
            # After the ride is safely processed, not before: the XP is the point,
            # Strava is a copy.
            await upload_after_processing(db, settings, uuid.UUID(payload["rideId"]))
            await db.commit()
        except Exception as exc:
            await db.rollback()
            log.error(EVENT_RIDE_UPLOAD_FAILED, ride_id=payload.get("rideId"), error=str(exc))
            from app.rides.models import Ride

            ride = await db.get(Ride, uuid.UUID(payload["rideId"]))
            if ride is not None:
                ride.status = "FLAGGED"
                ride.flags = list(ride.flags or []) + ["PROCESSING_ERROR"]
                ride.processing_result = {
                    "error": str(exc)[:500],
                    "xpAwarded": 0,
                    "xpBreakdown": [],
                    "levelUps": [],
                    "abilitiesUnlocked": [],
                    "titlesUnlocked": [],
                    "newCells": 0,
                    "newTerritoryMeters": 0,
                    "newRoadsMeters": 0,
                    "discoveries": [],
                    "flags": ride.flags,
                }
                await db.commit()
            raise
    # The model-written entry, now the summary is committed: Journey's end never
    # waits for it, and a failure there is a ride with only its composed entry.
    if is_enabled(settings, "chronicle_llm"):
        try:
            await enqueue("write_entry", {"rideId": payload["rideId"]})
        except Exception as exc:  # noqa: BLE001
            log.error("write_entry_enqueue_failed", ride_id=payload.get("rideId"), error=str(exc)[:200])
    # The districts the journey entered (0.9.0): their roads, fetched once each for
    # the honest %. Overpass is the importer's, so it is off where the import is.
    if settings.poi_import_enabled:
        try:
            await _fetch_district_ways(payload["rideId"])
        except Exception as exc:  # noqa: BLE001
            log.error("district_ways_enqueue_failed", ride_id=payload.get("rideId"), error=str(exc)[:200])


async def _fetch_district_ways(ride_id: str) -> None:
    from app.districts.ways import due_for
    from app.rides.models import Ride

    async with get_session_factory()() as db:
        ride = await db.get(Ride, uuid.UUID(ride_id))
        entered = [str(d.get("id")) for d in ((ride.processing_result or {}).get("districts") or [])] if ride else []
        due = await due_for(db, entered)
    for region_id in due:
        await enqueue("districts_fetch_ways", {"regionId": region_id})


async def districts_fetch_ways_job(payload: dict[str, Any]) -> None:
    """A district's roads, once (0.9.0, districts/ways.py)."""
    from app.districts.ways import fetch_ways

    settings = get_settings()
    async with get_session_factory()() as db:
        await fetch_ways(db, settings, uuid.UUID(payload["regionId"]))
        await db.commit()


async def enqueue(name: str, payload: dict[str, Any]) -> None:
    """A job from inside a job. With Redis it is queued for a worker; inline (tests,
    development) it runs now, in its own session, after the one before has committed."""
    settings = get_settings()
    if settings.job_queue == "redis" or settings.environment in ("staging", "production"):
        import redis.asyncio as redis

        from app.jobs.queue import RedisJobQueue

        await RedisJobQueue(redis.from_url(settings.redis_url)).enqueue(name, payload)
        return
    await HANDLERS[name](payload)


async def write_entry_job(payload: dict[str, Any]) -> None:
    """The model-written journal entry for a processed ride (flag chronicle_llm)."""
    from app.chronicle.written import write_entry
    from app.core.llm import build_llm

    settings = get_settings()
    async with get_session_factory()() as db:
        await write_entry(db, settings, build_llm(settings), uuid.UUID(payload["rideId"]))
        await db.commit()


async def strava_upload_job(payload: dict[str, Any]) -> None:
    from app.integrations.strava import upload_ride

    settings = get_settings()
    async with get_session_factory()() as db:
        try:
            await upload_ride(db, settings, uuid.UUID(payload["rideId"]))
        except Exception as exc:  # noqa: BLE001
            # upload_ride has already written FAILED and the reason onto the ride;
            # commit that so the rider sees it, rather than rolling it away.
            log.error(EVENT_STRAVA_UPLOAD_FAILED, ride_id=payload.get("rideId"), error=str(exc))
        await db.commit()


async def notification_job(payload: dict[str, Any]) -> None:
    from app.notifications.service import send_push

    settings = get_settings()
    async with get_session_factory()() as db:
        await send_push(
            db,
            settings,
            uuid.UUID(payload["userId"]),
            payload["title"],
            payload["body"],
            payload.get("data") or {},
        )


HANDLERS = {
    "process_ride": process_ride_job,
    "write_entry": write_entry_job,
    "strava_upload": strava_upload_job,
    "notification": notification_job,
    "districts_fetch_ways": districts_fetch_ways_job,
}
