"""Sign in with Apple identity-token verification."""

from __future__ import annotations

import time
from typing import Any

import httpx
from jose import JWTError, jwt

from app.core.config import Settings
from app.core.errors import Unauthenticated


class AppleKeyCache:
    def __init__(self, url: str, ttl_seconds: int = 3600) -> None:
        self.url = url
        self.ttl = ttl_seconds
        self._keys: list[dict[str, Any]] = []
        self._fetched_at = 0.0

    async def keys(self) -> list[dict[str, Any]]:
        if self._keys and time.time() - self._fetched_at < self.ttl:
            return self._keys
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.get(self.url)
            response.raise_for_status()
            self._keys = response.json().get("keys", [])
            self._fetched_at = time.time()
        return self._keys


_cache: AppleKeyCache | None = None


async def verify_identity_token(settings: Settings, identity_token: str) -> dict[str, Any]:
    """Return the verified claims (sub, email, email_verified...)."""
    global _cache
    if _cache is None or _cache.url != settings.apple_jwks_url:
        _cache = AppleKeyCache(settings.apple_jwks_url)
    try:
        header = jwt.get_unverified_header(identity_token)
    except JWTError as exc:
        raise Unauthenticated("Malformed Apple identity token") from exc
    keys = await _cache.keys()
    key = next((k for k in keys if k.get("kid") == header.get("kid")), None)
    if key is None:
        _cache._fetched_at = 0.0  # force refresh next time (key rotation)
        raise Unauthenticated("Unknown Apple signing key")
    try:
        claims = jwt.decode(
            identity_token,
            key,
            algorithms=[header.get("alg", "RS256")],
            audience=settings.apple_client_id,
            issuer=settings.apple_issuer,
        )
    except JWTError as exc:
        raise Unauthenticated("Apple identity token rejected") from exc
    if not claims.get("sub"):
        raise Unauthenticated("Apple identity token has no subject")
    return claims
