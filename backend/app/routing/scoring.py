"""Route scoring service (spec §28). Weights come from config/scoring.json."""

from __future__ import annotations

import json
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Any

from app.routing.preferences import RoutePreferences

CONFIG_DIR = Path(__file__).parent / "config"


@lru_cache
def scoring_config() -> dict[str, Any]:
    return json.loads((CONFIG_DIR / "scoring.json").read_text())


@dataclass
class RouteMetrics:
    distance_m: float
    elevation_gain_m: float
    max_gradient_percent: float
    surface: dict[str, float]
    cycleway_fraction: float
    traffic_exposure: float
    new_territory_fraction: float
    quest_objective_coverage: float
    poi_count: int
    scenic_fraction: float = 0.0


@dataclass
class RiderLimits:
    comfortable_distance_km: float
    comfortable_elevation_gain: float
    max_preferred_gradient: float
    gravel_comfort: float
    technical_trail_comfort: float
    bike_allows_gravel: bool
    bike_allows_trails: bool


def _clamp(x: float) -> float:
    return max(0.0, min(1.0, x))


def score_route(
    metrics: RouteMetrics,
    prefs: RoutePreferences,
    rider: RiderLimits,
    target_distance_m: float | None,
) -> tuple[float, dict[str, float]]:
    w = scoring_config()["weights"]
    components: dict[str, float] = {}

    # User preference fit: distance closeness + slider agreement.
    distance_fit = 1.0
    if target_distance_m:
        distance_fit = _clamp(1 - abs(metrics.distance_m - target_distance_m) / max(target_distance_m, 1) / 0.35)
    gravel_fraction = metrics.surface.get("gravel", 0.0) + metrics.surface.get("trail", 0.0)
    gravel_fit = 1 - abs(gravel_fraction - prefs.gravelPreference * 0.6)
    cycleway_fit = 1 - max(0.0, prefs.cyclewayPreference - metrics.cycleway_fraction) * 0.6
    components["userPreferenceFit"] = _clamp(distance_fit * 0.5 + gravel_fit * 0.25 + cycleway_fit * 0.25)

    components["questCompletionFit"] = _clamp(metrics.quest_objective_coverage)
    components["explorationPotential"] = _clamp(metrics.new_territory_fraction)
    components["poiValue"] = _clamp(metrics.poi_count / 4)
    components["scenicValue"] = (
        _clamp(metrics.scenic_fraction * 0.6 + (1 - metrics.traffic_exposure) * 0.4) * prefs.scenicPreference
    )

    components["trafficPenalty"] = _clamp(metrics.traffic_exposure * prefs.trafficAversion)

    distance_over = max(0.0, metrics.distance_m / 1000 / max(rider.comfortable_distance_km, 5) - 1.0)
    climb_over = max(0.0, metrics.elevation_gain_m / max(rider.comfortable_elevation_gain, 50) - 1.0)
    gradient_over = max(0.0, (metrics.max_gradient_percent - rider.max_preferred_gradient) / 10)
    tolerance = 1 - prefs.hillTolerance * 0.7
    components["excessiveDifficultyPenalty"] = _clamp(
        distance_over * 0.5 + climb_over * 0.35 * tolerance + gradient_over * 0.15 * tolerance
    )

    mismatch = 0.0
    if not rider.bike_allows_gravel:
        mismatch += metrics.surface.get("gravel", 0.0)
    if not rider.bike_allows_trails:
        mismatch += metrics.surface.get("trail", 0.0)
    mismatch += max(0.0, gravel_fraction - rider.gravel_comfort) * 0.5
    mismatch += max(0.0, metrics.surface.get("trail", 0.0) - rider.technical_trail_comfort) * 0.5
    components["surfaceMismatchPenalty"] = _clamp(mismatch)

    positive = (
        w["userPreferenceFit"] * components["userPreferenceFit"]
        + w["questCompletionFit"] * components["questCompletionFit"]
        + w["explorationPotential"] * components["explorationPotential"]
        + w["poiValue"] * components["poiValue"]
        + w["scenicValue"] * components["scenicValue"]
    )
    negative = (
        w["trafficPenalty"] * components["trafficPenalty"]
        + w["excessiveDifficultyPenalty"] * components["excessiveDifficultyPenalty"]
        + w["surfaceMismatchPenalty"] * components["surfaceMismatchPenalty"]
    )
    max_positive = (
        w["userPreferenceFit"] + w["questCompletionFit"] + w["explorationPotential"] + w["poiValue"] + w["scenicValue"]
    )
    score = _clamp((positive - negative) / max_positive)
    return round(score, 3), {k: round(v, 3) for k, v in components.items()}
