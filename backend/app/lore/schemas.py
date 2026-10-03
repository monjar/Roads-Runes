from __future__ import annotations

from datetime import datetime

from app.core.schemas import APIModel


class CodexEntryOut(APIModel):
    id: str
    chapter: str
    title: str
    body: list[str]
    by: str
    byName: str
    # Set on a trade's page: which class it is.
    characterClass: str | None = None


class ElderOut(APIModel):
    tier: int
    name: str
    flavour: str
    # Whether this player has had one of these placed for them.
    seen: bool = False


class SigilOut(APIModel):
    body: str
    feature: str
    mark: str


class CreatureOut(APIModel):
    id: str
    name: str
    family: str
    flavour: str
    hint: str
    page: str
    leaves: str
    # What it wants done about it and what it shrugs at: ROAD, GROUND, CLIMB,
    # RUNE, WORD. The app shows these only once fights are decided by effort
    # (`effort_combat`); before that the old check is still what counts.
    wants: list[str]
    minds: list[str]
    rune: str | None = None
    elders: list[ElderOut]
    sigil: SigilOut
    # UNSEEN (never placed for this player), SEEN (on their map at least once),
    # MET (seen off, or loosened).
    state: str
    seenCount: int = 0
    seenOffCount: int = 0
    firstSeenAt: datetime | None = None
    lastSeenOffAt: datetime | None = None


class RuneOut(APIModel):
    id: str
    name: str
    order: int
    six: str
    gloss: str
    lends: str
    roadForm: str | None = None
    # HELD once the stone has been picked up; NOT_FOUND before.
    state: str
    found: int = 0


class SixOut(APIModel):
    id: str
    name: str
    how: str


class PersonOut(APIModel):
    id: str
    name: str
    role: str
    posts: str
    page: str
    pageBy: str
    lines: list[str]


class CodexCounts(APIModel):
    creaturesSeenOff: int
    creaturesSeen: int
    creaturesTotal: int
    runesHeld: int
    runesTotal: int


class CodexOut(APIModel):
    chapters: list[dict[str, str]]
    entries: list[CodexEntryOut]
    creatures: list[CreatureOut]
    runes: list[RuneOut]
    sixes: list[SixOut]
    people: list[PersonOut]
    counts: CodexCounts
