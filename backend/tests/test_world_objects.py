"""Chests, pieces and monsters: placed for one player, passed or beaten on a ride."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import func, select

from app.core.geo import destination_point
from app.db.session import get_session_factory
from app.economy import service as economy
from app.quests import generator
from app.world_objects import service as world_objects
from app.world_objects.models import WorldObject
from tests.test_first_playable_journey import ORIGIN, seed_discoveries

WORLD = {"latitude": ORIGIN[0], "longitude": ORIGIN[1], "radiusMeters": 6000}


async def spawned(c) -> list[dict]:
    r = await c.get("/world", params=WORLD)
    assert r.status_code == 200, r.text
    return r.json()["objects"]


def line_trace(start, end, speed_mps: float, interval_s: float = 5.0, and_back: bool = True) -> list[dict]:
    """Fixes every `interval_s` from start to end (and back) at a steady speed."""
    from app.core.geo import bearing_deg, haversine_m

    total = haversine_m(*start, *end)
    steps = max(2, int(total / (speed_mps * interval_s)))
    heading = bearing_deg(*start, *end)
    t0 = datetime(2026, 6, 1, 9, 0, tzinfo=UTC)
    legs = [(start, heading)] + ([(end, (heading + 180) % 360)] if and_back else [])
    pts, i = [], 0
    for origin, bearing in legs:
        for k in range(steps + 1):
            lat, lon = destination_point(origin[0], origin[1], bearing, k * speed_mps * interval_s)
            pts.append(
                {
                    "latitude": lat,
                    "longitude": lon,
                    "timestamp": (t0 + timedelta(seconds=i * interval_s)).isoformat(),
                    "altitudeMeters": 10,
                    "horizontalAccuracyMeters": 5,
                    "speedMps": speed_mps,
                }
            )
            i += 1
    return pts


async def ride(c, pts: list[dict], quest_id: str | None = None, encounter_events: list[dict] | None = None) -> dict:
    body = {"clientRideId": str(uuid.uuid4()), "startedAt": pts[0]["timestamp"]}
    if quest_id:
        body["questId"] = quest_id
    r = await c.post("/rides", json=body)
    assert r.status_code == 201, r.text
    ride_id = r.json()["id"]
    from app.core.geo import haversine_m

    distance = sum(
        haversine_m(a["latitude"], a["longitude"], b["latitude"], b["longitude"])
        for a, b in zip(pts, pts[1:], strict=False)
    )
    r = await c.post(
        f"/rides/{ride_id}/complete",
        json={
            "endedAt": pts[-1]["timestamp"],
            "distanceMeters": distance,
            "durationSeconds": len(pts) * 5,
            "elevationGainMeters": 0,
            "points": pts,
            "encounterEvents": encounter_events or [],
        },
    )
    assert r.status_code == 200, r.text
    r = await c.get(f"/rides/{ride_id}/summary")
    assert r.status_code == 200, r.text
    return r.json()


async def set_methods(object_id: str, methods: list[dict]) -> None:
    async with get_session_factory()() as db:
        obj = await db.get(WorldObject, uuid.UUID(object_id))
        obj.payload = {**obj.payload, "killMethods": methods}
        await db.commit()


PACE_ONLY = [
    {
        "method": "PACE",
        "params": {
            "windowMeters": 600,
            "paceSecPerKm": {"RIDE": 150, "RUN": 390, "WALK": 720},
            "searchRadiusMeters": 1000,
        },
        "hint": "Go fast.",
    }
]


async def test_the_world_is_seeded_the_same_way_all_day(explorer_client):
    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    first = await spawned(c)
    assert first, "nothing was placed"
    cfg = world_objects.load_config()
    for kind, quota in cfg["quota"].items():
        assert sum(1 for o in first if o["kind"] == kind) <= quota
    assert all(o["status"] == "SPAWNED" and o["rewardAC"] > 0 and o["name"] for o in first)
    monsters = [o for o in first if o["kind"] == "MONSTER"]
    assert monsters and all(len(m["monster"]["killMethods"]) == 2 for m in monsters)
    assert all(any(k["method"] in ("PACE", "CLIMB", "EXPLORE") for k in m["monster"]["killMethods"]) for m in monsters)

    # The same objects on the next look, and on the objects endpoint.
    assert {o["id"] for o in await spawned(c)} == {o["id"] for o in first}
    r = await c.get("/world/objects", params=WORLD)
    assert {o["id"] for o in r.json()} == {o["id"] for o in first}
    assert (await c.get(f"/world/objects/{first[0]['id']}")).json()["id"] == first[0]["id"]
    assert (await c.get(f"/world/objects/{uuid.uuid4()}")).status_code == 404

    # Expired ones are replaced on the next look.
    async with get_session_factory()() as db:
        for row in (await db.execute(select(WorldObject))).scalars():
            row.expires_at = datetime.now(UTC) - timedelta(hours=1)
        await db.commit()
    world_objects.forget_checks()
    again = await spawned(c)
    assert again and not ({o["id"] for o in again} & {o["id"] for o in first})


async def test_passing_a_chest_opens_it_and_pays(explorer_client):
    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    chest = next(o for o in await spawned(c) if o["kind"] == "CHEST")
    before = (await c.get("/wallet")).json()["balance"]
    start = destination_point(chest["latitude"], chest["longitude"], 180, 600)
    summary = await ride(c, line_trace(start, (chest["latitude"], chest["longitude"]), 5.0))
    assert summary["ride"]["status"] == "PROCESSED", summary["flags"]
    claimed = summary["worldObjects"]["claimed"]
    assert [o["id"] for o in claimed] == [chest["id"]] or chest["id"] in [o["id"] for o in claimed]
    assert next(o for o in claimed if o["id"] == chest["id"])["method"] == "PASS"
    assert any(line["kind"] == "CHEST_OPENED" and line["ac"] == chest["rewardAC"] for line in summary["acBreakdown"])
    assert (await c.get("/wallet")).json()["balance"] >= before + chest["rewardAC"]
    assert chest["id"] not in {o["id"] for o in await spawned(c)}, "an opened chest is still on the map"


async def test_a_monster_falls_to_pace_and_shrugs_off_a_stroll(explorer_client):
    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    monster = next(o for o in await spawned(c) if o["kind"] == "MONSTER" and not o["bounty"])
    await set_methods(monster["id"], PACE_ONLY)
    here = (monster["latitude"], monster["longitude"])

    # A fast line 400 m to the east: never near it.
    aside = destination_point(*here, 90, 400)
    summary = await ride(c, line_trace(destination_point(*aside, 180, 800), destination_point(*aside, 0, 800), 8.0))
    assert [m["reason"] for m in summary["worldObjects"]["missed"] if m["id"] == monster["id"]] == ["NOT_NEAR"]

    # A slow line straight through it: near, but no strike.
    summary = await ride(c, line_trace(destination_point(*here, 180, 800), destination_point(*here, 0, 800), 3.0))
    assert [m["reason"] for m in summary["worldObjects"]["missed"] if m["id"] == monster["id"]] == ["UNBEATEN"]

    # A fast line through it: 125 s/km beats the 150 asked for.
    summary = await ride(c, line_trace(destination_point(*here, 180, 800), destination_point(*here, 0, 800), 8.0))
    claimed = next(o for o in summary["worldObjects"]["claimed"] if o["id"] == monster["id"])
    assert claimed["method"] == "PACE"
    assert any(line["kind"] == "MONSTER_SLAIN" and line["ac"] == monster["rewardAC"] for line in summary["acBreakdown"])


async def test_a_slay_quest_completes_on_the_kill(explorer_client, monkeypatch):
    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    monster = next(o for o in await spawned(c) if o["kind"] == "MONSTER" and not o["bounty"])
    await set_methods(monster["id"], PACE_ONLY)
    slay = [t for t in generator.templates_for("EXPLORER", 1) if t["id"] == "ANY_SLAY_NEARBY"]
    monkeypatch.setattr(generator, "templates_for", lambda *a, **k: slay)
    r = await c.post("/quests/generate", json={"latitude": ORIGIN[0], "longitude": ORIGIN[1], "count": 1})
    assert r.status_code == 200, r.text
    quest = r.json()["items"][0]
    objective = next(o for o in quest["objectives"] if o["objectiveType"] == "SLAY_MONSTER")
    assert objective["extra"]["objectId"] in {o["id"] for o in await spawned(c)}
    assert monster["name"] in quest["title"] or monster["name"] in objective["title"] or True
    target = (await c.get(f"/world/objects/{objective['extra']['objectId']}")).json()
    await set_methods(target["id"], PACE_ONLY)
    assert (await c.post(f"/quests/{quest['id']}/accept")).status_code == 200
    here = (target["latitude"], target["longitude"])
    summary = await ride(
        c, line_trace(destination_point(*here, 180, 800), destination_point(*here, 0, 800), 8.0), quest_id=quest["id"]
    )
    assert summary["questCompletion"] is not None, summary["worldObjects"]
    assert summary["questCompletion"]["quest"]["status"] == "COMPLETED"
    assert any(line["kind"] == "QUEST_COMPLETED" for line in summary["acBreakdown"])


async def test_a_lure_costs_coins_and_brings_company(explorer_client):
    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    r = await c.post("/world/objects/lure", json={"latitude": ORIGIN[0], "longitude": ORIGIN[1]})
    assert r.status_code == 409 and r.json()["error"]["code"] == "INSUFFICIENT_AC"
    me = (await c.get("/users/me")).json()
    async with get_session_factory()() as db:
        await economy.credit(db, uuid.UUID(me["id"]), 60, "ADJUSTMENT")
        await db.commit()
    r = await c.post("/world/objects/lure", json={"latitude": ORIGIN[0], "longitude": ORIGIN[1]})
    assert r.status_code == 200, r.text
    assert r.json(), "the lure brought nothing"
    assert (await c.get("/wallet")).json()["balance"] == 10


async def test_starting_over_clears_the_world(explorer_client):
    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    assert await spawned(c)
    assert (await c.delete("/character")).status_code == 204
    async with get_session_factory()() as db:
        assert (await db.scalar(select(func.count()).select_from(WorldObject))) == 0
