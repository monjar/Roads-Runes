"""Route analysis: elevation statistics, climbs, surface composition (spec §27, §29)."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from app.core.geo import haversine_m

SURFACE_BUCKETS = {
    "paved": {
        "paved",
        "asphalt",
        "concrete",
        "paving_stones",
        "sett",
        "cobblestone",
        "concrete:plates",
        "concrete:lanes",
        "wood",
        "metal",
    },
    "gravel": {
        "gravel",
        "fine_gravel",
        "compacted",
        "pebblestone",
        "unpaved",
        "unhewn_cobblestone",
    },
    "trail": {"dirt", "ground", "earth", "grass", "mud", "sand", "woodchips", "rock", "path"},
}

TRAFFIC_BY_ROAD_CLASS = {
    "motorway": 1.0,
    "trunk": 1.0,
    "primary": 0.85,
    "secondary": 0.6,
    "tertiary": 0.4,
    "unclassified": 0.25,
    "residential": 0.2,
    "living_street": 0.1,
    "service": 0.15,
    "road": 0.4,
    "track": 0.0,
    "path": 0.0,
    "cycleway": 0.0,
    "footway": 0.0,
    "pedestrian": 0.05,
    "bridleway": 0.0,
    "steps": 0.0,
    "other": 0.3,
}


@dataclass
class Climb:
    start_meters: float
    length_meters: float
    gain_meters: float
    average_gradient_percent: float

    def to_dict(self) -> dict[str, Any]:
        return {
            "startMeters": round(self.start_meters),
            "lengthMeters": round(self.length_meters),
            "gainMeters": round(self.gain_meters, 1),
            "averageGradientPercent": round(self.average_gradient_percent, 1),
        }


@dataclass
class ElevationStats:
    total_ascent: float = 0.0
    total_descent: float = 0.0
    highest_point: float = 0.0
    lowest_point: float = 0.0
    max_gradient_percent: float = 0.0
    average_climb_gradient_percent: float = 0.0
    longest_climb: Climb | None = None
    climbs: list[Climb] = field(default_factory=list)
    samples: list[dict[str, float]] = field(default_factory=list)


def elevation_samples_from_coordinates(coords: list[list[float]], step_m: float = 100.0) -> list[dict[str, float]]:
    """Resample [[lon, lat, ele], ...] into {distanceMeters, elevationMeters} every `step_m`."""
    if not coords or len(coords[0]) < 3:
        return []
    samples: list[dict[str, float]] = [{"distanceMeters": 0.0, "elevationMeters": float(coords[0][2])}]
    cumulative = 0.0
    next_mark = step_m
    for prev, cur in zip(coords, coords[1:], strict=False):
        seg = haversine_m(prev[1], prev[0], cur[1], cur[0])
        start = cumulative
        cumulative += seg
        while next_mark <= cumulative and seg > 0:
            t = (next_mark - start) / seg
            ele = float(prev[2]) + (float(cur[2]) - float(prev[2])) * t
            samples.append({"distanceMeters": round(next_mark, 1), "elevationMeters": round(ele, 1)})
            next_mark += step_m
    if samples[-1]["distanceMeters"] < cumulative:
        samples.append({"distanceMeters": round(cumulative, 1), "elevationMeters": float(coords[-1][2])})
    return samples


def smooth(samples: list[dict[str, float]], window: int = 3) -> list[dict[str, float]]:
    if len(samples) < window:
        return samples
    out = []
    half = window // 2
    for i in range(len(samples)):
        lo, hi = max(0, i - half), min(len(samples), i + half + 1)
        avg = sum(s["elevationMeters"] for s in samples[lo:hi]) / (hi - lo)
        out.append({"distanceMeters": samples[i]["distanceMeters"], "elevationMeters": round(avg, 1)})
    return out


def analyse_elevation(
    samples: list[dict[str, float]],
    min_climb_gain_m: float = 30.0,
    min_climb_gradient: float = 2.0,
    hysteresis_m: float = 3.0,
) -> ElevationStats:
    stats = ElevationStats(samples=samples)
    if len(samples) < 2:
        if samples:
            stats.highest_point = stats.lowest_point = samples[0]["elevationMeters"]
        return stats
    sm = smooth(samples)
    elevations = [s["elevationMeters"] for s in sm]
    distances = [s["distanceMeters"] for s in sm]
    stats.highest_point = max(elevations)
    stats.lowest_point = min(elevations)

    # Ascent/descent with hysteresis to ignore GPS/DEM noise.
    anchor = elevations[0]
    for ele in elevations[1:]:
        delta = ele - anchor
        if delta >= hysteresis_m:
            stats.total_ascent += delta
            anchor = ele
        elif delta <= -hysteresis_m:
            stats.total_descent += -delta
            anchor = ele

    # Max gradient over 100 m windows.
    for i in range(1, len(sm)):
        dd = distances[i] - distances[i - 1]
        if dd > 0:
            grad = (elevations[i] - elevations[i - 1]) / dd * 100
            stats.max_gradient_percent = max(stats.max_gradient_percent, grad)

    # Climb detection: contiguous rising stretches allowing short dips.
    climbs: list[Climb] = []
    i = 0
    n = len(sm)
    while i < n - 1:
        if elevations[i + 1] > elevations[i]:
            start = i
            j = i + 1
            peak = j
            while j < n - 1:
                if elevations[j + 1] >= elevations[peak]:
                    peak = j + 1
                elif elevations[peak] - elevations[j + 1] > 15:  # sustained descent ends the climb
                    break
                j += 1
            gain = elevations[peak] - elevations[start]
            length = distances[peak] - distances[start]
            if length > 0 and gain >= min_climb_gain_m and (gain / length * 100) >= min_climb_gradient:
                climbs.append(Climb(distances[start], length, gain, gain / length * 100))
            i = max(peak, i + 1)
        else:
            i += 1
    stats.climbs = climbs
    if climbs:
        stats.longest_climb = max(climbs, key=lambda c: c.length_meters)
        stats.average_climb_gradient_percent = sum(c.average_gradient_percent for c in climbs) / len(climbs)
    stats.total_ascent = round(stats.total_ascent, 1)
    stats.total_descent = round(stats.total_descent, 1)
    stats.max_gradient_percent = round(stats.max_gradient_percent, 1)
    stats.average_climb_gradient_percent = round(stats.average_climb_gradient_percent, 1)
    return stats


def _bucket(value: str | None) -> str:
    if not value or value == "missing":
        return "unknown"
    for bucket, values in SURFACE_BUCKETS.items():
        if value in values:
            return bucket
    if value.startswith("paved") or value.startswith("asphalt"):
        return "paved"
    return "unknown"


def _segment_lengths(coords: list[list[float]]) -> list[float]:
    return [haversine_m(a[1], a[0], b[1], b[0]) for a, b in zip(coords, coords[1:], strict=False)]


def _detail_fractions(coords: list[list[float]], detail: list[list[Any]], mapper) -> dict[str, float]:
    """GraphHopper `details` are [[fromIndex, toIndex, value], ...] over coordinate indices."""
    lengths = _segment_lengths(coords)
    total = sum(lengths) or 1.0
    acc: dict[str, float] = {}
    for entry in detail:
        start, end, value = int(entry[0]), int(entry[1]), entry[2]
        seg = sum(lengths[start:end])
        key = mapper(value)
        acc[key] = acc.get(key, 0.0) + seg
    return {k: round(v / total, 3) for k, v in acc.items()}


def surface_composition(coords: list[list[float]], surface_detail: list[list[Any]] | None) -> dict[str, float]:
    base = {"paved": 0.0, "gravel": 0.0, "trail": 0.0, "unknown": 1.0}
    if not surface_detail or len(coords) < 2:
        return base
    fractions = _detail_fractions(coords, surface_detail, _bucket)
    base.update({k: 0.0 for k in base})
    for k, v in fractions.items():
        base[k] = base.get(k, 0.0) + v
    return base


def cycleway_fraction(
    coords: list[list[float]],
    road_class_detail: list[list[Any]] | None,
    bike_network_detail: list[list[Any]] | None,
) -> float:
    if len(coords) < 2:
        return 0.0
    fraction = 0.0
    if road_class_detail:
        fraction += _detail_fractions(
            coords, road_class_detail, lambda v: "cycleway" if v == "cycleway" else "other"
        ).get("cycleway", 0.0)
    if bike_network_detail:
        fraction = max(
            fraction,
            _detail_fractions(
                coords,
                bike_network_detail,
                lambda v: "network" if v and v != "missing" else "other",
            ).get("network", 0.0),
        )
    return round(min(1.0, fraction), 3)


def traffic_exposure(coords: list[list[float]], road_class_detail: list[list[Any]] | None) -> float:
    """0 = no traffic (paths/cycleways), 1 = all on major roads."""
    if not road_class_detail or len(coords) < 2:
        return 0.35
    lengths = _segment_lengths(coords)
    total = sum(lengths) or 1.0
    weighted = 0.0
    for entry in road_class_detail:
        seg = sum(lengths[int(entry[0]) : int(entry[1])])
        weighted += seg * TRAFFIC_BY_ROAD_CLASS.get(str(entry[2]), 0.3)
    return round(weighted / total, 3)


def bounding_box(coords: list[list[float]]) -> tuple[float, float, float, float]:
    lats = [c[1] for c in coords]
    lons = [c[0] for c in coords]
    return min(lats), min(lons), max(lats), max(lons)
