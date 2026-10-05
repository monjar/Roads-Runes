"""Letters to your future self (0.7.3).

Written at a standstill, during a journey or not (the phone decides when it may
be written; the server takes it any time). Passed again within 60 m a season or
more later (`letter_min_age_days`, 90 by default), Journey's end shows it once:
"You wrote this here in October." It is never sent anywhere.
"""

from __future__ import annotations

import math
import uuid
from collections.abc import Sequence
from datetime import datetime, timedelta
from typing import Any, Protocol

from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.between.models import Letter
from app.between.schemas import LetterIn, LetterOut
from app.core.config import Settings
from app.core.errors import AppError, NotFound
from app.core.security import utcnow
from app.discoveries.service import nearby as discoveries_nearby
from app.rides.models import Ride

TEXT_WIDTH = 140
PLACE_WIDTH = 160
PLACE_REACH_M = 80.0
FOUND_REACH_M = 60.0
MONTHS = (
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
)  # fmt: skip

EMPTY = "Your letter is empty. Write a few words first."
TOO_LONG = "That letter is too long. Keep it to 140 characters."
GONE = "That letter is already gone. Refresh your letters."


class _Point(Protocol):
    latitude: float
    longitude: float


def letter_out(letter: Letter) -> LetterOut:
    return LetterOut(
        id=letter.id,
        text=letter.text,
        latitude=letter.latitude,
        longitude=letter.longitude,
        placeName=letter.place_name,
        writtenAt=letter.written_at,
        shownAt=letter.shown_at,
        shownRideId=letter.shown_ride_id,
    )


async def write(db: AsyncSession, user_id: uuid.UUID, payload: LetterIn) -> Letter:
    text = payload.text.strip()
    if not text:
        raise AppError(EMPTY, code="LETTER_EMPTY")
    if len(text) > TEXT_WIDTH:
        raise AppError(TOO_LONG, code="LETTER_TOO_LONG")
    places = await discoveries_nearby(db, payload.latitude, payload.longitude, PLACE_REACH_M, limit=5)
    named = next((p for p in places if (p.name or "").strip()), None)
    letter = Letter(
        user_id=user_id,
        latitude=payload.latitude,
        longitude=payload.longitude,
        text=text,
        place_name=named.name.strip()[:PLACE_WIDTH] if named is not None else None,
        written_at=utcnow(),
    )
    db.add(letter)
    await db.flush()
    return letter


async def mine(db: AsyncSession, user_id: uuid.UUID, limit: int = 500) -> list[Letter]:
    return list(
        (
            await db.execute(
                select(Letter)
                .where(Letter.user_id == user_id)
                .order_by(Letter.written_at.desc(), Letter.id)
                .limit(limit)
            )
        ).scalars()
    )


async def remove(db: AsyncSession, user_id: uuid.UUID, letter_id: uuid.UUID) -> None:
    letter = await db.get(Letter, letter_id)
    if letter is None or letter.user_id != user_id:
        raise NotFound(GONE)
    await db.delete(letter)
    await db.flush()


def found_line(written_at: datetime, ride_started: datetime) -> str:
    """The line under a found letter: "You wrote this here in October.", with the
    year when it was written in another one."""
    month = MONTHS[written_at.month - 1]
    when = month if written_at.year == ride_started.year else f"{month} {written_at.year}"
    return f"You wrote this here in {when}."


def _passed_within(lat: float, lon: float, points: Sequence[_Point], reach_m: float) -> bool:
    """Whether the trace came within `reach_m` of a point: its fixes, or the line
    between two fixes (a fast pass can step over a small circle)."""
    k = math.cos(math.radians(lat))
    m_per_deg = 111_320.0

    def xy(p: _Point) -> tuple[float, float]:
        return ((p.longitude - lon) * m_per_deg * k, (p.latitude - lat) * m_per_deg)

    prev: tuple[float, float] | None = None
    for p in points:
        cur = xy(p)
        if math.hypot(*cur) <= reach_m:
            return True
        if prev is not None:
            dx, dy = cur[0] - prev[0], cur[1] - prev[1]
            length2 = dx * dx + dy * dy
            if length2 > 0:
                t = max(0.0, min(1.0, -(prev[0] * dx + prev[1] * dy) / length2))
                if math.hypot(prev[0] + t * dx, prev[1] + t * dy) <= reach_m:
                    return True
        prev = cur
    return False


async def found_on(
    db: AsyncSession, settings: Settings, ride: Ride, points: Sequence[_Point], ended: datetime
) -> list[dict[str, Any]]:
    """Letters this journey passed, old enough and not shown before, marked shown
    by it. Run again on the same journey, it finds the same letters."""
    if not points:
        return []
    written_before = ride.started_at - timedelta(days=max(0, settings.letter_min_age_days))
    lats = [p.latitude for p in points]
    lons = [p.longitude for p in points]
    pad_lat = FOUND_REACH_M / 111_320.0
    pad_lon = pad_lat / max(0.01, math.cos(math.radians(sum(lats) / len(lats))))
    rows = (
        await db.execute(
            select(Letter)
            .where(
                Letter.user_id == ride.user_id,
                Letter.written_at <= written_before,
                or_(Letter.shown_at.is_(None), Letter.shown_ride_id == ride.id),
                Letter.latitude.between(min(lats) - pad_lat, max(lats) + pad_lat),
                Letter.longitude.between(min(lons) - pad_lon, max(lons) + pad_lon),
            )
            .order_by(Letter.written_at)
        )
    ).scalars()
    found: list[dict[str, Any]] = []
    for letter in rows:
        if not _passed_within(letter.latitude, letter.longitude, points, FOUND_REACH_M):
            continue
        if letter.shown_at is None:
            letter.shown_at = ended
            letter.shown_ride_id = ride.id
        found.append(
            {
                "id": str(letter.id),
                "text": letter.text,
                "writtenAt": letter.written_at.isoformat(),
                "placeName": letter.place_name,
                "latitude": letter.latitude,
                "longitude": letter.longitude,
                "line": found_line(letter.written_at, ride.started_at),
            }
        )
    await db.flush()
    return found
