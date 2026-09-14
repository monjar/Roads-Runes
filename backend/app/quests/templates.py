"""Quest template catalog."""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Any

CONFIG_DIR = Path(__file__).parent / "config"

OBJECTIVE_TYPES = (
    "VISIT_LOCATION",
    "VISIT_REGION",
    "EXPLORE_DISTANCE",
    "EXPLORE_NEW_ROADS",
    "REACH_ELEVATION",
    "COMPLETE_DISTANCE",
    "COMPLETE_CLIMB",
    "VISIT_POI",
    "PHOTO_LOCATION",
    "WRITE_NOTE",
    "VISIT_MULTIPLE_LOCATIONS",
    "RETURN_TO_START",
    "COMPLETE_WITH_FRIEND",
    "COMPLETE_ROUTE",
    "RIDE_DURATION",
    "SUSTAIN_SPEED",
    # The world: something placed for this player to beat, open or gather (world_objects).
    "SLAY_MONSTER",
    "OPEN_CHEST",
    "COLLECT",
)

DIFFICULTIES = ("EASY", "MODERATE", "HARD", "EPIC")
# Templates any class can take; every list of quests on offer keeps one of them.
ANY_CLASS = "ANY"


@lru_cache
def all_templates() -> list[dict[str, Any]]:
    data = json.loads((CONFIG_DIR / "templates.json").read_text())
    templates = data["templates"]
    for t in templates:
        for o in t["objectives"]:
            assert o["type"] in OBJECTIVE_TYPES, f"unknown objective type in {t['id']}"
    return templates


@lru_cache
def template_by_id() -> dict[str, dict[str, Any]]:
    return {t["id"]: t for t in all_templates()}


def templates_for(
    character_class: str, class_level: int, unlocked: set[str] | None = None, activity: str = "RIDE"
) -> list[dict[str, Any]]:
    unlocked = unlocked or set()
    out = []
    for t in all_templates():
        # A quest for anyone is a quest for this class too.
        if t["characterClass"] not in (character_class.upper(), ANY_CLASS):
            continue
        # A template written for bikes stays a bike quest unless it says otherwise.
        if activity.upper() not in t.get("activities", ["RIDE"]):
            continue
        if t["minLevel"] > class_level and t["id"] not in unlocked:
            continue
        out.append(t)
    return out
