"""Ride anywhere (0.9.2): a journey with no route and no quest, and the world that
grows round it as it goes (docs/API.md, `GET /world/around`)."""

from __future__ import annotations

import asyncio
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select

from app.core.geo import destination_point
from app.core.security import utcnow
from app.db.session import get_session_factory
from app.discoveries import osm_import
from app.world_objects import service as world_objects
from app.world_objects.models import WorldObject
from tests.test_first_playable_journey import ORIGIN, seed_discoveries
from tests.test_world_objects import line_trace, remake, ride, spawned

T0 = datetime(2026, 6, 1, 9, 0, tzinfo=UTC)


async def recording_ride(c) -> str:
    r = await c.post("/rides", json={"clientRideId": str(uuid.uuid4()), "startedAt": utcnow().isoformat()})
    assert r.status_code == 201, r.text
    assert r.json()["status"] == "RECORDING" and r.json()["routeId"] is None and r.json()["questId"] is None
    return r.json()["id"]


async def around(c, ride_id: str | None = None, at=ORIGIN) -> dict:
    params = {"latitude": at[0], "longitude": at[1]}
    if ride_id:
        params["rideId"] = ride_id
    r = await c.get("/world/around", params=params)
    assert r.status_code == 200, r.text
    return r.json()


async def expire_everything() -> None:
    async with get_session_factory()() as db:
        for row in (await db.execute(select(WorldObject))).scalars():
            row.expires_at = datetime.now(UTC) - timedelta(hours=1)
        await db.commit()


# --- a journey with no route ------------------------------------------------------


async def test_a_journey_with_no_route_and_no_quest_pays_for_the_ground_and_what_it_passed(explorer_client):
    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    chest = next(o for o in await spawned(c) if o["kind"] == "CHEST")
    start = destination_point(chest["latitude"], chest["longitude"], 180, 900)
    summary = await ride(c, line_trace(start, (chest["latitude"], chest["longitude"]), 5.0))
    assert summary["ride"]["status"] == "PROCESSED", summary["flags"]
    assert summary["ride"]["routeId"] is None and summary["ride"]["questId"] is None
    assert summary["quest"] is None and summary["questCompletion"] is None
    assert summary["xpAwarded"] > 0 and summary["newCells"] > 0
    assert chest["id"] in {o["id"] for o in summary["worldObjects"]["claimed"]}


# --- what was placed on the way counts from when it was placed ---------------------


async def test_a_chest_placed_after_the_rider_went_past_is_not_paid_for(explorer_client):
    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    chest = next(o for o in await spawned(c) if o["kind"] == "CHEST")
    here = (chest["latitude"], chest["longitude"])
    # One way through it: past it about two minutes in, on at 5 m/s for another two.
    pts = line_trace(destination_point(*here, 180, 600), destination_point(*here, 0, 600), 5.0, and_back=False)
    started = datetime.fromisoformat(pts[0]["timestamp"])
    passed = next(i for i, p in enumerate(pts) if abs(p["latitude"] - here[0]) < 0.0003)

    # Placed a minute after the rider was beside it: the fixes before do not open it.
    await remake(chest["id"], spawned_at=started + timedelta(seconds=passed * 5 + 60))
    summary = await ride(c, pts)
    assert chest["id"] not in {o["id"] for o in summary["worldObjects"]["claimed"]}

    # Placed before the rider got there: opened as ever.
    await remake(chest["id"], spawned_at=started + timedelta(seconds=30))
    summary = await ride(c, pts)
    assert chest["id"] in {o["id"] for o in summary["worldObjects"]["claimed"]}


async def test_a_creature_placed_mid_journey_is_fought_only_from_then_on(explorer_client, settings, monkeypatch):
    """Effort is damage: a creature placed behind the rider is not hit by the road
    already ridden past it."""
    from tests.test_effort_combat import past, place_monster

    monkeypatch.setattr(settings, "feature_flags", "effort_combat")
    pts = past(950, 1900)
    started = datetime.fromisoformat(pts[0]["timestamp"])
    object_id = await place_monster("fen-troll", tier=2, wants=["GROUND", "WORD"], minds=["CLIMB"])
    # It came when the rider was already 700 m past it (the journey is 380 s long).
    await remake(object_id, spawned_at=started + timedelta(seconds=(950 + 700) / 5))
    summary = await ride(explorer_client, pts)
    assert not summary["worldObjects"]["fights"]
    assert {m["id"]: m["reason"] for m in summary["worldObjects"]["missed"]}[object_id] == "NOT_NEAR"


def test_only_a_thing_placed_during_the_journey_is_cut():
    from app.rides.validation import CleanPoint

    points = [CleanPoint(51.0, 0.0, T0 + timedelta(seconds=10 * i)) for i in range(10)]
    obj = WorldObject(spawned_at=T0 + timedelta(seconds=35))
    ended = points[-1].timestamp
    assert world_objects.from_spawn(obj, points, T0, ended) == 4
    obj.spawned_at = T0 - timedelta(hours=1)
    assert world_objects.from_spawn(obj, points, T0, ended) == 0
    # After it ended: a late upload, judged as it always was.
    obj.spawned_at = ended + timedelta(days=30)
    assert world_objects.from_spawn(obj, points, T0, ended) == 0


# --- the spawn cache waits for the places -----------------------------------------

MILAN = (45.4642, 9.19)


async def test_new_ground_is_spawned_on_once_its_places_arrive(explorer_client, settings, monkeypatch):
    """A tile looked at while its places were still being fetched used to be marked
    done for the day, and stayed empty until midnight."""
    monkeypatch.setattr(settings, "poi_import_enabled", True)
    released = asyncio.Event()

    async def fetch(bbox):
        await released.wait()
        south, west, north, east = bbox
        if not (south <= MILAN[0] < north and west <= MILAN[1] < east):
            return []
        return [
            {"type": "node", "id": 9_000 + i, "lat": MILAN[0] + dy, "lon": MILAN[1] + dx,
             "tags": {"name": f"Piazza {i}", "leisure": "park"}}
            for i, (dy, dx) in enumerate([(0.004, 0.0), (0.0, 0.006), (-0.005, 0.002), (0.008, -0.004),
                                          (-0.002, -0.009), (0.011, 0.007), (-0.009, 0.010), (0.002, 0.013)])
        ]  # fmt: skip

    monkeypatch.setattr(osm_import, "overpass_fetcher", lambda _settings: fetch)
    monkeypatch.setattr(osm_import, "places_fetcher", lambda _settings: fetch)
    world_objects.forget_checks()
    where = {"latitude": MILAN[0], "longitude": MILAN[1], "radiusMeters": 6000}
    ride_id = await recording_ride(explorer_client)

    # The first look starts the import and finds nowhere to put anything yet.
    r = await explorer_client.get("/world/objects", params=where)
    assert r.status_code == 200, r.text
    assert r.json() == []
    first = await around(explorer_client, ride_id, at=MILAN)
    assert first["importing"] is True and first["objects"] == [] and first["places"] == []

    released.set()
    await osm_import.drain()

    # The next look spawns on the places that came.
    r = await explorer_client.get("/world/objects", params=where)
    assert r.status_code == 200, r.text
    assert r.json(), "the tile stayed empty after its places arrived"
    world_objects._ride_spawns.clear()
    again = await around(explorer_client, ride_id, at=MILAN)
    assert again["importing"] is False
    assert again["objects"] and {p["name"] for p in again["places"]} >= {"Piazza 0", "Piazza 1"}


# --- GET /world/around ------------------------------------------------------------


async def test_around_a_recording_journey_places_things_once_a_minute_and_twenty_times(explorer_client):
    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    ride_id = await recording_ride(c)

    first = await around(c, ride_id)
    assert set(first) == {"objects", "places", "importing"}
    assert first["objects"] and first["importing"] is False
    assert "The Crown" in {p["name"] for p in first["places"]}
    assert all(
        {"id", "name", "category", "latitude", "longitude", "discoveredByUser"} <= set(p) for p in first["places"]
    )

    # Everything gone and the tile forgotten: within the minute nothing new comes.
    await expire_everything()
    world_objects._checked.clear()
    assert (await around(c, ride_id))["objects"] == []

    # A minute on, it may place again.
    count, last = world_objects._ride_spawns[ride_id]
    world_objects._ride_spawns[ride_id] = (count, last - timedelta(seconds=61))
    assert (await around(c, ride_id))["objects"]

    # Twenty times a journey, and no more.
    await expire_everything()
    world_objects._checked.clear()
    world_objects._ride_spawns[ride_id] = (world_objects.RIDE_SPAWN_MAX, utcnow() - timedelta(hours=1))
    assert (await around(c, ride_id))["objects"] == []


async def test_around_without_a_recording_journey_only_shows_what_is_there(explorer_client):
    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    assert (await around(c))["objects"] == []
    assert (await around(c, str(uuid.uuid4())))["objects"] == []
    placed = await spawned(c)
    shown = await around(c)
    assert {o["id"] for o in shown["objects"]} == {o["id"] for o in placed if o["kind"] != "LAIR"}


async def test_around_is_refused_with_the_flag_off(explorer_client, settings, monkeypatch):
    monkeypatch.setattr(settings, "feature_flags", "!ride_anywhere")
    r = await explorer_client.get("/world/around", params={"latitude": ORIGIN[0], "longitude": ORIGIN[1]})
    assert r.status_code == 403
    assert r.json()["error"]["code"] == "FEATURE_DISABLED"


def test_the_flag_is_on_by_default(settings):
    assert settings.flags["ride_anywhere"] is True


@pytest.fixture(autouse=True)
def fresh_limits():
    world_objects.forget_checks()
    yield
    world_objects.forget_checks()
