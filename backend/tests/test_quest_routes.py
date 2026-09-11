import uuid

import pytest
from httpx import AsyncClient

ORIGIN = (51.49, -0.04)


@pytest.mark.anyio
async def test_quest_route_is_fixed_until_tweaked(explorer_client: AsyncClient):
    c = explorer_client
    quest = (await c.get("/quests", params={"latitude": ORIGIN[0], "longitude": ORIGIN[1]})).json()["items"][0]
    assert quest["suggestedRouteId"] is None

    r = await c.get(f"/quests/{quest['id']}/route")
    assert r.status_code == 200, r.text
    route = r.json()
    assert route["distanceMeters"] > 0 and len(route["coordinates"]) > 10
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
