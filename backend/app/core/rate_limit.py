"""Simple fixed-window rate limiter: Redis when available, in-memory otherwise."""

from __future__ import annotations

import time
from collections import defaultdict

from app.core.errors import RateLimited


class RateLimiter:
    def __init__(self, per_minute: int, redis_client=None) -> None:
        self.per_minute = per_minute
        self.redis = redis_client
        self._memory: dict[str, list[float]] = defaultdict(list)

    async def check(self, key: str) -> None:
        now = time.time()
        if self.redis is not None:
            window = int(now // 60)
            redis_key = f"rl:{key}:{window}"
            count = await self.redis.incr(redis_key)
            if count == 1:
                await self.redis.expire(redis_key, 65)
            if count > self.per_minute:
                raise RateLimited("Too many requests")
            return
        hits = self._memory[key]
        cutoff = now - 60
        self._memory[key] = hits = [t for t in hits if t > cutoff]
        if len(hits) >= self.per_minute:
            raise RateLimited("Too many requests")
        hits.append(now)
