"""Worldwide routing: the Valhalla client, its costing, and GraphHopper-or-Valhalla per request."""

from __future__ import annotations

import json

import httpx
import pytest

from app.core.geo import encode_polyline, haversine_m
from app.routing.custom_models import valhalla_costing
from app.routing.engine import EngineRequest, RegionalRouter, RoutingUnavailable, SyntheticRouter
from app.routing.preferences import RoutePreferences
from app.routing.valhalla import ValhallaClient

SHAPE = [(51.5000, -0.1000), (51.5010, -0.1000), (51.5020, -0.1010), (51.5030, -0.1020)]
GREATER_LONDON = (-0.51, 51.28, 0.34, 51.70)  # GraphHopper /info bbox: min lon, min lat, max lon, max lat
TRACE = {
    "edges": [
        {"begin_shape_index": 0, "end_shape_index": 1, "surface": "paved_smooth", "road_class": "residential",
         "use": "road", "bicycle_network": 0, "length": 0.111},
        {"begin_shape_index": 1, "end_shape_index": 3, "surface": "gravel", "road_class": "service_other",
         "use": "cycleway", "bicycle_network": 4, "length": 0.26},
    ]
}  # fmt: skip


def route_payload(length_km: float = 0.4) -> dict:
    maneuvers = [
        {"type": 1, "instruction": "Bike north.", "street_names": ["Mill Road"], "length": 0.111, "time": 25,
         "begin_shape_index": 0},
        {"type": 15, "instruction": "Turn left onto River Path.", "street_names": ["River Path"], "length": 0.29,
         "time": 75, "begin_shape_index": 1},
        {"type": 4, "instruction": "You have arrived at your destination.", "length": 0.0, "time": 0,
         "begin_shape_index": 3},
    ]  # fmt: skip
    leg = {
        "shape": encode_polyline(SHAPE, precision=6),
        "elevation_interval": 30.0,
        "elevation": [10.0, 12.0, 20.0, 22.0, 25.0],
        "maneuvers": maneuvers,
    }
    return {"trip": {"summary": {"length": length_km, "time": 100.0}, "legs": [leg]}}


def client_for(handler) -> ValhallaClient:
    return ValhallaClient("https://valhalla.test", transport=httpx.MockTransport(handler))


async def test_route_translates_geometry_elevation_instructions_and_details():
    calls: list[tuple[str, dict]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append((request.url.path, json.loads(request.content)))
        return httpx.Response(200, json=route_payload() if request.url.path == "/route" else TRACE)

    costing = {"bicycle_type": "Cross", "use_roads": 0.2}
    [route] = await client_for(handler).route(
        EngineRequest([(51.5, -0.1), (51.503, -0.102)], "gravel", costing=costing)
    )

    assert route.engine == "valhalla"
    assert route.distance_m == 400.0
    for coordinate, (lat, lon) in zip(route.coordinates, SHAPE, strict=True):
        assert coordinate[:2] == pytest.approx([lon, lat])
    # Heights sampled every 30 m are interpolated onto each point of the shape.
    assert route.coordinates[0][2] == 10.0
    assert route.coordinates[1][2] == pytest.approx(24.1, abs=0.3)
    assert route.coordinates[-1][2] == 25.0
    assert [i["sign"] for i in route.instructions] == ["CONTINUE", "LEFT", "FINISH"]
    assert route.instructions[1]["text"] == "Turn left onto River Path"
    assert route.instructions[1]["streetName"] == "River Path"
    assert route.instructions[1]["coordinateIndex"] == 1
    assert route.details == {
        "surface": [[0, 1, "asphalt"], [1, 3, "gravel"]],
        "road_class": [[0, 1, "residential"], [1, 3, "cycleway"]],
        "bike_network": [[0, 1, "missing"], [1, 3, "local"]],
    }
    (route_path, route_body), (trace_path, trace_body) = calls
    assert (route_path, trace_path) == ("/route", "/trace_attributes")
    assert route_body["costing"] == "bicycle"
    assert route_body["costing_options"]["bicycle"] == costing
    assert trace_body["shape_match"] == "walk_or_snap"


async def test_loop_runs_through_waypoints_and_is_rescaled_toward_the_target():
    lengths = iter([30.0, 21.0])  # the first circle rides long; the rescaled one lands near 20 km
    bodies: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/trace_attributes":
            return httpx.Response(200, json={"edges": []})
        bodies.append(json.loads(request.content))
        return httpx.Response(200, json=route_payload(next(lengths)))

    [route] = await client_for(handler).route(
        EngineRequest([(51.5, -0.1)], "hybrid", round_trip_distance_m=20_000, seed=4)
    )

    assert route.distance_m == 21_000
    assert len(bodies) == 2
    for body in bodies:
        locations = body["locations"]
        assert [loc["type"] for loc in locations] == ["break", "via", "via", "via", "break"]
        assert (
            (locations[0]["lat"], locations[0]["lon"]) == (locations[-1]["lat"], locations[-1]["lon"]) == (51.5, -0.1)
        )

    def reach(body: dict) -> float:
        return max(haversine_m(51.5, -0.1, loc["lat"], loc["lon"]) for loc in body["locations"])

    assert reach(bodies[1]) < reach(bodies[0])


async def test_no_path_is_routing_unavailable():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(400, json={"error_code": 442, "error": "No path could be found for input"})

    with pytest.raises(RoutingUnavailable):
        await client_for(handler).route(EngineRequest([(51.5, -0.1), (51.6, -0.2)], "road"))


async def test_route_stands_without_details():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/route":
            return httpx.Response(200, json=route_payload())
        return httpx.Response(500, text="trace_attributes is down")

    [route] = await client_for(handler).route(EngineRequest([(51.5, -0.1), (51.503, -0.102)], "gravel"))
    assert route.details == {}
    assert route.distance_m == 400.0


class Named(SyntheticRouter):
    def __init__(self, name: str) -> None:
        self.name = name

    async def route(self, request: EngineRequest):
        routes = await super().route(request)
        for route in routes:
            route.engine = self.name
        return routes


class Down(Named):
    async def route(self, request: EngineRequest):
        raise RoutingUnavailable("GraphHopper is down")


async def test_regional_router_uses_graphhopper_inside_its_graph_and_valhalla_elsewhere():
    router = RegionalRouter(Named("graphhopper"), GREATER_LONDON, Named("valhalla"))

    [london] = await router.route(EngineRequest([(51.49, -0.03), (51.46, -0.02)], "gravel"))
    [paris] = await router.route(EngineRequest([(48.85, 2.35), (48.84, 2.33)], "gravel"))
    # A 40 km loop from the edge of the graph could run off it; a 20 km one from the middle cannot.
    [edge_loop] = await router.route(EngineRequest([(51.32, -0.1)], "gravel", round_trip_distance_m=40_000, seed=1))
    [middle_loop] = await router.route(EngineRequest([(51.50, -0.1)], "gravel", round_trip_distance_m=20_000, seed=1))

    assert (london.engine, paris.engine) == ("graphhopper", "valhalla")
    assert (edge_loop.engine, middle_loop.engine) == ("valhalla", "graphhopper")


async def test_regional_router_falls_back_when_graphhopper_fails():
    router = RegionalRouter(Down("graphhopper"), GREATER_LONDON, Named("valhalla"))
    [route] = await router.route(EngineRequest([(51.49, -0.03), (51.46, -0.02)], "gravel"))
    assert route.engine == "valhalla"


def test_valhalla_costing_follows_the_rider_and_the_bike():
    quiet_gravel = valhalla_costing(
        RoutePreferences(trafficAversion=0.9, gravelPreference=0.8, hillTolerance=0.2), "GRAVEL", True, False
    )
    assert quiet_gravel == {"bicycle_type": "Cross", "use_roads": 0.1, "use_hills": 0.2, "avoid_bad_surfaces": 0.12}

    road = valhalla_costing(
        RoutePreferences(trafficAversion=0.2, cyclewayPreference=0.2, gravelPreference=0.8), "ROAD", False, False
    )
    assert (road["bicycle_type"], road["use_roads"], road["avoid_bad_surfaces"]) == ("Road", 0.8, 0.9)
