from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from pydantic import Field

from app.core.schemas import APIModel


class KillMethodOut(APIModel):
    method: str
    params: dict[str, Any] = {}
    hint: str


class MonsterOut(APIModel):
    hp: int
    flavour: str | None = None
    killMethods: list[KillMethodOut] = []


class WorldObjectOut(APIModel):
    id: uuid.UUID
    kind: str
    status: str
    tier: int
    latitude: float
    longitude: float
    name: str
    anchorName: str | None = None
    bounty: bool = False
    rewardAC: int
    expiresAt: datetime
    claimedAt: datetime | None = None
    monster: MonsterOut | None = None
    setId: str | None = None
    piece: str | None = None
    # How close the player must be to open or pick it up; nothing for a monster.
    claimRadiusMeters: float | None = None


class ClaimIn(APIModel):
    """Where the phone says the player is standing when they reach for it."""

    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    horizontalAccuracyMeters: float | None = Field(default=None, ge=0)


class ClaimResultOut(APIModel):
    object: WorldObjectOut
    acAwarded: int
    walletBalance: int
    # The quest this finished, if opening it was the last thing a quest asked for.
    questCompleted: Any | None = None


class ClaimedOut(APIModel):
    id: uuid.UUID
    kind: str
    name: str
    tier: int
    rewardAC: int
    method: str | None = None


class MissedOut(APIModel):
    id: uuid.UUID
    kind: str
    name: str
    reason: str
