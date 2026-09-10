from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any, Literal

from pydantic import Field

from app.core.schemas import APIModel

DiscoveryCategory = Literal[
    "NATURE",
    "HISTORICAL",
    "CULTURAL",
    "FOOD",
    "PUB",
    "CAFE",
    "VIEWPOINT",
    "CYCLING",
    "LANDMARK",
    "TRAIL",
    "CUSTOM",
]


class DiscoverySummary(APIModel):
    id: uuid.UUID
    name: str
    category: str
    latitude: float
    longitude: float
    source: str
    discoveredByUser: bool = False
    discoveredAt: datetime | None = None


class UserDiscoveryOut(APIModel):
    discoveryId: uuid.UUID
    discoveredAt: datetime
    rideId: uuid.UUID | None = None
    note: str | None = None
    rating: int | None = None
    tags: list[str] = []
    photoIds: list[str] = []
    visibility: str = "PRIVATE"


class DiscoveryOut(DiscoverySummary):
    description: str | None = None
    osmId: str | None = None
    tags: dict[str, Any] = {}
    userDiscovery: UserDiscoveryOut | None = None


class UserDiscoveryIn(APIModel):
    note: str | None = Field(default=None, max_length=4000)
    rating: int | None = Field(default=None, ge=1, le=5)
    tags: list[str] = []
    photoIds: list[str] = []
    visibility: Literal["PRIVATE", "FRIENDS", "PUBLIC"] | None = None


class DiscoveryCreate(APIModel):
    name: str = Field(min_length=1, max_length=160)
    category: DiscoveryCategory = "CUSTOM"
    latitude: float
    longitude: float
    description: str | None = Field(default=None, max_length=2000)
