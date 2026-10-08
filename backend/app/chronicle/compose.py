"""The entry: a few written lines about an outing, composed from its facts
(docs/ROADMAP.md, 0.6.2). Pure; no model, no clock, no place it was not given.

An entry is an opening line about the ground, a line or two about what happened,
and, only when little did, one dry closing line. Every phrase comes from a pool
picked by seed, so the same outing always reads the same and thirty in a row do
not. Names are only ever the ones in the facts.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field

WAYS = {"RIDE": "by bike", "RUN": "at a run", "WALK": "on foot"}

OPEN_NEW = (
    "Out {way}, {distance}, most of it unexplored.",
    "{Distance} {way}, and most of it new to you.",
    "{Distance} {way}. The map had little to say about most of it before today.",
    "A new way, mostly: {distance} {way}.",
)
OPEN_SOME = (
    "{Distance} {way}, with {cells} in it.",
    "{Distance} {way}, and {tiles} of it unexplored until today.",
    "Out {way} for {distance}; {cells} on the way.",
    "{Distance} {way}, mostly known, with {tiles} that were not.",
)
OPEN_KNOWN = (
    "{Distance} {way} on ground you know.",
    "{Distance} {way}, all of it explored before. The roads do not mind a second visit.",
    "A known way, {distance} {way}.",
    "{Distance} {way} on familiar roads.",
)
CLIMB = (
    "{Climb} climbed on the way.",
    "It asked for {climb} of climbing.",
    "{Climb} up, and the same down, more or less.",
)
CLOSE = (
    "It is in the Journal.",
    "Nothing else to report, which is its own kind of report.",
    "The roads were where they were left.",
    "Walter Garth has written it down.",
    "That will do for one journey.",
)


@dataclass
class Facts:
    activity: str = "RIDE"
    distance_m: float = 0.0
    climb_m: float = 0.0
    new_cells: int = 0
    known_share: float = 1.0
    places: list[str] = field(default_factory=list)
    seen_off: list[str] = field(default_factory=list)
    loosened: list[str] = field(default_factory=list)
    chests: int = 0
    pieces: int = 0
    quest_title: str | None = None
    arc_finished: str | None = None
    quarry: str | None = None
    quarry_seen_off: bool | None = None
    days_kept: int = 0


def _pick(pool: tuple[str, ...], seed: str, slot: str) -> str:
    digest = hashlib.sha256(f"{seed}:{slot}".encode()).hexdigest()
    return pool[int(digest[:8], 16) % len(pool)]


def _km(meters: float) -> str:
    km = meters / 1000
    return f"{km:.1f} km" if km < 10 else f"{km:.0f} km"


def _tiles(n: int, new: bool = False) -> str:
    what = "new tile" if new else "tile"
    return f"{n} {what}" if n == 1 else f"{n} {what}s"


def _the(name: str) -> str:
    """A name with "the" before it, unless it brings its own ("the Long Cold")."""
    return name if name[:4].lower() == "the " else f"the {name}"


def _and(names: list[str]) -> str:
    if len(names) <= 1:
        return "".join(names)
    return ", ".join(names[:-1]) + " and " + names[-1]


def _cap(text: str) -> str:
    return text[:1].upper() + text[1:]


def compose(facts: Facts, seed: str) -> str:
    """Two to five sentences. Empty for an outing too short to write about."""
    if facts.distance_m < 300:
        return ""
    values = {
        "way": WAYS.get(facts.activity.upper(), "out"),
        "distance": _km(facts.distance_m),
        "cells": _tiles(facts.new_cells, new=True),
        "tiles": _tiles(facts.new_cells),
        "climb": f"{facts.climb_m:.0f} m",
    }
    values.update({_cap(k): _cap(v) for k, v in list(values.items())})
    if facts.new_cells > 0 and facts.known_share < 0.4:
        opening = _pick(OPEN_NEW, seed, "open")
    elif facts.new_cells > 0:
        opening = _pick(OPEN_SOME, seed, "open")
    else:
        opening = _pick(OPEN_KNOWN, seed, "open")
    sentences = [opening.format(**values)]
    if facts.climb_m >= 150:
        sentences.append(_pick(CLIMB, seed, "climb").format(**values))

    events: list[str] = []
    seen_off = list(facts.seen_off)
    loosened = list(facts.loosened)
    if facts.quarry:
        # What the outing was for comes first.
        if facts.quarry_seen_off:
            events.append(f"{_cap(_the(facts.quarry))}, which was the point, was defeated.")
            seen_off = [n for n in seen_off if n != facts.quarry]
        elif facts.quarry in loosened:
            events.append(f"{_cap(_the(facts.quarry))} got away, weakened.")
            loosened = [n for n in loosened if n != facts.quarry]
        else:
            events.append(f"{_cap(_the(facts.quarry))} was not met.")
    if seen_off:
        verb = "was" if len(seen_off) == 1 else "were"
        events.append(f"{_cap(_and([_the(n) for n in seen_off[:3]]))} {verb} defeated.")
    if loosened:
        events.append(f"{_cap(_and([_the(n) for n in loosened[:2]]))} got away, weakened.")
    if facts.places:
        shown = facts.places[:2]
        more = len(facts.places) - len(shown)
        tail = f", and {more} more" if more else ""
        events.append(f"{_and(shown)}{tail}: new to you.")
    found = []
    if facts.chests:
        found.append("a chest opened" if facts.chests == 1 else f"{facts.chests} chests opened")
    if facts.pieces:
        found.append("a piece picked up" if facts.pieces == 1 else f"{facts.pieces} pieces picked up")
    if found:
        events.append(_cap(_and(found)) + ".")
    if facts.quest_title:
        events.append(f"{facts.quest_title}: done.")
    if facts.arc_finished:
        events.append(f"That finishes {facts.arc_finished}.")
    sentences.extend(events[:4])
    # One dry turn at most, and only when there was little else to say.
    if len(events) <= 1:
        sentences.append(_pick(CLOSE, seed, "close"))
    return " ".join(sentences)
