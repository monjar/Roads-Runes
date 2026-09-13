"""How the player moves: on a bike, on foot fast, on foot slow.

Everything that used to assume a bicycle — speed plausibility, routing costing,
distances a quest asks for, the workout Strava is told about — reads from here.
The code keeps its cycling names (`Ride`, `/rides`); only the numbers change.
"""

from __future__ import annotations

from typing import Any, Literal

Activity = Literal["RIDE", "RUN", "WALK"]
ACTIVITIES: tuple[str, ...] = ("RIDE", "RUN", "WALK")
DEFAULT_ACTIVITY = "RIDE"

# Faster than this, sustained, is a vehicle (or a broken GPS), not the activity claimed.
SPEED_CAP_MPS: dict[str, float] = {"RIDE": 25.0, "RUN": 8.0, "WALK": 4.0}
# What a quest's distance range (written for bikes) becomes on foot.
DISTANCE_SCALE: dict[str, float] = {"RIDE": 1.0, "RUN": 0.35, "WALK": 0.2}
# For duration estimates: a steady pace, not a race.
ASSUMED_SPEED_KMH: dict[str, float] = {"RIDE": 15.0, "RUN": 9.5, "WALK": 4.8}
STRAVA_TYPE: dict[str, str] = {"RIDE": "ride", "RUN": "run", "WALK": "walk"}
VALHALLA_COSTING: dict[str, str] = {"RIDE": "bicycle", "RUN": "pedestrian", "WALK": "pedestrian"}
# Valhalla's pedestrian costing plans at this speed (km/h); it shapes durations, not roads.
WALKING_SPEED_KMH: dict[str, float] = {"RUN": 9.5, "WALK": 5.0}
VERB: dict[str, str] = {"RIDE": "Ride", "RUN": "Run", "WALK": "Walk"}
NOUN: dict[str, str] = {"RIDE": "ride", "RUN": "run", "WALK": "walk"}


def normalise(value: Any) -> str:
    """Any spelling of an activity, or the default for nothing and nonsense."""
    text = str(value or "").strip().upper()
    return text if text in ACTIVITIES else DEFAULT_ACTIVITY


def verb(activity: str, *, lower: bool = False) -> str:
    word = VERB.get(normalise(activity), "Ride")
    return word.lower() if lower else word


def noun(activity: str) -> str:
    return NOUN.get(normalise(activity), "ride")


def comfortable_distance_km(profile: Any, activity: str) -> float:
    """The distance the rider profile calls comfortable, for this way of moving."""
    activity = normalise(activity)
    if activity == "RUN":
        return float(getattr(profile, "run_distance_km", 8.0) or 8.0)
    if activity == "WALK":
        return float(getattr(profile, "walk_distance_km", 5.0) or 5.0)
    return float(getattr(profile, "comfortable_distance_km", 25.0) or 25.0)


def is_foot(activity: str) -> bool:
    return normalise(activity) in ("RUN", "WALK")
