"""How much two routes share, and how much a loop rides its own way twice (0.9.2).

Plan a ride's three cards came back 99% the same, and "to Westminster and back"
rode one road both ways; nothing measured either. These are the measures.
"""

from __future__ import annotations

import math
import time

import pytest

from app.core.geo import destination_point, haversine_m
from app.core.schemas import Coordinate
from app.routing import overlap
from app.routing.engine import EngineRoute, head_of, join_routes
from app.routing.service import _distance_to_leg, _offset_point, _signed_offset

ORIGIN = (51.4906, -0.0316)


def line(start: tuple[float, float], bearing: float, length_m: float, step_m: float = 20.0) -> list[list[float]]:
    """[[lon, lat, ele]] along a bearing."""
    out = []
    for i in range(int(length_m / step_m) + 1):
        lat, lon = destination_point(start[0], start[1], bearing, i * step_m)
        out.append([lon, lat, 10.0])
    return out


def through(*points: tuple[float, float], step_m: float = 20.0) -> list[list[float]]:
    """Straight lines from point to point."""
    out: list[list[float]] = []
    for (lat1, lon1), (lat2, lon2) in zip(points, points[1:], strict=False):
        steps = max(1, int(haversine_m(lat1, lon1, lat2, lon2) / step_m))
        for i in range(steps):
            t = i / steps
            out.append([lon1 + (lon2 - lon1) * t, lat1 + (lat2 - lat1) * t, 10.0])
    out.append([points[-1][1], points[-1][0], 10.0])
    return out


def test_the_same_road_is_the_same_whichever_way_it_is_ridden():
    a = line(ORIGIN, 60, 4000)
    assert overlap.similarity(a, a) == pytest.approx(1.0)
    assert overlap.similarity(a, list(reversed(a))) == pytest.approx(1.0)
    # Sampled differently, still the same road.
    assert overlap.similarity(a, line(ORIGIN, 60, 4000, step_m=7.0)) == pytest.approx(1.0)


def test_a_parallel_street_100_m_away_is_another_road():
    a = line(ORIGIN, 90, 4000)
    beside = line(destination_point(*ORIGIN, 0, 100), 90, 4000)
    assert overlap.similarity(a, beside) == 0.0
    # 20 m is the other side of the same road.
    assert overlap.similarity(a, line(destination_point(*ORIGIN, 0, 20), 90, 4000)) == pytest.approx(1.0)


def test_two_sides_of_a_triangle_share_almost_nothing():
    end = destination_point(*ORIGIN, 90, 4000)
    apex = destination_point(*ORIGIN, 45, 2800)
    straight = through(ORIGIN, end)
    bent = through(ORIGIN, apex, end)
    assert overlap.similarity(straight, bent) < 0.1


def test_similarity_is_the_smaller_share():
    """A short ride entirely along a long one is not the same ride."""
    long = line(ORIGIN, 90, 6000)
    short = long[: len(long) // 3]
    assert overlap.covered(short, long) == pytest.approx(1.0)
    assert overlap.similarity(short, long) < 0.5


def test_three_thousand_points_are_measured_quickly():
    a = [[ORIGIN[1] + 0.0004 * i, ORIGIN[0] + 0.01 * math.sin(i / 200), 10.0] for i in range(3000)]  # an 80 km wiggle
    b = [[c[0], c[1] + 0.0001, 10.0] for c in a]
    started = time.perf_counter()
    overlap.similarity(a, b)
    overlap.self_overlap(a + list(reversed(a)), len(a) - 1)
    assert time.perf_counter() - started < 0.3


def test_an_out_and_back_overlaps_itself_and_a_loop_does_not():
    out = line(ORIGIN, 70, 5000)
    there_and_back = out + list(reversed(out))[1:]
    assert overlap.self_overlap(there_and_back, len(out) - 1) == pytest.approx(1.0)

    end = destination_point(*ORIGIN, 70, 5000)
    left = destination_point(*ORIGIN, 40, 3000)
    right = destination_point(*ORIGIN, 100, 3000)
    loop = through(ORIGIN, left, end, right, ORIGIN)
    turn = min(range(len(loop)), key=lambda i: haversine_m(end[0], end[1], loop[i][1], loop[i][0]))
    assert overlap.self_overlap(loop, turn) < 0.05
    # Without a named turn, the furthest point is the turn.
    assert overlap.self_overlap(there_and_back) == pytest.approx(1.0)


def test_points_to_stay_off_keep_clear_of_the_ends_the_stops_and_the_turns():
    out = line(ORIGIN, 90, 12_000)
    stop = destination_point(*ORIGIN, 90, 6000)
    junction = destination_point(*ORIGIN, 90, 4200)
    samples = overlap.exclusion_samples(out, avoid=[stop], manoeuvres=[junction])
    assert 0 < len(samples) <= 25
    end = (out[-1][1], out[-1][0])
    for lat, lon in samples:
        along = haversine_m(*ORIGIN, lat, lon)
        assert 0.2 * 12_000 - 25 <= along <= 0.8 * 12_000 + 25
        assert haversine_m(lat, lon, *stop) >= 350
        assert haversine_m(lat, lon, *end) >= 350
        assert haversine_m(lat, lon, *junction) >= 40
    # A long way out is thinned to the cap, not cut short.
    long = overlap.exclusion_samples(line(ORIGIN, 90, 40_000))
    assert len(long) == 25
    assert haversine_m(*ORIGIN, *long[-1]) > 0.75 * 40_000


def test_which_side_of_the_line_a_place_is_on():
    start = Coordinate(latitude=ORIGIN[0], longitude=ORIGIN[1])
    end_lat, end_lon = destination_point(*ORIGIN, 90, 4000)  # due east
    end = Coordinate(latitude=end_lat, longitude=end_lon)
    north = destination_point(*destination_point(*ORIGIN, 90, 1000), 0, 300)
    south = destination_point(*destination_point(*ORIGIN, 90, 3000), 180, 500)

    signed, along = _signed_offset(*north, start, end)
    assert signed == pytest.approx(300, abs=5) and along == pytest.approx(0.25, abs=0.01)
    signed, along = _signed_offset(*south, start, end)
    assert signed == pytest.approx(-500, abs=5) and along == pytest.approx(0.75, abs=0.01)
    # The old measure is the unsigned one, clamped to the segment.
    assert _distance_to_leg(*south, start, end) == pytest.approx((500, 0.75), abs=5)
    behind = destination_point(*ORIGIN, 270, 400)
    distance, along = _distance_to_leg(*behind, start, end)
    assert along == 0.0 and distance == pytest.approx(400, abs=5)
    # And back again: a point placed by offset lands where it was asked to.
    lat, lon = _offset_point(start, end, 0.5, -800)
    assert _signed_offset(lat, lon, start, end) == pytest.approx((-800, 0.5), abs=1)


def _route(coords: list[list[float]], finish: str = "FINISH") -> EngineRoute:
    n = len(coords)
    instructions = [
        {"index": 0, "sign": "CONTINUE", "coordinateIndex": 0, "text": "Head out"},
        {"index": 1, "sign": "LEFT", "coordinateIndex": n // 2, "text": "Turn left"},
        {"index": 2, "sign": finish, "coordinateIndex": n - 1, "text": "Arrive"},
    ]
    details = {"surface": [[0, n - 1, "asphalt"]]}
    return EngineRoute(coords, 1000.0, 200, instructions, details, engine="valhalla")


def test_two_routes_join_into_one():
    out = _route(line(ORIGIN, 90, 1000))
    end = (out.coordinates[-1][1], out.coordinates[-1][0])
    back = _route(line(end, 270, 1000))
    joined = join_routes(out, back)

    assert len(joined.coordinates) == len(out.coordinates) + len(back.coordinates) - 1
    assert joined.distance_m == 2000.0 and joined.duration_s == 400
    assert [i["index"] for i in joined.instructions] == list(range(6))
    assert [i["sign"] for i in joined.instructions] == ["CONTINUE", "LEFT", "WAYPOINT", "CONTINUE", "LEFT", "FINISH"]
    offset = len(out.coordinates) - 1
    assert joined.instructions[-1]["coordinateIndex"] == offset + len(back.coordinates) - 1
    assert joined.leg_boundaries == [offset]
    assert joined.details["surface"] == [
        [0, offset, "asphalt"],
        [offset, offset + len(back.coordinates) - 1, "asphalt"],
    ]


def test_the_way_out_of_a_loop_ends_at_the_turn():
    out = line(ORIGIN, 90, 1000)
    back = list(reversed(out))[1:]
    loop = _route(out + back)
    turn = len(out) - 1
    loop.leg_boundaries = [turn]
    loop.instructions.insert(2, {"index": 2, "sign": "WAYPOINT", "coordinateIndex": turn, "text": "Arrive"})
    head = head_of(loop, turn)
    assert len(head.coordinates) == turn + 1
    assert head.instructions[-1]["sign"] == "FINISH"
    assert head.instructions[-1]["coordinateIndex"] == turn
    assert head.distance_m == pytest.approx(500.0, rel=0.02)
    assert head.leg_boundaries == []
    assert all(entry[1] <= turn for entry in head.details["surface"])


def test_ridden_twice_is_both_ways_of_one_road_wherever_the_loop_turns():
    out = line(ORIGIN, 45, 3000)
    assert overlap.ridden_twice(out + list(reversed(out))[1:]) > 0.9
    square = through(
        ORIGIN,
        destination_point(*ORIGIN, 0, 2000),
        destination_point(*destination_point(*ORIGIN, 0, 2000), 90, 2000),
        destination_point(*ORIGIN, 90, 2000),
        ORIGIN,
    )
    assert overlap.ridden_twice(square) == 0.0
    # Two there-and-backs through home, with no one turn to split at.
    west, north = destination_point(*ORIGIN, 270, 2000), destination_point(*ORIGIN, 0, 3000)
    spokes = through(ORIGIN, west, ORIGIN, north, ORIGIN)
    assert overlap.ridden_twice(spokes) > 0.8  # all but the tips, where each spoke turns
