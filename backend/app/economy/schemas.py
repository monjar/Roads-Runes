from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from app.core.schemas import APIModel


class WalletOut(APIModel):
    balance: int
    lifetimeEarned: int


class WalletTransactionOut(APIModel):
    id: uuid.UUID
    amount: int
    kind: str
    rideId: uuid.UUID | None = None
    questId: uuid.UUID | None = None
    objectId: uuid.UUID | None = None
    payload: dict[str, Any] = {}
    createdAt: datetime
