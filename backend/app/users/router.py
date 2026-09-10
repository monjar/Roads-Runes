from __future__ import annotations

import uuid

from fastapi import APIRouter

from app.core.deps import CurrentUser, DBDep
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


@router.get("/{user_id}", response_model=PublicProfile)
async def profile(user_id: uuid.UUID, user: CurrentUser, db: DBDep) -> PublicProfile:
    return await service.public_profile(db, user, user_id)
