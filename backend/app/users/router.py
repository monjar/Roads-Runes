from __future__ import annotations

import uuid

from fastapi import APIRouter, Query

from app.core.deps import CurrentUser, DBDep
from app.social.schemas import FriendSummary
from app.users import service
from app.users.schemas import PublicProfile, UserOut, UserUpdate

router = APIRouter(prefix="/users", tags=["users"])


@router.get("/me", response_model=UserOut)
async def me(user: CurrentUser, db: DBDep) -> UserOut:
    return await service.to_user_out(db, user)


@router.patch("/me", response_model=UserOut)
async def update_me(patch: UserUpdate, user: CurrentUser, db: DBDep) -> UserOut:
    await service.update_user(db, user, patch)
    return await service.to_user_out(db, user)


@router.get("/search", response_model=list[FriendSummary])
async def search(
    user: CurrentUser,
    db: DBDep,
    q: str = Query(min_length=2, max_length=80),
    limit: int = Query(default=10, ge=1, le=25),
) -> list[FriendSummary]:
    """People by name, for adding as friends. The app used to ask for a user id,
    which nobody knows — their own included."""
    return await service.search_users(db, user, q, limit)


@router.get("/{user_id}", response_model=PublicProfile)
async def profile(user_id: uuid.UUID, user: CurrentUser, db: DBDep) -> PublicProfile:
    return await service.public_profile(db, user, user_id)
