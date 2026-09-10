from __future__ import annotations

from fastapi import APIRouter, status

from app.auth import service
from app.auth.schemas import AppleSignInRequest, DevSignInRequest, RefreshRequest, TokenResponse
from app.core.deps import CurrentUser, DBDep, SettingsDep

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/apple", response_model=TokenResponse)
async def apple(payload: AppleSignInRequest, db: DBDep, settings: SettingsDep) -> TokenResponse:
    return await service.sign_in_with_apple(db, settings, payload)


@router.post("/refresh", response_model=TokenResponse)
async def refresh(payload: RefreshRequest, db: DBDep, settings: SettingsDep) -> TokenResponse:
    return await service.refresh_tokens(db, settings, payload.refreshToken)


@router.post("/dev", response_model=TokenResponse)
async def dev(payload: DevSignInRequest, db: DBDep, settings: SettingsDep) -> TokenResponse:
    return await service.dev_sign_in(db, settings, payload.subject, payload.displayName)


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(user: CurrentUser, db: DBDep) -> None:
    await service.revoke_all(db, user)
