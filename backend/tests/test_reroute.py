"""Off the route, mid-ride: one new route from where the rider is."""

from __future__ import annotations

import uuid

from httpx import AsyncClient

from app.core.geo import destination_point, haversine_m
from tests.conftest import sign_in
from tests.test_first_playable_journey import ORIGIN, seed_discoveries

HERE = {"latitude": ORIGIN[0], "longitude": ORIGIN[1]}


def ends(route: dict) -> tuple[tuple[float, float], tuple[float, float]]:
    first, last = route["coordinates"][0], route["coordinates"][-1]
    return (first[1], first[0]), (last[1], last[0])


async def planned(c: AsyncClient, **body) -> dict:
    r = await c.post("/routes/generate", json={"origin": HERE, **body})
    assert r.status_code == 200, r.text
    return r.json()["alternatives"][0]


async def test_a_ride_somewhere_still_ends_there(explorer_client: AsyncClient):
    """A reroute used to be planned with no destination at all, so a ride to the
    tower could not be given a way back to the road to the tower."""
    c = explorer_client
    tower = destination_point(*ORIGIN, 90, 4000)
    route = await planned(c, destination={"latitude": tower[0], "longitude": tower[1]}, loop=False)
    astray = destination_point(*ORIGIN, 0, 1200)
    r = await c.post(
        f"/routes/{route['id']}/reroute",
        json={"origin": {"latitude": astray[0], "longitude": astray[1]}, "progressMeters": 300},
    )
    assert r.status_code == 200, r.text
    again = r.json()
    start, end = ends(again)
    assert again["id"] != route["id"] and again["label"] == "Rerouted"
    assert haversine_m(*astray, *start) < 100
    assert haversine_m(*tower, *end) < 100
    assert again["instructions"] and again["distanceMeters"] > 0


async def test_a_loop_is_rejoined_and_ends_at_home(explorer_client: AsyncClient):
    c = explorer_client
    route = await planned(c, distanceTargetKm=12, loop=True)
    astray = destination_point(*ORIGIN, 200, 2500)
    r = await c.post(
        f"/routes/{route['id']}/reroute",
        json={"origin": {"latitude": astray[0], "longitude": astray[1]}, "progressMeters": 1000},
    )
    assert r.status_code == 200, r.text
    again = r.json()
    start, end = ends(again)
    assert haversine_m(*astray, *start) < 100
    assert haversine_m(*ORIGIN, *end) < 150
    # The rest of the loop, not a straight line home.
    assert again["distanceMeters"] > haversine_m(*astray, *ORIGIN) * 1.3


async def test_a_quest_reroute_goes_on_to_what_is_left_and_not_back_to_what_is_done(
    app, explorer_client: AsyncClient, monkeypatch
):
    from app.quests import generator
    from app.routing.engine import SyntheticRouter
    from app.world_objects import service as world_objects

    asked: list[list[tuple[float, float]]] = []

    class Watching(SyntheticRouter):
        async def route(self, request):
            asked.append(list(request.points))
            return await super().route(request)

    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    slay = [t for t in generator.templates_for("EXPLORER", 1) if t["id"] == "ANY_SLAY_NEARBY"]
    monkeypatch.setattr(generator, "templates_for", lambda *a, **k: slay)
    quest = (await c.post("/quests/generate", json={**HERE, "count": 1})).json()["items"][0]
    target = next(o for o in quest["objectives"] if o["objectiveType"] == "SLAY_MONSTER")
    monster = (target["latitude"], target["longitude"])
    route = (await c.get(f"/quests/{quest['id']}/route", params=HERE)).json()

    app.state.router = Watching()
    astray = destination_point(*ORIGIN, 30, 2000)
    body = {"origin": {"latitude": astray[0], "longitude": astray[1]}, "progressMeters": 200}
    r = await c.post(f"/routes/{route['id']}/reroute", json=body)
    assert r.status_code == 200, r.text
    # From the rider, by the monster, home.
    assert asked[-1][0] == astray and monster in asked[-1][1:-1]
    assert haversine_m(*ORIGIN, *asked[-1][-1]) < 150
    assert haversine_m(*ORIGIN, *ends(r.json())[1]) < 150

    # The phone saw the monster fall before the server heard of it.
    r = await c.post(f"/routes/{route['id']}/reroute", json={**body, "completedObjectiveIds": [target["id"]]})
    assert r.status_code == 200, r.text
    assert monster not in asked[-1]
    # And the quest keeps the route it had: a reroute is the ride's, not the quest's.
    assert (await c.get(f"/quests/{quest['id']}")).json()["suggestedRouteId"] == route["id"]


async def test_a_reroute_that_cannot_be_drawn_says_so(app, explorer_client: AsyncClient):
    from app.routing.engine import RoutingUnavailable, SyntheticRouter

    class Down(SyntheticRouter):
        async def route(self, request):
            raise RoutingUnavailable("the engine is down")

    c = explorer_client
    route = await planned(c, distanceTargetKm=10, loop=True)
    app.state.router = Down()
    r = await c.post(f"/routes/{route['id']}/reroute", json={"origin": HERE})
    assert r.status_code == 502 and r.json()["error"]["code"] == "ROUTE_GENERATION_FAILED"


async def test_a_reroute_asks_the_engine_once_and_without_details(app, explorer_client: AsyncClient):
    from app.routing.engine import SyntheticRouter

    asked = []

    class Counting(SyntheticRouter):
        async def route(self, request):
            asked.append(request)
            return await super().route(request)

    c = explorer_client
    route = await planned(c, distanceTargetKm=10, loop=True)
    app.state.router = Counting()
    r = await c.post(f"/routes/{route['id']}/reroute", json={"origin": HERE})
    assert r.status_code == 200, r.text
    assert len(asked) == 1 and asked[0].details is False


async def test_someone_elses_route_is_not_there(client: AsyncClient, explorer_client: AsyncClient):
    route = await planned(explorer_client, distanceTargetKm=10, loop=True)
    await sign_in(client, subject="another", name="Another")
    r = await client.post(f"/routes/{route['id']}/reroute", json={"origin": HERE})
    assert r.status_code == 404
    r = await client.post(f"/routes/{uuid.uuid4()}/reroute", json={"origin": HERE})
    assert r.status_code == 404
