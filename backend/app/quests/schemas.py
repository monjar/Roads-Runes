from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any, Literal

from pydantic import Field

from app.core.activity import Activity
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
    activity: str = "RIDE"
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
    # What a kind of quest carries beyond the rest. A sealed quest (0.7.3):
    # {"sealed": true, "minutes": 40, "revealAtFraction": 0.5, "goal": {...}}.
    extra: dict[str, Any] = {}


class StoryStepOut(APIModel):
    slug: str
    sequence: int
    title: str
    description: str
    # COMPLETED (done) / OPEN (on the board now) / READY (next up) / WAITING (next
    # up, but it cannot be set where the player is: `waitingReason` says why) / LOCKED
    state: str
    waitingReason: str | None = None
    questId: uuid.UUID | None = None


class StoryArcOut(APIModel):
    slug: str
    title: str
    description: str
    characterClass: str | None = None
    minLevel: int
    unlocked: bool
    quests: list[StoryStepOut]
    # The campaign (0.6.2): MAIN or SIDE, its act and chapter, the chapter it
    # comes after, who posts it, and what finishing it gives. All optional.
    track: str | None = None
    act: int | None = None
    actTitle: str | None = None
    chapter: int | None = None
    after: str | None = None
    giver: str | None = None
    reward: dict[str, Any] | None = None
    # A festival's arc (0.9.0, track SEASON): SPRING, MIDSUMMER, HARVEST or MIDWINTER,
    # and its window. Shown only while the festival is on.
    season: str | None = None
    startsAt: datetime | None = None
    endsAt: datetime | None = None


class WeekNoticeOut(APIModel):
    """The week's notice (0.6.2): one goal an ISO week, a fixed target, paid once."""

    week: str
    kind: str
    title: str
    line: str
    postedBy: str
    target: int
    unit: str
    progress: int
    done: bool
    paid: bool
    coins: int
    xp: int
    endsAt: datetime


class QuestGenerateRequest(APIModel):
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    count: int = Field(default=3, ge=1, le=6)
    request: str | None = Field(default=None, max_length=300)
    # None: however this player usually moves (the rider profile).
    activity: Activity | None = None


class SealedQuestRequest(APIModel):
    """A sealed quest (0.7.3): how long, from where, and how the player is going."""

    minutes: Literal[20, 40, 90]
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    # None: however this player usually moves (the rider profile).
    activity: Activity | None = None


class QuestStartRequest(APIModel):
    rideId: uuid.UUID | None = None


class ObjectiveEventIn(APIModel):
    objectiveId: uuid.UUID
    occurredAt: datetime
    latitude: float | None = None
    longitude: float | None = None
    value: float | None = None
    # A note written for the objective (WRITE_NOTE, or Ansuz's INSCRIBE_RUNE), 0.7.0.
    note: str | None = Field(default=None, max_length=2000)


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
    # The quest's item reward, given (ItemFoundOut), 0.7.2.
    itemsFound: list[dict[str, Any]] = []
