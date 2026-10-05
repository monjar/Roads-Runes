"""Every level pays (docs/ROADMAP.md 0.7.2; config/level_rewards.json). Pure.

A level that opens a rune slot (inventory/config/runes.json), a gear slot
(inventory/config/gear.json) or the stall, or brings a level title
(config/titles.json), pays that. Every other level from 2 to 50 pays one
consumable, in turn. Every tenth level adds a Rare sealed chest. The slots, the
stall and the titles come with the level itself; only the consumables are given
(inventory.service.pay_level, once per level).
"""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Any

from app.inventory import catalog as runes
from app.inventory import gear
from app.progression import titles

CONFIG = Path(__file__).parent / "config" / "level_rewards.json"


@lru_cache
def book() -> dict[str, Any]:
    data = json.loads(CONFIG.read_text())
    assert all(r["consumable"] in gear.CONSUMABLES for r in data["rotation"]), "rotation names a consumable"
    assert len(data["runeSlotTexts"]) >= len(runes.book()["slotsAtLevel"]), "a text per rune slot"
    return data


def max_level() -> int:
    return int(book()["maxLevel"])


def _stall_level() -> int:
    from app.inventory import loot

    return int(loot.book()["stall"]["opensAtLevel"])


def consumable_text(consumable: str, count: int = 1) -> str:
    """ "A lamp", "2 lamps", "A sealed chest (Rare)"."""
    names = {
        "LAMP": ("A lamp", "lamps"),
        "MAP_FRAGMENT": ("A map piece", "map pieces"),
        "REST_TOKEN": ("A rest token", "rest tokens"),
        "SEALED_CHEST_COMMON": ("A sealed chest (Common)", "sealed chests (Common)"),
        "SEALED_CHEST_RARE": ("A sealed chest (Rare)", "sealed chests (Rare)"),
    }
    one, many = names[consumable]
    return one if count == 1 else f"{count} {many}"


def _consumable(consumable: str, count: int) -> dict[str, Any]:
    return {
        "kind": "CONSUMABLE",
        "text": consumable_text(consumable, count),
        "icon": gear.consumables_by_id()[consumable]["icon"],
        "consumable": consumable,
        "count": count,
    }


def _fixed(n: int) -> list[dict[str, Any]]:
    """What a level opens or brings, before any consumable."""
    icons = book()["icons"]
    out: list[dict[str, Any]] = []
    rune_levels = list(runes.book()["slotsAtLevel"])
    if n in rune_levels:
        out.append(
            {"kind": "RUNE_SLOT", "text": book()["runeSlotTexts"][rune_levels.index(n)], "icon": icons["RUNE_SLOT"]}
        )
    for slot in gear.book()["slots"]:
        if int(slot["opensAtLevel"]) == n:
            out.append({"kind": "SLOT", "text": f"{slot['name']} slot opens", "icon": slot["icon"], "slot": slot["id"]})
    if n == _stall_level():
        out.append({"kind": "STALL", "text": book()["stallText"], "icon": icons["STALL"]})
    for title in titles.level_titles():
        if int(title["level"]) == n:
            out.append({"kind": "TITLE", "text": f"Title: {title['name']}", "icon": icons["TITLE"]})
    return out


@lru_cache
def _rotation_slots() -> dict[int, int]:
    """Which turn of the rotation each consumable-only level takes."""
    turns: dict[int, int] = {}
    for n in range(2, max_level() + 1):
        if not _fixed(n):
            turns[n] = len(turns)
    return turns


def rewards_for_level(n: int) -> list[dict[str, Any]]:
    """What reaching level n pays, as LevelRewardOut dicts."""
    if n < 1 or n > max_level():
        return []
    out = _fixed(n)
    turn = _rotation_slots().get(n)
    if turn is not None:
        rotation = book()["rotation"]
        pick = rotation[turn % len(rotation)]
        out.append(_consumable(pick["consumable"], int(pick["count"])))
    if n % int(book()["rareChestEvery"]) == 0:
        out.append(_consumable("SEALED_CHEST_RARE", 1))
    return out


def consumables_for_level(n: int) -> dict[str, int]:
    """Only what is given: consumable id to count."""
    out: dict[str, int] = {}
    for reward in rewards_for_level(n):
        if reward["kind"] == "CONSUMABLE":
            out[reward["consumable"]] = out.get(reward["consumable"], 0) + int(reward["count"])
    return out


def table() -> list[dict[str, Any]]:
    """Every level and what it pays."""
    return [{"level": n, "rewards": rewards_for_level(n)} for n in range(1, max_level() + 1)]
