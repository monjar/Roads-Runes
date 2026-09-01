from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any, Literal

from pydantic import Field

from app.core.schemas import APIModel

Visibility = Literal["PRIVATE", "FRIENDS", "PUBLIC"]


class UserSettings(APIModel):
    defaultRideVisibility: Visibility = "PRIVATE"
    batteryMode: Literal["FULL", "BALANCED", "ENDURANCE"] = "BALANCED"
    mapStyle: Literal["MINIMAL", "CYCLING", "ADVENTURE", "DETAILED"] = "ADVENTURE"
    stravaUploadMode: Literal["AUTO", "ASK", "NEVER"] = "NEVER"
    units: Literal["METRIC", "IMPERIAL"] = "METRIC"


class UserOut(APIModel):
    id: uuid.UUID
    displayName: str
    avatarUrl: str | None = None
    createdAt: datetime
    hasCharacter: bool = False
    settings: UserSettings


class UserUpdate(APIModel):
    displayName: str | None = Field(default=None, min_length=1, max_length=80)
    avatarUrl: str | None = None
    settings: dict[str, Any] | None = None


class AdventureSummaryPublic(APIModel):
    rideId: uuid.UUID
    questTitle: str | None = None
    completedAt: datetime
    distanceMeters: float
    newTerritoryMeters: float = 0.0
    xpAwarded: int = 0


class PublicProfile(APIModel):
    id: uuid.UUID
    displayName: str
    avatarUrl: str | None = None
    characterClass: str | None = None
    overallLevel: int | None = None
    title: str | None = None
    questsCompleted: int = 0
    discoveriesFound: int = 0
    favouriteTerrain: str | None = None
    friendship: Literal["NONE", "REQUEST_SENT", "REQUEST_RECEIVED", "FRIENDS", "BLOCKED"] = "NONE"
    recentAdventures: list[AdventureSummaryPublic] = []
