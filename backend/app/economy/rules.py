"""Pure Active Coin arithmetic, tuned by config/ac_rules.json. No I/O, no session."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Any

TRANSACTION_KINDS = (
    "RIDE_DISTANCE",
    "NEW_CELLS",
    "QUEST_COMPLETED",
    "CHEST_OPENED",
    "COLLECTABLE",
    "MONSTER_SLAIN",
    "BOUNTY",
    "SET_COMPLETED",
    "STORY_ARC",
    "STREAK",
    "CLASS_CHANGE",
    "LURE",
    "WEEK_NOTICE",
    "RUNE_RANK",
    # 0.7.2: a stall purchase, an item sold (by hand, or on the spot into a full
    # bag), and a level's coins (unused: levels pay in consumables).
    "STALL",
    "ITEM_SOLD",
    "LEVEL_REWARD",
    "ADJUSTMENT",
    # 0.8.0: a legend's phase broken, a lair's great chest, buried treasure found;
    # each paid outside the per-journey cap.
    "LEGEND",
    "LAIR",
    "TREASURE",
)


@dataclass
class ACLine:
    kind: str
    ac: int
    detail: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {"kind": self.kind, "ac": self.ac, **({"detail": self.detail} if self.detail else {})}


@lru_cache(maxsize=1)
def load_ac_rules() -> dict[str, Any]:
    return json.loads((Path(__file__).parent / "config" / "ac_rules.json").read_text())


def quest_ac(difficulty: str | None) -> int:
    table = load_ac_rules()["questCompleted"]
    return int(table.get(difficulty or "EASY", table["EASY"]))


def class_change_terms() -> dict[str, Any]:
    return load_ac_rules()["classChange"]


def compute_ride_ac(
    *,
    activity: str = "RIDE",
    distance_meters: float,
    new_cells: int,
    quest_completed: bool = False,
    quest_difficulty: str | None = None,
    claims: list[dict[str, Any]] | None = None,
    extra_lines: list[ACLine] | None = None,
    coin_pct: dict[str, float] | None = None,
) -> list[ACLine]:
    """What a ride earns: coins per kilometre by activity, one per new cell, the quest's
    purse, and whatever was opened, gathered or beaten on the way."""
    rules = load_ac_rules()
    lines: list[ACLine] = []
    km = max(0.0, distance_meters) / 1000
    per_km = rules["perKm"].get(activity, rules["perKm"]["RIDE"])
    # The Saddle Roll pays more for distance (COIN_PCT.RIDE_DISTANCE).
    distance_ac = int(km * per_km * (1 + float((coin_pct or {}).get("RIDE_DISTANCE", 0.0))))
    if distance_ac > 0:
        lines.append(ACLine("RIDE_DISTANCE", distance_ac, {"km": round(km, 1), "perKm": per_km}))
    if new_cells > 0 and rules["newCell"] > 0:
        lines.append(ACLine("NEW_CELLS", new_cells * int(rules["newCell"]), {"cells": new_cells}))
    if quest_completed:
        lines.append(ACLine("QUEST_COMPLETED", quest_ac(quest_difficulty), {"difficulty": quest_difficulty or "EASY"}))
    kinds = {"CHEST": "CHEST_OPENED", "COLLECTABLE": "COLLECTABLE", "MONSTER": "MONSTER_SLAIN"}
    for claim in claims or []:
        reward = int(claim.get("rewardAC", 0))
        # A knack that makes boxes pay more (characters/sheet.py `coin_pct`).
        reward = int(round(reward * (1 + float((coin_pct or {}).get(str(claim.get("kind")), 0.0)))))
        if reward <= 0:
            continue
        kind = "BOUNTY" if claim.get("bounty") else kinds.get(str(claim.get("kind")), "ADJUSTMENT")
        lines.append(ACLine(kind, reward, {"objectId": str(claim.get("id")), "name": claim.get("name")}))
    # Sets, streaks and arcs pay their purse whole: the cap is for what an outing
    # earns by the kilometre and the thing, not for an ending.
    return apply_cap(lines, int(rules["caps"]["perRideTotal"])) + list(extra_lines or [])


def apply_cap(lines: list[ACLine], cap: int) -> list[ACLine]:
    """Scales every line down proportionally so the breakdown still sums to the total."""
    total = sum(line.ac for line in lines)
    if total <= cap or total == 0:
        return lines
    scale = cap / total
    capped = [ACLine(line.kind, int(line.ac * scale), {**line.detail, "capped": True}) for line in lines]
    # Rounding down leaves a remainder; give it to the biggest line so the sum is exactly the cap.
    remainder = cap - sum(line.ac for line in capped)
    if remainder and capped:
        biggest = max(capped, key=lambda line: line.ac)
        biggest.ac += remainder
    return capped
