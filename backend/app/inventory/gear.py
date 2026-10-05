"""Gear (config/gear.json): five slots, fifteen items, the consumables, and the one
function that merges what runes and gear do into the sheet's rules. Pure.

An item is a rule, never a damage percentage. The same rule from a rune and an
item merge by kind: a reach, a sight, a threshold, a finish or a chest's reach
takes the largest; rings and extras add; scales multiply. `COIN_PCT.<kind>` is
a yield, kept apart and added into the sheet's coin percentages.
"""

from __future__ import annotations

import json
from collections.abc import Iterable
from functools import lru_cache
from pathlib import Path
from typing import Any

CONFIG = Path(__file__).parent / "config" / "gear.json"

RARITIES = ("COMMON", "RARE", "LEGENDARY")
SLOTS = ("BELL", "LANTERN", "BAG", "MAP_CASE", "KEEPSAKE")
CONSUMABLES = ("LAMP", "MAP_FRAGMENT", "REST_TOKEN", "SEALED_CHEST_COMMON", "SEALED_CHEST_RARE")
SEALED = {"SEALED_CHEST_COMMON": "COMMON", "SEALED_CHEST_RARE": "RARE"}

# How two values of the same rule combine (docs/ROADMAP.md 0.7.2, §1).
LARGEST = {"SIGHT_M", "RUNE_REACH_M", "RUNE_THRESHOLD", "FINISH_UNDER", "CHEST_REACH_M"}
ADDED = {"NEW_TILE_RINGS", "WOKEN_EXTRA", "BOARD_EXTRA", "LOOT_FIND"}
SCALES = {"CARRIED_SCALE", "FRAGMENT_SCALE", "SELL_SCALE", "OPTIONAL_XP_SCALE", "GROUND_CELL_SCALE"}
COIN_PCT = "COIN_PCT."
# Every rule an item may make; anything else in gear.json is a typo.
GEAR_RULES = LARGEST | ADDED | SCALES


@lru_cache
def book() -> dict[str, Any]:
    data = json.loads(CONFIG.read_text())
    assert [s["id"] for s in data["slots"]] == list(SLOTS), "the five slots, in order"
    assert [c["id"] for c in data["consumables"]] == list(CONSUMABLES), "the five consumables, in order"
    ids = [i["id"] for i in data["items"]]
    assert len(ids) == len(set(ids)), "item ids must be unique"
    pairs = {(i["slot"], i["rarity"]) for i in data["items"]}
    assert pairs == {(s, r) for s in SLOTS for r in RARITIES}, "one item per slot and rarity"
    for item in data["items"]:
        assert len(item["id"]) <= 40, f"{item['id']}: an item id fits inventory_items.item_id"
        assert item["text"].strip() and item["icon"] and item["name"], item["id"]
        for rule in item["rules"]:
            assert rule in GEAR_RULES or rule.startswith(COIN_PCT), f"{item['id']}: unknown rule {rule}"
    assert set(data["sellPrice"]) == set(RARITIES)
    return data


@lru_cache
def by_id() -> dict[str, dict[str, Any]]:
    return {i["id"]: i for i in book()["items"]}


@lru_cache
def slots_by_id() -> dict[str, dict[str, Any]]:
    return {s["id"]: s for s in book()["slots"]}


@lru_cache
def consumables_by_id() -> dict[str, dict[str, Any]]:
    return {c["id"]: c for c in book()["consumables"]}


def item(item_id: str) -> dict[str, Any] | None:
    return by_id().get(item_id)


def item_for(slot: str, rarity: str) -> str:
    """The one item of this slot and rarity."""
    return next(i["id"] for i in book()["items"] if i["slot"] == slot and i["rarity"] == rarity)


def items_of(rarity: str) -> list[str]:
    return [i["id"] for i in book()["items"] if i["rarity"] == rarity]


def legendaries() -> set[str]:
    return set(items_of("LEGENDARY"))


def slot_opens_at(slot: str) -> int:
    return int(slots_by_id()[slot]["opensAtLevel"])


def slot_open(slot: str, level: int) -> bool:
    return slot in slots_by_id() and level >= slot_opens_at(slot)


def bag_size() -> int:
    return int(book()["bagSize"])


def rarity_name(rarity: str) -> str:
    return str(book()["rarityNames"].get(rarity, rarity.title()))


def sell_price(rarity: str, scale: float = 1.0) -> int:
    return int(round(int(book()["sellPrice"][rarity]) * max(scale, 0.0)))


def worn(gear: dict[str, str] | None, level: int) -> dict[str, str]:
    """What counts of what is worn: known items, in their own slot, in a slot the
    level has opened."""
    out = {}
    for slot, item_id in (gear or {}).items():
        entry = by_id().get(str(item_id))
        if entry is not None and entry["slot"] == slot and slot_open(slot, level):
            out[slot] = str(item_id)
    return out


def merge_rules(*sources: dict[str, float]) -> dict[str, float]:
    """One rules dict from several (the inscribed runes, the gear worn)."""
    out: dict[str, float] = {}
    for rules in sources:
        for rule, value in (rules or {}).items():
            value = float(value)
            if rule not in out:
                out[rule] = value
            elif rule in ADDED or rule.startswith(COIN_PCT):
                out[rule] = out[rule] + value
            elif rule in SCALES:
                out[rule] = out[rule] * value
            else:
                out[rule] = max(out[rule], value)
    return {k: round(v, 6) for k, v in out.items()}


def rules_for(item_ids: Iterable[str]) -> dict[str, float]:
    """The rules a set of worn items make, merged."""
    return merge_rules(*((by_id()[i]["rules"] if i in by_id() else {}) for i in item_ids))


def split_coins(rules: dict[str, float]) -> tuple[dict[str, float], dict[str, float]]:
    """(the rules, the coin percentages by kind): COIN_PCT.CHEST is coin_pct["CHEST"]."""
    plain = {k: v for k, v in rules.items() if not k.startswith(COIN_PCT)}
    coins = {k[len(COIN_PCT) :]: v for k, v in rules.items() if k.startswith(COIN_PCT)}
    return plain, coins
