from __future__ import annotations

from fastapi import APIRouter

from app.core.deps import CurrentUser, DBDep, SettingsDep
from app.core.feature_flags import require_flag
from app.lore import service
from app.lore.schemas import CodexOut

router = APIRouter(prefix="/codex", tags=["codex"])


@router.get("", response_model=CodexOut)
async def codex(user: CurrentUser, db: DBDep, settings: SettingsDep) -> CodexOut:
    """The world in its own words, and what this player has met of it."""
    require_flag(settings, "codex")
    return await service.codex(db, settings, user.id)
