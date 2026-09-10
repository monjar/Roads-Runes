"""Strava OAuth + upload (spec §39). Optional; disabled unless the `strava`
feature flag and client credentials are configured."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

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


async def upload_ride(db: AsyncSession, settings: Settings, ride_id: uuid.UUID) -> str:
    ride = await db.get(Ride, ride_id)
    if ride is None:
        raise NotFound("Ride not found")
    connection = await db.scalar(select(StravaConnection).where(StravaConnection.user_id == ride.user_id))
    if connection is None:
        raise FeatureDisabled("Strava not connected")
    token = await _fresh_token(settings, connection)
    points = list(
        (await db.execute(select(RidePoint).where(RidePoint.ride_id == ride.id).order_by(RidePoint.sequence))).scalars()
    )
    gpx = to_gpx(ride, points)
    async with httpx.AsyncClient(timeout=30.0) as client:
        response = await client.post(
            STRAVA_UPLOAD,
            headers={"Authorization": f"Bearer {token}"},
            data={
                "data_type": "gpx",
                "name": ride.title or "Roads & Runes adventure",
                "activity_type": "ride",
                "external_id": str(ride.id),
            },
            files={"file": (f"{ride.id}.gpx", gpx.encode(), "application/gpx+xml")},
        )
        response.raise_for_status()
    upload_id = str(response.json().get("id", ""))
    ride.strava_activity_id = upload_id
    await db.flush()
    return upload_id


async def disconnect(db: AsyncSession, user_id: uuid.UUID) -> None:
    connection = await db.scalar(select(StravaConnection).where(StravaConnection.user_id == user_id))
    if connection is not None:
        await db.delete(connection)
        await db.flush()
