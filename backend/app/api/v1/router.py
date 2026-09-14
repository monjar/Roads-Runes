from __future__ import annotations

from fastapi import APIRouter

from app import __version__
from app.auth.router import router as auth_router
from app.characters.router import router as character_router
from app.core.deps import SettingsDep
from app.discoveries.router import router as discoveries_router
from app.economy.router import router as wallet_router
from app.exploration.router import router as world_router
from app.integrations.router import router as integrations_router
from app.notifications.router import router as devices_router
from app.progression.engine import max_level
from app.quests.router import router as quests_router
from app.rides.journal import router as journal_router
from app.rides.router import router as rides_router
from app.routing.router import router as routes_router
from app.social.router import feed_router, friends_router, parties_router
from app.users.router import router as users_router
from app.world_objects.router import router as world_objects_router

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
):
    api_router.include_router(r)
