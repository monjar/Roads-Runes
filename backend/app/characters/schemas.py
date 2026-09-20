from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any, Literal

from pydantic import Field

from app.core.activity import Activity
from app.core.schemas import APIModel

CharacterClass = Literal["EXPLORER", "WIZARD", "WARRIOR", "SCRIBE"]
BikeType = Literal["ROAD", "GRAVEL", "MOUNTAIN", "HYBRID", "FOLDING", "OTHER"]


class AbilityOut(APIModel):
    id: str
    characterClass: str
    name: str
    description: str
    requiredClassLevel: int
    maxRank: int
    effects: list[dict[str, Any]] = []


class AbilityState(APIModel):
    ability: AbilityOut
    rank: int = 0
    unlocked: bool = False
    canUnlock: bool = False


class CharacterCreate(APIModel):
    name: str = Field(min_length=1, max_length=40)
    characterClass: CharacterClass = "EXPLORER"


class CharacterClassChange(APIModel):
    characterClass: CharacterClass


class ClassProgressOut(APIModel):
    classXp: int
    classLevel: int


class CharacterOut(APIModel):
    id: uuid.UUID
    name: str
    characterClass: str
    overallLevel: int
    overallXP: int
    nextOverallLevelXP: int | None
    overallLevelFloorXP: int
    classLevel: int
    classXP: int
    nextClassLevelXP: int | None
    classLevelFloorXP: int
    title: str | None
    abilities: list[AbilityState]
    unspentAbilityPoints: int
    createdAt: datetime
    activeCoins: int = 0
    classChanges: int = 0
    # When the next change is allowed (None: now) and what it costs (0: free).
    nextClassChangeAt: datetime | None = None
    classChangeCostAC: int = 0
    classProgress: dict[str, ClassProgressOut] = {}
    streakDays: int = 0
    longestStreakDays: int = 0
    # True once an outing has counted today, so the app can say "keep it alive" or "done".
    streakActiveToday: bool = False


class ClassInfo(APIModel):
    id: str
    name: str
    tagline: str
    description: str
    enabled: bool


class BikeIn(APIModel):
    name: str = Field(min_length=1, max_length=80)
    bikeType: BikeType
    allowGravel: bool | None = None
    allowTrails: bool | None = None
    maxTechnicalSurface: int | None = Field(default=None, ge=0, le=3)
    isDefault: bool = False


class BikePatch(APIModel):
    name: str | None = Field(default=None, min_length=1, max_length=80)
    bikeType: BikeType | None = None
    allowGravel: bool | None = None
    allowTrails: bool | None = None
    maxTechnicalSurface: int | None = Field(default=None, ge=0, le=3)
    isDefault: bool | None = None


class BikeOut(APIModel):
    id: uuid.UUID
    name: str
    bikeType: str
    allowGravel: bool
    allowTrails: bool
    maxTechnicalSurface: int
    isDefault: bool


class RiderProfileIO(APIModel):
    comfortableDistanceKm: float = Field(default=25.0, ge=1, le=400)
    comfortableElevationGain: float = Field(default=300.0, ge=0, le=10000)
    maxPreferredGradient: float = Field(default=8.0, ge=0, le=30)
    trafficTolerance: float = Field(default=0.3, ge=0, le=1)
    gravelComfort: float = Field(default=0.5, ge=0, le=1)
    technicalTrailComfort: float = Field(default=0.2, ge=0, le=1)
    cyclewayPreference: float = Field(default=0.8, ge=0, le=1)
    defaultActivity: Activity = "RIDE"
    runDistanceKm: float = Field(default=8.0, ge=1, le=100)
    walkDistanceKm: float = Field(default=5.0, ge=0.5, le=60)
