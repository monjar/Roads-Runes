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
    assert quiet_gravel == {"bicycle_type": "Cross", "use_roads": 0.1, "use_hills": 0.2, "avoid_bad_surfaces": 0.2}

    # Both ends of the range are reachable, or "tarmac only" rides the same towpath
    # as "gravel heavy": Valhalla only changes its mind above 0.6.
    tarmac = valhalla_costing(RoutePreferences(gravelPreference=0.0), "HYBRID", True, False)
    assert tarmac["avoid_bad_surfaces"] == 1.0
    assert valhalla_costing(RoutePreferences(gravelPreference=1.0), "HYBRID", True, False)["avoid_bad_surfaces"] == 0.0

    road = valhalla_costing(
        RoutePreferences(trafficAversion=0.2, cyclewayPreference=0.2, gravelPreference=0.8), "ROAD", False, False
    )
    assert (road["bicycle_type"], road["use_roads"], road["avoid_bad_surfaces"]) == ("Road", 0.8, 0.9)


async def test_a_run_is_routed_as_a_pedestrian():
    """Runs and walks use Valhalla's pedestrian costing; bikes keep theirs."""
    calls: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(json.loads(request.content))
        return httpx.Response(200, json=route_payload() if request.url.path == "/route" else TRACE)

    await client_for(handler).route(EngineRequest([(51.5, -0.1), (51.503, -0.102)], "foot", activity="RUN"))
    route_body, trace_body = calls[0], calls[1]
    assert route_body["costing"] == "pedestrian"
    assert route_body["costing_options"] == {"pedestrian": {"walking_speed": 9.5}}
    assert trace_body["costing"] == "pedestrian"

    calls.clear()
    await client_for(handler).route(EngineRequest([(51.5, -0.1), (51.503, -0.102)], "gravel"))
    assert calls[0]["costing"] == "bicycle"


def test_the_local_graph_never_routes_feet():
    router = RegionalRouter(SyntheticRouter(), GREATER_LONDON, SyntheticRouter())
    inside = EngineRequest([(51.5, -0.1), (51.51, -0.11)], "hybrid")
    assert router.covers(inside)
    assert not router.covers(EngineRequest([(51.5, -0.1), (51.51, -0.11)], "foot", activity="RUN"))


async def test_a_busy_server_is_asked_again(monkeypatch):
    """The public server sheds load with a 429 or a 5xx; the second try usually lands."""
    from app.routing import valhalla

    monkeypatch.setattr(valhalla, "RETRY_DELAYS_S", (0.0, 0.0))
    answers = iter([httpx.Response(429, text="slow down"), httpx.Response(503, text="busy")])
    route_calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal route_calls
        if request.url.path != "/route":
            return httpx.Response(200, json=TRACE)
        route_calls += 1
        return next(answers, httpx.Response(200, json=route_payload()))

    [route] = await client_for(handler).route(EngineRequest([(51.5, -0.1), (51.503, -0.102)], "gravel"))
    assert route.distance_m == 400.0
    assert route_calls == 3


async def test_no_path_is_not_asked_twice(monkeypatch):
    from app.routing import valhalla

    monkeypatch.setattr(valhalla, "RETRY_DELAYS_S", (0.0, 0.0))
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(400, json={"error_code": 442, "error": "No path could be found for input"})

    with pytest.raises(RoutingUnavailable):
        await client_for(handler).route(EngineRequest([(51.5, -0.1), (51.6, -0.2)], "road"))
    assert calls == 1


async def test_a_route_without_details_is_one_request():
    paths: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        paths.append(request.url.path)
        return httpx.Response(200, json=route_payload())

    [route] = await client_for(handler).route(EngineRequest([(51.5, -0.1), (51.503, -0.102)], "gravel", details=False))
    assert paths == ["/route"]
    assert route.details == {}


async def test_valhalla_by_name_is_valhalla_even_when_it_was_slow_at_boot(monkeypatch):
    """One failed /status used to put the whole machine on synthetic straight lines."""
    from app.core.config import Settings
    from app.routing import engine

    async def down(self) -> bool:
        return False

    monkeypatch.setattr(ValhallaClient, "healthy", down)
    monkeypatch.setattr(engine.GraphHopperClient, "healthy", down)
    assert (await engine.build_engine(Settings(routing_engine="valhalla"))).name == "valhalla"
    assert (await engine.build_engine(Settings(routing_engine="auto"))).name == "synthetic"


# --- 0.9.2: loops that come back another way, a budget, a pace ---------------------


def two_leg_payload() -> dict:
    """A trip with a break in the middle: two legs, as a break_through point gives."""
    first = route_payload()["trip"]["legs"][0]
    second = {**route_payload()["trip"]["legs"][0], "shape": encode_polyline(list(reversed(SHAPE)), precision=6)}
    return {"trip": {"summary": {"length": 0.8, "time": 200.0}, "legs": [first, second]}}


async def test_location_types_exclusions_and_cutoffs_reach_the_body():
    bodies: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        bodies.append(json.loads(request.content))
        return httpx.Response(200, json=two_leg_payload())

    request = EngineRequest(
        [(51.5, -0.1), (51.503, -0.102), (51.502, -0.105), (51.5, -0.1)],
        "hybrid",
        location_types=["break", "break_through", "through", "break"],
        exclude_points=[(51.501, -0.1005), (51.502, -0.101)],
        search_cutoff_m=[None, None, 400.0, None],
        details=False,
    )
    [route] = await client_for(handler).route(request)
    [body] = bodies
    assert [loc["type"] for loc in body["locations"]] == ["break", "break_through", "through", "break"]
    assert body["locations"][2]["search_cutoff"] == 400
    assert all("search_cutoff" not in loc for i, loc in enumerate(body["locations"]) if i != 2)
    assert body["exclude_locations"] == [
        {"lat": 51.501, "lon": -0.1005, "radius": 20},
        {"lat": 51.502, "lon": -0.101, "radius": 20},
    ]
    assert "alternates" not in body
    # Where the first leg ends, in the joined line.
    assert route.leg_boundaries == [len(SHAPE) - 1]
    assert [i["sign"] for i in route.instructions].count("WAYPOINT") == 1


async def test_two_points_can_ask_for_alternates():
    bodies: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        bodies.append(json.loads(request.content))
        payload = route_payload()
        payload["alternates"] = [route_payload(0.5), route_payload(0.6)]
        return httpx.Response(200, json=payload)

    routes = await client_for(handler).route(
        EngineRequest([(51.5, -0.1), (51.503, -0.102)], "hybrid", alternatives=3, details=False)
    )
    assert bodies[0]["alternates"] == 2
    assert [r.distance_m for r in routes] == [400.0, 500.0, 600.0]


async def test_details_are_fetched_only_when_asked_for():
    paths: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        paths.append(request.url.path)
        return httpx.Response(200, json=route_payload() if request.url.path == "/route" else TRACE)

    client = client_for(handler)
    request = EngineRequest([(51.5, -0.1), (51.503, -0.102)], "gravel", details=False)
    [route] = await client.route(request)
    assert paths == ["/route"] and route.details == {}
    await client.details(route, request)
    assert paths == ["/route", "/trace_attributes"]
    assert route.details["surface"] == [[0, 1, "asphalt"], [1, 3, "gravel"]]
    # Asked twice, fetched once.
    await client.details(route, request)
    assert paths == ["/route", "/trace_attributes"]


async def test_every_attempt_is_charged_to_the_plan(monkeypatch):
    from app.routing import budget, valhalla

    monkeypatch.setattr(valhalla, "RETRY_DELAYS_S", (0.0, 0.0))
    answers = iter([httpx.Response(503, text="busy")])

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/route":
            return next(answers, httpx.Response(200, json=route_payload()))
        return httpx.Response(200, json=TRACE)

    with budget.plan_budget(10) as plan:
        await client_for(handler).route(EngineRequest([(51.5, -0.1), (51.503, -0.102)], "gravel"))
    assert plan.used == 3  # a refused route, the route, its details


async def test_the_details_are_asked_again_only_while_the_plan_can_pay(monkeypatch):
    from app.routing import budget, valhalla

    monkeypatch.setattr(valhalla, "RETRY_DELAYS_S", (0.0, 0.0))
    traces = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal traces
        if request.url.path == "/route":
            return httpx.Response(200, json=route_payload())
        traces += 1
        return httpx.Response(503, text="busy") if traces == 1 else httpx.Response(200, json=TRACE)

    with budget.plan_budget(10):
        [route] = await client_for(handler).route(EngineRequest([(51.5, -0.1), (51.503, -0.102)], "gravel"))
    assert traces == 2 and route.details  # retried, and measured

    traces = 0
    with budget.plan_budget(2):  # the route and one try at the details, nothing over
        [route] = await client_for(handler).route(EngineRequest([(51.5, -0.1), (51.503, -0.102)], "gravel"))
    assert traces == 1 and route.details == {}


async def test_requests_wait_their_turn():
    """The public server asks for about one request a second, from every caller."""
    import asyncio
    import time

    sent: list[float] = []

    def handler(request: httpx.Request) -> httpx.Response:
        sent.append(time.monotonic())
        return httpx.Response(200, json=route_payload())

    client = ValhallaClient("https://valhalla.test", transport=httpx.MockTransport(handler), min_interval_s=0.15)
    request = EngineRequest([(51.5, -0.1), (51.503, -0.102)], "gravel", details=False)
    await asyncio.gather(*(client.route(request) for _ in range(3)))
    await client.route(request)
    gaps = [b - a for a, b in zip(sent, sent[1:], strict=False)]
    assert len(gaps) == 3 and min(gaps) >= 0.14


async def test_a_rider_goes_ahead_of_the_quest_board():
    import asyncio

    from app.routing import budget

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=route_payload())

    client = ValhallaClient("https://valhalla.test", transport=httpx.MockTransport(handler), min_interval_s=0.1)
    seen: list[str] = []

    async def ask(who: str, background: bool) -> None:
        request = EngineRequest([(51.5, -0.1), (51.503, -0.102)], "gravel", details=False)
        if background:
            with budget.background():
                await client.route(request)
        else:
            await client.route(request)
        seen.append(who)

    board = [asyncio.create_task(ask(f"board{i}", True)) for i in range(4)]
    await asyncio.sleep(0.02)  # the board is already queued when the rider asks
    await asyncio.gather(ask("rider", False), *board)
    # The first board request has gone and the second is already waiting out its
    # interval; the rider goes next, ahead of the rest of the board.
    assert seen == ["board0", "board1", "rider", "board2", "board3"], seen


async def test_a_429_rests_the_server_for_everyone(monkeypatch):
    import time

    from app.routing import valhalla

    monkeypatch.setattr(valhalla, "RETRY_DELAYS_S", (0.0,))
    monkeypatch.setattr(valhalla, "COOL_DOWN_S", 0.3)
    sent: list[float] = []
    answers = iter([httpx.Response(429, text="slow down")])

    def handler(request: httpx.Request) -> httpx.Response:
        sent.append(time.monotonic())
        return next(answers, httpx.Response(200, json=route_payload()))

    client = ValhallaClient("https://valhalla.test", transport=httpx.MockTransport(handler), min_interval_s=0.01)
    await client.route(EngineRequest([(51.5, -0.1), (51.503, -0.102)], "gravel", details=False))
    assert sent[1] - sent[0] >= 0.29


async def test_no_path_says_so_and_a_busy_server_does_not(monkeypatch):
    from app.routing import valhalla

    monkeypatch.setattr(valhalla, "RETRY_DELAYS_S", ())

    def no_path(request: httpx.Request) -> httpx.Response:
        return httpx.Response(400, json={"error_code": 442, "error": "No path could be found for input"})

    def busy(request: httpx.Request) -> httpx.Response:
        return httpx.Response(503, text="busy")

    with pytest.raises(RoutingUnavailable) as refused:
        await client_for(no_path).route(EngineRequest([(51.5, -0.1), (51.6, -0.2)], "road"))
    assert refused.value.no_path is True
    with pytest.raises(RoutingUnavailable) as down:
        await client_for(busy).route(EngineRequest([(51.5, -0.1), (51.6, -0.2)], "road"))
    assert down.value.no_path is False


async def test_the_synthetic_router_keeps_out_of_points_to_avoid():
    from app.routing import overlap

    o, d = (51.49, -0.04), (51.49, 0.0)
    [there] = await SyntheticRouter().route(EngineRequest([o, d], "hybrid", seed=2))
    [back] = await SyntheticRouter().route(EngineRequest([d, o], "hybrid", seed=2))
    assert overlap.covered(back.coordinates, there.coordinates) > 0.9  # the same bend both ways
    avoid = overlap.exclusion_samples(there.coordinates)
    [detour] = await SyntheticRouter().route(EngineRequest([d, o], "hybrid", seed=2, exclude_points=avoid))
    assert overlap.covered(detour.coordinates, there.coordinates, trim_m=250) < 0.2

    [loop] = await SyntheticRouter().route(
        EngineRequest([o, d, o], "hybrid", seed=2, location_types=["break", "break_through", "break"])
    )
    [turn] = loop.leg_boundaries
    assert loop.coordinates[turn][:2] == pytest.approx([d[1], d[0]])


async def test_a_stretch_the_bike_is_pushed_through_is_measured():
    """Valhalla routes a bike through a foot tunnel as pedestrian maneuvers (the
    Greenwich Foot Tunnel, lifts and all); the route says how far that is."""
    payload = route_payload()
    payload["trip"]["legs"][0]["maneuvers"][1].update({"travel_mode": "pedestrian", "travel_type": "foot"})

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=payload)

    [ridden] = await client_for(handler).route(EngineRequest([(51.5, -0.1), (51.503, -0.102)], "gravel", details=False))
    assert ridden.walked_m == 290.0
    # On foot every maneuver is pedestrian, and none of it is pushing a bike.
    [walked] = await client_for(handler).route(
        EngineRequest([(51.5, -0.1), (51.503, -0.102)], "foot", details=False, activity="WALK")
    )
    assert walked.walked_m == 0.0
