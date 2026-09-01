from __future__ import annotations

from typing import Literal

from fastapi import APIRouter, status

from app.core.deps import CurrentUser, DBDep
from app.core.schemas import APIModel
from app.notifications import service

router = APIRouter(prefix="/devices", tags=["notifications"])


class DeviceIn(APIModel):
    token: str
    platform: Literal["IOS", "WATCHOS"]
    environment: Literal["SANDBOX", "PRODUCTION"] = "PRODUCTION"


@router.put("", status_code=status.HTTP_204_NO_CONTENT)
async def register(payload: DeviceIn, user: CurrentUser, db: DBDep) -> None:
    await service.register_device(db, user.id, payload.token, payload.platform, payload.environment)


@router.delete("/{token}", status_code=status.HTTP_204_NO_CONTENT)
async def unregister(token: str, user: CurrentUser, db: DBDep) -> None:
    await service.unregister_device(db, user.id, token)
