"""A quest's ways: a loop, one way, quiet roads, new ground, the long way (2026-10-19).

"The quests don't always have to be loops": the quest's page offers its ways, the
rider picks one and it becomes the quest's route, and the long way and new ground
pay a little extra when the journey did what they promised.
"""

from __future__ import annotations

import uuid
from types import SimpleNamespace

import pytest

from app.core.config import get_settings
from app.core.geo import destination_point, haversine_m
from app.core.schemas import Coordinate
from app.db.session import get_session_factory
from app.discoveries.models import Discovery
from app.exploration.cells import cell_for
from app.progression.engine import RideRewardInput, compute_ride_xp
from app.routing import quest_ways, service, shapes
from app.routing.engine import EngineRequest, SyntheticRouter
from tests.test_first_playable_journey import seed_discoveries
from tests.test_quest_routes import ORIGIN, _one_quest

HERE = {"latitude": ORIGIN[0], "longitude": ORIGIN[1]}


class Counting(SyntheticRouter):
    def __init__(self) -> None:
        self.requests: list[EngineRequest] = []

    async def route(self, request: EngineRequest):
        self.requests.append(request)
        return await super().route(request)


async def ways_of(client, quest_id: str) -> dict:
    r = await client.get(f"/quests/{quest_id}/ways", params=HERE)
    assert r.status_code == 200, r.text
    return r.json()


def kinds(body: dict) -> list[str]:
    return [way["kind"] for way in body["ways"]]


@pytest.mark.anyio
async def test_a_quest_to_a_place_offers_a_loop_and_one_way_and_more(app, explorer_client, monkeypatch):
    await seed_discoveries()
    quest = await _one_quest(explorer_client, monkeypatch, "ANY_GREEN_HOUR")  # coming home is optional
    body = await ways_of(explorer_client, quest["id"])

    assert kinds(body)[0] == "LOOP"
    assert "ONE_WAY" in kinds(body)
    loop = body["ways"][0]
    assert body["chosenRouteId"] == loop["route"]["id"]
    for way in body["ways"]:
        assert way["route"]["questWay"] == way["kind"]
        assert way["route"]["label"] == way["name"]
    # Every way is offered or said not to be: none disappears without a word.
    said = " ".join(body["notes"])
    for kind in shapes.WAYS:
        assert kind in kinds(body) or quest_ways.config()["names"][kind] in said, (kind, body["notes"])

    one_way = next(way for way in body["ways"] if way["kind"] == "ONE_WAY")
    (target,) = [(o["latitude"], o["longitude"]) for o in quest["objectives"] if o["objectiveType"] == "VISIT_POI"]
    end_lon, end_lat = one_way["route"]["coordinates"][-1][:2]
    assert haversine_m(*target, end_lat, end_lon) < 100  # it ends there
    assert haversine_m(*ORIGIN, end_lat, end_lon) > 1000  # and not at home
    assert one_way["summary"] == "Ends at Greenwich Park"
    assert one_way["bonus"] is None

    long_way = next((way for way in body["ways"] if way["kind"] == "LONG_WAY"), None)
    if long_way is not None:
        assert long_way["bonus"]["xp"] > 0
        assert long_way["route"]["distanceMeters"] > loop["route"]["distanceMeters"]


@pytest.mark.anyio
async def test_the_ways_are_planned_once_while_the_rider_stays_there(app, explorer_client, monkeypatch):
    await seed_discoveries()
    quest = await _one_quest(explorer_client, monkeypatch, "ANY_GREEN_HOUR")
    first = await ways_of(explorer_client, quest["id"])
    router = Counting()
    app.state.router = router
    again = await ways_of(explorer_client, quest["id"])
    assert router.requests == []
    assert [w["route"]["id"] for w in again["ways"]] == [w["route"]["id"] for w in first["ways"]]


async def seed_cafe() -> None:
    lat, lon = destination_point(*ORIGIN, 70, 3000)
    async with get_session_factory()() as db:
        db.add(Discovery(name="The Kettle", category="CAFE", latitude=lat, longitude=lon, source="OSM", tags={}))
        await db.commit()


@pytest.mark.anyio
async def test_no_one_way_when_the_quest_asks_you_to_come_home(explorer_client, monkeypatch):
    await seed_cafe()
    quest = await _one_quest(explorer_client, monkeypatch, "ANY_COFFEE_LOOP")
    assert any(o["objectiveType"] == "RETURN_TO_START" and o["required"] for o in quest["objectives"])
    body = await ways_of(explorer_client, quest["id"])
    assert "ONE_WAY" not in kinds(body)
    assert "No one way here: this quest asks you to come home" in body["notes"]


@pytest.mark.anyio
async def test_a_quest_with_nowhere_to_go_has_no_one_way_and_every_way_is_long_enough(explorer_client, monkeypatch):
    quest = await _one_quest(explorer_client, monkeypatch, "ANY_FIRST_FIVE")
    must = next(o["targetMeters"] for o in quest["objectives"] if o["objectiveType"] == "COMPLETE_DISTANCE")
    body = await ways_of(explorer_client, quest["id"])
    assert "ONE_WAY" not in kinds(body)
    assert "No one way here: this quest has no place to end at" in body["notes"]
    assert all(way["route"]["distanceMeters"] >= must * 0.98 for way in body["ways"])
    assert kinds(body)[0] == "LOOP" and body["ways"][0]["summary"] == "Round and home again"


@pytest.mark.anyio
async def test_choosing_a_way_makes_it_the_quests_route(explorer_client, monkeypatch):
    await seed_discoveries()
    quest = await _one_quest(explorer_client, monkeypatch, "ANY_GREEN_HOUR")
    body = await ways_of(explorer_client, quest["id"])
    one_way = next(way["route"] for way in body["ways"] if way["kind"] == "ONE_WAY")

    r = await explorer_client.post(f"/quests/{quest['id']}/way", json={"routeId": one_way["id"]})
    assert r.status_code == 200, r.text
    chosen = r.json()
    assert chosen["suggestedRouteId"] == one_way["id"]
    assert chosen["recommendedDistanceKm"] == round(one_way["distanceMeters"] / 1000, 1)
    # The planner, the board and the Watch get the quest's route: this one now.
    route = (await explorer_client.get(f"/quests/{quest['id']}/route", params=HERE)).json()
    assert route["id"] == one_way["id"]
    assert (await ways_of(explorer_client, quest["id"]))["chosenRouteId"] == one_way["id"]

    # A route that is not one of its ways is not taken.
    r = await explorer_client.post(f"/quests/{quest['id']}/way", json={"routeId": str(uuid.uuid4())})
    assert r.status_code == 404


@pytest.mark.anyio
async def test_a_sealed_quest_keeps_the_way_the_board_picked(explorer_client):
    r = await explorer_client.post("/quests/sealed", json={"minutes": 40, **HERE})
    assert r.status_code == 200, r.text
    quest = r.json()
    body = await ways_of(explorer_client, quest["id"])
    assert len(body["ways"]) == 1 and body["notes"] == ["The board picked this way"]
    r = await explorer_client.post(f"/quests/{quest['id']}/way", json={"routeId": body["ways"][0]["route"]["id"]})
    assert r.status_code == 409 and r.json()["error"]["code"] == "QUEST_SEALED"


def test_new_ground_sets_off_where_the_rider_has_never_been():
    resolution = get_settings().h3_resolution
    start = Coordinate(latitude=ORIGIN[0], longitude=ORIGIN[1])
    # Everything west, north and south of home is known; the east is not.
    known = {}
    for bearing in range(150, 400, 10):
        for metres in range(0, 6000, 150):
            known[cell_for(*destination_point(*ORIGIN, bearing % 360, metres), resolution)] = "EXPLORED"
    heading = service._newest_heading(start, 12.0, known, resolution)
    assert heading in (45.0, 90.0, 135.0)


def test_the_way_bonus_is_its_own_xp_line():
    lines = compute_ride_xp(
        RideRewardInput(
            character_class="EXPLORER", quest_completed=True, quest_difficulty="EASY", way_bonus=("The long way", 60)
        )
    )
    bonus = next(line for line in lines if line.source == "QUEST_WAY_BONUS")
    assert bonus.xp == 60 and bonus.detail == {"way": "The long way"}
    plain = compute_ride_xp(RideRewardInput(character_class="EXPLORER", quest_completed=True, quest_difficulty="EASY"))
    assert not any(line.source == "QUEST_WAY_BONUS" for line in plain)


class FakeDB:
    def __init__(self, route) -> None:
        self.route = route

    async def get(self, _model, _id):
        return self.route


@pytest.mark.anyio
async def test_the_bonus_is_paid_only_for_doing_what_the_way_promised():
    quest = SimpleNamespace(id=uuid.uuid4())
    long_way = SimpleNamespace(quest_id=quest.id, distance_meters=15_000, request={"questWay": "LONG_WAY"})
    ride = SimpleNamespace(route_id=uuid.uuid4(), distance_meters=14_000)
    earned = await quest_ways.bonus_earned(FakeDB(long_way), ride, quest, 0)
    assert earned == {"kind": "LONG_WAY", "name": "The long way", "xp": 60, "ac": 10}
    # Turned back early: the long way was not ridden.
    ride.distance_meters = 9_000
    assert await quest_ways.bonus_earned(FakeDB(long_way), ride, quest, 0) is None

    new_ground = SimpleNamespace(quest_id=quest.id, distance_meters=10_000, request={"questWay": "NEW_GROUND"})
    ride.distance_meters = 10_000
    assert await quest_ways.bonus_earned(FakeDB(new_ground), ride, quest, 400) is None
    assert (await quest_ways.bonus_earned(FakeDB(new_ground), ride, quest, 1500))["kind"] == "NEW_GROUND"

    # Another quest's route, or a way with no bonus, pays nothing.
    other = SimpleNamespace(quest_id=uuid.uuid4(), distance_meters=15_000, request={"questWay": "LONG_WAY"})
    assert await quest_ways.bonus_earned(FakeDB(other), ride, quest, 0) is None
    loop = SimpleNamespace(quest_id=quest.id, distance_meters=15_000, request={"questWay": "LOOP"})
    assert await quest_ways.bonus_earned(FakeDB(loop), ride, quest, 5000) is None
