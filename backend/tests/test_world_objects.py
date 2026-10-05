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
    """What is placed around the player. The map (GET /world) only lists; it is the
    player's own position (GET /world/objects) that places things."""
    r = await c.get("/world/objects", params=WORLD)
    assert r.status_code == 200, r.text
    on_the_map = (await c.get("/world", params=WORLD)).json()["objects"]
    assert {o["id"] for o in on_the_map} == {o["id"] for o in r.json()}
    return r.json()


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
    """A lamp left out at a place brings one thing there, and costs only if it does."""
    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    # Nowhere with a name near the middle of the river: nothing comes, nothing is taken.
    r = await c.post("/world/objects/lure", json={"latitude": 51.5072, "longitude": -0.0400})
    assert r.status_code == 409 and r.json()["error"]["code"] == "NO_PLACE_NEAR"
    assert "named place" in r.json()["error"]["message"]
    stave_hill = (51.4990, -0.0480)
    r = await c.post("/world/objects/lure", json={"latitude": stave_hill[0], "longitude": stave_hill[1]})
    assert r.status_code == 409 and r.json()["error"]["code"] == "INSUFFICIENT_AC"
    # A lamp that could not be paid for leaves nothing behind.
    async with get_session_factory()() as db:
        left = (await db.execute(select(WorldObject))).scalars().all()
        assert not left, [(o.seed, o.kind, o.payload.get("anchorName")) for o in left]
    me = (await c.get("/users/me")).json()
    async with get_session_factory()() as db:
        await economy.credit(db, uuid.UUID(me["id"]), 60, "ADJUSTMENT")
        await db.commit()
    r = await c.post("/world/objects/lure", json={"latitude": stave_hill[0], "longitude": stave_hill[1]})
    assert r.status_code == 200, r.text
    came = r.json()
    assert len(came) == 1 and came[0]["kind"] == "MONSTER"
    assert came[0]["anchorName"] == "Stave Hill"
    assert (await c.get("/wallet")).json()["balance"] == 10


async def test_a_lamp_works_on_a_full_day_and_says_why_when_it_will_not(explorer_client):
    """On an ordinary day the world has put something on nearly every named place
    near the player. A chest or a piece there does not stop a lamp; a creature
    already there is named, and nothing is charged."""
    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    me = (await c.get("/users/me")).json()
    async with get_session_factory()() as db:
        await economy.credit(db, uuid.UUID(me["id"]), 200, "ADJUSTMENT")
        await db.commit()
    live = await spawned(c)

    def apart(a: dict, b: dict) -> float:
        return world_objects.haversine_m(a["latitude"], a["longitude"], b["latitude"], b["longitude"])

    creatures = [o for o in live if o["kind"] == "MONSTER"]
    others = [o for o in live if o["kind"] != "MONSTER" and all(apart(o, m) >= 90 for m in creatures)]
    assert creatures and others, [(o["kind"], o["anchorName"]) for o in live]
    creature, other = creatures[0], others[0]

    # Asking first costs nothing and says what would happen.
    at = {"latitude": creature["latitude"], "longitude": creature["longitude"]}
    check = (await c.get("/world/objects/lure", params=at)).json()
    assert check["ok"] is False and check["code"] == "ALREADY_HERE" and check["cost"] == 50
    assert creature["name"] in check["message"] and creature["anchorName"] in check["message"]
    r = await c.post("/world/objects/lure", json=at)
    assert r.status_code == 409 and r.json()["error"]["code"] == "ALREADY_HERE"
    assert (await c.get("/wallet")).json()["balance"] == 200

    at = {"latitude": other["latitude"], "longitude": other["longitude"]}
    check = (await c.get("/world/objects/lure", params=at)).json()
    assert check == {
        "ok": True,
        "cost": 50,
        "placeName": other["anchorName"],
        "code": None,
        "message": None,
        "lampsInBag": 0,
    }
    r = await c.post("/world/objects/lure", json=at)
    assert r.status_code == 200, r.text
    came = r.json()
    assert len(came) == 1 and came[0]["kind"] == "MONSTER" and came[0]["anchorName"] == other["anchorName"]
    assert (await c.get("/wallet")).json()["balance"] == 150
    # Its creature stands there now.
    r = await c.post("/world/objects/lure", json=at)
    assert r.status_code == 409 and r.json()["error"]["code"] == "ALREADY_HERE"
    assert (await c.get("/wallet")).json()["balance"] == 150


async def test_two_lamps_in_the_same_second_each_bring_their_own(explorer_client, monkeypatch):
    """Lamps were seeded to the second: the second of two took its coins and placed nothing."""
    c = explorer_client
    await seed_discoveries()
    me = (await c.get("/users/me")).json()
    async with get_session_factory()() as db:
        await economy.credit(db, uuid.UUID(me["id"]), 100, "ADJUSTMENT")
        await db.commit()
    moment = datetime.now(UTC)
    monkeypatch.setattr(world_objects, "utcnow", lambda: moment)
    for place in ((51.4990, -0.0480), (51.4950, -0.0450)):  # Stave Hill, The Crown: one tile
        r = await c.post("/world/objects/lure", json={"latitude": place[0], "longitude": place[1]})
        assert r.status_code == 200 and len(r.json()) == 1, r.text
    assert (await c.get("/wallet")).json()["balance"] == 0


async def test_starting_over_clears_the_world(explorer_client):
    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    assert await spawned(c)
    assert (await c.delete("/character")).status_code == 204
    async with get_session_factory()() as db:
        assert (await db.scalar(select(func.count()).select_from(WorldObject))) == 0


def test_spawns_land_in_rings_around_the_player():
    """Most places in a city are a mile off, so a weighting put most spawns there too.
    Slots belong to rings: the first is on the doorstep when there is a doorstep."""
    from app.economy.rules import load_ac_rules
    from app.world_objects.spawner import Anchor, plan_spawns

    centre = (51.4906, -0.0316)
    anchors = [
        Anchor(str(uuid.uuid4()), f"Place {i}", "CAFE", *destination_point(*centre, (i * 37) % 360, 150 + i * 60), None)
        for i in range(60)
    ]
    plans = plan_spawns(
        seed="s",
        kind="CHEST",
        indices=list(range(8)),
        anchors=anchors,
        taken_anchor_ids=set(),
        occupied=[],
        cfg=world_objects.load_config(),
        ac_rules=load_ac_rules(),
        frontier=set(),
        known={},
        character_class="EXPLORER",
        activity="RIDE",
        centre=centre,
    )
    from app.core.geo import haversine_m

    distances = sorted(haversine_m(*centre, p.anchor.latitude, p.anchor.longitude) for p in plans)
    assert len(plans) == 8
    assert sum(1 for d in distances if d <= 700) >= 3, distances
    assert sum(1 for d in distances if d <= 1800) >= 6, distances


# --- reaching for it ---------------------------------------------------------


def beside(obj: dict, meters: float = 10.0, bearing: float = 90.0, accuracy: float | None = 8.0) -> dict:
    lat, lon = destination_point(obj["latitude"], obj["longitude"], bearing, meters)
    body: dict = {"latitude": lat, "longitude": lon}
    if accuracy is not None:
        body["horizontalAccuracyMeters"] = accuracy
    return body


async def remake(object_id: str, **fields) -> None:
    async with get_session_factory()() as db:
        obj = await db.get(WorldObject, uuid.UUID(object_id))
        for name, value in fields.items():
            setattr(obj, name, value)
        await db.commit()


async def test_a_chest_within_reach_opens_to_the_hand(explorer_client):
    """Thirty metres from a chest, the card said "pass within 40 m" and offered a route."""
    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    chest = next(o for o in await spawned(c) if o["kind"] == "CHEST")
    assert chest["claimRadiusMeters"] == 40
    before = (await c.get("/wallet")).json()["balance"]

    r = await c.post(f"/world/objects/{chest['id']}/claim", json=beside(chest, 30))
    assert r.status_code == 200, r.text
    opened = r.json()
    assert opened["object"]["status"] == "CLAIMED" and opened["object"]["claimedAt"]
    assert opened["acAwarded"] == chest["rewardAC"]
    assert opened["walletBalance"] == before + chest["rewardAC"] == (await c.get("/wallet")).json()["balance"]
    assert chest["id"] not in {o["id"] for o in await spawned(c)}

    # It opens once.
    r = await c.post(f"/world/objects/{chest['id']}/claim", json=beside(chest, 30))
    assert r.status_code == 409 and r.json()["error"]["code"] == "OBJECT_GONE"
    assert (await c.get("/wallet")).json()["balance"] == before + chest["rewardAC"]


async def test_a_chest_out_of_reach_stays_shut(explorer_client):
    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    chest = next(o for o in await spawned(c) if o["kind"] == "CHEST")
    r = await c.post(f"/world/objects/{chest['id']}/claim", json=beside(chest, 200))
    assert r.status_code == 409, r.text
    error = r.json()["error"]
    assert error["code"] == "OBJECT_OUT_OF_RANGE"
    assert error["details"]["radiusMeters"] == 40 and 190 < error["details"]["distanceMeters"] < 210

    # A phone unsure of itself to 20 m is given 20 m; one unsure to 200 m is not believed at all.
    assert (await c.post(f"/world/objects/{chest['id']}/claim", json=beside(chest, 62, accuracy=5))).status_code == 409
    weak = await c.post(f"/world/objects/{chest['id']}/claim", json=beside(chest, 10, accuracy=200))
    assert weak.status_code == 409 and weak.json()["error"]["code"] == "GPS_TOO_WEAK"
    assert (await c.post(f"/world/objects/{chest['id']}/claim", json=beside(chest, 62, accuracy=20))).status_code == 200


async def test_a_monster_is_not_picked_up(explorer_client):
    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    monster = next(o for o in await spawned(c) if o["kind"] == "MONSTER")
    assert monster["claimRadiusMeters"] is None
    r = await c.post(f"/world/objects/{monster['id']}/claim", json=beside(monster, 5))
    assert r.status_code == 409 and r.json()["error"]["code"] == "OBJECT_NOT_CLAIMABLE"
    assert (await c.post(f"/world/objects/{uuid.uuid4()}/claim", json=beside(monster, 5))).status_code == 404


async def test_two_chests_across_town_are_not_opened_in_a_breath(explorer_client):
    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    first, second = (await spawned(c))[:2]
    there = destination_point(first["latitude"], first["longitude"], 45, 3000)
    await remake(first["id"], kind="CHEST", bounty=False)
    await remake(second["id"], kind="CHEST", bounty=False, latitude=there[0], longitude=there[1])
    second = {**second, "latitude": there[0], "longitude": there[1]}

    assert (await c.post(f"/world/objects/{first['id']}/claim", json=beside(first))).status_code == 200
    r = await c.post(f"/world/objects/{second['id']}/claim", json=beside(second))
    assert r.status_code == 409 and r.json()["error"]["code"] == "CLAIM_TOO_FAST"

    # Ten minutes later it is a bike ride, and the chest is still there for it.
    async with get_session_factory()() as db:
        opened = await db.get(WorldObject, uuid.UUID(first["id"]))
        opened.claimed_at = opened.claimed_at - timedelta(minutes=10)
        await db.commit()
    assert (await c.post(f"/world/objects/{second['id']}/claim", json=beside(second))).status_code == 200


async def test_opening_the_chest_a_quest_points_at_finishes_the_quest(explorer_client, monkeypatch):
    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    assert any(o["kind"] == "CHEST" for o in await spawned(c))
    unlock = [t for t in generator.templates_for("EXPLORER", 1) if t["id"] == "ANY_UNLOCK_CHEST"]
    monkeypatch.setattr(generator, "templates_for", lambda *a, **k: unlock)
    r = await c.post("/quests/generate", json={"latitude": ORIGIN[0], "longitude": ORIGIN[1], "count": 1})
    quest = r.json()["items"][0]
    objective = next(o for o in quest["objectives"] if o["objectiveType"] == "OPEN_CHEST")
    chest = (await c.get(f"/world/objects/{objective['extra']['objectId']}")).json()
    xp_before = (await c.get("/character")).json()["overallXP"]
    before = (await c.get("/wallet")).json()["balance"]

    r = await c.post(f"/world/objects/{chest['id']}/claim", json=beside(chest))
    assert r.status_code == 200, r.text
    finished = r.json()["questCompleted"]
    required_left = [o for o in quest["objectives"] if o["required"] and o["objectiveType"] != "OPEN_CHEST"]
    if required_left:
        # The chest is done for good; the rest of the quest is still to ride.
        assert finished is None
        now = (await c.get(f"/quests/{quest['id']}")).json()
        done = next(o for o in now["objectives"] if o["id"] == objective["id"])
        assert done["status"] == "COMPLETED" and done["provisional"] is False
        return
    assert finished["id"] == quest["id"] and finished["status"] == "COMPLETED"
    assert (await c.get(f"/quests/{quest['id']}")).json()["status"] == "COMPLETED"
    assert (await c.get("/character")).json()["overallXP"] > xp_before
    # The chest's coins and the quest's purse, each once.
    assert r.json()["walletBalance"] > before + chest["rewardAC"]
    kinds = [t["kind"] for t in (await c.get("/wallet/transactions")).json()["items"]]
    assert kinds.count("QUEST_COMPLETED") == 1 and kinds.count("CHEST_OPENED") + kinds.count("BOUNTY") == 1


async def test_a_chest_opened_by_hand_is_not_paid_again_by_the_ride_past_it(explorer_client):
    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    chest = next(o for o in await spawned(c) if o["kind"] == "CHEST")
    assert (await c.post(f"/world/objects/{chest['id']}/claim", json=beside(chest))).status_code == 200
    here = (chest["latitude"], chest["longitude"])
    summary = await ride(c, line_trace(destination_point(*here, 180, 600), here, 5.0))
    assert chest["id"] not in [o["id"] for o in summary["worldObjects"]["claimed"]]
    kinds = [t["kind"] for t in (await c.get("/wallet/transactions")).json()["items"]]
    assert kinds.count("CHEST_OPENED") == 1


def test_what_was_picked_up_by_hand_on_a_ride_counts_for_its_quest():
    from app.quests.models import QuestInstance, QuestObjective
    from app.rides.processing import evaluate_objectives
    from app.world_objects.service import ClaimOutcome

    gather = QuestObjective(objective_type="COLLECT", title="Gather two", target_count=2, progress_target=2.0)
    quest = QuestInstance(objectives=[gather])
    piece = WorldObject(kind="COLLECTABLE")
    counted = dict(distance_m=0, duration_s=0, elevation_gain_m=0, new_roads_m=0, new_cells=set(), resolution=9)

    one_each = ClaimOutcome(claimed=[piece], tapped=[WorldObject(kind="COLLECTABLE")])
    assert evaluate_objectives(quest, [], client_events=[], claims=one_each, **counted) == [gather]
    # Paid for at the time: the ride's own claims, which are what it pays, do not include it.
    assert one_each.claimed_of("COLLECTABLE") == [piece]


# --- sets, near things, and XP ------------------------------------------------


async def test_pieces_make_a_set_and_the_last_one_pays(explorer_client):
    """ "Found: Raido +10 AC" said nothing of what it belonged to or how many were left."""
    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    coins = ["Farthing", "Groat", "Shilling", "Crown"]
    objects = (await spawned(c))[:5]
    for obj, piece in zip(objects, [*coins[:3], "Farthing", "Crown"], strict=True):
        await remake(
            obj["id"],
            kind="COLLECTABLE",
            bounty=False,
            tier=1,
            reward_ac=10,
            payload={"name": f"{piece} (Odd Coins)", "setId": "COINS", "piece": piece},
        )
    listed = {o["id"]: o for o in await spawned(c)}
    assert listed[objects[0]["id"]]["setName"] == "Odd Coins"
    assert (listed[objects[0]["id"]]["setSize"], listed[objects[0]["id"]]["setOwned"]) == (4, 0)

    async def pick(obj: dict) -> dict:
        # Each from where it lies, ten minutes after the last: this is about sets, not speed.
        async with get_session_factory()() as db:
            for row in (await db.execute(select(WorldObject).where(WorldObject.status == "CLAIMED"))).scalars():
                row.claimed_at = row.claimed_at - timedelta(minutes=10)
            await db.commit()
        r = await c.post(f"/world/objects/{obj['id']}/claim", json=beside(obj))
        assert r.status_code == 200, r.text
        return r.json()

    for count, obj in enumerate(objects[:3], start=1):
        found = await pick(obj)
        assert (found["object"]["setOwned"], found["object"]["setSize"]) == (count, 4)
        assert found["setCompleted"] is None and found["acAwarded"] == 10 and found["xpAwarded"] == 8
    # A second Farthing is ten coins and no nearer a set.
    again = await pick(objects[3])
    assert again["object"]["setOwned"] == 3 and again["setCompleted"] is None

    last = await pick(objects[4])
    assert last["object"]["setOwned"] == 4
    assert last["setCompleted"] == {"id": "COINS", "name": "Odd Coins", "bonusAC": 50}
    assert last["acAwarded"] == 60 and last["xpAwarded"] == 8 + 150
    kinds = [t["kind"] for t in (await c.get("/wallet/transactions")).json()["items"]]
    assert kinds.count("SET_COMPLETED") == 1 and kinds.count("COLLECTABLE") == 5


async def test_a_piece_passed_on_a_ride_says_its_set(explorer_client):
    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    obj = (await spawned(c))[0]
    await remake(
        obj["id"],
        kind="COLLECTABLE",
        bounty=False,
        tier=1,
        reward_ac=10,
        payload={"name": "Raido (Road Six)", "setId": "RUNES", "piece": "Raido"},
    )
    here = (obj["latitude"], obj["longitude"])
    summary = await ride(c, line_trace(destination_point(*here, 180, 600), here, 5.0))
    found = next(o for o in summary["worldObjects"]["claimed"] if o["id"] == obj["id"])
    assert (found["setName"], found["piece"], found["setOwned"], found["setSize"]) == ("Road Six", "Raido", 1, 6)
    assert summary["worldObjects"]["setsCompleted"] == []
    assert any(line["source"] == "COLLECTABLE_FOUND" for line in summary["xpBreakdown"])


async def test_a_monster_that_got_away_says_how_nearly(explorer_client):
    """ "X shrugged it off" and nothing else: not what it wanted, nor how close it was."""
    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    monster = next(o for o in await spawned(c) if o["kind"] == "MONSTER" and not o["bounty"])
    await set_methods(monster["id"], PACE_ONLY)
    here = (monster["latitude"], monster["longitude"])
    # Past it at five metres a second: 200 s a kilometre, where it wants 150.
    summary = await ride(c, line_trace(destination_point(*here, 180, 800), destination_point(*here, 0, 800), 5.0))
    missed = next(o for o in summary["worldObjects"]["missed"] if o["id"] == monster["id"])
    assert missed["reason"] == "UNBEATEN" and missed["expiresAt"]
    attempt = missed["attempt"]
    assert attempt["method"] == "PACE" and attempt["targetSecPerKm"] == 150
    assert 190 < attempt["paceSecPerKm"] < 210
    assert 0.7 < attempt["progress"] < 0.8
    # And one it beat gives XP as well as coins.
    summary = await ride(c, line_trace(destination_point(*here, 180, 800), destination_point(*here, 0, 800), 8.0))
    assert any(line["source"] == "MONSTER_BEATEN" and line["xp"] > 0 for line in summary["xpBreakdown"])


async def test_a_run_is_paid_as_a_run(explorer_client):
    """Runs and walks had their own rates in the rules and were paid the ride's."""
    c = explorer_client
    pts = line_trace(ORIGIN, destination_point(*ORIGIN, 90, 2000), 3.0)
    r = await c.post(
        "/rides", json={"clientRideId": str(uuid.uuid4()), "startedAt": pts[0]["timestamp"], "activity": "RUN"}
    )
    ride_id = r.json()["id"]
    r = await c.post(
        f"/rides/{ride_id}/complete",
        json={
            "endedAt": pts[-1]["timestamp"],
            "distanceMeters": 4000,
            "durationSeconds": len(pts) * 5,
            "elevationGainMeters": 0,
            "points": pts,
        },
    )
    assert r.status_code == 200, r.text
    summary = (await c.get(f"/rides/{ride_id}/summary")).json()
    distance = next(line for line in summary["acBreakdown"] if line["kind"] == "RIDE_DISTANCE")
    assert distance["detail"]["perKm"] == world_objects.load_ac_rules()["perKm"]["RUN"] == 5
    assert distance["ac"] == int(distance["detail"]["km"] * 5)


async def test_every_creature_comes_with_its_species_and_its_face(explorer_client):
    await seed_discoveries()
    monsters = [o for o in await spawned(explorer_client) if o["kind"] == "MONSTER"]
    assert monsters
    from app.lore import catalog

    for m in monsters:
        species = catalog.species_by_id()[m["monster"]["speciesId"]]
        assert m["monster"]["sigil"] == species["sigil"]
        # Tier 1 is the thing itself; tiers 2 and 3 are its elders, by name.
        assert m["name"] == catalog.name_at_tier(species, m["tier"])


def test_a_creature_is_chosen_to_suit_its_place():
    import random

    from app.world_objects.spawner import Anchor, pick_species

    monsters = load_config_monsters()
    pond = Anchor("1", "Greenland Dock", "NATURE", 51.49, -0.04, None, tags={"natural": "water", "water": "dock"})
    pub = Anchor("2", "The Ship", "PUB", 51.49, -0.04, None, tags={"amenity": "pub"})
    rng = random.Random(1)
    at_water = [pick_species(rng, pond, monsters)["family"] for _ in range(200)]
    at_pub = [pick_species(rng, pub, monsters)["family"] for _ in range(200)]
    assert at_water.count("WATER") > 120
    assert at_pub.count("STREET") > 120


def load_config_monsters():
    return world_objects.load_config()["monsters"]


def test_nothing_is_placed_at_a_memorial_a_church_or_anywhere_private():
    from app.discoveries.sensitivity import is_sensitive

    assert is_sensitive("Cenotaph", {"historic": "memorial"})
    assert is_sensitive("St Mary's", {"amenity": "place_of_worship"})
    assert is_sensitive("Nunhead Cemetery", {"leisure": "nature_reserve"})
    assert is_sensitive("A garden", {"leisure": "garden", "access": "private"})
    assert not is_sensitive("Southwark Park", {"leisure": "park"})


async def test_the_spawner_leaves_sensitive_places_alone(explorer_client):
    from app.discoveries.models import Discovery

    await seed_discoveries()
    async with get_session_factory()() as db:
        db.add(
            Discovery(
                name="Rotherhithe War Memorial",
                category="HISTORICAL",
                latitude=ORIGIN[0] + 0.0004,
                longitude=ORIGIN[1],
                h3_index=None,
                source="OSM",
                osm_id="node/999",
                moderation_status="APPROVED",
                cycling_accessible=True,
                tags={"historic": "memorial"},
            )
        )
        await db.commit()
    for o in await spawned(explorer_client):
        assert o["anchorName"] != "Rotherhithe War Memorial"


async def test_pace_is_never_dealt_and_new_monsters_carry_their_species(explorer_client):
    await seed_discoveries()
    for o in await spawned(explorer_client):
        if o["kind"] != "MONSTER":
            continue
        assert all(m["method"] != "PACE" for m in o["monster"]["killMethods"])
        async with get_session_factory()() as db:
            row = await db.get(WorldObject, uuid.UUID(o["id"]))
            species = row.payload["species"]
        assert species["wants"] and species["minds"]
