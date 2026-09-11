"""FastAPI application factory."""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app import __version__
from app.api.v1.router import api_router
from app.core.config import Settings, get_settings
from app.core.errors import install_error_handlers
from app.core.llm import build_llm
from app.core.logging import configure_logging, get_logger
from app.core.rate_limit import RateLimiter
from app.discoveries import osm_import
from app.jobs.handlers import HANDLERS
from app.jobs.queue import InlineJobQueue, RedisJobQueue
from app.routing.engine import SyntheticRouter, build_engine

log = get_logger(__name__)


async def build_state(app: FastAPI, settings: Settings) -> None:
    app.state.settings = settings
    app.state.llm = build_llm(settings)
    redis_client = None
    if settings.job_queue == "redis" or settings.environment in ("staging", "production"):
        import redis.asyncio as redis

        redis_client = redis.from_url(settings.redis_url)
        app.state.jobs = RedisJobQueue(redis_client)
    else:
        app.state.jobs = InlineJobQueue(HANDLERS)
    app.state.rate_limiter = RateLimiter(settings.rate_limit_per_minute, redis_client)
    if settings.environment == "test":
        app.state.router = SyntheticRouter()
    else:
        app.state.router = await build_engine(settings)
        if settings.is_production and app.state.router.name == "synthetic":
            raise RuntimeError("No routing engine is reachable; refusing to serve synthetic routes in production")


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    configure_logging(settings.log_level, json_output=settings.environment not in ("development", "test"))

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        await build_state(app, settings)
        log.info(
            "app_started",
            environment=settings.environment,
            routing=app.state.router.name,
            flags=settings.flags,
        )
        yield
        osm_import.cancel_all()
        jobs = getattr(app.state, "jobs", None)
        if isinstance(jobs, InlineJobQueue):
            await jobs.drain()

    app = FastAPI(
        title=settings.app_name,
        version=__version__,
        lifespan=lifespan,
        docs_url="/docs" if not settings.is_production else None,
    )
    install_error_handlers(app)
    app.include_router(api_router, prefix=settings.api_prefix)
    return app


app = create_app()
