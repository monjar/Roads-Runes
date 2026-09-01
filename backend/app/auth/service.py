from __future__ import annotations

from datetime import timedelta

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.apple import verify_identity_token
from app.auth.models import RefreshToken
from app.auth.schemas import AppleSignInRequest, TokenResponse
from app.core.config import Settings
from app.core.errors import Forbidden, Unauthenticated
from app.core.security import create_access_token, generate_refresh_token, hash_token, utcnow
from app.users.models import User
from app.users.service import to_user_out


async def _issue_tokens(db: AsyncSession, settings: Settings, user: User, is_new: bool) -> TokenResponse:
    access, ttl = create_access_token(settings, user.id)
    refresh = generate_refresh_token()
    db.add(
        RefreshToken(
            user_id=user.id,
            token_hash=hash_token(refresh),
            expires_at=utcnow() + timedelta(days=settings.refresh_token_ttl_days),
        )
    )
    await db.flush()
    return TokenResponse(
        accessToken=access,
        refreshToken=refresh,
        expiresIn=ttl,
        isNewUser=is_new,
        user=await to_user_out(db, user),
    )


async def _get_or_create_user(
    db: AsyncSession, subject: str, display_name: str, email: str | None
) -> tuple[User, bool]:
    user = await db.scalar(select(User).where(User.apple_subject == subject))
    if user is not None:
        if user.deleted_at is not None:
            user.deleted_at = None
        return user, False
    user = User(apple_subject=subject, display_name=display_name[:80] or "Rider", email=email, settings={})
    db.add(user)
    await db.flush()
    return user, True


async def sign_in_with_apple(db: AsyncSession, settings: Settings, payload: AppleSignInRequest) -> TokenResponse:
    claims = await verify_identity_token(settings, payload.identityToken)
    name_parts = [payload.fullName.givenName, payload.fullName.familyName] if payload.fullName else []
    display = " ".join(p for p in name_parts if p).strip() or "Rider"
    user, is_new = await _get_or_create_user(db, claims["sub"], display, claims.get("email"))
    return await _issue_tokens(db, settings, user, is_new)


async def dev_sign_in(db: AsyncSession, settings: Settings, subject: str, display_name: str) -> TokenResponse:
    if not settings.dev_auth_enabled or settings.is_production:
        raise Forbidden("Dev auth is disabled")
    user, is_new = await _get_or_create_user(db, f"dev:{subject}", display_name, None)
    return await _issue_tokens(db, settings, user, is_new)


async def refresh_tokens(db: AsyncSession, settings: Settings, refresh_token: str) -> TokenResponse:
    row = await db.scalar(select(RefreshToken).where(RefreshToken.token_hash == hash_token(refresh_token)))
    if row is None or row.revoked_at is not None or row.expires_at < utcnow():
        raise Unauthenticated("Refresh token invalid")
    user = await db.get(User, row.user_id)
    if user is None or user.deleted_at is not None:
        raise Unauthenticated("User not found")
    row.revoked_at = utcnow()  # rotation
    return await _issue_tokens(db, settings, user, False)


async def revoke_all(db: AsyncSession, user: User) -> None:
    rows = (
        await db.execute(select(RefreshToken).where(RefreshToken.user_id == user.id, RefreshToken.revoked_at.is_(None)))
    ).scalars()
    for row in rows:
        row.revoked_at = utcnow()
