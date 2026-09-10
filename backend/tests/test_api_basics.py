import pytest
from httpx import AsyncClient

from tests.conftest import sign_in


@pytest.mark.anyio
async def test_health_and_config(client: AsyncClient):
    assert (await client.get("/health")).json()["status"] == "ok"
    cfg = (await client.get("/config")).json()
    assert cfg["levels"]["max"] == 50 and cfg["featureFlags"]["fog_of_war"] is True


@pytest.mark.anyio
async def test_auth_required_and_error_schema(client: AsyncClient):
    r = await client.get("/users/me")
    assert r.status_code == 401
    assert r.json()["error"]["code"] == "UNAUTHENTICATED"


@pytest.mark.anyio
async def test_refresh_rotation(client: AsyncClient):
    tokens = await sign_in(client)
    r = await client.post("/auth/refresh", json={"refreshToken": tokens["refreshToken"]})
    assert r.status_code == 200
    r2 = await client.post("/auth/refresh", json={"refreshToken": tokens["refreshToken"]})
    assert r2.status_code == 401  # rotated


@pytest.mark.anyio
async def test_character_and_locked_classes(user_client: AsyncClient):
    r = await user_client.post("/character", json={"name": "Merlin", "characterClass": "WIZARD"})
    assert r.status_code == 403 and r.json()["error"]["code"] == "FEATURE_DISABLED"
    r = await user_client.post("/character", json={"name": "Rowan", "characterClass": "EXPLORER"})
    assert r.status_code == 201
    data = r.json()
    assert data["overallLevel"] == 1 and data["nextOverallLevelXP"] == 250
    assert any(a["ability"]["name"] == "Trail Sense" for a in data["abilities"])
    r = await user_client.post("/character", json={"name": "Again", "characterClass": "EXPLORER"})
    assert r.status_code == 409
    r = await user_client.get("/users/me")
    assert r.json()["hasCharacter"] is True and r.json()["settings"]["defaultRideVisibility"] == "PRIVATE"


@pytest.mark.anyio
async def test_bikes_and_rider_profile(explorer_client: AsyncClient):
    r = await explorer_client.get("/character/bikes")
    assert r.json()[0]["isDefault"] is True and r.json()[0]["allowGravel"] is True
    r = await explorer_client.put(
        "/character/rider-profile",
        json={
            "comfortableDistanceKm": 40,
            "comfortableElevationGain": 500,
            "maxPreferredGradient": 10,
            "trafficTolerance": 0.2,
            "gravelComfort": 0.7,
            "technicalTrailComfort": 0.3,
            "cyclewayPreference": 0.9,
        },
    )
    assert r.status_code == 200 and r.json()["comfortableDistanceKm"] == 40
    # Levelling up never changes the rider profile (spec §30).
    r = await explorer_client.get("/character")
    assert r.json()["overallLevel"] == 1


@pytest.mark.anyio
async def test_friends_flow_and_privacy(client: AsyncClient):
    a = await sign_in(client, "alice", "Alice")
    await client.post("/character", json={"name": "A", "characterClass": "EXPLORER"})
    alice_token = client.headers["Authorization"]
    b = await sign_in(client, "bob", "Bob")
    await client.post("/character", json={"name": "B", "characterClass": "EXPLORER"})
    bob_token = client.headers["Authorization"]

    r = await client.post("/friends/requests", json={"userId": a["user"]["id"]})
    assert r.status_code == 201
    profile = (await client.get(f"/users/{a['user']['id']}")).json()
    assert profile["friendship"] == "REQUEST_SENT"
    assert "homeLocation" not in profile and "liveLocation" not in profile

    client.headers["Authorization"] = alice_token
    reqs = (await client.get("/friends/requests")).json()
    assert len(reqs["incoming"]) == 1
    r = await client.post(f"/friends/requests/{reqs['incoming'][0]['id']}/accept")
    assert r.status_code == 200
    assert (await client.get("/friends")).json()[0]["id"] == b["user"]["id"]

    client.headers["Authorization"] = bob_token
    assert (await client.get(f"/users/{a['user']['id']}")).json()["friendship"] == "FRIENDS"
    r = await client.post("/parties", json={"questId": str(a["user"]["id"])})
    assert r.status_code == 403 and r.json()["error"]["code"] == "FEATURE_DISABLED"
