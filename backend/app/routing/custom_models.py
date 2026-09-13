"""Build GraphHopper custom-model overlays from user preferences (spec §25).

The base bike profiles live in routing/custom_models/*.json and are loaded by
GraphHopper at import time. Request-time overlays here only *tighten* them:
they can never re-enable road classes the base profile blocks (motorways,
trunk roads) so preference sliders cannot make a route less safe.
"""

from __future__ import annotations

from typing import Any

from app.core.activity import WALKING_SPEED_KMH, is_foot, normalise
from app.routing.preferences import RoutePreferences


def build_custom_model(
    prefs: RoutePreferences, bike_type: str, allow_gravel: bool, allow_trails: bool
) -> dict[str, Any]:
    priority: list[dict[str, Any]] = []
    speed: list[dict[str, Any]] = []

    # Traffic aversion: penalise busy road classes proportionally.
    if prefs.trafficAversion > 0:
        primary = round(max(0.05, 1 - prefs.trafficAversion), 2)
        secondary = round(max(0.15, 1 - prefs.trafficAversion * 0.7), 2)
        tertiary = round(max(0.4, 1 - prefs.trafficAversion * 0.4), 2)
        priority.append({"if": "road_class == PRIMARY", "multiply_by": str(primary)})
        priority.append({"else_if": "road_class == SECONDARY", "multiply_by": str(secondary)})
        priority.append({"else_if": "road_class == TERTIARY", "multiply_by": str(tertiary)})

    # Cycleway preference: boost cycling infrastructure by lowering everything else.
    if prefs.cyclewayPreference > 0:
        other = round(max(0.5, 1 - prefs.cyclewayPreference * 0.35), 2)
        priority.append({"if": "road_class != CYCLEWAY && bike_network == MISSING", "multiply_by": str(other)})

    # Gravel/trail preference respecting bike capabilities.
    unpaved = "surface == GRAVEL || surface == FINE_GRAVEL || surface == COMPACTED || surface == UNPAVED"
    if not allow_gravel:
        priority.append({"if": unpaved, "multiply_by": "0.2"})
    elif prefs.gravelPreference < 0.3:
        priority.append({"if": unpaved, "multiply_by": str(round(0.5 + prefs.gravelPreference, 2))})
    elif prefs.gravelPreference > 0.6:
        priority.append(
            {
                "if": "surface == ASPHALT && road_class != CYCLEWAY",
                "multiply_by": str(round(1 - (prefs.gravelPreference - 0.6) * 0.6, 2)),
            }
        )
    trails = "road_class == TRACK || road_class == PATH"
    if not allow_trails:
        priority.append({"if": trails, "multiply_by": "0.3"})

    # Hill tolerance: penalise steep uphill when tolerance is low.
    if prefs.hillTolerance < 0.5:
        factor = round(0.4 + prefs.hillTolerance, 2)
        priority.append({"if": "average_slope >= 6", "multiply_by": str(factor)})
        speed.append({"if": "average_slope >= 6", "multiply_by": "0.8"})

    # Scenic preference: prefer parks/forests/water-side environments.
    if prefs.scenicPreference > 0.5:
        boost_other = round(1 - (prefs.scenicPreference - 0.5) * 0.4, 2)
        priority.append(
            {
                "if": "road_environment == ROAD && road_class != CYCLEWAY && road_class != RESIDENTIAL",
                "multiply_by": str(boost_other),
            }
        )

    model: dict[str, Any] = {"priority": priority, "speed": speed}
    # GraphHopper (with LM) only accepts a query-time distance_influence at or above
    # the profile's base (road 90, hybrid 80, gravel 70, mountain 60), so the overlay
    # may raise it for riders who want directness but never lower it; traffic-averse
    # riders keep the base's detour tolerance and get quiet roads through priority.
    if prefs.trafficAversion <= 0.6:
        model["distance_influence"] = 100
    # Internal hint for the synthetic router only; GraphHopper ignores unknown keys? It does not — strip before sending.
    model["_gravel"] = prefs.gravelPreference
    return model


def strip_internal(model: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in model.items() if not k.startswith("_")}


VALHALLA_BICYCLE_TYPE = {
    "ROAD": "Road",
    "GRAVEL": "Cross",
    "MOUNTAIN": "Mountain",
    "HYBRID": "Hybrid",
    "FOLDING": "Hybrid",
    "OTHER": "Hybrid",
}


def valhalla_costing(
    prefs: RoutePreferences, bike_type: str, allow_gravel: bool, allow_trails: bool, activity: str = "RIDE"
) -> dict[str, Any]:
    """The same preferences as Valhalla costing, for rides outside GraphHopper's graph.

    Valhalla has fewer knobs: quiet roads and cycleways both lower `use_roads`,
    gravel appetite lowers `avoid_bad_surfaces` (bikes that cannot take gravel
    avoid it strongly), and hill tolerance is `use_hills`. On foot the costing is
    pedestrian: quiet means footways and pavements, gravel means tracks.
    """
    quiet = max(prefs.trafficAversion, prefs.cyclewayPreference * 0.8)
    if is_foot(activity):
        return {
            "walking_speed": WALKING_SPEED_KMH.get(normalise(activity), 5.0),
            "walkway_factor": _unit(1.0 - 0.6 * quiet) or 0.1,
            "sidewalk_factor": _unit(1.0 - 0.5 * quiet) or 0.1,
            "use_hills": _unit(prefs.hillTolerance),
            "use_tracks": _unit(prefs.gravelPreference),
            "use_ferry": 0,
        }
    # The whole range, not the bottom half of it: at 0.6 Valhalla still takes the
    # gravel, so "tarmac only" used to come back on the same towpath as "gravel
    # heavy". Verified against valhalla1.openstreetmap.de across Richmond Park,
    # where 0.6 and 0.0 give the same 7.2 km and 1.0 gives a 7.9 km way round.
    avoid_rough = 1.0 - prefs.gravelPreference if allow_gravel else 0.9
    if bike_type == "ROAD":
        avoid_rough = max(avoid_rough, 0.7)
    if allow_trails and bike_type == "MOUNTAIN":
        avoid_rough = min(avoid_rough, 0.1)
    return {
        "bicycle_type": VALHALLA_BICYCLE_TYPE.get(bike_type, "Hybrid"),
        "use_roads": _unit(1 - quiet),
        "use_hills": _unit(prefs.hillTolerance),
        "avoid_bad_surfaces": _unit(avoid_rough),
    }


def _unit(value: float) -> float:
    return round(min(1.0, max(0.0, value)), 2)
