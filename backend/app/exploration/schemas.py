from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from app.core.schemas import APIModel, Coordinate


class CellOut(APIModel):
    h3: str
    state: str
    firstVisitedAt: datetime | None = None


class QuestMarker(APIModel):
    questId: uuid.UUID
    title: str
    latitude: float
    longitude: float
    difficulty: str
    questType: str
    status: str


class WorldOut(APIModel):
    center: Coordinate
    h3Resolution: int
    cells: list[CellOut]
    discoveries: list[Any]
    questMarkers: list[QuestMarker]
    featureFlags: dict[str, bool]
    # Chests, pieces and monsters placed for this player (world_objects); default for old readers.
    objects: list[Any] = []


class ExplorationOut(APIModel):
    h3Resolution: int
    cells: list[CellOut]


class ExplorationStats(APIModel):
    cellsVisited: int
    cellsExplored: int
    cellsDiscovered: int
    newTerritoryKm: float
    uniqueRoadsKm: float
    regionsVisited: int
    questsCompleted: int
    discoveriesFound: int
    storyQuestsCompleted: int
    totalDistanceMeters: float
    totalElevationMeters: float
    ridesCompleted: int
    averageSpeedMps: float | None = None
    maxSpeedMps: float | None = None
