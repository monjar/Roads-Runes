"""The five legends and their rules (world_objects/config/legends.json). Pure: the
config, checked once, and the numbers worked out from it. No clock, no database.

A legend is fought one phase at a time. Each phase is a creature to the fight
model (world_objects/fight.py): its health is the phase's, it is weak to and
resists what the phase says, and a rune lands on it as the phase's `rune` says.
"""

from __future__ import annotations

import json
import math
from datetime import datetime
from functools import lru_cache
from pathlib import Path
from typing import Any

from app.world_objects.fight import KINDS

CONFIG = Path(__file__).parent.parent / "world_objects" / "config" / "legends.json"
ORDER = ("fog-dragon", "water-wyrm", "hill-king", "trail-wyrm", "rune-golem")
HOME_RULES = ("FOG", "PLACE")
# What lands as a rune on a phase weak to one: any shape, only a woken rune, or a rune's own shape.
RUNE_ANY = "ANY"
RUNE_WOKEN = "WOKEN"
# Columns the legend's text must fit (legends/models.py).
NAME_WIDTH = 80
SPECIES_WIDTH = 30


@lru_cache
def book() -> dict[str, Any]:
    from app.inventory import catalog as runes
    from app.lore.catalog import runes_by_id
    from app.progression.titles import legend_title

    data = json.loads(CONFIG.read_text())
    legends = data["legends"]
    assert tuple(legend["id"] for legend in legends) == ORDER, "the five legends, in the order they wake"
    assert int(data["phases"]) == 3 and int(data["phaseHealth"]) > 0
    low, high = data["ringMeters"]
    assert 0 < low < high
    assert int(data["wakeReachTests"]) >= int(data["anchorTries"]) > 0
    for legend in legends:
        lid = legend["id"]
        assert len(lid) <= SPECIES_WIDTH, lid
        # The second and later rounds add " II", " III" and so on.
        assert len(legend["name"]) + 5 <= NAME_WIDTH, lid
        assert legend["icon"] and legend["flavour"].strip() and legend["page"].strip() and legend["livesAt"], lid
        assert legend["rune"] in runes.hard_six(), f"{lid} leaves a rune that is not one of the Hard Six"
        assert legend_title(lid) is not None, f"{lid} has no bane title"
        assert legend["home"]["rule"] in HOME_RULES, lid
        assert len(legend["phases"]) == int(data["phases"]), lid
        for phase in legend["phases"]:
            weak, resists = set(phase["weakTo"]), set(phase["resists"])
            assert weak and weak <= set(KINDS) and resists <= set(KINDS), lid
            assert not weak & resists, f"{lid} is weak to and resists the same thing"
            rule = phase.get("rune")
            if "RUNE" in weak:
                assert rule in (RUNE_ANY, RUNE_WOKEN) or (runes_by_id().get(str(rule)) or {}).get("roadForm") in (
                    runes.CUT_FORMS
                ), f"{lid}: what rune lands on this phase?"
            else:
                assert rule is None, f"{lid}: a rune rule on a phase not weak to runes"
    return data


@lru_cache
def by_id() -> dict[str, dict[str, Any]]:
    return {legend["id"]: legend for legend in book()["legends"]}


def legend(species_id: str) -> dict[str, Any]:
    return by_id()[species_id]


def phase_spec(species_id: str, phase: int) -> dict[str, Any]:
    return legend(species_id)["phases"][max(1, min(3, phase)) - 1]


def phase_health(round_: int = 1) -> int:
    """One phase's health: 500 the first time round, a quarter more each round after."""
    scale = 1 + float(book()["roundHealthScale"]) * max(0, round_ - 1)
    return int(round(int(book()["phaseHealth"]) * scale))


def round_name(species_id: str, round_: int) -> str:
    """ "The Fog Dragon", then "The Fog Dragon II" the second time round."""
    name = str(legend(species_id)["name"])
    return name if round_ <= 1 else f"{name} {_roman(round_)}"


def _roman(n: int) -> str:
    out = ""
    for value, letters in ((10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")):
        while n >= value:
            out += letters
            n -= value
    return out


def heal_per_week(phase_max: int) -> int:
    return int(round(phase_max * float(book()["healPerWeek"])))


def sleep_after_days() -> int:
    return int(book()["sleepAfterDays"])


def weeks_between(since: datetime, now: datetime) -> int:
    return max(0, math.floor((now - since).total_seconds() / (7 * 86400)))


def healed(left: int, phase_max: int, since: datetime, now: datetime) -> int:
    """What is left of a phase after being left alone from `since` to `now`: a tenth
    of the phase back for every full week, never above the phase's health. A phase
    already broken is never healed (the caller only asks about the current one)."""
    weeks = min(weeks_between(since, now), sleep_after_days() // 7)
    return min(phase_max, left + weeks * heal_per_week(phase_max))


def is_asleep(since: datetime, now: datetime) -> bool:
    return (now - since).total_seconds() >= sleep_after_days() * 86400


def wake_after_defeats() -> int:
    return int(book()["wakeAfterDefeats"])


def rune_road_form(rule: str | None) -> str | None:
    """The shape a phase's own rune is ridden as, when the phase names one."""
    if rule in (None, RUNE_ANY, RUNE_WOKEN):
        return None
    from app.lore.catalog import runes_by_id

    return (runes_by_id().get(str(rule)) or {}).get("roadForm")
