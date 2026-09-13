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
    "STREAK",
    "CLASS_CHANGE",
    "LURE",
    "ADJUSTMENT",
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
) -> list[ACLine]:
    """What a ride earns: coins per kilometre by activity, one per new cell, and the quest's purse."""
    rules = load_ac_rules()
    lines: list[ACLine] = []
    km = max(0.0, distance_meters) / 1000
    per_km = rules["perKm"].get(activity, rules["perKm"]["RIDE"])
    if int(km * per_km) > 0:
        lines.append(ACLine("RIDE_DISTANCE", int(km * per_km), {"km": round(km, 1), "perKm": per_km}))
    if new_cells > 0 and rules["newCell"] > 0:
        lines.append(ACLine("NEW_CELLS", new_cells * int(rules["newCell"]), {"cells": new_cells}))
    if quest_completed:
        lines.append(ACLine("QUEST_COMPLETED", quest_ac(quest_difficulty), {"difficulty": quest_difficulty or "EASY"}))
    return apply_cap(lines, int(rules["caps"]["perRideTotal"]))


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
