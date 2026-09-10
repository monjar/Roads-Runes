"""Background job handlers. Each opens its own DB session."""

from __future__ import annotations

import uuid
from typing import Any

from app.core.config import get_settings
from app.core.logging import EVENT_RIDE_UPLOAD_FAILED, EVENT_STRAVA_UPLOAD_FAILED, get_logger
from app.db.session import get_session_factory

log = get_logger(__name__)


async def process_ride_job(payload: dict[str, Any]) -> None:
    from app.rides.processing import process_ride

    settings = get_settings()
    async with get_session_factory()() as db:
        try:
            await process_ride(db, settings, uuid.UUID(payload["rideId"]))
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


async def strava_upload_job(payload: dict[str, Any]) -> None:
    from app.integrations.strava import upload_ride

    settings = get_settings()
    async with get_session_factory()() as db:
        try:
            await upload_ride(db, settings, uuid.UUID(payload["rideId"]))
            await db.commit()
        except Exception as exc:  # noqa: BLE001
            await db.rollback()
            log.error(EVENT_STRAVA_UPLOAD_FAILED, ride_id=payload.get("rideId"), error=str(exc))


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
    "strava_upload": strava_upload_job,
    "notification": notification_job,
}
