"""How much two routes share, and how much a loop rides its own way twice (0.9.2).

Pure arithmetic on [[lon, lat, ...]] lines, no I/O. Both lines are resampled every
25 m in a flat frame around the first point (`world_objects/claims.py`), and the
line being measured against is dropped into a grid of cells about as wide as
"near", so each sample looks at nine cells instead of every point of the other
line: linear in length, not length squared.

* `covered(a, b)` — the share of `a` that runs within `near` metres of `b`.
* `similarity(a, b)` — the smaller of the two coverings, leaving out the first
  and last 200 m, which every card of one plan shares.
* `self_overlap(coords, turn)` — the share of the way back that runs along the
  way out, leaving out 250 m at each end and at the turn.
* `exclusion_samples(...)` — points along the way out for a second try at the
  way back to stay off.

London's parallel streets are 60–100 m apart, so 30 m means "the same road".
"""

from __future__ import annotations

import math
from collections.abc import Iterable, Sequence

from app.core.geo import EARTH_RADIUS_M
from app.world_objects.claims import local_xy, resample

STEP_M = 25.0
NEAR_M = 30.0
SHARED_ENDS_M = 200.0
TURN_TRIM_M = 250.0

Line = Sequence[Sequence[float]]  # [[lon, lat, ...], ...]
Point = tuple[float, float]  # (lat, lon)


def _xy(coords: Line, lat0: float, lon0: float) -> list[complex]:
    out: list[complex] = []
    for c in coords:
        x, y = local_xy(float(c[1]), float(c[0]), lat0, lon0)
        point = complex(x, y)
        if not out or point != out[-1]:
            out.append(point)
    return out


def _length(points: Sequence[complex]) -> float:
    return sum(abs(b - a) for a, b in zip(points, points[1:], strict=False))


def _samples(points: Sequence[complex], step: float = STEP_M) -> tuple[list[complex], float]:
    """Points every `step` metres or a little less, and the spacing actually used."""
    if len(points) < 2:
        return list(points), step
    total = _length(points)
    n = max(2, math.ceil(total / step) + 1)
    return resample(points, n), total / (n - 1)


def _trimmed(samples: list[complex], spacing: float, start_m: float, end_m: float) -> list[complex]:
    first = round(start_m / spacing) if spacing > 0 else 0
    last = round(end_m / spacing) if spacing > 0 else 0
    kept = samples[first : len(samples) - last] if last else samples[first:]
    return kept or samples


class _Grid:
    """Points dropped into square cells, so "is any of them near here" is nine lookups."""

    def __init__(self, points: Iterable[complex], cell: float) -> None:
        self.cell = max(cell, 1.0)
        self.buckets: dict[tuple[int, int], list[complex]] = {}
        for p in points:
            self.buckets.setdefault(self._key(p), []).append(p)

    def _key(self, p: complex) -> tuple[int, int]:
        return math.floor(p.real / self.cell), math.floor(p.imag / self.cell)

    def near(self, p: complex, radius: float) -> bool:
        i, j = self._key(p)
        for di in (-1, 0, 1):
            for dj in (-1, 0, 1):
                for q in self.buckets.get((i + di, j + dj), ()):
                    if abs(p - q) <= radius:
                        return True
        return False


def covered(a: Line, b: Line, near: float = NEAR_M, *, trim_m: float = 0.0) -> float:
    """The share of `a`'s length within `near` metres of `b` (0..1).

    `trim_m` leaves that much of `a` out at each end.
    """
    if len(a) < 2 or len(b) < 2:
        return 0.0
    lat0, lon0 = float(a[0][1]), float(a[0][0])
    samples_a, spacing_a = _samples(_xy(a, lat0, lon0))
    samples_b, spacing_b = _samples(_xy(b, lat0, lon0))
    if len(samples_a) < 2 or len(samples_b) < 2:
        return 0.0
    samples_a = _trimmed(samples_a, spacing_a, trim_m, trim_m)
    # A point within `near` of b's line is within this of one of b's samples.
    reach = math.hypot(near, spacing_b / 2)
    grid = _Grid(samples_b, reach)
    hits = sum(1 for p in samples_a if grid.near(p, reach))
    return hits / len(samples_a)


def similarity(a: Line, b: Line, near: float = NEAR_M) -> float:
    """How much of each route the other one rides (the smaller share), ends left out."""
    return min(covered(a, b, near, trim_m=SHARED_ENDS_M), covered(b, a, near, trim_m=SHARED_ENDS_M))


def turn_index(coords: Line) -> int:
    """The point furthest from the start: where a loop with no named turn turns."""
    if not coords:
        return 0
    lat0, lon0 = float(coords[0][1]), float(coords[0][0])
    points = [local_xy(float(c[1]), float(c[0]), lat0, lon0) for c in coords]
    return max(range(len(points)), key=lambda i: math.hypot(*points[i]))


def self_overlap(coords: Line, turn: int | None = None, near: float = NEAR_M) -> float:
    """The share of the way back (after `turn`) that runs along the way out (0..1)."""
    if len(coords) < 3:
        return 0.0
    turn = turn_index(coords) if turn is None else max(1, min(turn, len(coords) - 2))
    out, back = coords[: turn + 1], coords[turn:]
    if len(out) < 2 or len(back) < 2:
        return 0.0
    return covered(back, out, near, trim_m=TURN_TRIM_M)


def exclusion_samples(
    out: Line,
    *,
    avoid: Iterable[Point] = (),
    manoeuvres: Iterable[Point] = (),
    every_m: float = 300.0,
    start: float = 0.2,
    end: float = 0.8,
    clear_of_points_m: float = 350.0,
    clear_of_manoeuvres_m: float = 40.0,
    cap: int = 25,
) -> list[Point]:
    """Points on the way out for the way back to stay off.

    From 20% to 80% of the way, every 300 m; never near the start, the turn or a
    stop (the way back has to reach those), and never on a junction where the
    rider turns (excluding it would close the cross street too). At most `cap`.
    """
    if len(out) < 2:
        return []
    lat0, lon0 = float(out[0][1]), float(out[0][0])
    points = _xy(out, lat0, lon0)
    if len(points) < 2:
        return []
    along = [0.0]
    for a, b in zip(points, points[1:], strict=False):
        along.append(along[-1] + abs(b - a))
    total = along[-1]
    keep_clear = [points[0], points[-1]]
    for lat, lon in avoid:
        keep_clear.append(complex(*local_xy(lat, lon, lat0, lon0)))
    junctions = [complex(*local_xy(lat, lon, lat0, lon0)) for lat, lon in manoeuvres]
    chosen: list[complex] = []
    k = 0
    s = total * start
    while s <= total * end:
        while k < len(along) - 2 and along[k + 1] < s:
            k += 1
        span = along[k + 1] - along[k]
        fraction = (s - along[k]) / span if span > 0 else 0.0
        p = points[k] + (points[k + 1] - points[k]) * fraction
        if all(abs(p - q) >= clear_of_points_m for q in keep_clear) and all(
            abs(p - q) >= clear_of_manoeuvres_m for q in junctions
        ):
            chosen.append(p)
        s += every_m
    if len(chosen) > cap:
        chosen = [chosen[round(i * (len(chosen) - 1) / (cap - 1))] for i in range(cap)]
    return [_latlon(p, lat0, lon0) for p in chosen]


def _latlon(p: complex, lat0: float, lon0: float) -> Point:
    lat = lat0 + math.degrees(p.imag / EARTH_RADIUS_M)
    lon = lon0 + math.degrees(p.real / (EARTH_RADIUS_M * math.cos(math.radians(lat0))))
    return lat, lon
