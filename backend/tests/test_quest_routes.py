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
