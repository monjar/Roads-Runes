"""Strava OAuth + upload (spec §39). Optional; disabled unless the `strava`
feature flag and client credentials are configured."""

from __future__ import annotations

import asyncio
import uuid
from datetime import UTC, datetime, timedelta

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.activity import STRAVA_TYPE, normalise
from app.core.config import Settings
from app.core.errors import FeatureDisabled, NotFound
from app.core.feature_flags import require_flag
from app.integrations.models import StravaConnection
from app.rides.export import to_gpx
from app.rides.models import Ride, RidePoint

STRAVA_AUTH = "https://www.strava.com/oauth/authorize"
STRAVA_TOKEN = "https://www.strava.com/oauth/token"
STRAVA_UPLOAD = "https://www.strava.com/api/v3/uploads"


def _check(settings: Settings) -> None:
    require_flag(settings, "strava")
    if not settings.strava_client_id or not settings.strava_client_secret:
        raise FeatureDisabled("Strava credentials are not configured")


def authorize_url(settings: Settings, state: str) -> str:
    _check(settings)
    params = {
        "client_id": settings.strava_client_id,
        "response_type": "code",
        "redirect_uri": settings.strava_redirect_uri,
        "approval_prompt": "auto",
        "scope": "activity:write,read",
        "state": state,
    }
    return f"{STRAVA_AUTH}?{httpx.QueryParams(params)}"


async def exchange_code(db: AsyncSession, settings: Settings, user_id: uuid.UUID, code: str) -> StravaConnection:
    _check(settings)
    async with httpx.AsyncClient(timeout=15.0) as client:
        response = await client.post(
            STRAVA_TOKEN,
            data={
                "client_id": settings.strava_client_id,
                "client_secret": settings.strava_client_secret,
                "code": code,
                "grant_type": "authorization_code",
            },
        )
        response.raise_for_status()
    data = response.json()
    athlete = data.get("athlete", {})
    connection = await db.scalar(select(StravaConnection).where(StravaConnection.user_id == user_id))
    if connection is None:
        connection = StravaConnection(
            user_id=user_id,
            athlete_id=str(athlete.get("id", "")),
            access_token="",
            refresh_token="",
            expires_at=datetime.now(UTC),
        )
        db.add(connection)
    connection.athlete_id = str(athlete.get("id", connection.athlete_id))
    connection.athlete_name = " ".join(p for p in [athlete.get("firstname"), athlete.get("lastname")] if p) or None
    connection.access_token = data["access_token"]
    connection.refresh_token = data["refresh_token"]
    connection.expires_at = datetime.fromtimestamp(data["expires_at"], tz=UTC)
    connection.scope = data.get("scope")
    await db.flush()
    return connection


async def _fresh_token(settings: Settings, connection: StravaConnection) -> str:
    if connection.expires_at > datetime.now(UTC) + timedelta(minutes=5):
        return connection.access_token
    async with httpx.AsyncClient(timeout=15.0) as client:
        response = await client.post(
            STRAVA_TOKEN,
            data={
                "client_id": settings.strava_client_id,
                "client_secret": settings.strava_client_secret,
                "grant_type": "refresh_token",
                "refresh_token": connection.refresh_token,
            },
        )
        response.raise_for_status()
    data = response.json()
    connection.access_token = data["access_token"]
    connection.refresh_token = data["refresh_token"]
    connection.expires_at = datetime.fromtimestamp(data["expires_at"], tz=UTC)
    return connection.access_token


# Strava takes the file at once and makes the activity a few seconds later; the
# upload record says when, and the activity id is what "Open in Strava" needs.
UPLOAD_POLL_ATTEMPTS = 6
UPLOAD_POLL_SECONDS = 2.0


async def connection_for(db: AsyncSession, user_id: uuid.UUID) -> StravaConnection | None:
    return await db.scalar(select(StravaConnection).where(StravaConnection.user_id == user_id))


async def upload_ride(
    db: AsyncSession, settings: Settings, ride_id: uuid.UUID, transport: httpx.AsyncBaseTransport | None = None
) -> str:
    """Send the ride to Strava and record where it got to on the ride itself.

    Returns the Strava activity id, or the upload id when Strava has the file but
    has not finished making the activity — the status on the ride says which.
    Raises on failure, after recording FAILED and why, so the caller decides
    whether that is a job to log or a request to answer.
    """
    ride = await db.get(Ride, ride_id)
    if ride is None:
        raise NotFound("Ride not found")
    connection = await connection_for(db, ride.user_id)
    if connection is None:
        raise FeatureDisabled("Strava not connected")
    try:
        token = await _fresh_token(settings, connection)
        points = list(
            (
                await db.execute(select(RidePoint).where(RidePoint.ride_id == ride.id).order_by(RidePoint.sequence))
            ).scalars()
        )
        gpx = to_gpx(ride, points)
        async with httpx.AsyncClient(timeout=30.0, transport=transport) as client:
            response = await client.post(
                STRAVA_UPLOAD,
                headers={"Authorization": f"Bearer {token}"},
                data={
                    "data_type": "gpx",
                    "name": ride.title or "Roads & Runes adventure",
                    "activity_type": STRAVA_TYPE.get(normalise(ride.activity), "ride"),
                    "external_id": str(ride.id),
                },
                files={"file": (f"{ride.id}.gpx", gpx.encode(), "application/gpx+xml")},
            )
            response.raise_for_status()
            upload = response.json()
            upload_id = str(upload.get("id", ""))
            activity_id = upload.get("activity_id")
            for _ in range(UPLOAD_POLL_ATTEMPTS):
                if activity_id or not upload_id:
                    break
                await asyncio.sleep(UPLOAD_POLL_SECONDS)
                status = await client.get(f"{STRAVA_UPLOAD}/{upload_id}", headers={"Authorization": f"Bearer {token}"})
                if status.status_code != 200:
                    break
                upload = status.json()
                if upload.get("error"):
                    raise RuntimeError(str(upload["error"])[:200])
                activity_id = upload.get("activity_id")
    except Exception as exc:
        ride.strava_upload_status = "FAILED"
        ride.strava_error = _reason(exc)
        await db.flush()
        raise
    ride.strava_activity_id = str(activity_id) if activity_id else None
    ride.strava_upload_status = "UPLOADED"
    ride.strava_error = None
    await db.flush()
    return str(activity_id or upload_id)


def _reason(exc: Exception) -> str:
    """What the rider can act on: Strava's own message when there is one."""
    if isinstance(exc, httpx.HTTPStatusError):
        try:
            body = exc.response.json()
            return str(body.get("message") or body)[:300]
        except ValueError:
            return f"Strava answered {exc.response.status_code}"[:300]
    return (str(exc) or exc.__class__.__name__)[:300]


async def upload_after_processing(db: AsyncSession, settings: Settings, ride_id: uuid.UUID) -> bool:
    """The automatic half of the loop: a processed ride goes to Strava on its own
    when the rider asked for that and is connected. Never raises — a Strava
    outage is not a reason for the ride's own processing to fail."""
    ride = await db.get(Ride, ride_id)
    if ride is None or ride.status not in ("PROCESSED", "FLAGGED") or ride.strava_upload_status:
        return False
    if not settings.flags.get("strava"):
        return False
    from app.users.models import User

    user = await db.get(User, ride.user_id)
    if user is None or user.effective_settings().get("stravaUploadMode") != "AUTO":
        return False
    if await connection_for(db, ride.user_id) is None:
        return False
    try:
        await upload_ride(db, settings, ride.id)
    except Exception:  # noqa: BLE001 - recorded on the ride by upload_ride
        return False
    return True


async def disconnect(db: AsyncSession, user_id: uuid.UUID) -> None:
    connection = await db.scalar(select(StravaConnection).where(StravaConnection.user_id == user_id))
    if connection is not None:
        await db.delete(connection)
        await db.flush()
