"""Cursor pagination helpers. Cursors are opaque base64 of "<sort_key>|<id>"."""

from __future__ import annotations

import base64
import uuid
from datetime import datetime
from typing import Generic, TypeVar

from pydantic import BaseModel

T = TypeVar("T")

MAX_LIMIT = 100
DEFAULT_LIMIT = 25


class Page(BaseModel, Generic[T]):
    items: list[T]
    nextCursor: str | None = None


def clamp_limit(limit: int | None) -> int:
    if limit is None:
        return DEFAULT_LIMIT
    return max(1, min(limit, MAX_LIMIT))


def encode_cursor(sort_key: datetime, item_id: uuid.UUID) -> str:
    raw = f"{sort_key.isoformat()}|{item_id}"
    return base64.urlsafe_b64encode(raw.encode()).decode()


def decode_cursor(cursor: str | None) -> tuple[datetime, uuid.UUID] | None:
    if not cursor:
        return None
    try:
        raw = base64.urlsafe_b64decode(cursor.encode()).decode()
        sort_raw, id_raw = raw.split("|", 1)
        return datetime.fromisoformat(sort_raw), uuid.UUID(id_raw)
    except Exception:  # noqa: BLE001 - any malformed cursor is a client error
        return None
