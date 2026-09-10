"""Redis-backed worker: `python -m app.jobs.worker`."""

from __future__ import annotations

import asyncio

import redis.asyncio as redis

from app.core.config import get_settings
from app.core.logging import configure_logging, get_logger
from app.jobs.handlers import HANDLERS
from app.jobs.queue import RedisJobQueue

log = get_logger(__name__)


async def main() -> None:
    settings = get_settings()
    configure_logging(settings.log_level, json_output=settings.environment != "development")
    queue = RedisJobQueue(redis.from_url(settings.redis_url))
    log.info("worker_started", redis=settings.redis_url)
    while True:
        item = await queue.pop()
        if item is None:
            continue
        name, payload = item
        handler = HANDLERS.get(name)
        if handler is None:
            log.warning("unknown_job", job=name)
            continue
        try:
            await handler(payload)
            log.info("job_done", job=name)
        except Exception as exc:  # noqa: BLE001
            log.error("job_failed", job=name, error=str(exc))


if __name__ == "__main__":
    asyncio.run(main())
