import asyncio

from app.core.geo import decode_polyline, encode_polyline
from app.routing.analysis import (
    analyse_elevation,
    elevation_samples_from_coordinates,
    surface_composition,
)
from app.routing.engine import EngineRequest, SyntheticRouter
from app.routing.preferences import RoutePreferences, parse_rules
from app.routing.scoring import RiderLimits, RouteMetrics, score_route


def test_polyline_roundtrip():
    pts = [(51.5, -0.1), (51.501, -0.102), (51.49, -0.09)]
    assert decode_polyline(encode_polyline(pts)) == pts


def test_nl_parse_rules():
    parsed = parse_rules("Give me around 30 km, quiet roads, some gravel and a pub towards the end.")
    p = parsed.preferences
    assert p.distanceKm["target"] == 30
    assert p.trafficAversion >= 0.9
    assert 0.5 <= p.gravelPreference <= 0.7
    assert p.poi == {"category": "PUB", "preferredPosition": 0.8}


def test_elevation_analysis_finds_climb():
    coords = [[0.0, 51.0 + i * 0.001, 10 + (i * 4 if i < 30 else 130 - (i - 30) * 4)] for i in range(60)]
    stats = analyse_elevation(elevation_samples_from_coordinates(coords))
    assert stats.total_ascent > 100
    assert stats.longest_climb is not None and stats.longest_climb.gain_meters > 100
    assert stats.max_gradient_percent > 2


def test_surface_composition_from_details():
    coords = [[0.0, 51.0 + i * 0.001, 0] for i in range(11)]
    comp = surface_composition(coords, [[0, 5, "asphalt"], [5, 10, "gravel"]])
    assert abs(comp["paved"] - 0.5) < 0.01 and abs(comp["gravel"] - 0.5) < 0.01


def test_scoring_prefers_new_territory_and_penalises_traffic():
    prefs = RoutePreferences(trafficAversion=0.9)
    rider = RiderLimits(30, 400, 8, 0.5, 0.2, True, True)
    quiet_new = RouteMetrics(
        30000,
        200,
        5,
        {"paved": 0.8, "gravel": 0.2, "trail": 0, "unknown": 0},
        0.5,
        0.1,
        0.7,
        1.0,
        2,
    )
    busy_old = RouteMetrics(30000, 200, 5, {"paved": 1.0, "gravel": 0, "trail": 0, "unknown": 0}, 0.1, 0.8, 0.0, 1.0, 0)
    assert score_route(quiet_new, prefs, rider, 30000)[0] > score_route(busy_old, prefs, rider, 30000)[0]


def test_synthetic_router_loop_returns_home():
    route = asyncio.run(
        SyntheticRouter().route(EngineRequest([(51.5, -0.1)], "gravel", round_trip_distance_m=20000, seed=3))
    )[0]
    assert route.coordinates[0][:2] == route.coordinates[-1][:2]
    assert 15000 < route.distance_m < 30000
    assert route.instructions[-1]["sign"] == "FINISH"
