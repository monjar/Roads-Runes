from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any, Literal

from pydantic import Field

from app.core.activity import Activity
from app.core.schemas import APIModel

RideStatus = Literal["RECORDING", "UPLOADED", "PROCESSING", "PROCESSED", "FLAGGED", "DISCARDED"]


class RidePointIn(APIModel):
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    timestamp: datetime
    altitudeMeters: float | None = None
    horizontalAccuracyMeters: float | None = None
    speedMps: float | None = None
    heartRateBpm: int | None = Field(default=None, ge=20, le=250)


class RideCreate(APIModel):
    clientRideId: uuid.UUID
    startedAt: datetime
    activity: Activity = "RIDE"
    questId: uuid.UUID | None = None
    bikeId: uuid.UUID | None = None
    routeId: uuid.UUID | None = None
    # Custom adventures (no quest) name themselves; quest rides take the quest title.
    title: str | None = Field(default=None, max_length=120)


class RidePointsIn(APIModel):
    points: list[RidePointIn] = Field(max_length=5000)


class RideCellsIn(APIModel):
    cellsVisited: list[str] = Field(max_length=5000)


class ObjectiveEventIn(APIModel):
    objectiveId: uuid.UUID
    occurredAt: datetime
    latitude: float | None = None
    longitude: float | None = None
    value: float | None = None


class EncounterEventIn(APIModel):
    """The phone's word that it beat or opened something; the trace has the last word."""

    objectId: uuid.UUID
    method: str = Field(max_length=16)
    occurredAt: datetime
    latitude: float | None = None
    longitude: float | None = None
    note: str | None = Field(default=None, max_length=1000)
    photoTaken: bool = False


class RideCompleteIn(APIModel):
    endedAt: datetime
    distanceMeters: float = Field(ge=0)
    durationSeconds: int = Field(ge=0)
    movingSeconds: int | None = Field(default=None, ge=0)
    elevationGainMeters: float = Field(default=0, ge=0)
    activeCalories: float | None = Field(default=None, ge=0)
    points: list[RidePointIn] = Field(default_factory=list, max_length=20000)
    cellsVisited: list[str] = Field(default_factory=list, max_length=5000)
    objectiveEvents: list[ObjectiveEventIn] = Field(default_factory=list, max_length=200)
    encounterEvents: list[EncounterEventIn] = Field(default_factory=list, max_length=200)
    healthKitWorkoutId: str | None = None


class RidePatch(APIModel):
    visibility: Literal["PRIVATE", "FRIENDS", "PUBLIC"] | None = None
    title: str | None = Field(default=None, max_length=120)
    notes: str | None = Field(default=None, max_length=4000)


class RideOut(APIModel):
    id: uuid.UUID
    clientRideId: uuid.UUID
    status: str
    activity: str = "RIDE"
    title: str | None
    startedAt: datetime
    endedAt: datetime | None
    distanceMeters: float
    durationSeconds: int
    movingSeconds: int
    elevationGainMeters: float
    activeCalories: float | None
    averageSpeedMps: float | None
    maxSpeedMps: float | None
    questId: uuid.UUID | None
    bikeId: uuid.UUID | None
    routeId: uuid.UUID | None
    visibility: str
    healthKitWorkoutId: str | None
    pointCount: int
    flags: list[str]
    createdAt: datetime
    stravaActivityId: str | None = None
    stravaUploadStatus: str | None = None  # QUEUED / UPLOADED / FAILED
    stravaError: str | None = None


class RideCompleteOut(APIModel):
    ride: RideOut
    processing: str


class AdventureSummary(APIModel):
    ride: RideOut
    quest: Any | None
    questCompletion: dict[str, Any] | None
    xpAwarded: int
    xpBreakdown: list[dict[str, Any]]
    newCells: int
    newTerritoryMeters: float
    newRoadsMeters: float
    discoveries: list[dict[str, Any]]
    levelUps: list[dict[str, Any]]
    abilitiesUnlocked: list[dict[str, Any]]
    titlesUnlocked: list[str]
    flags: list[str]
    acAwarded: int = 0
    acBreakdown: list[dict[str, Any]] = []
    walletBalance: int | None = None
    worldObjects: dict[str, Any] | None = None
    streak: dict[str, Any] | None = None


class RideGeometry(APIModel):
    coordinates: list[list[float]]
    encodedPolyline: str
