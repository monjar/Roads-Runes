"""A quest's loop is a loop, not a line ridden twice (2026-10-19).

The report: "all of the loops still look like a line". On the real engine a quest
board's routes rode 87–94% of themselves twice: 0.9.2 shaped the planner's loops,
but a quest kept its points, `[O, T, O]`, and nothing stopped the way home from
riding the way there. A sealed quest went the same way. And a loop through stops
whose shorter card took the two nearest, either side of the start, rode out to
one, back through home to the other and home again.

The synthetic router bends a leg there and its leg back the same way, so it
reproduces the line; these tests show the loop.
"""

from __future__ import annotations

import uuid
from types import SimpleNamespace

import pytest

from app.core.geo import destination_point, haversine_m
from app.core.schemas import Coordinate
from app.routing import overlap, service, shapes
from app.routing.engine import EngineRequest, SyntheticRouter
from tests.conftest import parse, stops
from tests.test_first_playable_journey import seed_discoveries
from tests.test_quest_routes import ORIGIN, _one_quest
from tests.test_route_variety import seed_pubs_around


class Recording(SyntheticRouter):
    def __init__(self) -> None:
        self.requests: list[EngineRequest] = []

    async def route(self, request: EngineRequest):
        self.requests.append(request)
        return await super().route(request)


def objective_points(quest: dict) -> list[tuple[float, float]]:
    return [
        (o["latitude"], o["longitude"])
        for o in quest["objectives"]
        if o.get("latitude") is not None and o["objectiveType"] != "RETURN_TO_START"
    ]


def passes(route: dict, point: tuple[float, float], within_m: float = 60.0) -> bool:
    return any(haversine_m(*point, c[1], c[0]) <= within_m for c in route["coordinates"])


@pytest.mark.anyio
async def test_a_quest_to_a_place_comes_home_another_way(app, explorer_client, monkeypatch):
    """ "Come back the way you did not go", said the Green Hour, and its route came
    back the way it went."""
    await seed_discoveries()
    router = Recording()
    app.state.router = router
    quest = await _one_quest(explorer_client, monkeypatch, "ANY_GREEN_HOUR")
    (target,) = objective_points(quest)
    router.requests.clear()
    route = (
        await explorer_client.get(
            f"/quests/{quest['id']}/route", params={"latitude": ORIGIN[0], "longitude": ORIGIN[1]}
        )
    ).json()

    assert passes(route, target)
    assert route["selfOverlap"] < shapes.SELF_OVERLAP_MAX
    assert overlap.ridden_twice(route["coordinates"]) < shapes.RIDDEN_TWICE_MAX
    # Out to the objective with no U-turn there, home through a point off the line.
    first = router.requests[0]
    assert first.types()[first.points.index(pytest.approx(target, abs=1e-9))] == "break_through"
    assert "through" in first.types()


@pytest.mark.anyio
async def test_without_the_flag_a_quest_rides_there_and_back(app, explorer_client, monkeypatch, settings):
    """The line these tests are about, so the one above is not passing by luck."""
    monkeypatch.setattr(settings, "feature_flags", "!route_shapes")
    await seed_discoveries()
    quest = await _one_quest(explorer_client, monkeypatch, "ANY_GREEN_HOUR")
    route = (
        await explorer_client.get(
            f"/quests/{quest['id']}/route", params={"latitude": ORIGIN[0], "longitude": ORIGIN[1]}
        )
    ).json()
    assert overlap.ridden_twice(route["coordinates"]) > 0.8


@pytest.mark.anyio
async def test_a_sealed_quest_goes_out_to_its_goal_and_home_another_way(app, explorer_client):
    router = Recording()
    app.state.router = router
    r = await explorer_client.post(
        "/quests/sealed", json={"minutes": 40, "latitude": ORIGIN[0], "longitude": ORIGIN[1]}
    )
    assert r.status_code == 200, r.text
    quest = r.json()
    route = (await explorer_client.get(f"/quests/{quest['id']}/route")).json()
    assert overlap.ridden_twice(route["coordinates"]) < shapes.RIDDEN_TWICE_MAX
    assert any("break_through" in request.types() for request in router.requests)


@pytest.mark.anyio
async def test_a_quest_with_places_either_side_rides_out_past_one_and_home_past_the_other():
    start = Coordinate(latitude=ORIGIN[0], longitude=ORIGIN[1])
    far = destination_point(*ORIGIN, 90, 4000)
    left = destination_point(*ORIGIN, 60, 2000)  # north of the line east
    right = destination_point(*ORIGIN, 120, 2000)  # south of it
    targets = service.QuestTargets([(*left, 60.0), (*far, 60.0), (*right, 60.0)], True)

    shape = await service._quest_loop_shape(None, start, targets, 10.0, seed=1)  # type: ignore[arg-type]

    assert shape.destination == far
    assert {shape.via, shape.back_via} == {(left,), (right,)}
    # The way back has a place of its own: nothing else to pull it wide.
    assert shape.offset is None
    assert shape.types() == ["break", "via", "break_through", "via", "break"]


def test_a_quest_loop_is_pulled_as_wide_as_its_distance():
    # 2 km out, 10 km asked: the way back swings well off the line.
    factor = shapes.offset_factor_for(2000, 10_000)
    h = factor * 2000
    polygon = 2000 + 2 * ((1000**2 + h**2) ** 0.5)
    assert polygon * shapes.TARGET_DETOUR == pytest.approx(10_000, rel=0.01)
    # A quest that is only there and back's length keeps the usual offset.
    assert shapes.offset_factor_for(5000, 11_000) == shapes.OFFSET_FACTOR
    assert shapes.offset_factor_for(0, 10_000) == shapes.OFFSET_FACTOR


def stop(bearing: float, distance_m: float):
    lat, lon = destination_point(*ORIGIN, bearing, distance_m)
    return SimpleNamespace(id=uuid.uuid4(), latitude=lat, longitude=lon)


def test_a_shorter_loop_takes_stops_that_open_out_from_the_start():
    """The nearest two sat either side of the start: out to one, back through home
    to the other. Two that open out 45–150° make a loop."""
    west, east, north_east = stop(270, 1000), stop(90, 1100), stop(40, 1800)
    picked = service._round_stops(*ORIGIN, [west, east, north_east], 2)
    assert {p.id for p in picked} == {east.id, north_east.id}
    # Round the compass in order, not nearest first.
    bearings = [service.bearing_deg(*ORIGIN, p.latitude, p.longitude) for p in picked]
    assert bearings == sorted(bearings)

    # Up one road, all of them: the nearest, as before.
    along = [stop(10, 800), stop(12, 1600), stop(8, 2400)]
    assert [p.id for p in service._round_stops(*ORIGIN, along, 2)] == [along[0].id, along[1].id]


def test_the_arc_wraps_round_north():
    width, first = service._arc([350.0, 20.0])
    assert width == pytest.approx(30.0) and first == pytest.approx(350.0)
    assert service._arc([0.0, 180.0])[0] == pytest.approx(180.0)


class HomeThroughTheStart(SyntheticRouter):
    """Roads where every stop is reached from the start and back to it, unless told
    what to keep off: a loop through stops comes back as two there-and-backs."""

    def __init__(self) -> None:
        self.requests: list[EngineRequest] = []

    async def route(self, request: EngineRequest):
        self.requests.append(request)
        if request.exclude_points or len(request.points) < 3 or request.round_trip_distance_m:
            return await super().route(request)
        home = request.points[0]
        spokes: list[tuple[float, float]] = [home]
        for point in request.points[1:-1]:
            spokes += [point, home]
        flat = EngineRequest(spokes, request.profile, seed=request.seed)
        return await super().route(flat)


@pytest.mark.anyio
async def test_a_loop_through_stops_that_rides_itself_twice_is_asked_home_another_way(app, explorer_client, reading):
    await seed_pubs_around(ORIGIN, 6, 1800)
    router = HomeThroughTheStart()
    app.state.router = router
    reading(parse(stops=stops("PUB", count=3), distanceKm={"target": 12, "tolerance": 3}, loop=True))
    r = await explorer_client.post(
        "/routes/generate",
        json={"origin": {"latitude": ORIGIN[0], "longitude": ORIGIN[1]}, "request": "a 12 km loop through 3 pubs"},
    )
    assert r.status_code == 200, r.text
    again = [request for request in router.requests if request.exclude_points]
    assert again, "no second try at the way home"
    # The way home on its own: from a stop, home.
    assert again[0].points[-1] == pytest.approx(ORIGIN, abs=1e-6)
    assert all(0 < len(request.exclude_points) <= 25 for request in again)
    asked = next(card for card in r.json()["alternatives"] if card["label"] == "As asked")
    assert overlap.ridden_twice(asked["coordinates"]) < 0.8
