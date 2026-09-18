from __future__ import annotations

import secrets
import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, status
from sqlalchemy import select

from app.core.deps import CurrentUser, DBDep, SettingsDep, get_job_queue
from app.core.errors import FeatureDisabled
from app.core.schemas import APIModel
from app.integrations import strava
from app.integrations.models import StravaConnection
from app.rides.service import get_ride

router = APIRouter(prefix="/integrations", tags=["integrations"])


class StravaStatus(APIModel):
    connected: bool
    athleteName: str | None = None
    uploadMode: str = "NEVER"
    enabled: bool = False


class StravaCallback(APIModel):
    code: str


@router.get("/strava", response_model=StravaStatus)
async def strava_status(user: CurrentUser, db: DBDep, settings: SettingsDep) -> StravaStatus:
    connection = await db.scalar(select(StravaConnection).where(StravaConnection.user_id == user.id))
    return StravaStatus(
        connected=connection is not None,
        athleteName=connection.athlete_name if connection else None,
        uploadMode=user.effective_settings().get("stravaUploadMode", "NEVER"),
        enabled=settings.flags.get("strava", False),
    )


@router.get("/strava/authorize")
async def strava_authorize(user: CurrentUser, settings: SettingsDep) -> dict:
    return {"url": strava.authorize_url(settings, secrets.token_urlsafe(16))}


@router.post("/strava/callback", response_model=StravaStatus)
async def strava_callback(payload: StravaCallback, user: CurrentUser, db: DBDep, settings: SettingsDep) -> StravaStatus:
    connection = await strava.exchange_code(db, settings, user.id, payload.code)
    return StravaStatus(
        connected=True,
        athleteName=connection.athlete_name,
        uploadMode=user.effective_settings().get("stravaUploadMode", "NEVER"),
        enabled=True,
    )


@router.delete("/strava", status_code=status.HTTP_204_NO_CONTENT)
async def strava_disconnect(user: CurrentUser, db: DBDep) -> None:
    await strava.disconnect(db, user.id)


@router.post("/strava/upload/{ride_id}")
async def strava_upload(
    ride_id: uuid.UUID,
    user: CurrentUser,
    db: DBDep,
    settings: SettingsDep,
    jobs: Annotated[object, Depends(get_job_queue)],
) -> dict:
    strava._check(settings)
    ride = await get_ride(db, user, ride_id)
    if await strava.connection_for(db, user.id) is None:
        raise FeatureDisabled("Strava not connected")
    ride.strava_upload_status = "QUEUED"
    ride.strava_error = None
    await db.commit()  # the job runs in another session/process; make QUEUED visible first
    await jobs.enqueue("strava_upload", {"rideId": str(ride.id)})  # type: ignore[attr-defined]
    return {"status": "QUEUED"}
