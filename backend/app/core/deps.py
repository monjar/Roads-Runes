"""FastAPI dependencies shared across routers."""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings, get_settings
from app.core.errors import Unauthenticated
from app.core.security import decode_access_token
from app.db.session import get_db
from app.users.models import User

bearer = HTTPBearer(auto_error=False)

SettingsDep = Annotated[Settings, Depends(get_settings)]
DBDep = Annotated[AsyncSession, Depends(get_db)]


async def get_current_user(
    request: Request,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)],
    settings: SettingsDep,
    db: DBDep,
) -> User:
    if credentials is None:
        raise Unauthenticated("Missing bearer token")
    user_id = decode_access_token(settings, credentials.credentials)
    user = await db.get(User, user_id)
    if user is None or user.deleted_at is not None:
        raise Unauthenticated("User not found")
    limiter = getattr(request.app.state, "rate_limiter", None)
    if limiter is not None:
        await limiter.check(str(user_id))
    return user


CurrentUser = Annotated[User, Depends(get_current_user)]


def get_llm(request: Request):
    return request.app.state.llm


def get_job_queue(request: Request):
    return request.app.state.jobs


def get_router_client(request: Request):
    return request.app.state.router


def parse_uuid(value: str) -> uuid.UUID:
    try:
        return uuid.UUID(value)
    except ValueError as exc:
        from app.core.errors import NotFound

        raise NotFound("Invalid identifier") from exc
