"""What the legends API says (0.8.0). Every field is new, so an older client never asks."""

from __future__ import annotations

import uuid
from datetime import datetime

from app.core.schemas import APIModel


class LegendPhaseOut(APIModel):
    n: int
    # ROAD, GROUND, CLIMB, RUNE, WORD, as the fight uses them.
    weakTo: list[str]
    resists: list[str]
    healthMax: int
    healthLeft: int
    broken: bool
    # For a phase weak to runes, what lands: ANY (any rune shape cut near it, or a
    # woken rune), WOKEN (only a rune woken on a rune ride) or a rune's id ("dagaz"),
    # whose shape is `roadForm`.
    rune: str | None = None
    roadForm: str | None = None
    # A stop of a few minutes beside it counts as a note (the Water Wyrm's second phase).
    stopIsNote: bool = False


class LegendJourneyOut(APIModel):
    rideId: str
    date: str | None = None
    damage: int
    phase: int


class LegendOut(APIModel):
    id: uuid.UUID
    speciesId: str
    name: str
    # The app's GameIcon name ("fogDragon").
    icon: str
    flavour: str
    page: str
    # Where this kind of legend lives, in words: "water with a path beside it".
    livesAt: str
    latitude: float
    longitude: float
    anchorName: str | None = None
    # AWAKE, DORMANT (asleep, off the map) or DEFEATED.
    status: str
    phase: int
    phases: list[LegendPhaseOut]
    # Over all three phases.
    healthLeft: int
    healthMax: int
    moved: bool
    wokeAt: datetime
    lastHitAt: datetime | None = None
    defeatedAt: datetime | None = None
    # Health a phase gets back each full week it is left alone.
    healsPerWeek: int
    # The Hard rune it leaves.
    rune: str
    sleepsAfterDays: int
    # When it falls asleep if left alone (awake only).
    sleepsAt: datetime | None = None
    # A phase broke today, so the next cannot until tomorrow.
    phaseBrokenToday: bool = False
    # 1 the first time round, 2 for "the Fog Dragon II".
    round: int = 1
    # GET /legends/{id} only: each journey that hurt it.
    journeys: list[LegendJourneyOut] | None = None


class LegendSummaryOut(APIModel):
    id: uuid.UUID
    speciesId: str
    name: str
    icon: str
    status: str
    rune: str
    wokeAt: datetime
    defeatedAt: datetime | None = None


class LegendsOut(APIModel):
    awake: LegendOut | None = None
    defeated: list[LegendSummaryOut]
    # Asleep: met, left alone four weeks, and waiting to wake again.
    sleeping: list[LegendSummaryOut] = []
    # Creatures still to defeat before one wakes; null while one is awake.
    creaturesUntilNext: int | None = None
