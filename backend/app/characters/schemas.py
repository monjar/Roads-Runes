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
    # Whether the server acts on this knack yet. Most were promised before they
    # did anything; the sheet says so plainly rather than advertise them.
    working: bool | None = None


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
    # The sheet a ride started now would be frozen with (characters/sheet.py), so an
    # outing started offline folds the fight over the last one seen.
    sheet: dict[str, Any] | None = None
    # The player chose the title they wear (PUT /character/title); earning another
    # no longer changes it.
    titlePinned: bool = False


class TitleOut(APIModel):
    """A title, earned or not: `how` says how to earn it."""

    slug: str
    name: str
    source: str
    how: str
    earned: bool
    earnedAt: datetime | None = None
    worn: bool = False


class TitleChoice(APIModel):
    # A title earned, or null to wear the newest earned again.
    slug: str | None = None


class ClassInfo(APIModel):
    id: str
    name: str
    tagline: str
    description: str
    enabled: bool
    # The trade's guild, its saying and its crest id (docs/WORLD.md). Optional:
    # an older server sends none, and the app draws the class symbol instead.
    guild: str | None = None
    saying: str | None = None
    crest: str | None = None


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
