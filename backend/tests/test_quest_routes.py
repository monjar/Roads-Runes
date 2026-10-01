import uuid

import pytest
from httpx import AsyncClient

ORIGIN = (51.49, -0.04)


@pytest.mark.anyio
async def test_quest_route_is_fixed_until_tweaked(explorer_client: AsyncClient):
    c = explorer_client
    quest = (await c.get("/quests", params={"latitude": ORIGIN[0], "longitude": ORIGIN[1]})).json()["items"][0]
    # A quest on the board already has its route, so the distance on its card is the
    # route's and not a guess: the list used to say 10 km and the quest, opened, 7.7.
    assert quest["suggestedRouteId"] is not None

    r = await c.get(f"/quests/{quest['id']}/route")
    assert r.status_code == 200, r.text
    route = r.json()
    assert route["id"] == quest["suggestedRouteId"]
    assert route["distanceMeters"] > 0 and len(route["coordinates"]) > 10
    must_cover = (
        max(
            (o.get("targetMeters") or 0)
            for o in quest["objectives"]
            if o["required"] and o["objectiveType"] in ("COMPLETE_DISTANCE", "COMPLETE_ROUTE")
        )
        if any(
            o["required"] and o["objectiveType"] in ("COMPLETE_DISTANCE", "COMPLETE_ROUTE") for o in quest["objectives"]
        )
        else 0
    )
    assert quest["recommendedDistanceKm"] == round(max(route["distanceMeters"], must_cover) / 1000, 1)
    assert (await c.get(f"/quests/{quest['id']}/route")).json()["id"] == route["id"]
    assert (await c.get(f"/quests/{quest['id']}")).json()["suggestedRouteId"] == route["id"]

    # Tweaking adds alternatives; the quest keeps its route.
    r = await c.post(
        "/routes/generate",
        json={
            "origin": {"latitude": ORIGIN[0], "longitude": ORIGIN[1]},
            "questId": quest["id"],
            "request": "quiet roads",
        },
    )
    assert r.status_code == 200, r.text
    assert all(a["id"] != route["id"] for a in r.json()["alternatives"])
    assert (await c.get(f"/quests/{quest['id']}/route")).json()["id"] == route["id"]


@pytest.mark.anyio
async def test_quest_route_unknown_quest(explorer_client: AsyncClient):
    r = await explorer_client.get(f"/quests/{uuid.uuid4()}/route")
    assert r.status_code == 404 and r.json()["error"]["code"] == "NOT_FOUND"


@pytest.mark.anyio
async def test_identical_alternatives_are_collapsed(app, explorer_client: AsyncClient):
    from app.routing.engine import SyntheticRouter

    class SamePathRouter(SyntheticRouter):
        async def route(self, request):
            request.seed = 1  # every label now gets the same A→B path
            return await super().route(request)

    app.state.router = SamePathRouter()
    r = await explorer_client.post(
        "/routes/generate",
        json={
            "origin": {"latitude": ORIGIN[0], "longitude": ORIGIN[1]},
            "destination": {"latitude": 51.477, "longitude": 0.001},
            "loop": False,
        },
    )
    assert r.status_code == 200, r.text
    assert len(r.json()["alternatives"]) == 1


@pytest.mark.anyio
async def test_a_quest_that_asks_for_a_distance_has_a_route_that_long(explorer_client: AsyncClient, monkeypatch):
    """ "Ride at least 11.3 km" came with a 9.5 km route: follow it and the quest could
    never be finished."""
    from app.quests import generator

    only = [t for t in generator.templates_for("EXPLORER", 1) if t["id"] == "ANY_FIRST_FIVE"]
    monkeypatch.setattr(generator, "templates_for", lambda *a, **k: only)
    r = await explorer_client.post("/quests/generate", json={"latitude": ORIGIN[0], "longitude": ORIGIN[1], "count": 1})
    assert r.status_code == 200, r.text
    quest = r.json()["items"][0]
    must_cover = next(o["targetMeters"] for o in quest["objectives"] if o["objectiveType"] == "COMPLETE_DISTANCE")
    route = (await explorer_client.get(f"/quests/{quest['id']}/route")).json()
    assert route["distanceMeters"] >= must_cover * 0.98, (route["distanceMeters"], must_cover)
    settled = (await explorer_client.get(f"/quests/{quest['id']}")).json()
    assert settled["recommendedDistanceKm"] == round(max(route["distanceMeters"], must_cover) / 1000, 1)


async def _one_quest(c: AsyncClient, monkeypatch, template_id: str) -> dict:
    """A board of exactly this template, so the test knows what it is routing."""
    from app.quests import generator

    only = [t for t in generator.templates_for("EXPLORER", 1) if t["id"] == template_id]
    monkeypatch.setattr(generator, "templates_for", lambda *a, **k: only)
    r = await c.post("/quests/generate", json={"latitude": ORIGIN[0], "longitude": ORIGIN[1], "count": 1})
    assert r.status_code == 200, r.text
    return r.json()["items"][0]


@pytest.mark.anyio
async def test_a_quest_route_starts_where_the_player_is(explorer_client: AsyncClient, monkeypatch):
    """A quest drawn up in Deptford and opened in Bermondsey showed a route in
    Deptford, three kilometres from the rider it was for."""
    from app.core.geo import destination_point, haversine_m

    c = explorer_client
    quest = await _one_quest(c, monkeypatch, "ANY_FIRST_FIVE")
    at_home = {"latitude": ORIGIN[0], "longitude": ORIGIN[1]}
    first = (await c.get(f"/quests/{quest['id']}/route", params=at_home)).json()

    # Across the road is still here: the same route, not a new one per step.
    lat, lon = destination_point(*ORIGIN, 90, 100)
    again = await c.get(f"/quests/{quest['id']}/route", params={"latitude": lat, "longitude": lon})
    assert again.json()["id"] == first["id"]

    lat, lon = destination_point(*ORIGIN, 300, 3000)
    r = await c.get(f"/quests/{quest['id']}/route", params={"latitude": lat, "longitude": lon})
    assert r.status_code == 200, r.text
    moved = r.json()
    assert moved["id"] != first["id"]
    start_lon, start_lat = moved["coordinates"][0][:2]
    assert haversine_m(lat, lon, start_lat, start_lon) < 100
    settled = (await c.get(f"/quests/{quest['id']}")).json()
    assert settled["suggestedRouteId"] == moved["id"]
    assert haversine_m(lat, lon, settled["origin"]["latitude"], settled["origin"]["longitude"]) < 1
    # And with no position the stored route is the answer, as it always was.
    assert (await c.get(f"/quests/{quest['id']}/route")).json()["id"] == moved["id"]


@pytest.mark.anyio
async def test_coming_home_is_to_where_the_quest_was_begun(explorer_client: AsyncClient, monkeypatch):
    from app.core.geo import destination_point, haversine_m
    from app.world_objects import service as world_objects
    from tests.test_first_playable_journey import seed_discoveries

    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    quest = await _one_quest(c, monkeypatch, "ANY_SLAY_NEARBY")
    lat, lon = destination_point(*ORIGIN, 300, 3000)
    assert (await c.get(f"/quests/{quest['id']}/route", params={"latitude": lat, "longitude": lon})).status_code == 200
    settled = (await c.get(f"/quests/{quest['id']}")).json()
    home = next(o for o in settled["objectives"] if o["objectiveType"] == "RETURN_TO_START")
    assert haversine_m(lat, lon, home["latitude"], home["longitude"]) < 1


@pytest.mark.anyio
async def test_a_quest_the_engine_cannot_route_says_so(app, explorer_client: AsyncClient, monkeypatch):
    """The board swallowed the failure and so did the app: a quest with a bare map
    and nothing to say why. The board still loads; the route itself is an error."""
    from app.routing.engine import RoutingUnavailable, SyntheticRouter

    class Down(SyntheticRouter):
        async def route(self, request):
            raise RoutingUnavailable("the engine is down")

    c = explorer_client
    quest = await _one_quest(c, monkeypatch, "ANY_FIRST_FIVE")
    working = app.state.router
    app.state.router = Down()
    here = {"latitude": ORIGIN[0], "longitude": ORIGIN[1]}
    board = await c.get("/quests", params=here)
    assert board.status_code == 200, board.text
    assert next(q for q in board.json()["items"] if q["id"] == quest["id"])["suggestedRouteId"] is None
    r = await c.get(f"/quests/{quest['id']}/route", params=here)
    assert r.status_code == 502 and r.json()["error"]["code"] == "ROUTE_GENERATION_FAILED"

    # The next look, with the engine back, draws it.
    app.state.router = working
    assert (await c.get(f"/quests/{quest['id']}/route", params=here)).status_code == 200


@pytest.mark.anyio
async def test_an_accepted_quest_gets_its_route_too(explorer_client: AsyncClient, monkeypatch):
    c = explorer_client
    quest = await _one_quest(c, monkeypatch, "ANY_FIRST_FIVE")
    assert quest["suggestedRouteId"] is None
    assert (await c.post(f"/quests/{quest['id']}/accept")).status_code == 200
    r = await c.get("/quests", params={"latitude": ORIGIN[0], "longitude": ORIGIN[1], "status": "ACCEPTED"})
    assert r.status_code == 200, r.text
    assert next(q for q in r.json()["items"] if q["id"] == quest["id"])["suggestedRouteId"] is not None


@pytest.mark.anyio
async def test_a_quest_out_of_reach_leaves_the_board(explorer_client: AsyncClient, monkeypatch):
    from app.core.geo import destination_point
    from app.world_objects import service as world_objects
    from tests.test_first_playable_journey import seed_discoveries

    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    quest = await _one_quest(c, monkeypatch, "ANY_SLAY_NEARBY")

    # A few kilometres on it is the same quest, routed from here.
    lat, lon = destination_point(*ORIGIN, 270, 3000)
    near = await c.get("/quests", params={"latitude": lat, "longitude": lon})
    assert quest["id"] in {q["id"] for q in near.json()["items"]}

    # A day's ride away it is not this rider's quest any more.
    lat, lon = destination_point(*ORIGIN, 270, 60_000)
    far = await c.get("/quests", params={"latitude": lat, "longitude": lon, "status": "AVAILABLE"})
    assert far.status_code == 200, far.text
    assert quest["id"] not in {q["id"] for q in far.json()["items"]}
    assert (await c.get(f"/quests/{quest['id']}")).json()["status"] == "EXPIRED"


@pytest.mark.anyio
async def test_a_quest_for_something_that_has_gone_goes_with_it(explorer_client: AsyncClient, monkeypatch):
    """Quests lasted a fortnight and monsters three days: "Trouble at New Cross Inn"
    sat on the board long after there was nothing at New Cross Inn."""
    from datetime import datetime

    from app.db.session import get_session_factory
    from app.world_objects import service as world_objects
    from app.world_objects.models import WorldObject
    from tests.test_first_playable_journey import seed_discoveries

    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    quest = await _one_quest(c, monkeypatch, "ANY_SLAY_NEARBY")
    objective = next(o for o in quest["objectives"] if o["objectiveType"] == "SLAY_MONSTER")
    target = (await c.get(f"/world/objects/{objective['extra']['objectId']}")).json()
    assert datetime.fromisoformat(quest["expiresAt"]) <= datetime.fromisoformat(target["expiresAt"])

    async with get_session_factory()() as db:
        obj = await db.get(WorldObject, uuid.UUID(target["id"]))
        obj.status = "EXPIRED"
        await db.commit()
    board = await c.get("/quests", params={"latitude": ORIGIN[0], "longitude": ORIGIN[1], "status": "AVAILABLE"})
    assert quest["id"] not in {q["id"] for q in board.json()["items"]}
    assert (await c.get(f"/quests/{quest['id']}")).json()["status"] == "EXPIRED"


def test_a_route_does_not_go_back_to_what_is_done():
    from app.quests.models import QuestInstance, QuestObjective
    from app.routing.service import _quest_targets

    quest = QuestInstance(
        objectives=[
            QuestObjective(
                objective_type="VISIT_POI", title="Done", latitude=51.5, longitude=-0.05, status="COMPLETED"
            ),
            QuestObjective(objective_type="VISIT_POI", title="To do", latitude=51.48, longitude=-0.02),
        ]
    )
    assert [(lat, lon) for lat, lon, _ in _quest_targets(quest).points] == [(51.48, -0.02)]
