"""Pure progression maths: XP → level, event → XP. No I/O.

Everything tunable comes from `config/levels.json` and `config/xp_rules.json`.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Any

from app.core.activity import DISTANCE_SCALE, normalise

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
    "WEEK_NOTICE",
    "WELCOME_BACK",
    "PATHFINDER",
    "FAR_WANDERER",
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
    from app.progression.titles import level_title

    reached = level_title(level)
    return reached["name"] if reached else None


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
    # How the outing was done: a kilometre on foot is more of an outing than one on a bike.
    activity: str = "RIDE"
    # What was beaten, opened or found on the way: (kind, tier, bounty).
    claims: list[tuple[str, int, bool]] = field(default_factory=list)
    # Effort is damage (world_objects/fight.py): half a monster's XP is paid by the
    # share of its hold taken, on any outing that takes some, and half on the finish.
    effort: bool = False
    blows: list[tuple[int, bool, float]] = field(default_factory=list)
    sets_completed: int = 0
    # Knacks from the ride's frozen sheet (characters/sheet.py `xp_pct`):
    # FIRST_CELLS (a count), FAR_CELLS, LONG_DISTANCE, DISCOVERY_WITH_NOTE (shares).
    xp_mods: dict[str, float] = field(default_factory=dict)
    # New cells more than 5 km from where the outing began (Far Wanderer).
    far_new_cells: int = 0
    # A note was written on the outing (Footnote).
    wrote_note: bool = False
    # Days since the outing before this one; None for a first outing.
    days_away: int | None = None
    # Optional objectives' XP × this (the Pedlar's Road-book, OPTIONAL_XP_SCALE), 0.7.2.
    optional_xp_scale: float = 1.0
    # XP for distance × this on a run or a walk (Mannaz, FOOT_XP_SCALE), 0.9.0.
    foot_xp_scale: float = 1.0


CLAIM_SOURCES = {"CHEST": "CHEST_OPENED", "COLLECTABLE": "COLLECTABLE_FOUND", "MONSTER": "MONSTER_BEATEN"}
# The lines that pay for distance: new roads, the long way, and ground already ridden.
DISTANCE_SOURCES = ("NEW_ROAD_EXPLORED", "LONG_DISTANCE_ADVENTURE", "KNOWN_GROUND")


def claim_xp(kind: str, tier: int, bounty: bool = False) -> int:
    """What one chest, piece or monster is worth in XP."""
    rules = load_xp_rules()["worldObject"]
    by_tier = rules.get(kind, {})
    xp = int(by_tier.get(str(tier), by_tier.get("1", 0)))
    return int(round(xp * rules["bountyMultiplier"])) if bounty else xp


def claim_lines(claims: list[tuple[str, int, bool]], effort: bool = False) -> list[XPLine]:
    """One line per kind of thing, so the breakdown reads "two chests", not a list."""
    lines: list[XPLine] = []
    for kind, source in CLAIM_SOURCES.items():
        mine = [c for c in claims if c[0] == kind]
        xp = sum(claim_xp(*c) for c in mine)
        if effort and kind == "MONSTER":
            # The other half was paid blow by blow (BLOWS_LANDED).
            xp = int(round(xp / 2))
        if xp:
            lines.append(XPLine(source, xp, {"count": len(mine)}))
    return lines


def blow_lines(blows: list[tuple[int, bool, float]]) -> list[XPLine]:
    """Half of each monster's XP, by the share of its hold this outing took."""
    xp = int(round(sum(claim_xp("MONSTER", tier, bounty) / 2 * share for tier, bounty, share in blows)))
    return [XPLine("BLOWS_LANDED", xp, {"count": len(blows)})] if xp else []


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

    objective_xp = int(
        round(
            inp.objectives_completed_required * rules["objectiveCompleted"]
            + inp.objectives_completed_optional * rules["objectiveCompletedOptional"] * inp.optional_xp_scale
        )
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
        # Pathfinder: the first new cells of an outing pay twice.
        first = min(capped_cells, int(inp.xp_mods.get("FIRST_CELLS", 0)))
        if first:
            lines.append(XPLine("PATHFINDER", first * rules["newCell"], {"cells": first}))
        # Far Wanderer: new cells a long way from the start pay more.
        far = min(capped_cells, inp.far_new_cells)
        if far and inp.xp_mods.get("FAR_CELLS"):
            xp = int(round(far * rules["newCell"] * inp.xp_mods["FAR_CELLS"]))
            if xp:
                lines.append(XPLine("FAR_WANDERER", xp, {"cells": far}))

    if inp.new_roads_meters > 0:
        km = inp.new_roads_meters / 1000.0
        lines.append(XPLine("NEW_ROAD_EXPLORED", int(round(km * rules["newRoadsPerKm"])), {"km": round(km, 2)}))

    discoveries = inp.discovery_categories[: rules["caps"]["perRideDiscoveries"]]
    if discoveries:
        xp = sum(rules["discoveryByCategory"].get(c, rules["discoveryByCategory"]["CUSTOM"]) for c in discoveries)
        # Footnote: places found on an outing with a note pay more.
        if inp.wrote_note and inp.xp_mods.get("DISCOVERY_WITH_NOTE"):
            xp = int(round(xp * (1 + inp.xp_mods["DISCOVERY_WITH_NOTE"])))
        lines.append(XPLine("DISCOVERY_FOUND", xp, {"count": len(discoveries)}))

    ld = rules["longDistance"]
    if inp.distance_meters >= ld["thresholdMeters"]:
        extra_km = (inp.distance_meters - ld["thresholdMeters"]) / 1000.0
        xp = min(ld["xp"] + int(extra_km * ld["perExtraKm"]), ld["maxXp"])
        # Endurance: the long way pays more.
        xp = int(round(xp * (1 + inp.xp_mods.get("LONG_DISTANCE", 0.0))))
        lines.append(XPLine("LONG_DISTANCE_ADVENTURE", xp, {"distanceMeters": inp.distance_meters}))

    cl = rules["climb"]
    if inp.elevation_gain_meters >= cl["thresholdGainMeters"]:
        extra = (inp.elevation_gain_meters - cl["thresholdGainMeters"]) / 100.0
        xp = min(cl["xp"] + int(extra * cl["perExtraHundredMeters"]), cl["maxXp"])
        lines.append(XPLine("CLIMB_COMPLETED", xp, {"gainMeters": inp.elevation_gain_meters}))

    lines.extend(claim_lines(inp.claims, inp.effort))
    if inp.effort:
        lines.extend(blow_lines(inp.blows))

    if inp.sets_completed:
        lines.append(XPLine("SET_COMPLETED", inp.sets_completed * rules["setCompleted"], {"sets": inp.sets_completed}))

    # Ground already ridden: not much, and never nothing.
    kg = rules["knownGround"]
    known_km = max(0.0, inp.distance_meters - inp.new_roads_meters) / 1000.0
    if known_km >= kg["minKm"]:
        scaled_km = known_km / DISTANCE_SCALE.get(normalise(inp.activity), 1.0)
        xp = min(int(kg["maxXp"]), int(round(scaled_km * kg["perKm"])))
        if xp:
            lines.append(XPLine("KNOWN_GROUND", xp, {"km": round(known_km, 1)}))

    # Mannaz (0.9.0): runs and walks give more XP for distance.
    if inp.foot_xp_scale != 1.0 and normalise(inp.activity) in ("RUN", "WALK"):
        for line in lines:
            if line.source in DISTANCE_SOURCES:
                line.xp = int(round(line.xp * inp.foot_xp_scale))
                line.detail = {**line.detail, "footScale": inp.foot_xp_scale}

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

    # Welcome back: the first outing after a fortnight away pays its first
    # kilometre twice, as a share of what the whole outing paid.
    wb = rules.get("welcomeBack", {})
    if inp.days_away is not None and inp.days_away >= int(wb.get("afterDays", 14)) and inp.distance_meters > 0:
        share = min(1.0, float(wb.get("firstMeters", 1000)) / inp.distance_meters)
        xp = int(round(sum(line.xp for line in lines) * share))
        if xp:
            lines.append(XPLine("WELCOME_BACK", xp, {"daysAway": inp.days_away}))

    # Per-ride cap, applied proportionally so the breakdown still adds up.
    cap = rules["caps"]["perRideTotal"]
    total = sum(line.xp for line in lines)
    if total > cap:
        scale = cap / total
        for line in lines:
            line.xp = int(line.xp * scale)
    return lines


def cap_to_day(lines: list[XPLine], earned_today: int) -> list[XPLine]:
    """What is left of the day's XP (`caps.perDayTotal`), shared out over the lines
    so the breakdown still adds up. Applied to what is taken by hand."""
    left = max(0, int(load_xp_rules()["caps"]["perDayTotal"]) - earned_today)
    total = sum(line.xp for line in lines)
    if total <= left:
        return lines
    scale = left / total if total else 0
    return [XPLine(line.source, int(line.xp * scale), {**line.detail, "capped": True}) for line in lines]


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
