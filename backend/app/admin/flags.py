"""Feature flag overrides saved on /admin.

The code's defaults, then FEATURE_FLAGS, then these (app/core/config.py `Settings.flags`).
Flags are read synchronously all over the backend, so the overrides are held in memory
(`RUNTIME_FLAG_OVERRIDES`) and reloaded from the database: at startup, then at most every
REFRESH_SECONDS on the next request or job. The process that saves a change has it at
once; any other process (a second machine, the Redis worker) within REFRESH_SECONDS.
"""

from __future__ import annotations

import time

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.admin.models import FeatureFlagOverride
from app.core.config import ALL_FEATURE_FLAGS, RUNTIME_FLAG_OVERRIDES, Settings, parse_feature_flags
from app.core.logging import get_logger
from app.db.session import get_session_factory

log = get_logger(__name__)

REFRESH_SECONDS = 30.0

_loaded_at: float | None = None


async def load(db: AsyncSession) -> dict[str, FeatureFlagOverride]:
    """The saved overrides for flags the code still has; a retired flag's row is inert."""
    rows = (await db.execute(select(FeatureFlagOverride))).scalars().all()
    return {row.name: row for row in rows if row.name in ALL_FEATURE_FLAGS}


def _apply(overrides: dict[str, bool]) -> None:
    RUNTIME_FLAG_OVERRIDES.clear()
    RUNTIME_FLAG_OVERRIDES.update(overrides)


async def refresh(*, force: bool = False) -> None:
    """Reload the overrides when they are older than REFRESH_SECONDS. A database that
    cannot be read keeps the last overrides loaded (none, at startup) and says so."""
    global _loaded_at
    now = time.monotonic()
    if not force and _loaded_at is not None and now - _loaded_at < REFRESH_SECONDS:
        return
    _loaded_at = now  # before the await, so concurrent requests do not all reload
    try:
        async with get_session_factory()() as db:
            rows = await load(db)
    except Exception as exc:  # noqa: BLE001
        log.warning("flag_overrides_refresh_failed", error=str(exc)[:300])
        return
    _apply({name: row.enabled for name, row in rows.items()})


class RefreshFlagsMiddleware:
    """Pure ASGI, so it adds nothing to a request but the reload when one is due."""

    def __init__(self, app) -> None:
        self.app = app

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] == "http":
            await refresh()
        await self.app(scope, receive, send)


async def save(db: AsyncSession, name: str, enabled: bool | None, note: str | None) -> None:
    """Switch a flag on or off over FEATURE_FLAGS, or clear the override (None)."""
    if name not in ALL_FEATURE_FLAGS:
        raise ValueError(f"unknown flag {name}")
    if enabled is None:
        await db.execute(delete(FeatureFlagOverride).where(FeatureFlagOverride.name == name))
    else:
        row = await db.scalar(select(FeatureFlagOverride).where(FeatureFlagOverride.name == name))
        if row is None:
            db.add(FeatureFlagOverride(name=name, enabled=enabled, note=note))
        else:
            row.enabled, row.note = enabled, note
    await db.commit()
    if enabled is None:
        RUNTIME_FLAG_OVERRIDES.pop(name, None)
    else:
        RUNTIME_FLAG_OVERRIDES[name] = enabled
    log.info("feature_flag_override_saved", flag=name, enabled=enabled, note=note)


def table(settings: Settings, overrides: dict[str, FeatureFlagOverride]) -> list[dict]:
    """Every flag, where its value comes from, and what it is."""
    defaults = settings.default_flags
    from_env = parse_feature_flags(settings.feature_flags)
    rows = []
    for name in sorted(ALL_FEATURE_FLAGS):
        override = overrides.get(name)
        env_value = from_env.get(name)
        if override is not None:
            source, effective = "override", override.enabled
        elif env_value is not None:
            source, effective = "FEATURE_FLAGS", env_value
        else:
            source, effective = "default", defaults.get(name, False)
        rows.append(
            {
                "name": name,
                "default": defaults.get(name, False),
                "env": env_value,
                "override": override.enabled if override else None,
                "note": override.note if override else None,
                "updatedAt": override.updated_at if override else None,
                "effective": effective,
                "source": source,
            }
        )
    return rows
