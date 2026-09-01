"""Minimal job queue abstraction.

`InlineJobQueue` runs handlers immediately in the request process (tests,
development). `RedisJobQueue` pushes JSON onto a Redis list consumed by
`app.jobs.worker`. Handlers are registered by name in `app.jobs.handlers`.
"""

from __future__ import annotations

import asyncio
import json
from collections.abc import Awaitable, Callable
from typing import Any, Protocol

from app.core.logging import get_logger

log = get_logger(__name__)

Handler = Callable[[dict[str, Any]], Awaitable[None]]
QUEUE_KEY = "rr:jobs"


class JobQueue(Protocol):
    async def enqueue(self, name: str, payload: dict[str, Any]) -> None: ...


class InlineJobQueue:
    def __init__(self, handlers: dict[str, Handler], background: bool = True) -> None:
        self.handlers = handlers
        self.background = background
        self.tasks: set[asyncio.Task[None]] = set()

    async def enqueue(self, name: str, payload: dict[str, Any]) -> None:
        handler = self.handlers[name]
        if not self.background:
            await handler(payload)
            return
        task = asyncio.create_task(self._run(handler, name, payload))
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)

    async def _run(self, handler: Handler, name: str, payload: dict[str, Any]) -> None:
        try:
            await handler(payload)
        except Exception as exc:  # noqa: BLE001
            log.error("job_failed", job=name, error=str(exc), payload=payload)

    async def drain(self) -> None:
        if self.tasks:
            await asyncio.gather(*list(self.tasks), return_exceptions=True)


class RedisJobQueue:
    def __init__(self, redis_client) -> None:
        self.redis = redis_client

    async def enqueue(self, name: str, payload: dict[str, Any]) -> None:
        await self.redis.rpush(QUEUE_KEY, json.dumps({"name": name, "payload": payload}))

    async def pop(self, timeout: int = 5) -> tuple[str, dict[str, Any]] | None:
        item = await self.redis.blpop(QUEUE_KEY, timeout=timeout)
        if item is None:
            return None
        data = json.loads(item[1])
        return data["name"], data["payload"]
