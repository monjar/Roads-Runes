"""The Hard Six (0.8.0): held, inscribed, and each changing one rule; and the
capstone skills, against legends only (SHEET_VERSION 5)."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import select

from app.characters import catalog as abilities
from app.characters.models import Character, CharacterAbility
from app.characters.sheet import SHEET_VERSION, CharacterSheet, build_sheet
from app.core.geo import destination_point
from app.db.session import get_session_factory
from app.discoveries.models import Discovery
from app.inventory import catalog
from app.inventory import service as inventory
from app.lore.voice import violations
from app.users.models import User
from app.world_objects import fight
from app.world_objects import service as world_objects
from app.world_objects.models import WorldObject
from app.world_objects.service import combat_config
from app.world_objects.spawner import RUNE_SETS
from scripts.gen_fight_fixtures import HOME, line
from tests.test_first_playable_journey import ORIGIN
from tests.test_world_objects import line_trace, ride

NOW = datetime.now(UTC)
CFG = combat_config()


def test_the_hard_six_are_holdable_each_with_one_rule_and_never_a_stone():
    hard = catalog.hard_six()
    assert hard == ["uruz", "isa", "nauthiz", "hagalaz", "thurisaz", "ingwaz"]
    rules = {r: catalog.by_id()[r]["rule"] for r in hard}
    assert rules == {
        "uruz": "CLIMB_SHARED_M",
        "isa": "WEAKENED_STAYS_DAYS",
        "nauthiz": "ENGAGE_M",
        "hagalaz": "FIND_RADIUS_M",
        "thurisaz": "ELDER_CARRIED_SCALE",
        "ingwaz": "PICKUP_REACH_M",
    }
    assert [catalog.value("uruz", r) for r in (1, 2, 3, 4)] == [500, 750, 1000, 1250]
    assert [catalog.value("thurisaz", r) for r in (1, 2, 3, 4)] == [1.5, 2.0, 2.5, 3.0]
    assert catalog.rule_text("isa", 1) == "A weakened creature stays 2 more days."
    assert catalog.rule_text("thurisaz", 2) == "Against elders and legends, your opening blow is 2× stronger."
    for rune_id in hard:
        assert catalog.holdable(rune_id)
        for rank in (1, 2, 3):
            text = catalog.rule_text(rune_id, rank)
            assert "{" not in text and text.endswith(".") and not violations(text, glossary=True), text
    # Never placed on the map: no set holds them.
    sets = [s for s in world_objects.load_config()["collectableSets"] if s["id"] in RUNE_SETS]
    pieces = {p.lower() for s in sets for p in s["pieces"]}
    assert not pieces & set(hard)


# --- in the fold -------------------------------------------------------------------


def resolve(points, foe, rules, *, elder=False, activity="RIDE", pct=None):
    sheet = CharacterSheet(rules=rules)
    cfg = sheet.foe_cfg(sheet.fight_cfg(CFG), elder=elder)
    return fight.resolve(points, foe, activity=activity, damage_pct=pct or {}, cfg=cfg)


def test_nauthiz_meets_a_creature_from_further_away():
    beside = destination_point(*destination_point(HOME[0], HOME[1], 0, 220), 270, 950)
    track = line(beside, 90, 1900, 10)
    foe = fight.Foe(HOME[0], HOME[1], 220, 220, ("ROAD", "WORD"), ("CLIMB",))
    assert resolve(track, foe, {}).outcome == "NOT_NEAR"
    assert resolve(track, foe, {"ENGAGE_M": 250}).outcome == "LOOSENED"
    assert CharacterSheet(rules={"ENGAGE_M": 100}).fight_cfg(CFG)["engageMeters"] == CFG["engageMeters"]


def test_uruz_counts_climbing_near_it_in_full_not_just_as_the_opening_blow():
    approach = line(destination_point(HOME[0], HOME[1], 180, 900), 0, 900, 10, climb=60)
    foe = fight.Foe(HOME[0], HOME[1], 220, 220, ("CLIMB", "RUNE"), ("WORD",), "TRIANGLE")
    plain = resolve(approach, foe, {})
    shared = resolve(approach, foe, {"CLIMB_SHARED_M": 1000})
    assert shared.damage["CLIMB"] > plain.damage["CLIMB"]
    assert shared.damage.get("CARRIED", 0) < plain.damage.get("CARRIED", 0)
    assert shared.taken > plain.taken
    # Every creature is folded on its own: the same climb counts for each one in reach.
    other = fight.Foe(*destination_point(HOME[0], HOME[1], 180, 400), 220, 220, ("CLIMB",), ())
    assert resolve(approach, other, {"CLIMB_SHARED_M": 1000}).damage["CLIMB"] > 0


def test_thurisaz_strengthens_the_opening_blow_on_elders_only():
    climb = line(destination_point(HOME[0], HOME[1], 180, 500), 0, 900, 10, climb=60)
    foe = fight.Foe(HOME[0], HOME[1], 400, 400, ("CLIMB", "RUNE"), ("WORD",), "TRIANGLE")
    rules = {"ELDER_CARRIED_SCALE": 2.0}
    plain = resolve(climb, foe, rules, elder=False)
    elder = resolve(climb, foe, rules, elder=True)
    assert elder.damage["CARRIED"] == plain.damage["CARRIED"] * 2
    sheet = CharacterSheet(rules=rules)
    assert sheet.foe_cfg(CFG, elder=True)["carriedCap"] == CFG["carriedCap"]
    assert sheet.legend_cfg(CFG)["carriedFraction"] == CFG["carriedFraction"] * 2


def test_isa_keeps_a_weakened_creature_longer():
    spawned = NOW - timedelta(days=1)
    obj = WorldObject(
        kind="MONSTER", tier=2, bounty=False, latitude=0.0, longitude=0.0, payload={}, spawned_at=spawned,
        expires_at=spawned + timedelta(days=3),
    )  # fmt: skip
    report = fight.FightReport("LOOSENED", 220, 220, 120)
    world_objects._wound(obj, "ride-1", NOW.date().isoformat(), report, NOW, stays_extra_days=3)
    assert obj.expires_at == NOW + timedelta(days=2 + 3)
    late = WorldObject(
        kind="MONSTER", tier=2, bounty=False, latitude=0.0, longitude=0.0, payload={}, spawned_at=NOW - timedelta(days=6),
        expires_at=NOW + timedelta(hours=1),
    )  # fmt: skip
    world_objects._wound(late, "ride-1", NOW.date().isoformat(), report, NOW, stays_extra_days=3)
    assert late.expires_at == late.spawned_at + timedelta(days=7 + 3), "the week's cap moves out too"


# --- through a journey ---------------------------------------------------------------


async def hold_and_inscribe(client, rune_id: str) -> None:
    async with get_session_factory()() as db:
        user = await db.scalar(select(User).where(User.apple_subject == "dev:tester"))
        hero = await db.scalar(select(Character).where(Character.user_id == user.id))
        await inventory.give_rune(db, hero, rune_id, key=f"test:{rune_id}")
        await db.commit()
    r = await client.put("/runes/inscribed", json={"runes": [rune_id]})
    assert r.status_code == 200, r.text


def recent(start, end) -> list[dict]:
    pts = line_trace(start, end, speed_mps=5.0, and_back=False)
    shift = (NOW - timedelta(minutes=40)) - datetime.fromisoformat(pts[-1]["timestamp"])
    for p in pts:
        p["timestamp"] = (datetime.fromisoformat(p["timestamp"]) + shift).isoformat()
    return pts


async def test_ingwaz_picks_up_a_chest_from_further_away(explorer_client):
    chest_at = destination_point(ORIGIN[0], ORIGIN[1], 0, 85)
    async with get_session_factory()() as db:
        user = await db.scalar(select(User).where(User.apple_subject == "dev:tester"))
        chest = WorldObject(
            user_id=user.id, kind="CHEST", status="SPAWNED", tier=1, latitude=chest_at[0], longitude=chest_at[1],
            seed=str(uuid.uuid4()), reward_ac=20, payload={"name": "Old chest"}, spawned_at=NOW - timedelta(hours=3),
            expires_at=NOW + timedelta(days=1),
        )  # fmt: skip
        db.add(chest)
        await db.commit()
        chest_id = str(chest.id)
    await hold_and_inscribe(explorer_client, "ingwaz")
    # Rank I reaches 60 m: the chest 85 m off the line stays shut.
    west, east = destination_point(*ORIGIN, 270, 800), destination_point(*ORIGIN, 90, 800)
    summary = await ride(explorer_client, recent(west, east))
    assert chest_id not in {c["id"] for c in summary["worldObjects"]["claimed"]}
    from app.economy import service as economy

    for _ in range(2):  # rank II (80 m), then rank III (100 m): two stones and some coins each
        async with get_session_factory()() as db:
            user = await db.scalar(select(User).where(User.apple_subject == "dev:tester"))
            hero = await db.scalar(select(Character).where(Character.user_id == user.id))
            await economy.credit(db, user.id, 500, "TEST")
            for _ in range(2):
                await inventory.give_rune(db, hero, "ingwaz", key=f"test:shard:{uuid.uuid4()}")
            await db.commit()
        r = await explorer_client.post("/runes/ingwaz/rank")
        assert r.status_code == 200, r.text
    later = [
        {**p, "timestamp": (datetime.fromisoformat(p["timestamp"]) + timedelta(minutes=20)).isoformat()}
        for p in recent(west, east)
    ]
    summary = await ride(explorer_client, later)
    assert chest_id in {c["id"] for c in summary["worldObjects"]["claimed"]}


async def test_hagalaz_finds_hidden_places_further_from_the_journey(explorer_client):
    near = destination_point(ORIGIN[0], ORIGIN[1], 0, 120)
    async with get_session_factory()() as db:
        db.add(Discovery(name="Quiet Garden", category="NATURE", latitude=near[0], longitude=near[1], source="OSM",
                         tags={"leisure": "garden"}))  # fmt: skip
        await db.commit()
    west, east = destination_point(*ORIGIN, 270, 800), destination_point(*ORIGIN, 90, 800)
    plain = await ride(explorer_client, recent(west, east))
    assert "Quiet Garden" not in {d["name"] for d in plain["discoveries"]}
    await hold_and_inscribe(explorer_client, "hagalaz")
    later = [
        {**p, "timestamp": (datetime.fromisoformat(p["timestamp"]) + timedelta(minutes=20)).isoformat()}
        for p in recent(west, east)
    ]
    found = await ride(explorer_client, later)
    assert "Quiet Garden" in {d["name"] for d in found["discoveries"]}


# --- the capstones ---------------------------------------------------------------------


def test_four_capstones_at_class_level_twenty_against_legends_only():
    caps = [a for a in abilities.abilities() if a["requiredClassLevel"] == 20]
    assert {(a["characterClass"], a["name"]) for a in caps} == {
        ("EXPLORER", "Fog Breaker"),
        ("WIZARD", "Rune Master"),
        ("WARRIOR", "Giant Toppler"),
        ("SCRIBE", "Loremaster"),
    }
    for a in caps:
        assert a["maxRank"] == 1 and abilities.is_working(a)
        assert all(e["type"] in ("VS_LEGENDS_PCT", "LEGEND_WORD_RADIUS_M") for e in a["effects"])
    assert abilities.effect_total_kindless({"warrior_vanguard": 2}, "VS_ELDERS_PCT") == 0.2


async def test_the_capstones_are_on_the_sheet_and_the_legend_fold_reads_them(explorer_client):
    async with get_session_factory()() as db:
        user = await db.scalar(select(User).where(User.apple_subject == "dev:tester"))
        hero = await db.scalar(select(Character).where(Character.user_id == user.id))
        hero.character_class = "SCRIBE"
        hero.class_level = 20
        hero.abilities.append(CharacterAbility(character_id=hero.id, ability_id="scribe_loremaster", rank=1))
        await db.commit()
        sheet = build_sheet(await db.get(Character, hero.id))
    assert sheet.version == SHEET_VERSION == 5
    assert sheet.vs_legends_pct == {"WORD": 0.25} and sheet.legend_word_radius_m == 500
    assert sheet.damage_pct.get("WORD", 0) == 0.30, "against creatures, nothing changes"
    assert CharacterSheet.from_dict(sheet.to_dict()) == sheet
    assert sheet.to_dict()["vsLegendsPct"] == {"WORD": 0.25} and sheet.to_dict()["legendWordRadiusMeters"] == 500
    assert sheet.pct_against_legend(made_good_m=0, foot=False)["WORD"] == 0.30 + 0.25
    assert sheet.legend_cfg(CFG)["wordRadiusMeters"] == 500
    # An older sheet reads as one without them.
    old = CharacterSheet.from_dict({k: v for k, v in sheet.to_dict().items() if k not in ("vsLegendsPct",)})
    assert old.vs_legends_pct == {}
