"""The sealed quest (0.7.3): pick a time, the board picks the way, the goal opens halfway."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import select

from app.core.activity import ASSUMED_SPEED_KMH
from app.core.geo import destination_point, haversine_m
from app.db.session import get_session_factory
from app.discoveries.models import Discovery
from app.economy.rules import quest_ac
from app.lore.voice import violations
from app.quests import sealed
from app.quests.models import QuestInstance
from tests.test_first_playable_journey import ORIGIN, seed_discoveries
from tests.test_world_objects import ride

HERE = {"latitude": ORIGIN[0], "longitude": ORIGIN[1]}


async def ask(c, minutes: int = 40, activity: str | None = "RIDE", **where) -> dict:
    body = {"minutes": minutes, **(where or HERE)}
    if activity:
        body["activity"] = activity
    r = await c.post("/quests/sealed", json=body)
    assert r.status_code == 200, r.text
    return r.json()


async def test_a_sealed_quest_is_accepted_with_its_goal_hidden_and_a_route_of_about_the_time(explorer_client):
    c = explorer_client
    await seed_discoveries()
    quest = await ask(c, 40)
    assert quest["status"] == "ACCEPTED" and quest["acceptedAt"] is not None
    assert quest["title"] == "Sealed quest (40 min)"
    assert quest["description"] == "The board picked the way. Your goal opens halfway."
    assert quest["templateId"] == "SEALED" and quest["characterClass"] == "ANY" and quest["activity"] == "RIDE"
    assert quest["difficulty"] == "EASY" and quest["rewards"]["ac"] == quest_ac("EASY")
    [objective] = quest["objectives"]
    # Hidden like a riddle's: no pin and no name on the objective itself...
    assert objective["latitude"] is None and objective["longitude"] is None and objective["discoveryId"] is None
    assert "poiName" not in objective["extra"] and "objectName" not in objective["extra"]
    assert objective["extra"]["hidden"] is True and objective["extra"]["revealAtFraction"] == 0.5
    # ...while the goal rides along for the phone to open halfway.
    goal = objective["extra"]["goal"]
    assert goal["kind"] in ("PLACE", "CREATURE") and goal["name"] and goal["title"].startswith("Ride to ")
    assert quest["extra"] == {"sealed": True, "minutes": 40, "revealAtFraction": 0.5, "goal": goal}
    # About half the time away at a ride's usual pace, as the crow flies.
    one_way_m = ASSUMED_SPEED_KMH["RIDE"] * 40 / 60 / 2 * 1000
    away = haversine_m(ORIGIN[0], ORIGIN[1], goal["latitude"], goal["longitude"])
    assert 0.6 * one_way_m / sealed.DETOUR <= away <= 1.4 * one_way_m / sealed.DETOUR, away

    # The route is fixed, goes there and back, and lasts about the minutes asked.
    assert quest["suggestedRouteId"] is not None
    r = await c.get(f"/quests/{quest['id']}/route")
    assert r.status_code == 200, r.text
    route = r.json()
    assert route["id"] == quest["suggestedRouteId"]
    assert 0.6 * 2 * one_way_m <= route["distanceMeters"] <= 1.4 * 2 * one_way_m, route["distanceMeters"]
    assert (
        min(haversine_m(goal["latitude"], goal["longitude"], lat, lon) for lon, lat, *_ in route["coordinates"]) < 100
    )
    start, end = route["coordinates"][0], route["coordinates"][-1]
    assert haversine_m(start[1], start[0], end[1], end[0]) < 50, "a sealed quest comes home"
    assert quest["recommendedDistanceKm"] == round(route["distanceMeters"] / 1000, 1)

    # The route package carries the quest as the board does: the goal in its extra.
    r = await c.get(f"/routes/{route['id']}/package")
    assert r.status_code == 200, r.text
    assert r.json()["quest"]["extra"]["goal"] == goal


async def test_the_long_one_pays_like_a_moderate_quest_and_a_walk_stays_near(explorer_client):
    c = explorer_client
    await seed_discoveries()
    long = await ask(c, 90)
    assert long["title"] == "Sealed quest (90 min)" and long["difficulty"] == "MODERATE"
    assert long["rewards"]["ac"] == quest_ac("MODERATE")
    walk = await ask(c, 20, activity="WALK")
    assert walk["activity"] == "WALK"
    goal = walk["extra"]["goal"]
    assert goal["title"].startswith("Walk to ")
    one_way_m = ASSUMED_SPEED_KMH["WALK"] * 20 / 60 / 2 * 1000
    assert haversine_m(ORIGIN[0], ORIGIN[1], goal["latitude"], goal["longitude"]) <= 1.6 * one_way_m


async def test_only_twenty_forty_or_ninety_minutes(explorer_client):
    r = await explorer_client.post("/quests/sealed", json={"minutes": 30, **HERE})
    assert r.status_code == 400 and r.json()["error"]["code"] == "VALIDATION_ERROR"


async def test_a_second_sealed_quest_replaces_one_not_yet_started(explorer_client):
    c = explorer_client
    await seed_discoveries()
    first = await ask(c, 20)
    second = await ask(c, 40)
    assert (await c.get(f"/quests/{first['id']}")).json()["status"] == "EXPIRED"
    assert (await c.get(f"/quests/{second['id']}")).json()["status"] == "ACCEPTED"
    # One under way is the rider's: it is not taken from them.
    r = await c.post(f"/quests/{second['id']}/start", json={})
    assert r.status_code == 200, r.text
    third = await ask(c, 20)
    assert (await c.get(f"/quests/{second['id']}")).json()["status"] == "ACTIVE"
    assert third["status"] == "ACCEPTED"


async def test_riding_to_the_goal_opens_it_and_finishes_the_quest(explorer_client):
    c = explorer_client
    await seed_discoveries()
    quest = await ask(c, 40)
    goal = quest["extra"]["goal"]
    pts = out_and_back(ORIGIN, (goal["latitude"], goal["longitude"]))
    summary = await ride(c, pts, quest_id=quest["id"])
    assert summary["questCompletion"] is not None, summary["flags"]
    [objective] = summary["questCompletion"]["quest"]["objectives"]
    assert objective["status"] == "COMPLETED"
    assert objective["latitude"] == goal["latitude"] and objective["longitude"] == goal["longitude"]


async def test_a_sensitive_place_is_never_the_goal(explorer_client):
    c = explorer_client
    target_m = ASSUMED_SPEED_KMH["RIDE"] * 40 / 60 / 2 * 1000 / sealed.DETOUR
    lat, lon = destination_point(ORIGIN[0], ORIGIN[1], 90, target_m)
    async with get_session_factory()() as db:
        db.add(Discovery(name="St Mary's Church", category="HISTORICAL", latitude=lat, longitude=lon,
                         source="OSM", tags={"amenity": "place_of_worship"}))  # fmt: skip
        await db.commit()
    quest = await ask(c, 40)
    assert quest["extra"]["goal"]["name"] != "St Mary's Church"
    assert quest["extra"]["goal"]["kind"] in ("CREATURE", "TILE")


def test_the_words_keep_the_voice_and_fit_their_columns():
    widths = {c.name: c.type.length for c in QuestInstance.__table__.c if getattr(c.type, "length", None)}
    for minutes in sealed.MINUTES:
        title = sealed.title_for(minutes)
        assert len(title) <= widths["title"] and not violations(title, glossary=True)
    assert len(sealed.TEMPLATE_ID) <= widths["template_id"] and len(sealed.QUEST_TYPE) <= widths["quest_type"]
    assert not violations(sealed.DESCRIPTION, glossary=True)
    assert not violations(sealed.OBJECTIVE_TITLE, glossary=True)
    from app.quests.models import QuestObjective

    assert len(sealed.OBJECTIVE_TITLE) <= QuestObjective.__table__.c.title.type.length


async def test_an_unknown_player_position_still_gets_a_goal(explorer_client):
    """Nowhere near any place or creature: a tile on the map, about as far."""
    c = explorer_client
    far = {"latitude": 10.0, "longitude": 10.0}
    quest = await ask(c, 20, **far)
    goal = quest["extra"]["goal"]
    assert goal["kind"] in ("TILE", "CREATURE", "PLACE")
    async with get_session_factory()() as db:
        row = await db.get(QuestInstance, uuid.UUID(quest["id"]))
        assert row.expires_at is not None and row.expires_at <= datetime.now(UTC) + timedelta(days=1, minutes=1)
        assert (await db.scalar(select(QuestInstance.status).where(QuestInstance.id == row.id))) == "ACCEPTED"


def out_and_back(start, end, speed_mps: float = 5.0, interval_s: float = 5.0) -> list[dict]:
    from tests.test_world_objects import line_trace

    pts = line_trace(start, end, speed_mps=speed_mps, interval_s=interval_s)
    now = datetime.now(UTC) - timedelta(hours=2)
    t0 = datetime.fromisoformat(pts[0]["timestamp"])
    for p in pts:
        p["timestamp"] = (datetime.fromisoformat(p["timestamp"]) - t0 + now).isoformat()
    return pts
