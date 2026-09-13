"""Basic ride validation / anti-cheat (spec §16). Flags, never bans."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime

from app.core.activity import SPEED_CAP_MPS, normalise
from app.core.geo import haversine_m

MAX_PLAUSIBLE_SPEED_MPS = 25.0  # 90 km/h sustained is not cycling; runs and walks cap lower (core/activity.py)
MAX_ACCURACY_M = 100.0
TELEPORT_DISTANCE_M = 500.0
TELEPORT_WINDOW_S = 10.0
MAX_CELLS_PER_KM = 12.0  # at res 9 a straight line crosses ~3 cells/km; 12 leaves room for wiggles
DISTANCE_TOLERANCE = 0.25


@dataclass
class CleanPoint:
    latitude: float
    longitude: float
    timestamp: datetime
    altitude: float | None = None
    speed: float | None = None
    heart_rate: int | None = None


@dataclass
class ValidationResult:
    points: list[CleanPoint] = field(default_factory=list)
    flags: list[str] = field(default_factory=list)
    dropped_points: int = 0
    computed_distance_m: float = 0.0
    computed_elevation_gain_m: float = 0.0
    max_speed_mps: float = 0.0
    moving_seconds: int = 0

    @property
    def suspicious(self) -> bool:
        return any(f.startswith("IMPOSSIBLE") or f == "TELEPORT" for f in self.flags)


def validate_points(
    raw: list[dict], *, client_distance_m: float | None = None, activity: str = "RIDE"
) -> ValidationResult:
    result = ValidationResult()
    speed_cap = SPEED_CAP_MPS.get(normalise(activity), MAX_PLAUSIBLE_SPEED_MPS)
    cleaned: list[CleanPoint] = []
    for p in raw:
        try:
            lat, lon = float(p["latitude"]), float(p["longitude"])
            ts = (
                p["timestamp"]
                if isinstance(p["timestamp"], datetime)
                else datetime.fromisoformat(str(p["timestamp"]).replace("Z", "+00:00"))
            )
        except (KeyError, TypeError, ValueError):
            result.dropped_points += 1
            continue
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            result.dropped_points += 1
            continue
        acc = p.get("horizontalAccuracyMeters")
        if acc is not None and float(acc) > MAX_ACCURACY_M:
            result.dropped_points += 1
            continue
        cleaned.append(CleanPoint(lat, lon, ts, p.get("altitudeMeters"), p.get("speedMps"), p.get("heartRateBpm")))
    cleaned.sort(key=lambda c: c.timestamp)
    if result.dropped_points and raw:
        if result.dropped_points / len(raw) > 0.3:
            result.flags.append("MALFORMED_GPS")

    speeding = 0
    anchor_alt: float | None = None
    for prev, cur in zip(cleaned, cleaned[1:], strict=False):
        dt = (cur.timestamp - prev.timestamp).total_seconds()
        d = haversine_m(prev.latitude, prev.longitude, cur.latitude, cur.longitude)
        if dt <= 0:
            continue
        speed = d / dt
        if d > TELEPORT_DISTANCE_M and dt < TELEPORT_WINDOW_S:
            if "TELEPORT" not in result.flags:
                result.flags.append("TELEPORT")
            continue
        if speed > speed_cap:
            speeding += 1
            continue
        result.computed_distance_m += d
        result.max_speed_mps = max(result.max_speed_mps, speed)
        if speed >= 0.5:
            result.moving_seconds += int(dt)
        if cur.altitude is not None:
            if anchor_alt is None:
                anchor_alt = cur.altitude
            elif cur.altitude - anchor_alt >= 3.0:
                result.computed_elevation_gain_m += cur.altitude - anchor_alt
                anchor_alt = cur.altitude
            elif anchor_alt - cur.altitude >= 3.0:
                anchor_alt = cur.altitude
    if speeding > 3:
        result.flags.append("IMPOSSIBLE_SPEED")
    if client_distance_m is not None and cleaned and result.computed_distance_m > 0:
        if client_distance_m > result.computed_distance_m * (1 + DISTANCE_TOLERANCE) + 500:
            result.flags.append("DISTANCE_MISMATCH")
    result.points = cleaned
    return result


def check_cell_plausibility(new_cell_count: int, distance_m: float) -> str | None:
    km = max(distance_m / 1000.0, 0.5)
    if new_cell_count / km > MAX_CELLS_PER_KM:
        return "UNREALISTIC_CELL_COUNT"
    return None
