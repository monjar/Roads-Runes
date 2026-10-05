"""What the districts API says (0.9.0). Every field is new."""

from __future__ import annotations

from datetime import datetime

from app.core.schemas import APIModel


class DistrictOut(APIModel):
    id: str
    name: str
    # suburb, neighbourhood, quarter, village, town or hamlet.
    kind: str
    # "the Riverlands"; null under 10% explored (or before its roads are known).
    title: str | None = None
    # "Rotherhithe, the Riverlands", or "Rotherhithe, in the fog".
    displayName: str
    # Explored %, 0–100, of its tiles with a road or path; null until those are known.
    percent: float | None = None
    exploredTiles: int = 0
    # How many of its tiles have a road or path, once known.
    wayTiles: int | None = None
    yours: bool = False
    wasYours: bool = False
    completed: bool = False
    # What it pays a week while it is yours (5, more with Fehu).
    weeklyCoins: int
    latitude: float
    longitude: float
    firstPassed: datetime | None = None
    lastPassed: datetime | None = None


class DistrictLedgerOut(APIModel):
    placesFound: int = 0
    creaturesDefeated: int = 0
    runesCut: int = 0
    questsDone: int = 0
    firstPassed: datetime | None = None
    lastPassed: datetime | None = None


class DistrictDetailOut(DistrictOut):
    ledger: DistrictLedgerOut
