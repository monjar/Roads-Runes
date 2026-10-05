from __future__ import annotations

from fastapi import APIRouter

from app import __version__
from app.auth.router import router as auth_router
from app.between.router import letters_router, pledge_router
from app.characters.router import router as character_router
from app.core.deps import SettingsDep
from app.discoveries.router import router as discoveries_router
from app.economy.router import router as wallet_router
from app.exploration.router import router as world_router
from app.integrations.router import router as integrations_router
from app.inventory.router import router as runes_router
from app.legends.router import router as legends_router
from app.lore.router import router as codex_router
from app.notifications.router import router as devices_router
from app.progression.engine import max_level
from app.quests.router import router as quests_router
from app.rides.journal import router as journal_router
from app.rides.router import router as rides_router
from app.routing.router import router as routes_router
from app.social.router import feed_router, friends_router, parties_router
from app.users.router import router as users_router
from app.world_objects.router import router as world_objects_router
from app.world_objects.service import load_config as load_world_config

api_router = APIRouter()


@api_router.get("/health", tags=["meta"])
async def health() -> dict:
    return {"status": "ok", "version": __version__}


@api_router.get("/config", tags=["meta"])
async def config(settings: SettingsDep) -> dict:
    return {
        "featureFlags": settings.flags,
        "h3Resolution": settings.h3_resolution,
        "levels": {"max": max_level("overall"), "maxClass": max_level("class")},
        "environment": settings.environment,
        # The fight's constants (world_objects/fight.py), so the phone folds the
        # same fight as the server without a release to change a number.
        "combat": {k: v for k, v in load_world_config()["combat"].items() if not k.startswith("_")},
        # How long a letter waits before a journey may find it again (0.7.3).
        "letterMinAgeDays": settings.letter_min_age_days,
    }


for r in (
    auth_router,
    users_router,
    character_router,
    world_router,
    quests_router,
    routes_router,
    rides_router,
    journal_router,
    discoveries_router,
    friends_router,
    feed_router,
    parties_router,
    integrations_router,
    devices_router,
    wallet_router,
    world_objects_router,
    codex_router,
    runes_router,
    pledge_router,
    letters_router,
    legends_router,
):
    api_router.include_router(r)
