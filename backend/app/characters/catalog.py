"""Static class and ability catalog loaded from JSON config."""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Any

CONFIG_DIR = Path(__file__).parent / "config"
CLASS_IDS = ("EXPLORER", "WIZARD", "WARRIOR", "SCRIBE")


@lru_cache
def classes() -> dict[str, dict[str, Any]]:
    return json.loads((CONFIG_DIR / "classes.json").read_text())


@lru_cache
def abilities() -> list[dict[str, Any]]:
    return json.loads((CONFIG_DIR / "abilities.json").read_text())


@lru_cache
def abilities_by_id() -> dict[str, dict[str, Any]]:
    return {a["id"]: a for a in abilities()}


# The effects something on the server actually reads. An ability with none of
# these is shown as "not yet" rather than as if it did something.
READ_EFFECTS = frozenset(
    {
        "QUEST_POI_VISIBILITY",
        "UNLOCK_TEMPLATE",
        # Into the sheet (characters/sheet.py), so the fight on both sides reads them.
        "DAMAGE_PCT",
        "RUNE_REACH_M",
        "LATE_ROAD_PCT",
        "VS_ELDERS_PCT",
        "WORD_OLD_PLACES_PCT",
        # Into the ride's XP and coins (progression/engine.py, economy/rules.py).
        "XP_DOUBLE_FIRST_CELLS",
        "XP_BONUS_FAR_CELLS",
        "XP_BONUS_LONG_DISTANCE",
        "XP_BONUS_DISCOVERY_WITH_NOTE",
        "COIN_PCT",
    }
)


def is_working(ability: dict[str, Any]) -> bool:
    return any(e.get("type") in READ_EFFECTS for e in ability.get("effects", []))


def abilities_for_class(character_class: str) -> list[dict[str, Any]]:
    return [a for a in abilities() if a["characterClass"] == character_class.upper()]


def effect_total(character_abilities: dict[str, int], effect_type: str, kind: str | None = None) -> float:
    """Sum of `perRank * rank` for every owned ability with the given effect (and,
    for an effect on one kind of effort or coin, that kind)."""
    total = 0.0
    for ability_id, rank in character_abilities.items():
        ability = abilities_by_id().get(ability_id)
        if not ability:
            continue
        for effect in ability.get("effects", []):
            if effect.get("type") == effect_type and (kind is None or effect.get("kind") == kind):
                total += float(effect.get("perRank", 0)) * rank
    return total


def effects_by_kind(character_abilities: dict[str, int], effect_type: str) -> dict[str, float]:
    """`effect_total` for every kind an effect names: {"GROUND": 0.1, "WORD": 0.08}."""
    kinds = {
        e["kind"] for a in abilities() for e in a.get("effects", []) if e.get("type") == effect_type and e.get("kind")
    }
    out = {k: effect_total(character_abilities, effect_type, k) for k in sorted(kinds)}
    return {k: v for k, v in out.items() if v}


def unlocked_templates(character_abilities: dict[str, int]) -> set[str]:
    out: set[str] = set()
    for ability_id in character_abilities:
        ability = abilities_by_id().get(ability_id)
        if not ability:
            continue
        for effect in ability.get("effects", []):
            if effect.get("type") == "UNLOCK_TEMPLATE" and effect.get("template"):
                out.add(effect["template"])
    return out
