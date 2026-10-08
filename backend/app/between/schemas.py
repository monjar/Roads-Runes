from __future__ import annotations

import uuid
from datetime import date, datetime
from typing import Literal

from pydantic import Field

from app.core.schemas import APIModel

PledgeKind = Literal["CREATURE", "QUEST"]


class PledgeIn(APIModel):
    day: date
    targetKind: PledgeKind
    targetId: uuid.UUID
    # One local reminder at this time on the phone ("HH:MM", 24-hour), or none.
    remindAt: str | None = Field(default=None, pattern=r"^([01]\d|2[0-3]):[0-5]\d$")


class PledgeOut(APIModel):
    day: date
    targetKind: str
    targetId: uuid.UUID
    targetName: str
    # The app's GameIcon name: the creature's mark, or the quest's ("scroll").
    icon: str | None = None
    remindAt: str | None = None
    # PLEDGED or KEPT. A missed one is never shown.
    status: str


class PledgeStanding(APIModel):
    today: PledgeOut | None = None
    tomorrow: PledgeOut | None = None


class LetterIn(APIModel):
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    # 1 to 140 characters once trimmed (between/letters.py says so in words).
    text: str = Field(max_length=2000)


class LetterOut(APIModel):
    id: uuid.UUID
    text: str
    latitude: float
    longitude: float
    placeName: str | None = None
    writtenAt: datetime
    shownAt: datetime | None = None
    shownRideId: uuid.UUID | None = None
