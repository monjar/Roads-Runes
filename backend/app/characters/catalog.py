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


def abilities_for_class(character_class: str) -> list[dict[str, Any]]:
    return [a for a in abilities() if a["characterClass"] == character_class.upper()]


def effect_total(character_abilities: dict[str, int], effect_type: str) -> float:
    """Sum of `perRank * rank` for every owned ability with the given effect."""
    total = 0.0
    for ability_id, rank in character_abilities.items():
        ability = abilities_by_id().get(ability_id)
        if not ability:
            continue
        for effect in ability.get("effects", []):
            if effect.get("type") == effect_type:
                total += float(effect.get("perRank", 0)) * rank
    return total


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
