"""Pure progression maths: XP → level, event → XP. No I/O.

Everything tunable comes from `config/levels.json` and `config/xp_rules.json`.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Any

CONFIG_DIR = Path(__file__).parent / "config"

XP_EVENT_TYPES = (
    "QUEST_COMPLETED",
    "QUEST_OBJECTIVE_COMPLETED",
    "NEW_AREA_EXPLORED",
    "NEW_ROAD_EXPLORED",
    "DISCOVERY_FOUND",
    "LONG_DISTANCE_ADVENTURE",
    "CLIMB_COMPLETED",
    "SOCIAL_QUEST_COMPLETED",
    "STORY_QUEST_COMPLETED",
    "CLASS_BONUS",
    "REGION_COMPLETED",
)


@lru_cache
def load_levels() -> dict[str, Any]:
    return json.loads((CONFIG_DIR / "levels.json").read_text())


@lru_cache
def load_xp_rules() -> dict[str, Any]:
    return json.loads((CONFIG_DIR / "xp_rules.json").read_text())


def max_level(track: str = "overall") -> int:
    return len(load_levels()[track])


def level_for_xp(xp: int, track: str = "overall") -> int:
    thresholds = load_levels()[track]
    level = 1
    for index, needed in enumerate(thresholds):
        if xp >= needed:
            level = index + 1
        else:
            break
    return level


def level_bounds(level: int, track: str = "overall") -> tuple[int, int | None]:
    """(xp at which this level starts, xp needed for next level or None at cap)."""
    thresholds = load_levels()[track]
    level = max(1, min(level, len(thresholds)))
    floor = thresholds[level - 1]
    nxt = thresholds[level] if level < len(thresholds) else None
    return floor, nxt


def title_for_level(level: int) -> str | None:
    titles = load_levels().get("titles", {}).get("overall", {})
    best: str | None = None
    for key in sorted((int(k) for k in titles), reverse=False):
        if level >= key:
            best = titles[str(key)]
    return best


def ability_points_between(old_level: int, new_level: int) -> int:
    levels = load_levels().get("abilityPointLevels", [])
    return sum(1 for lvl in levels if old_level < lvl <= new_level)


@dataclass
class XPLine:
    source: str
    xp: int
    detail: dict[str, Any] = field(default_factory=dict)


@dataclass
class RideRewardInput:
    character_class: str
    quest_completed: bool = False
    quest_difficulty: str | None = None
    quest_base_xp: int = 0
    is_story_quest: bool = False
    objectives_completed_required: int = 0
    objectives_completed_optional: int = 0
    new_cells: int = 0
    new_cells_explored: int = 0
    new_roads_meters: float = 0.0
    discovery_categories: list[str] = field(default_factory=list)
    distance_meters: float = 0.0
    elevation_gain_meters: float = 0.0
    friends_completed_with: int = 0
    regions_completed: int = 0


def compute_ride_xp(inp: RideRewardInput) -> list[XPLine]:
    """Turn what happened on a ride into XP lines (spec §12)."""
    rules = load_xp_rules()
    lines: list[XPLine] = []

    if inp.quest_completed:
        base = inp.quest_base_xp or rules["questBase"].get(inp.quest_difficulty or "MODERATE", 300)
        modifier = rules["difficultyModifier"].get(inp.quest_difficulty or "MODERATE", 0.0)
        lines.append(
            XPLine(
                "QUEST_COMPLETED",
                int(round(base * (1 + modifier))),
                {"base": base, "modifier": modifier},
            )
        )
        if inp.is_story_quest:
            lines.append(XPLine("STORY_QUEST_COMPLETED", rules["storyQuestBonus"]))

    objective_xp = (
        inp.objectives_completed_required * rules["objectiveCompleted"]
        + inp.objectives_completed_optional * rules["objectiveCompletedOptional"]
    )
    if objective_xp:
        lines.append(
            XPLine(
                "QUEST_OBJECTIVE_COMPLETED",
                objective_xp,
                {
                    "required": inp.objectives_completed_required,
                    "optional": inp.objectives_completed_optional,
                },
            )
        )

    capped_cells = min(inp.new_cells, rules["caps"]["perRideNewCells"])
    if capped_cells:
        xp = capped_cells * rules["newCell"] + min(inp.new_cells_explored, capped_cells) * rules["newCellExploredBonus"]
        lines.append(XPLine("NEW_AREA_EXPLORED", xp, {"cells": capped_cells, "explored": inp.new_cells_explored}))

    if inp.new_roads_meters > 0:
        km = inp.new_roads_meters / 1000.0
        lines.append(XPLine("NEW_ROAD_EXPLORED", int(round(km * rules["newRoadsPerKm"])), {"km": round(km, 2)}))

    discoveries = inp.discovery_categories[: rules["caps"]["perRideDiscoveries"]]
    if discoveries:
        xp = sum(rules["discoveryByCategory"].get(c, rules["discoveryByCategory"]["CUSTOM"]) for c in discoveries)
        lines.append(XPLine("DISCOVERY_FOUND", xp, {"count": len(discoveries)}))

    ld = rules["longDistance"]
    if inp.distance_meters >= ld["thresholdMeters"]:
        extra_km = (inp.distance_meters - ld["thresholdMeters"]) / 1000.0
        xp = min(ld["xp"] + int(extra_km * ld["perExtraKm"]), ld["maxXp"])
        lines.append(XPLine("LONG_DISTANCE_ADVENTURE", xp, {"distanceMeters": inp.distance_meters}))

    cl = rules["climb"]
    if inp.elevation_gain_meters >= cl["thresholdGainMeters"]:
        extra = (inp.elevation_gain_meters - cl["thresholdGainMeters"]) / 100.0
        xp = min(cl["xp"] + int(extra * cl["perExtraHundredMeters"]), cl["maxXp"])
        lines.append(XPLine("CLIMB_COMPLETED", xp, {"gainMeters": inp.elevation_gain_meters}))

    if inp.friends_completed_with and inp.quest_completed:
        lines.append(XPLine("SOCIAL_QUEST_COMPLETED", inp.friends_completed_with * rules["socialBonusPerFriend"]))

    if inp.regions_completed:
        lines.append(XPLine("REGION_COMPLETED", inp.regions_completed * rules["regionCompletedXp"]))

    # Class bonus: a percentage of the matching lines.
    bonus_rules = rules["classBonus"].get(inp.character_class.upper(), {})
    bonus = 0
    for line in lines:
        pct = bonus_rules.get(line.source, 0.0)
        bonus += int(round(line.xp * pct))
    if bonus:
        lines.append(XPLine("CLASS_BONUS", bonus, {"class": inp.character_class}))

    # Per-ride cap, applied proportionally so the breakdown still adds up.
    cap = rules["caps"]["perRideTotal"]
    total = sum(line.xp for line in lines)
    if total > cap:
        scale = cap / total
        for line in lines:
            line.xp = int(line.xp * scale)
    return lines


@dataclass
class LevelChange:
    kind: str  # OVERALL / CLASS
    from_level: int
    to_level: int


@dataclass
class ProgressionResult:
    overall_xp: int
    class_xp: int
    overall_level: int
    class_level: int
    level_ups: list[LevelChange]
    ability_points_gained: int
    title: str | None


def apply_xp(overall_xp: int, class_xp: int, overall_level: int, class_level: int, gained_xp: int) -> ProgressionResult:
    """Apply XP to both tracks. Class track receives `classXpShare` of the gain."""
    rules = load_xp_rules()
    class_gain = int(round(gained_xp * rules["classXpShare"]))
    new_overall_xp = overall_xp + gained_xp
    new_class_xp = class_xp + class_gain
    new_overall_level = max(overall_level, level_for_xp(new_overall_xp, "overall"))
    new_class_level = max(class_level, level_for_xp(new_class_xp, "class"))
    level_ups: list[LevelChange] = []
    if new_overall_level > overall_level:
        level_ups.append(LevelChange("OVERALL", overall_level, new_overall_level))
    if new_class_level > class_level:
        level_ups.append(LevelChange("CLASS", class_level, new_class_level))
    points = ability_points_between(class_level, new_class_level)
    return ProgressionResult(
        overall_xp=new_overall_xp,
        class_xp=new_class_xp,
        overall_level=new_overall_level,
        class_level=new_class_level,
        level_ups=level_ups,
        ability_points_gained=points,
        title=title_for_level(new_overall_level),
    )
