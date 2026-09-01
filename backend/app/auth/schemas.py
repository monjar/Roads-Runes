from __future__ import annotations

from app.core.schemas import APIModel
from app.users.schemas import UserOut


class AppleName(APIModel):
    givenName: str | None = None
    familyName: str | None = None


class AppleSignInRequest(APIModel):
    identityToken: str
    authorizationCode: str | None = None
    fullName: AppleName | None = None


class RefreshRequest(APIModel):
    refreshToken: str


class DevSignInRequest(APIModel):
    subject: str
    displayName: str = "Dev Rider"


class TokenResponse(APIModel):
    accessToken: str
    refreshToken: str
    expiresIn: int
    isNewUser: bool
    user: UserOut
