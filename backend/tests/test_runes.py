"""Runes as the build, waking, deeds and the last three knacks (docs/ROADMAP.md, 0.7.0)."""

from __future__ import annotations

import math
import random
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select

from app.characters.models import Character, CharacterAbility
from app.characters.sheet import CharacterSheet, build_sheet
from app.core.geo import destination_point
from app.db.session import get_session_factory
from app.inventory import catalog, deeds, service
from app.inventory.models import RuneCut
from app.rides.validation import CleanPoint
from app.world_objects import service as world_objects
from app.world_objects.service import combat_config
from app.world_objects.spawner import Anchor, _pick_piece
from tests.test_effort_combat import place_monster
from tests.test_first_playable_journey import ORIGIN
from tests.test_world_objects import ride

NOW = datetime.now(UTC)


@pytest.fixture(autouse=True)
def effort_on(settings, monkeypatch):
    monkeypatch.setattr(settings, "feature_flags", "effort_combat")
    return settings


async def me(client) -> Character:
    user_id = uuid.UUID((await client.get("/users/me")).json()["id"])
    async with get_session_factory()() as db:
        return (await db.execute(select(Character).where(Character.user_id == user_id))).scalar_one()


async def hold(client, *rune_ids: str, inscribe: bool = True, level: int = 30) -> None:
    character = await me(client)
    async with get_session_factory()() as db:
        row = await db.get(Character, character.id)
        row.overall_level = level
        for rune_id in rune_ids:
            await service.add_stone(db, row, rune_id, key=f"test:{rune_id}")
        if inscribe:
            await service.inscribe(db, row, list(rune_ids))
        await db.commit()


def loop_trace(centre, radius: float, *, laps: int = 1, spacing: float = 10.0, speed: float = 5.0) -> list[dict]:
    """A loop round a centre, ridden in the last hour."""
    circumference = 2 * math.pi * radius
    steps = int(circumference / spacing)
    t0 = NOW - timedelta(hours=1)
    pts = []
    for i in range(steps * laps + 1):
        lat, lon = destination_point(centre[0], centre[1], 360 * (i % steps) / steps, radius)
        pts.append(
            {
                "latitude": lat,
                "longitude": lon,
                "timestamp": (t0 + timedelta(seconds=i * spacing / speed)).isoformat(),
                "altitudeMeters": 10,
                "horizontalAccuracyMeters": 5,
                "speedMps": speed,
            }
        )
    return pts


# --- the catalogue ---------------------------------------------------------------


def test_the_road_and_ground_sixes_each_change_one_rule_and_say_it():
    ids = {r["id"] for r in catalog.book()["runes"]}
    assert ids == {
        "raido",
        "sowilo",
        "kenaz",
        "dagaz",
        "ansuz",
        "wunjo",
        "laguz",
        "berkano",
        "eihwaz",
        "ehwaz",
        "jera",
        "algiz",
    }
    for rune_id in ids:
        for rank in (1, 2, 3):
            text = catalog.rule_text(rune_id, rank)
            assert "{" not in text and text.endswith("."), (rune_id, text)
    assert catalog.slots_for_level(1) == 1 and catalog.slots_for_level(10) == 2 and catalog.slots_for_level(25) == 3
    assert catalog.ground_runes_at("NATURE", {"leisure": "park"}) == ["berkano", "jera"]
    assert catalog.ground_runes_at("PUB", {}) == []


def test_ground_six_stones_only_on_their_own_ground_and_pity_finds_one_not_held():
    cfg = world_objects.load_config()
    pond = Anchor("1", "The Pond", "NATURE", 51.5, -0.05, None, tags={"natural": "water"})
    pub = Anchor("2", "The Crown", "PUB", 51.5, -0.05, None, tags={})
    seen_at_pub = {_pick_piece(random.Random(i), pub, cfg, None)[1] for i in range(200)}
    assert not seen_at_pub & {"Laguz", "Berkano", "Eihwaz", "Ehwaz", "Jera", "Algiz"}
    seen_at_pond = {_pick_piece(random.Random(i), pond, cfg, None)[1] for i in range(200)}
    assert "Laguz" in seen_at_pond
    held = {"ansuz", "raido", "kenaz", "wunjo", "sowilo"}
    for i in range(50):
        the_set, piece = _pick_piece(random.Random(i), pub, cfg, {"held": held, "pity": True})
        if the_set["id"] == "RUNES":
            assert piece == "Dagaz", "after enough repeats the stone is one not held"


# --- holding, ranks, slots -----------------------------------------------------------


async def test_a_stone_holds_a_rune_then_counts_towards_its_next_rank(explorer_client):
    c = explorer_client
    character = await me(c)
    async with get_session_factory()() as db:
        row = await db.get(Character, character.id)
        first = await service.add_stone(db, row, "raido", key="stone:a")
        again = await service.add_stone(db, row, "raido", key="stone:a")
        await service.add_stone(db, row, "raido", key="stone:b")
        await service.add_stone(db, row, "raido", key="stone:c")
        await db.commit()
    assert first == {"rune": "raido", "new": True, "rank": 1, "shards": 0}
    assert again is None, "the same stone counts once"
    body = (await c.get("/runes")).json()
    raido = next(r for r in body["runes"] if r["id"] == "raido")
    assert raido["held"] and raido["rank"] == 1 and raido["shards"] == 2
    assert raido["nextRank"] == {"shards": 2, "coins": 100}
    # Rank II costs coins the player does not have yet.
    r = await c.post("/runes/raido/rank")
    assert r.status_code == 409 and r.json()["error"]["code"] == "INSUFFICIENT_AC"
    async with get_session_factory()() as db:
        from app.economy import service as economy

        await economy.credit(db, character.user_id, 500, "ADJUSTMENT")
        await db.commit()
    r = await c.post("/runes/raido/rank")
    assert r.status_code == 200
    raido = next(x for x in r.json()["runes"] if x["id"] == "raido")
    assert raido["rank"] == 2 and raido["shards"] == 0
    assert "2.5×" in raido["rule"]


async def test_inscribing_takes_held_runes_into_the_slots_the_level_opens(explorer_client):
    c = explorer_client
    await hold(c, "raido", "kenaz", inscribe=False, level=5)
    r = await c.put("/runes/inscribed", json={"runes": ["raido", "kenaz"]})
    assert r.status_code == 409 and r.json()["error"]["code"] == "NO_SLOT"
    r = await c.put("/runes/inscribed", json={"runes": ["sowilo"]})
    assert r.status_code == 409 and r.json()["error"]["code"] == "RUNE_NOT_HELD"
    r = await c.put("/runes/inscribed", json={"runes": ["raido"]})
    assert r.status_code == 200 and r.json()["inscribed"] == ["raido"] and r.json()["slots"] == 1
    sheet = (await c.get("/character")).json()["sheet"]
    assert sheet["inscribed"] == {"raido": 1} and sheet["rules"] == {"CARRIED_SCALE": 2.0}
    # Not while out.
    r = await c.post("/rides", json={"clientRideId": str(uuid.uuid4()), "startedAt": NOW.isoformat()})
    assert r.status_code == 201
    r = await c.put("/runes/inscribed", json={"runes": []})
    assert r.status_code == 409 and r.json()["error"]["code"] == "LOADOUT_LOCKED"


def test_the_rules_change_the_fight_and_a_woken_rune_counts_a_rank_deeper():
    cfg = combat_config()
    sheet = CharacterSheet(
        inscribed={"raido": 1, "ansuz": 1, "dagaz": 1},
        rules=catalog.rules_for({"raido": 1, "ansuz": 1, "dagaz": 1}),
    )
    changed = sheet.fight_cfg(cfg, first_outings_today=1)
    assert changed["carriedFraction"] == cfg["carriedFraction"] * 2
    assert changed["wordRadiusMeters"] == 1000
    assert changed["minds"] == 1.0
    assert sheet.fight_cfg(cfg, first_outings_today=2)["minds"] == cfg["minds"], "only the first outing of the day"
    woken = sheet.woken("raido")
    assert woken.inscribed["raido"] == 2 and woken.rules["CARRIED_SCALE"] == 2.5
    sowilo = CharacterSheet(inscribed={"sowilo": 1}, rules=catalog.rules_for({"sowilo": 1})).woken("sowilo")
    assert sowilo.rune_reach_m == 2500


# --- waking ---------------------------------------------------------------------------


async def ride_planned(c, pts: list[dict], route_id: str | None) -> dict:
    """An outing ridden on a planned route (a rune ride), through the API."""
    from app.core.geo import haversine_m

    body = {"clientRideId": str(uuid.uuid4()), "startedAt": pts[0]["timestamp"], "routeId": route_id}
    r = await c.post("/rides", json=body)
    assert r.status_code == 201, r.text
    ride_id = r.json()["id"]
    distance = sum(
        haversine_m(a["latitude"], a["longitude"], b["latitude"], b["longitude"])
        for a, b in zip(pts, pts[1:], strict=False)
    )
    r = await c.post(
        f"/rides/{ride_id}/complete",
        json={
            "endedAt": pts[-1]["timestamp"],
            "distanceMeters": distance,
            "durationSeconds": len(pts) * 2,
            "elevationGainMeters": 0,
            "points": pts,
        },
    )
    assert r.status_code == 200, r.text
    return (await c.get(f"/rides/{ride_id}/summary")).json()


async def test_a_planned_loop_wakes_raido_and_lands_on_what_is_in_reach(explorer_client):
    c = explorer_client
    await hold(c, "raido")
    # A thing with no wish for a rune at all, near where the loop is cut.
    far = destination_point(ORIGIN[0], ORIGIN[1], 0, 800)
    object_id = await place_monster("fen-troll", tier=3, at=far, wants=["GROUND", "WORD"], minds=["CLIMB"])
    planned = await c.post(
        "/routes/rune", json={"origin": {"latitude": ORIGIN[0], "longitude": ORIGIN[1]}, "rune": "raido"}
    )
    assert planned.status_code == 200, planned.text
    summary = await ride_planned(c, loop_trace(ORIGIN, 200, laps=2), planned.json()["alternatives"][0]["id"])
    world = summary["worldObjects"]
    assert world["woken"] == ["raido"]
    async with get_session_factory()() as db:
        cut = (await db.execute(select(RuneCut).where(RuneCut.source == "WAKING"))).scalar_one()
        assert cut.rune_id == "raido" and cut.woke
    report = next((f for f in world["fights"] if f["id"] == object_id), None)
    if report is not None:  # it was within reach of the loop
        assert report["damage"].get("RUNE", 0) > 0
    cuts = (await c.get("/runes/cuts")).json()
    assert cuts and cuts[0]["runeId"] == "raido" and cuts[0]["woke"] is True
    deeds_now = (await c.get("/character/deeds")).json()
    hand = next(d for d in deeds_now["deeds"] if d["id"] == "HAND")
    assert hand["value"] >= 1 and hand["title"] == "First Cut"
    assert "First Cut" in summary["titlesUnlocked"]


async def test_the_same_loop_on_an_ordinary_outing_wakes_nothing(explorer_client):
    """Street grids make shapes; only an outing planned to cut the rune wakes it."""
    c = explorer_client
    await hold(c, "raido")
    summary = await ride_planned(c, loop_trace(ORIGIN, 200, laps=2), None)
    assert summary["worldObjects"].get("woken", []) == []


async def test_a_rune_stone_picked_up_on_an_outing_is_held(explorer_client):
    c = explorer_client
    character = await me(c)
    async with get_session_factory()() as db:
        from app.world_objects.models import WorldObject

        obj = WorldObject(
            user_id=character.user_id,
            kind="COLLECTABLE",
            status="SPAWNED",
            tier=1,
            latitude=ORIGIN[0],
            longitude=ORIGIN[1],
            seed=str(uuid.uuid4()),
            reward_ac=10,
            payload={"name": "Kenaz (Road Six)", "setId": "RUNES", "piece": "Kenaz"},
            spawned_at=NOW - timedelta(hours=2),
            expires_at=NOW + timedelta(days=1),
        )
        db.add(obj)
        await db.commit()
    from tests.test_effort_combat import past

    summary = await ride(c, past(500, 1000))
    assert {"rune": "kenaz", "new": True, "rank": 1, "shards": 0} in summary.get("runesFound", []) or any(
        r["id"] == "kenaz" and r["held"] for r in (await c.get("/runes")).json()["runes"]
    )


# --- the Ground Six, Wunjo, Algiz --------------------------------------------------------


def test_the_ground_six_add_a_want_to_the_first_few_of_their_family():
    from app.world_objects.fight import FightPoint
    from app.world_objects.models import WorldObject

    def thing(species: str, metres: float) -> WorldObject:
        lat, lon = destination_point(ORIGIN[0], ORIGIN[1], 90, metres)
        return WorldObject(id=uuid.uuid4(), kind="MONSTER", latitude=lat, longitude=lon, payload={"speciesId": species})

    first, second, other = thing("fen-troll", 100), thing("bog-wraith", 600), thing("rook-lord", 300)
    pts = [FightPoint(*destination_point(ORIGIN[0], ORIGIN[1], 90, m), 10.0) for m in range(0, 800, 10)]
    sheet = CharacterSheet(rules={"WANTS_ROAD_AT_WATER": 1})
    wants = world_objects._ground_wants(sheet, [second, other, first], pts, combat_config(), "RIDE")
    assert wants == {first.id: {"ROAD"}}, "the first water thing met, and only one at rank I"


async def test_a_long_stop_at_a_cafe_is_the_word_with_wunjo(explorer_client):
    from app.discoveries.models import Discovery

    async with get_session_factory()() as db:
        db.add(
            Discovery(
                name="The Corner Café", category="CAFE", latitude=ORIGIN[0], longitude=ORIGIN[1], source="OSM", tags={}
            )
        )
        await db.commit()
    start = NOW
    stopped = [
        CleanPoint(ORIGIN[0] + 0.00001 * (i % 2), ORIGIN[1], start + timedelta(seconds=10 * i), 10.0) for i in range(40)
    ]
    away = [
        CleanPoint(*destination_point(ORIGIN[0], ORIGIN[1], 90, 50 * k), start + timedelta(seconds=400 + 10 * k), 10.0)
        for k in range(1, 20)
    ]
    async with get_session_factory()() as db:
        assert await world_objects._stops_as_words(db, stopped + away, 300) == [0]
        assert await world_objects._stops_as_words(db, stopped[:20] + away, 300) == [], "three minutes is not five"


# --- the last three knacks ------------------------------------------------------------------


async def test_cartographer_reads_a_ring_round_new_ground(explorer_client):
    from app.exploration.models import UserExplorationCell
    from tests.test_effort_combat import past

    c = explorer_client
    character = await me(c)
    async with get_session_factory()() as db:
        row = await db.get(Character, character.id)
        row.class_level = 5
        row.abilities.append(CharacterAbility(character_id=row.id, ability_id="explorer_cartographer", rank=1))
        await db.commit()
    await ride(c, past(500, 1500))
    async with get_session_factory()() as db:
        revealed = (
            (
                await db.execute(
                    select(UserExplorationCell).where(
                        UserExplorationCell.user_id == character.user_id,
                        UserExplorationCell.discovered_via == "CARTOGRAPHER",
                    )
                )
            )
            .scalars()
            .all()
        )
    assert revealed, "no ring read round the new cells"


def test_deed_tiers_and_titles():
    legs = next(d for d in deeds.DEEDS if d["id"] == "LEGS")
    assert deeds.tier_for(legs, 49.9) == 0 and deeds.tier_for(legs, 50) == 1 and deeds.tier_for(legs, 6000) == 5
    from app.progression import titles

    for deed in deeds.DEEDS:
        for tier in range(1, 6):
            assert deeds.title_slug(deed["id"], tier) in titles.by_slug()


def test_sheet_round_trips_with_runes():
    sheet = build_sheet(None)
    assert sheet.inscribed == {} and sheet.rules == {}
    with_runes = CharacterSheet(inscribed={"kenaz": 2}, rules={"REVEAL_RINGS": 2.0})
    assert CharacterSheet.from_dict(with_runes.to_dict()) == with_runes
