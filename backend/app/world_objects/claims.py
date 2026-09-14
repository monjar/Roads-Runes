"""Pure encounter arithmetic: was the chest passed, was the monster beaten. No I/O.

Everything here works on a GPS trace and answers with numbers, so the same
routine can run on the phone for live feedback (a Swift port with the same
constants) and here for the verdict that pays out.
"""

from __future__ import annotations

import cmath
import math
from collections.abc import Sequence
from dataclasses import dataclass
from functools import lru_cache

from app.core.geo import EARTH_RADIUS_M, haversine_m

Point = tuple[float, float]  # (lat, lon)

# --- distances ---------------------------------------------------------------


def local_xy(lat: float, lon: float, lat0: float, lon0: float) -> tuple[float, float]:
    """Metres east and north of (lat0, lon0): flat enough for a few kilometres."""
    x = math.radians(lon - lon0) * math.cos(math.radians(lat0)) * EARTH_RADIUS_M
    y = math.radians(lat - lat0) * EARTH_RADIUS_M
    return x, y


def point_to_segment_m(lat: float, lon: float, lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    px, py = local_xy(lat, lon, lat1, lon1)
    qx, qy = local_xy(lat2, lon2, lat1, lon1)
    length_sq = qx * qx + qy * qy
    t = 0.0 if length_sq == 0 else max(0.0, min(1.0, (px * qx + py * qy) / length_sq))
    return math.hypot(px - t * qx, py - t * qy)


def min_distance_to_path_m(lat: float, lon: float, coords: Sequence[Point]) -> float:
    """How close a trace came to a point, counting the road between fixes, not just the fixes."""
    if not coords:
        return math.inf
    if len(coords) == 1:
        return haversine_m(lat, lon, coords[0][0], coords[0][1])
    best = math.inf
    for (lat1, lon1), (lat2, lon2) in zip(coords, coords[1:], strict=False):
        # Cheap reject: both ends further than the best so far by more than the segment could close.
        if (
            min(haversine_m(lat, lon, lat1, lon1), haversine_m(lat, lon, lat2, lon2))
            - haversine_m(lat1, lon1, lat2, lon2)
            > best
        ):
            continue
        best = min(best, point_to_segment_m(lat, lon, lat1, lon1, lat2, lon2))
    return best


# --- pace --------------------------------------------------------------------


@dataclass
class TimedPoint:
    t: float  # seconds
    lat: float
    lon: float


@dataclass
class PaceWindow:
    start: int
    end: int
    seconds: float
    meters: float

    @property
    def pace_s_per_km(self) -> float:
        return self.seconds / (self.meters / 1000.0)


def best_pace_window(
    points: Sequence[TimedPoint],
    window_m: float,
    *,
    speed_cap_mps: float,
    near: Sequence[bool] | None = None,
    max_gap_s: float = 60.0,
) -> PaceWindow | None:
    """The fastest stretch of `window_m` metres, two pointers over cumulative distance.

    A window is thrown out if it spans a GPS gap longer than `max_gap_s` or a
    segment faster than the activity allows (a train, a dropped fix), and, when
    `near` is given, if no fix in it is near the monster. The end time is
    interpolated inside the last segment, so the window is exactly `window_m`.
    """
    n = len(points)
    if n < 3 or window_m <= 0:
        return None
    cum = [0.0] * n
    bad = [0] * n
    near_prefix = [0] * n
    for i in range(1, n):
        d = haversine_m(points[i - 1].lat, points[i - 1].lon, points[i].lat, points[i].lon)
        dt = points[i].t - points[i - 1].t
        cum[i] = cum[i - 1] + d
        bad[i] = bad[i - 1] + (1 if (dt <= 0 or dt > max_gap_s or d / dt > speed_cap_mps) else 0)
    for i in range(n):
        near_prefix[i] = (near_prefix[i - 1] if i else 0) + (1 if (near is None or near[i]) else 0)
    best: PaceWindow | None = None
    j = 0
    for i in range(n):
        while j < n and cum[j] - cum[i] < window_m:
            j += 1
        if j >= n:
            break
        if bad[j] - bad[i] > 0 or j - i < 2:
            continue
        if near_prefix[j] - (near_prefix[i - 1] if i else 0) == 0:
            continue
        over = cum[j] - cum[i] - window_m
        segment = cum[j] - cum[j - 1]
        t_end = points[j].t - (points[j].t - points[j - 1].t) * (over / segment if segment > 0 else 0.0)
        seconds = t_end - points[i].t
        if seconds <= 0:
            continue
        if best is None or seconds < best.seconds:
            best = PaceWindow(i, j, seconds, window_m)
    return best


# --- runes -------------------------------------------------------------------

RUNE_SHAPES = ("TRIANGLE", "SQUARE", "STAR", "LOOP", "ZIGZAG")
CLOSED = {"TRIANGLE": True, "SQUARE": True, "STAR": True, "LOOP": True, "ZIGZAG": False}
CORNERS = {"TRIANGLE": 3, "SQUARE": 4, "STAR": 5, "LOOP": 0, "ZIGZAG": 3}
SAMPLES = 32
CANDIDATE_LENGTHS_M = (300.0, 450.0, 675.0, 1000.0, 1500.0, 2250.0, 3000.0, 4000.0)
CORNER_TURN_DEG = 50.0
LOOP_THRESHOLD = 0.08
MAX_CANDIDATES = 400


@dataclass
class RuneMatch:
    shape: str
    score: float
    start: int
    end: int
    corners: int


def resample(points: Sequence[complex], n: int = SAMPLES, *, closed: bool = False) -> list[complex]:
    """`n` points at equal arc length along the polyline (around it, if closed)."""
    pts = list(points)
    if len(pts) < 2:
        return [pts[0] if pts else 0j] * n
    if closed:
        pts.append(pts[0])
    lengths = [abs(b - a) for a, b in zip(pts, pts[1:], strict=False)]
    total = sum(lengths)
    if total <= 0:
        return [pts[0]] * n
    targets = [total * i / n for i in range(n)] if closed else [total * i / (n - 1) for i in range(n)]
    out: list[complex] = []
    k = 0
    passed = 0.0
    for s in targets:
        while k < len(lengths) - 1 and passed + lengths[k] < s:
            passed += lengths[k]
            k += 1
        fraction = (s - passed) / lengths[k] if lengths[k] > 0 else 0.0
        out.append(pts[k] + (pts[k + 1] - pts[k]) * min(1.0, max(0.0, fraction)))
    return out


def normalise(points: Sequence[complex]) -> list[complex]:
    """Centred on its centroid and scaled to unit RMS radius: size and place no longer matter."""
    centre = sum(points) / len(points)
    shifted = [p - centre for p in points]
    rms = math.sqrt(sum(abs(p) ** 2 for p in shifted) / len(shifted)) or 1.0
    return [p / rms for p in shifted]


def _vertices(shape: str) -> list[complex]:
    if shape == "TRIANGLE":
        return [cmath.rect(1, math.radians(90 + 120 * k)) for k in range(3)]
    if shape == "SQUARE":
        return [cmath.rect(1, math.radians(45 + 90 * k)) for k in range(4)]
    if shape == "STAR":
        outer = [cmath.rect(1, math.radians(90 + 72 * k)) for k in range(5)]
        return [outer[k] for k in (0, 2, 4, 1, 3)]  # the pentagram stroke
    if shape == "LOOP":
        return [cmath.rect(1, 2 * math.pi * k / 64) for k in range(64)]
    if shape == "ZIGZAG":
        return [complex(0.5 * k, 0.866 if k % 2 else 0.0) for k in range(5)]
    raise ValueError(shape)


@lru_cache(maxsize=1)
def rune_templates() -> dict[str, list[complex]]:
    return {shape: normalise(resample(_vertices(shape), closed=CLOSED[shape])) for shape in RUNE_SHAPES}


def _procrustes_score(a: Sequence[complex], b: Sequence[complex]) -> float:
    """Mean distance after the rotation that best lays `a` on `b` (both already normalised)."""
    s = sum(ak.conjugate() * bk for ak, bk in zip(a, b, strict=True))
    if abs(s) == 0:
        return 2.0
    rotation = s / abs(s)
    return sum(abs(ak * rotation - bk) for ak, bk in zip(a, b, strict=True)) / len(a)


def score_against(track: Sequence[complex], template: Sequence[complex], *, closed: bool) -> float:
    """Best of both directions, both handednesses and (closed) every starting point."""
    best = math.inf
    for mirrored in (list(track), [p.conjugate() for p in track]):
        for ordered in (mirrored, mirrored[::-1]):
            for offset in range(len(ordered)) if closed else (0,):
                candidate = ordered[offset:] + ordered[:offset]
                best = min(best, _procrustes_score(candidate, template))
    return best


def corners(points: Sequence[complex], *, closed: bool = True) -> tuple[int, float]:
    """Sharp turns along a resampled track, and the total turning in degrees.

    A turn is measured over chords two samples wide, so a corner that falls
    between samples still reads as one sharp turn, while a circle (four gentle
    steps of 11°) reads as none. Closed shapes wrap, so the corner at the start
    counts too. Consecutive sharp samples are one corner.
    """
    n = len(points)
    if n < 5:
        return 0, 0.0

    def at(i: int) -> complex:
        return points[i % n] if closed else points[max(0, min(n - 1, i))]

    wide: list[float] = []
    total = 0.0
    for k in range(n):
        if not closed and (k < 2 or k > n - 3):
            wide.append(0.0)
            continue
        chord_in, chord_out = at(k) - at(k - 2), at(k + 2) - at(k)
        wide.append(abs(math.degrees(cmath.phase(chord_out / chord_in))) if abs(chord_in) and abs(chord_out) else 0.0)
    for k in range(n if closed else n - 2):
        step_in, step_out = at(k) - at(k - 1), at(k + 1) - at(k)
        if closed or 0 < k:
            if abs(step_in) and abs(step_out):
                total += abs(math.degrees(cmath.phase(step_out / step_in)))
    sharp = [w >= CORNER_TURN_DEG for w in wide]
    count = 0
    for k in range(n):
        before = sharp[(k - 1) % n] if closed else (sharp[k - 1] if k else False)
        if sharp[k] and not before:
            count += 1
    if closed and count == 0 and all(sharp):
        count = 1
    return count, total


def classify(track_xy: Sequence[complex], *, threshold: float) -> RuneMatch | None:
    """Which rune a sub-track traces, if any: the best-scoring template that passes its vetoes."""
    if len(track_xy) < 4:
        return None
    arc = sum(abs(b - a) for a, b in zip(track_xy, track_xy[1:], strict=False))
    if arc <= 0:
        return None
    closure = abs(track_xy[0] - track_xy[-1]) / arc
    closed_pts = normalise(resample(track_xy, closed=True))
    open_pts = normalise(resample(track_xy, closed=False))
    results: list[tuple[float, str, int]] = []
    for shape, template in rune_templates().items():
        closed = CLOSED[shape]
        if closed and closure > (0.12 if shape == "LOOP" else 0.15):
            continue
        pts = closed_pts if closed else open_pts
        count, total = corners(pts, closed=closed)
        expected = CORNERS[shape]
        if shape == "LOOP":
            # A circle is the easiest shape to resemble by accident: a wandering
            # track that happens to close scores 0.11, a real loop 0.03, and a
            # real loop turns through one revolution, not one and a bit.
            if count > 2 or not 300 <= total <= 450:
                continue
        elif abs(count - expected) > 1:
            continue
        if shape == "STAR" and total < 540:
            continue
        score = score_against(pts, template, closed=closed)
        if score <= (min(threshold, LOOP_THRESHOLD) if shape == "LOOP" else threshold):
            results.append((score, shape, count))
    if not results:
        return None
    results.sort()
    best_score, best_shape, best_count = results[0]
    for score, shape, count in results[1:]:
        if score - best_score <= 0.03 and count == CORNERS[shape] and best_count != CORNERS[best_shape]:
            best_score, best_shape, best_count = score, shape, count
            break
    return RuneMatch(best_shape, round(best_score, 4), 0, len(track_xy) - 1, best_count)


def match_rune(
    coords: Sequence[Point],
    centre: Point,
    *,
    threshold: float = 0.22,
    search_radius_m: float = 1000.0,
    min_length_m: float = 300.0,
    max_length_m: float = 4000.0,
) -> RuneMatch | None:
    """The rune traced near `centre`, if any: sub-tracks of several lengths from every
    start about 50 m apart, each classified; the best match wins."""
    if len(coords) < 4:
        return None
    xy = [complex(*local_xy(lat, lon, centre[0], centre[1])) for lat, lon in coords]
    near = [abs(p) <= search_radius_m for p in xy]
    runs: list[tuple[int, int]] = []
    start = None
    for i, ok in enumerate(near):
        if ok and start is None:
            start = i
        elif not ok and start is not None:
            runs.append((start, i - 1))
            start = None
    if start is not None:
        runs.append((start, len(near) - 1))
    lengths = [length for length in CANDIDATE_LENGTHS_M if min_length_m <= length <= max_length_m]
    candidates: list[tuple[int, int]] = []
    for first, last in runs:
        cum = [0.0]
        for i in range(first + 1, last + 1):
            cum.append(cum[-1] + abs(xy[i] - xy[i - 1]))
        if cum[-1] < min_length_m:
            continue
        stride = 50.0
        while True:
            found: set[tuple[int, int]] = set()
            next_start_at = 0.0
            for a in range(len(cum)):
                if cum[a] < next_start_at:
                    continue
                next_start_at = cum[a] + stride
                remaining = cum[-1] - cum[a]
                if remaining < min_length_m:
                    break
                # Fixed lengths, so an open rune of any size is covered within a quarter.
                for length in lengths:
                    b = next((k for k in range(a + 1, len(cum)) if cum[k] - cum[a] >= length), None)
                    if b is None:
                        break
                    found.add((a, b))
                # To the end of the run, for a rune traced right up to the monster.
                if remaining <= max_length_m:
                    found.add((a, len(cum) - 1))
                # Back to where it started: a closed rune of exactly its own size.
                skip_until = 0.0
                for b in range(a + 1, len(cum)):
                    arc = cum[b] - cum[a]
                    if arc < min_length_m or cum[b] < skip_until:
                        continue
                    if arc > max_length_m:
                        break
                    if abs(xy[first + b] - xy[first + a]) <= max(30.0, 0.08 * arc):
                        found.add((a, b))
                        skip_until = cum[b] + 100.0
            if len(found) <= MAX_CANDIDATES or stride >= 1600:
                candidates.extend((first + a, first + b) for a, b in sorted(found))
                break
            stride *= 2
    best: RuneMatch | None = None
    for a, b in candidates[:MAX_CANDIDATES]:
        match = classify(xy[a : b + 1], threshold=threshold)
        if match is None:
            continue
        match.start, match.end = a, b
        if best is None or match.score < best.score:
            best = match
    return best


# --- climbs ------------------------------------------------------------------


def elevation_gain_m(altitudes: Sequence[float | None], hysteresis_m: float = 3.0) -> float:
    """Climbing with the validator's hysteresis, so GPS jitter is not a mountain."""
    gain = 0.0
    anchor: float | None = None
    for altitude in altitudes:
        if altitude is None:
            continue
        if anchor is None:
            anchor = altitude
        elif altitude - anchor >= hysteresis_m:
            gain += altitude - anchor
            anchor = altitude
        elif anchor - altitude >= hysteresis_m:
            anchor = altitude
    return gain
