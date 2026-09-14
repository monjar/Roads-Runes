from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

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
