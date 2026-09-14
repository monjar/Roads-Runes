"""The arithmetic behind an encounter: the fast stretch, the rune, the climb."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.core.geo import destination_point
from app.world_objects import claims

FIXTURE = json.loads((Path(__file__).parent / "fixtures" / "rune_tracks.json").read_text())
START = (51.4906, -0.0316)


def northbound(speeds_mps: list[float], interval_s: float = 1.0) -> list[claims.TimedPoint]:
    """One fix per second heading north, at the speed given for that second."""
    points = [claims.TimedPoint(0.0, START[0], START[1])]
    for i, speed in enumerate(speeds_mps):
        lat, lon = destination_point(points[-1].lat, points[-1].lon, 0.0, speed * interval_s)
        points.append(claims.TimedPoint((i + 1) * interval_s, lat, lon))
    return points


def test_the_fastest_kilometre_is_found_and_timed():
    # 1 km at 5 m/s, 1 km at 8 m/s, 1 km at 5 m/s.
    points = northbound([5.0] * 200 + [8.0] * 125 + [5.0] * 200)
    window = claims.best_pace_window(points, 1000, speed_cap_mps=25)
    assert window is not None
    assert 124 <= window.seconds <= 126.5, window.seconds
    assert 199 <= window.start <= 202 and window.end <= 330
    assert 124 <= window.pace_s_per_km <= 127


def test_a_gap_in_the_trace_breaks_the_window():
    points = northbound([5.0] * 200 + [8.0] * 125 + [5.0] * 200)
    for p in points[262:]:  # the phone slept for 90 s in the middle of the fast stretch
        p.t += 90
    window = claims.best_pace_window(points, 1000, speed_cap_mps=25)
    assert window is not None and window.seconds > 140


def test_a_window_must_come_near_the_monster_and_stay_plausible():
    points = northbound([8.0] * 150)
    assert claims.best_pace_window(points, 1000, speed_cap_mps=25, near=[False] * len(points)) is None
    near = [i > 100 for i in range(len(points))]
    assert claims.best_pace_window(points, 1000, speed_cap_mps=25, near=near) is not None
    # 8 m/s is a fine ride and an impossible walk.
    assert claims.best_pace_window(points, 600, speed_cap_mps=4.0) is None


def test_the_templates_have_their_corners():
    counts = {
        shape: claims.corners(pts, closed=claims.CLOSED[shape])[0] for shape, pts in claims.rune_templates().items()
    }
    assert counts == {"TRIANGLE": 3, "SQUARE": 4, "STAR": 5, "LOOP": 0, "ZIGZAG": 3}
    assert claims.corners(claims.rune_templates()["STAR"])[1] > 540


@pytest.mark.parametrize("case", FIXTURE["cases"], ids=[c["name"] for c in FIXTURE["cases"]])
def test_runes_are_read_from_tracks(case):
    track = [tuple(p) for p in case["track"]]
    match = claims.match_rune(track, tuple(FIXTURE["centre"]))
    assert (match.shape if match else None) == case["expected"], (match, case["name"])


def test_distance_to_a_path_counts_the_road_between_fixes():
    a, b = START, destination_point(START[0], START[1], 90.0, 1000)
    mid = destination_point(START[0], START[1], 90.0, 500)
    off = destination_point(mid[0], mid[1], 0.0, 30)
    assert claims.min_distance_to_path_m(off[0], off[1], [a, b]) == pytest.approx(30, abs=1)
    assert claims.min_distance_to_path_m(START[0], START[1], [a, b]) < 1


def test_climbing_uses_the_validators_hysteresis():
    assert claims.elevation_gain_m([10, 11, 12, 11, 12, 11]) == 0
    assert claims.elevation_gain_m([10, 14, 18, 15, 25, None, 30]) == pytest.approx(23)
