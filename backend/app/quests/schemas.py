from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from pydantic import Field

from app.core.schemas import APIModel, Coordinate


class ObjectiveProgress(APIModel):
    current: float
    target: float


class ObjectiveOut(APIModel):
    id: uuid.UUID
    objectiveType: str
    title: str
    latitude: float | None = None
    longitude: float | None = None
    radiusMeters: float | None = None
    targetMeters: float | None = None
    targetCells: list[str] | None = None
    targetElevationMeters: float | None = None
    targetCount: int | None = None
    discoveryId: uuid.UUID | None = None
    required: bool
    order: int
    completionRule: str
    status: str
    completedAt: datetime | None = None
    provisional: bool = False
    progress: ObjectiveProgress
    extra: dict[str, Any] = {}


class QuestOut(APIModel):
    id: uuid.UUID
    questType: str
    characterClass: str
    templateId: str
    title: str
    description: str
    narrative: dict[str, Any]
    difficulty: str
    recommendedDistanceKm: float
    estimatedDurationMinutes: int
    baseXP: int
    status: str
    expiresAt: datetime | None
    storyQuestId: uuid.UUID | None
    partyId: uuid.UUID | None = None
    origin: Coordinate
    objectives: list[ObjectiveOut]
    rewards: dict[str, Any]
    suggestedRouteId: uuid.UUID | None
    rideId: uuid.UUID | None = None
    acceptedAt: datetime | None
    startedAt: datetime | None
    completedAt: datetime | None
    createdAt: datetime


class QuestGenerateRequest(APIModel):
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    count: int = Field(default=3, ge=1, le=6)
    request: str | None = Field(default=None, max_length=300)


class QuestStartRequest(APIModel):
    rideId: uuid.UUID | None = None


class ObjectiveEventIn(APIModel):
    objectiveId: uuid.UUID
    occurredAt: datetime
    latitude: float | None = None
    longitude: float | None = None
    value: float | None = None


class QuestProgressRequest(APIModel):
    events: list[ObjectiveEventIn] = Field(max_length=500)


class QuestCompleteRequest(APIModel):
    rideId: uuid.UUID | None = None


class LevelUp(APIModel):
    kind: str
    from_: int = Field(alias="from")
    to: int

    model_config = {"populate_by_name": True}


class QuestCompletion(APIModel):
    quest: QuestOut
    xpAwarded: int
    xpBreakdown: list[dict[str, Any]]
    levelUps: list[dict[str, Any]]
    abilitiesUnlocked: list[dict[str, Any]]
    titlesUnlocked: list[str]
    storyProgress: dict[str, Any] | None = None
