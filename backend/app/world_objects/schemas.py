from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from pydantic import Field

from app.core.schemas import APIModel


class KillMethodOut(APIModel):
    method: str
    params: dict[str, Any] = {}
    hint: str


class MonsterOut(APIModel):
    hp: int
    flavour: str | None = None
    killMethods: list[KillMethodOut] = []
    # Which creature this is, and its face (docs/WORLD.md): set from 0.6.0, and
    # found by name for anything placed before species had ids.
    speciesId: str | None = None
    # {"body", "feature", "mark", "icon"}; `icon` is the app's GameIcon name (0.7.2).
    sigil: dict[str, str] | None = None
    # Effort is damage (0.6.1, flag effort_combat): its hold, what it wants and
    # shrugs at (ROAD, GROUND, CLIMB, RUNE, WORD), and its rune and road form.
    holdMax: int | None = None
    holdLeft: int | None = None
    wants: list[str] | None = None
    minds: list[str] | None = None
    rune: str | None = None
    roadForm: str | None = None
    # Days since the player last passed its place, when they have and it was a while.
    unpassedDays: int | None = None
    # 0.7.2: a variant ({"id": "STUBBORN", "name": "Stubborn", "text": "30% more health
    # and 30% more coins."}), the name to show ("Stubborn Fen Troll"; `name` stays
    # plain), and a grudge ({"epithet": "Grumpy", "line": "It got away twice. ..."}).
    variant: dict[str, str] | None = None
    displayName: str | None = None
    grudge: dict[str, str] | None = None


class WorldObjectOut(APIModel):
    id: uuid.UUID
    kind: str
    status: str
    tier: int
    latitude: float
    longitude: float
    name: str
    anchorName: str | None = None
    bounty: bool = False
    rewardAC: int
    expiresAt: datetime
    claimedAt: datetime | None = None
    monster: MonsterOut | None = None
    setId: str | None = None
    piece: str | None = None
    # A piece belongs to a set: its name, how many pieces there are, and (where the
    # player is known) how many different ones they hold.
    setName: str | None = None
    setSize: int | None = None
    setOwned: int | None = None
    # They already hold this very piece: picking it up is coins, not progress.
    pieceOwned: bool | None = None
    # How close the player must be to open or pick it up; nothing for a monster.
    claimRadiusMeters: float | None = None
    # The name to show: a variant in front of a creature's ("Stubborn Fen Troll"), 0.7.2.
    displayName: str | None = None


class ClaimIn(APIModel):
    """Where the phone says the player is standing when they reach for it."""

    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    horizontalAccuracyMeters: float | None = Field(default=None, ge=0)


class ClaimResultOut(APIModel):
    object: WorldObjectOut
    acAwarded: int
    walletBalance: int
    # The quest this finished, if opening it was the last thing a quest asked for.
    questCompleted: Any | None = None
    xpAwarded: int = 0
    levelUps: list[dict[str, Any]] = []
    # The set this piece finished: {"id", "name", "bonusAC"}.
    setCompleted: dict[str, Any] | None = None
    # What the chest held besides coins, if anything (ItemFoundOut), 0.7.2.
    itemFound: dict[str, Any] | None = None


class ClaimedOut(APIModel):
    id: uuid.UUID
    kind: str
    name: str
    tier: int
    rewardAC: int
    method: str | None = None


class MissedOut(APIModel):
    id: uuid.UUID
    kind: str
    name: str
    reason: str
