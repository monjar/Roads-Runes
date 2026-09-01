from __future__ import annotations

import uuid

from fastapi import APIRouter, Query, status

from app.core.deps import CurrentUser, DBDep, SettingsDep
from app.core.pagination import Page, clamp_limit
from app.social import service
from app.social.schemas import (
    FeedEventOut,
    FriendRequestCreate,
    FriendRequests,
    FriendSummary,
    PartyCreate,
    PartyInvite,
    PartyOut,
)

friends_router = APIRouter(prefix="/friends", tags=["social"])
feed_router = APIRouter(prefix="/feed", tags=["social"])
parties_router = APIRouter(prefix="/parties", tags=["social"])


@friends_router.get("", response_model=list[FriendSummary])
async def friends(user: CurrentUser, db: DBDep) -> list[FriendSummary]:
    return await service.list_friends(db, user)


@friends_router.get("/requests", response_model=FriendRequests)
async def requests(user: CurrentUser, db: DBDep) -> FriendRequests:
    return await service.list_requests(db, user)


@friends_router.post("/requests", status_code=status.HTTP_201_CREATED)
async def send_request(payload: FriendRequestCreate, user: CurrentUser, db: DBDep) -> dict:
    row = await service.send_request(db, user, payload.userId)
    return {"id": str(row.id), "status": row.status}


@friends_router.post("/requests/{request_id}/accept", response_model=FriendRequests)
async def accept(request_id: uuid.UUID, user: CurrentUser, db: DBDep) -> FriendRequests:
    await service.respond(db, user, request_id, True)
    return await service.list_requests(db, user)


@friends_router.post("/requests/{request_id}/decline", response_model=FriendRequests)
async def decline(request_id: uuid.UUID, user: CurrentUser, db: DBDep) -> FriendRequests:
    await service.respond(db, user, request_id, False)
    return await service.list_requests(db, user)


@friends_router.delete("/{user_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove(user_id: uuid.UUID, user: CurrentUser, db: DBDep) -> None:
    await service.remove_friend(db, user, user_id)


@friends_router.post("/{user_id}/block", status_code=status.HTTP_204_NO_CONTENT)
async def block(user_id: uuid.UUID, user: CurrentUser, db: DBDep) -> None:
    await service.block(db, user, user_id)


@feed_router.get("", response_model=Page[FeedEventOut])
async def feed(user: CurrentUser, db: DBDep, limit: int | None = Query(default=None)) -> Page[FeedEventOut]:
    return Page(items=await service.feed(db, user, clamp_limit(limit)), nextCursor=None)


@parties_router.post("", response_model=PartyOut, status_code=status.HTTP_201_CREATED)
async def create_party(payload: PartyCreate, user: CurrentUser, db: DBDep, settings: SettingsDep) -> PartyOut:
    return await service.party_out(
        db, await service.create_party(db, settings, user, payload.questId, payload.memberIds)
    )


@parties_router.get("", response_model=list[PartyOut])
async def list_parties(user: CurrentUser, db: DBDep) -> list[PartyOut]:
    from sqlalchemy import select

    from app.social.models import Party, PartyMember

    rows = (
        (
            await db.execute(
                select(Party).join(PartyMember, PartyMember.party_id == Party.id).where(PartyMember.user_id == user.id)
            )
        )
        .scalars()
        .unique()
        .all()
    )
    return [await service.party_out(db, p) for p in rows]


@parties_router.get("/{party_id}", response_model=PartyOut)
async def get_party(party_id: uuid.UUID, user: CurrentUser, db: DBDep) -> PartyOut:
    return await service.party_out(db, await service.get_party(db, user, party_id))


@parties_router.post("/{party_id}/invite", response_model=PartyOut)
async def invite(party_id: uuid.UUID, payload: PartyInvite, user: CurrentUser, db: DBDep) -> PartyOut:
    party = await service.get_party(db, user, party_id)
    await service.invite(db, user, party, payload.userId)
    return await service.party_out(db, party)


@parties_router.post("/{party_id}/accept", response_model=PartyOut)
async def accept_invite(party_id: uuid.UUID, user: CurrentUser, db: DBDep) -> PartyOut:
    return await service.party_out(db, await service.accept_invite(db, user, party_id))


@parties_router.post("/{party_id}/leave", response_model=PartyOut)
async def leave(party_id: uuid.UUID, user: CurrentUser, db: DBDep) -> PartyOut:
    return await service.party_out(db, await service.leave(db, user, party_id))


@parties_router.post("/{party_id}/ready", response_model=PartyOut)
async def ready(party_id: uuid.UUID, user: CurrentUser, db: DBDep) -> PartyOut:
    return await service.party_out(db, await service.set_status(db, user, party_id, "READY"))


@parties_router.post("/{party_id}/start", response_model=PartyOut)
async def start(party_id: uuid.UUID, user: CurrentUser, db: DBDep) -> PartyOut:
    return await service.party_out(db, await service.set_status(db, user, party_id, "ACTIVE"))


@parties_router.post("/{party_id}/cancel", response_model=PartyOut)
async def cancel(party_id: uuid.UUID, user: CurrentUser, db: DBDep) -> PartyOut:
    return await service.party_out(db, await service.set_status(db, user, party_id, "CANCELLED"))
