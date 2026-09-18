from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.activity import normalise
from app.core.errors import NotFound, RideInvalidState
from app.core.pagination import decode_cursor, encode_cursor
from app.core.security import utcnow
from app.quests.models import QuestInstance
from app.quests.service import quest_out
from app.rides.models import Ride, RidePoint, RideRoute
from app.rides.schemas import (
    AdventureSummary,
    RideCompleteIn,
    RideCreate,
    RideGeometry,
    RideOut,
    RidePatch,
    RidePointIn,
)
from app.users.models import User


def ride_out(ride: Ride) -> RideOut:
    return RideOut(
        id=ride.id,
        clientRideId=ride.client_ride_id,
        status=ride.status,
        activity=normalise(ride.activity),
        title=ride.title,
        startedAt=ride.started_at,
        endedAt=ride.ended_at,
        distanceMeters=ride.distance_meters,
        durationSeconds=ride.duration_seconds,
        movingSeconds=ride.moving_seconds,
        elevationGainMeters=ride.elevation_gain_meters,
        activeCalories=ride.active_calories,
        averageSpeedMps=ride.average_speed_mps,
        maxSpeedMps=ride.max_speed_mps,
        questId=ride.quest_id,
        bikeId=ride.bike_id,
        routeId=ride.route_id,
        visibility=ride.visibility,
        healthKitWorkoutId=ride.healthkit_workout_id,
        pointCount=ride.point_count,
        flags=list(ride.flags or []),
        createdAt=ride.created_at,
        stravaActivityId=ride.strava_activity_id,
        stravaUploadStatus=ride.strava_upload_status,
        stravaError=ride.strava_error,
    )


async def get_ride(db: AsyncSession, user: User, ride_id: uuid.UUID) -> Ride:
    ride = await db.get(Ride, ride_id)
    if ride is None or ride.user_id != user.id or ride.status == "DISCARDED":
        raise NotFound("Ride not found")
    return ride


async def create_ride(db: AsyncSession, user: User, payload: RideCreate) -> Ride:
    existing = await db.scalar(select(Ride).where(Ride.user_id == user.id, Ride.client_ride_id == payload.clientRideId))
    if existing is not None:
        return existing
    visibility = user.effective_settings().get("defaultRideVisibility", "PRIVATE")
    ride = Ride(
        user_id=user.id,
        client_ride_id=payload.clientRideId,
        status="RECORDING",
        activity=normalise(payload.activity),
        title=(payload.title or "").strip() or None,
        started_at=payload.startedAt,
        quest_id=payload.questId,
        bike_id=payload.bikeId,
        route_id=payload.routeId,
        visibility=visibility,
    )
    db.add(ride)
    await db.flush()
    if payload.questId is not None:
        quest = await db.get(QuestInstance, payload.questId)
        if quest is not None and quest.user_id == user.id and quest.status in ("ACCEPTED", "ACTIVE"):
            if quest.status == "ACCEPTED":
                quest.status = "ACTIVE"
                quest.started_at = utcnow()
            quest.ride_id = ride.id
    return ride


async def _next_sequence(db: AsyncSession, ride_id: uuid.UUID) -> int:
    current = await db.scalar(select(func.max(RidePoint.sequence)).where(RidePoint.ride_id == ride_id))
    return (current + 1) if current is not None else 0


async def add_points(db: AsyncSession, ride: Ride, points: list[RidePointIn]) -> int:
    if ride.status != "RECORDING":
        raise RideInvalidState("Ride is not recording")
    if not points:
        return 0
    seq = await _next_sequence(db, ride.id)
    last_ts: datetime | None = await db.scalar(
        select(func.max(RidePoint.timestamp)).where(RidePoint.ride_id == ride.id)
    )
    added = 0
    for p in sorted(points, key=lambda x: x.timestamp):
        if last_ts is not None and p.timestamp <= last_ts:
            continue  # duplicate/out-of-order upload (idempotent batches)
        db.add(
            RidePoint(
                ride_id=ride.id,
                sequence=seq,
                latitude=p.latitude,
                longitude=p.longitude,
                timestamp=p.timestamp,
                altitude_meters=p.altitudeMeters,
                horizontal_accuracy_meters=p.horizontalAccuracyMeters,
                speed_mps=p.speedMps,
                heart_rate_bpm=p.heartRateBpm,
            )
        )
        seq += 1
        added += 1
        last_ts = p.timestamp
    ride.point_count += added
    await db.flush()
    return added


async def add_cells(db: AsyncSession, ride: Ride, cells: list[str]) -> int:
    if ride.status != "RECORDING":
        raise RideInvalidState("Ride is not recording")
    merged = list(
        dict.fromkeys(list(ride.client_cells or []) + [c for c in cells if isinstance(c, str) and len(c) <= 16])
    )
    added = len(merged) - len(ride.client_cells or [])
    ride.client_cells = merged
    await db.flush()
    return added


async def complete_ride(db: AsyncSession, ride: Ride, payload: RideCompleteIn) -> Ride:
    if ride.status != "RECORDING":
        if ride.status in ("UPLOADED", "PROCESSING", "PROCESSED", "FLAGGED"):
            return ride  # idempotent
        raise RideInvalidState("Ride cannot be completed")
    if payload.points:
        await add_points(db, ride, payload.points)
    if payload.cellsVisited:
        await add_cells(db, ride, payload.cellsVisited)
    ride.ended_at = payload.endedAt
    ride.distance_meters = payload.distanceMeters
    ride.duration_seconds = payload.durationSeconds
    ride.moving_seconds = payload.movingSeconds or 0
    ride.elevation_gain_meters = payload.elevationGainMeters
    ride.active_calories = payload.activeCalories
    ride.healthkit_workout_id = payload.healthKitWorkoutId
    ride.objective_events = [e.model_dump(mode="json") for e in payload.objectiveEvents]
    ride.encounter_events = [e.model_dump(mode="json") for e in payload.encounterEvents]
    ride.status = "UPLOADED"
    await db.flush()
    return ride


async def list_rides(db: AsyncSession, user: User, limit: int, cursor: str | None) -> tuple[list[Ride], str | None]:
    stmt = (
        select(Ride)
        .where(Ride.user_id == user.id, Ride.status != "DISCARDED")
        .order_by(Ride.started_at.desc(), Ride.id.desc())
    )
    decoded = decode_cursor(cursor)
    if decoded:
        started, rid = decoded
        stmt = stmt.where((Ride.started_at < started) | ((Ride.started_at == started) & (Ride.id < rid)))
    rows = list((await db.execute(stmt.limit(limit + 1))).scalars())
    next_cursor = None
    if len(rows) > limit:
        rows = rows[:limit]
        next_cursor = encode_cursor(rows[-1].started_at, rows[-1].id)
    return rows, next_cursor


async def summary(db: AsyncSession, user: User, ride: Ride) -> AdventureSummary | None:
    if ride.status in ("RECORDING", "UPLOADED", "PROCESSING"):
        return None
    result = ride.processing_result or {}
    quest = await db.get(QuestInstance, ride.quest_id) if ride.quest_id else None
    return AdventureSummary(
        ride=ride_out(ride),
        quest=quest_out(quest).model_dump(mode="json") if quest else None,
        questCompletion=result.get("questCompletion"),
        xpAwarded=int(result.get("xpAwarded", 0)),
        xpBreakdown=result.get("xpBreakdown", []),
        newCells=int(result.get("newCells", 0)),
        newTerritoryMeters=float(result.get("newTerritoryMeters", 0.0)),
        newRoadsMeters=float(result.get("newRoadsMeters", 0.0)),
        discoveries=result.get("discoveries", []),
        levelUps=result.get("levelUps", []),
        abilitiesUnlocked=result.get("abilitiesUnlocked", []),
        titlesUnlocked=result.get("titlesUnlocked", []),
        flags=list(ride.flags or []),
        acAwarded=int(result.get("acAwarded", 0)),
        acBreakdown=result.get("acBreakdown", []),
        walletBalance=result.get("walletBalance"),
        worldObjects=result.get("worldObjects"),
        streak=result.get("streak"),
    )


async def geometry(db: AsyncSession, ride: Ride) -> RideGeometry:
    route = await db.scalar(select(RideRoute).where(RideRoute.ride_id == ride.id))
    if route is None:
        return RideGeometry(coordinates=[], encodedPolyline="")
    return RideGeometry(coordinates=route.coordinates, encodedPolyline=route.encoded_polyline)


async def points(db: AsyncSession, ride: Ride) -> list[RidePoint]:
    return list(
        (await db.execute(select(RidePoint).where(RidePoint.ride_id == ride.id).order_by(RidePoint.sequence))).scalars()
    )


async def patch(db: AsyncSession, ride: Ride, payload: RidePatch) -> Ride:
    if payload.visibility is not None:
        ride.visibility = payload.visibility
    if payload.title is not None:
        ride.title = payload.title
    if payload.notes is not None:
        ride.notes = payload.notes
    await db.flush()
    return ride


async def discard(db: AsyncSession, ride: Ride) -> None:
    ride.status = "DISCARDED"
    await db.flush()
