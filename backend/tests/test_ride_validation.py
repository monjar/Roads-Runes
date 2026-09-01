from datetime import UTC, datetime, timedelta

from app.rides.validation import check_cell_plausibility, validate_points


def _pts(n=20, speed_mps=5.0, start=None):
    start = start or datetime(2026, 5, 1, 9, 0, tzinfo=UTC)
    out = []
    for i in range(n):
        out.append(
            {
                "latitude": 51.5 + i * speed_mps / 111_195,
                "longitude": -0.1,
                "timestamp": start + timedelta(seconds=i),
                "horizontalAccuracyMeters": 5,
            }
        )
    return out


def test_normal_ride_is_clean():
    r = validate_points(_pts())
    assert r.flags == [] and len(r.points) == 20 and r.computed_distance_m > 80


def test_impossible_speed_is_flagged():
    r = validate_points(_pts(speed_mps=40))
    assert "IMPOSSIBLE_SPEED" in r.flags and r.suspicious


def test_teleport_is_flagged():
    pts = _pts(10)
    pts[5]["latitude"] += 0.02  # ~2.2 km jump in 1 s
    r = validate_points(pts)
    assert "TELEPORT" in r.flags


def test_inaccurate_points_dropped_and_malformed_flagged():
    pts = _pts(10)
    for p in pts[:4]:
        p["horizontalAccuracyMeters"] = 500
    pts.append({"latitude": "x"})
    r = validate_points(pts)
    assert r.dropped_points == 5 and "MALFORMED_GPS" in r.flags


def test_cell_plausibility():
    assert check_cell_plausibility(5, 1000) is None
    assert check_cell_plausibility(200, 1000) == "UNREALISTIC_CELL_COUNT"
