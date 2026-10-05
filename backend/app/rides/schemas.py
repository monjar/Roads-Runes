from __future__ import annotations

import uuid
from datetime import date, datetime
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
    # The thing this outing is for, if it was planned at one (0.6.1).
    quarryId: uuid.UUID | None = None
    # Custom adventures (no quest) name themselves; quest rides take the quest title.
    title: str | None = Field(default=None, max_length=120)
    # The day it began on the phone's calendar (0.7.3): the day whose pledge it keeps.
    localDate: date | None = None


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
    # A note written for the objective (WRITE_NOTE, or Ansuz's INSCRIBE_RUNE), 0.7.0.
    note: str | None = Field(default=None, max_length=2000)


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
    # The character sheet frozen at the start (characters/sheet.py); the phone folds
    # the fight over it. Absent for rides from before 0.6.1.
    loadout: dict[str, Any] | None = None
    quarryId: uuid.UUID | None = None
    # 0.7.2: the entry written by the model, when there is one: {"lines": [...],
    # "by": "model"}. The composed `entry` stays on the summary either way.
    entryWritten: dict[str, Any] | None = None


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
    # The thing the outing was planned for; its fight leads the reckoning (0.6.1).
    quarryId: str | None = None
    streak: dict[str, Any] | None = None
    # 0.6.2: the entry the outing leaves in the journal, the week's notice when this
    # outing met it, and the creatures met for the first time (the codex stamp).
    entry: str | None = None
    weekNotice: dict[str, Any] | None = None
    codexFirsts: list[dict[str, Any]] = []
    # 0.7.0: rune stones picked up, and what the outing did for the deeds (in the
    # processing result since 0.7.0; on the summary since 0.7.2).
    runesFound: list[dict[str, Any]] | None = None
    deeds: dict[str, Any] | None = None
    # 0.7.2: what creatures, chests and the quest left (ItemFoundOut), and the
    # model-written entry when there is one.
    itemsFound: list[dict[str, Any]] | None = None
    entryWritten: dict[str, Any] | None = None
    # 0.7.3: a pledge kept on this journey ({"kept": true, "targetName", "line", ...};
    # absent otherwise: a missed pledge is never mentioned), and letters found again.
    pledge: dict[str, Any] | None = None
    letters: list[dict[str, Any]] | None = None


class RideGeometry(APIModel):
    coordinates: list[list[float]]
    encodedPolyline: str
