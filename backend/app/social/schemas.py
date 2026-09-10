from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any, Literal

from app.core.schemas import APIModel

Friendship = Literal["NONE", "REQUEST_SENT", "REQUEST_RECEIVED", "FRIENDS", "BLOCKED"]
PartyStatus = Literal["FORMING", "READY", "ACTIVE", "COMPLETED", "CANCELLED"]


class FriendSummary(APIModel):
    id: uuid.UUID
    displayName: str
    avatarUrl: str | None = None
    characterClass: str | None = None
    overallLevel: int | None = None
    title: str | None = None
    since: datetime | None = None


class FriendRequestOut(APIModel):
    id: uuid.UUID
    user: FriendSummary
    createdAt: datetime


class FriendRequests(APIModel):
    incoming: list[FriendRequestOut]
    outgoing: list[FriendRequestOut]


class FriendRequestCreate(APIModel):
    userId: uuid.UUID


class FeedEventOut(APIModel):
    id: uuid.UUID
    eventType: str
    user: FriendSummary
    payload: dict[str, Any]
    createdAt: datetime


class PartyMemberOut(APIModel):
    user: FriendSummary
    role: str
    status: str
    questId: uuid.UUID | None = None


class PartyOut(APIModel):
    id: uuid.UUID
    ownerId: uuid.UUID
    questId: uuid.UUID | None
    routeId: uuid.UUID | None
    status: PartyStatus
    completionRule: str
    members: list[PartyMemberOut]
    createdAt: datetime


class PartyCreate(APIModel):
    questId: uuid.UUID
    memberIds: list[uuid.UUID] = []


class PartyInvite(APIModel):
    userId: uuid.UUID
