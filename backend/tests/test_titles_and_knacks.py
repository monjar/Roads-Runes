"""Titles you can wear and knacks that do something (docs/ROADMAP.md, 0.6.2 a)."""

from __future__ import annotations

import uuid

from sqlalchemy import select

from app.characters import catalog
from app.characters.models import Character, CharacterAbility
from app.characters.sheet import CharacterSheet, build_sheet
from app.db.session import get_session_factory
from app.economy.rules import ACLine, compute_ride_ac
from app.progression import titles
from app.progression.engine import RideRewardInput, XPLine, cap_to_day, compute_ride_xp, load_xp_rules
from app.progression.service import award_title, grant


async def me(client) -> Character:
    user_id = uuid.UUID((await client.get("/users/me")).json()["id"])
    async with get_session_factory()() as db:
        return (await db.execute(select(Character).where(Character.user_id == user_id))).scalar_one()


async def set_levels(client, overall: int | None = None, trade: int | None = None) -> None:
    character = await me(client)
    async with get_session_factory()() as db:
        row = await db.get(Character, character.id)
        if overall is not None:
            row.overall_level = overall
        if trade is not None:
            row.class_level = trade
        await db.commit()


# --- titles --------------------------------------------------------------------


def test_the_catalogue_has_seven_degrees_of_being_known_and_says_how_each_is_earned():
    level = titles.level_titles()
    assert [t["name"] for t in level] == [
        "Passer-by",
        "Familiar Face",
        "Roadwise",
        "Journeyman",
        "Waywright",
        "Old Hand",
        "Known to the Roads",
    ]
    assert len(titles.catalogue()) == 51, "7 level, 9 arc, 25 deed, 5 cast and 5 legend titles"
    assert set(titles.renamed().values()) == {t["name"] for t in level}
    assert titles.level_title(7)["name"] == "Familiar Face"


async def test_a_new_character_is_a_passer_by_and_can_see_every_title(explorer_client):
    assert (await explorer_client.get("/character")).json()["title"] == "Passer-by"
    listed = (await explorer_client.get("/character/titles")).json()
    assert len(listed) == 51
    assert listed[0]["slug"] == "level-1" and listed[0]["earned"] and listed[0]["worn"]
    unearned = next(t for t in listed if t["slug"] == "level-5")
    assert not unearned["earned"] and unearned["how"] == "Reach level 5."


async def test_a_title_is_worn_when_earned_until_one_is_chosen(explorer_client):
    c = explorer_client
    # Enough XP for level 5: Familiar Face is earned and worn.
    character = await me(c)
    async with get_session_factory()() as db:
        row = await db.get(Character, character.id)
        await grant(db, row, [XPLine("ADJUSTMENT", 1700)])
        await db.commit()
    assert (await c.get("/character")).json()["title"] == "Familiar Face"

    # Choosing the first keeps it, through the next level title.
    r = await c.put("/character/title", json={"slug": "level-1"})
    assert r.status_code == 200 and r.json()["title"] == "Passer-by" and r.json()["titlePinned"] is True
    async with get_session_factory()() as db:
        row = await db.get(Character, character.id)
        await grant(db, row, [XPLine("ADJUSTMENT", 6000)])
        await db.commit()
    body = (await c.get("/character")).json()
    assert body["overallLevel"] >= 10 and body["title"] == "Passer-by"
    assert any(t["slug"] == "level-10" and t["earned"] for t in (await c.get("/character/titles")).json())

    # Letting go wears the newest again; a title not earned cannot be chosen.
    r = await c.put("/character/title", json={"slug": None})
    assert r.json()["title"] == "Roadwise" and r.json()["titlePinned"] is False
    r = await c.put("/character/title", json={"slug": "level-50"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "TITLE_NOT_EARNED"


async def test_a_title_is_earned_once(explorer_client):
    character = await me(explorer_client)
    async with get_session_factory()() as db:
        row = await db.get(Character, character.id)
        assert await award_title(db, row, "arc-first-light") == "Early Riser"
        assert await award_title(db, row, "arc-first-light") is None
        await db.commit()


# --- knacks --------------------------------------------------------------------


def test_every_knack_works_and_says_its_numbers():
    """Thirteen worked from 0.6.2; Cartographer, Arcane Sight and Second Chance from 0.7.0;
    the four capstones from 0.8.0."""
    working = [a for a in catalog.abilities() if catalog.is_working(a)]
    assert len(working) == len(catalog.abilities()) == 20
    for a in working:
        assert any(ch.isdigit() for ch in a["description"]), a["id"]


async def test_knacks_are_counted_per_trade(explorer_client):
    c = explorer_client
    await set_levels(c, trade=5)
    body = (await c.get("/character")).json()
    assert body["unspentAbilityPoints"] == 2, "levels 2 and 5 each give one"
    r = await c.post("/character/abilities/explorer_trail_sense/unlock")
    assert r.status_code == 200 and r.json()["unspentAbilityPoints"] == 1

    # A Wizard at trade level 1 has nothing to choose, whatever the Explorer had.
    r = await c.patch("/character", json={"characterClass": "WIZARD"})
    assert r.status_code == 200, r.text
    assert r.json()["unspentAbilityPoints"] == 0
    assert r.json()["sheet"]["damagePct"] == {}, "the Explorer's knack waits for the Explorer"


async def test_a_knack_changes_the_sheet(explorer_client):
    character = await me(explorer_client)
    async with get_session_factory()() as db:
        row = await db.get(Character, character.id)
        row.class_level = 12
        row.abilities.append(CharacterAbility(character_id=row.id, ability_id="explorer_trail_sense", rank=2))
        row.abilities.append(CharacterAbility(character_id=row.id, ability_id="explorer_pathfinder", rank=1))
        await db.commit()
        sheet = build_sheet(await db.get(Character, character.id))
    assert sheet.damage_pct == {"GROUND": 0.4}
    assert sheet.xp_pct == {"FIRST_CELLS": 10.0}
    assert CharacterSheet.from_dict(sheet.to_dict()) == sheet


def test_what_depends_on_the_thing_and_the_outing():
    sheet = CharacterSheet(damage_pct={"CLIMB": 0.3}, vs_elders_pct=0.1, late_road_pct=0.1, word_old_places_pct=0.15)
    plain = sheet.pct_against(elder=False, old_place=False, made_good_m=4000, foot=False)
    assert plain == {"CLIMB": 0.3}
    elder = sheet.pct_against(elder=True, old_place=True, made_good_m=12_000, foot=False)
    assert elder["CLIMB"] == 0.4 and elder["ROAD"] == 0.2 and elder["WORD"] == 0.25
    # On foot the long way starts at half the distance.
    assert sheet.pct_against(elder=False, old_place=False, made_good_m=6000, foot=True)["ROAD"] == 0.1


# --- XP and coins ---------------------------------------------------------------


def _by(lines):
    return {line.source: line.xp for line in lines}


def test_xp_knacks_pay_what_they_say():
    rules = load_xp_rules()
    base = RideRewardInput(character_class="EXPLORER", new_cells=30, distance_meters=45_000)
    plain = _by(compute_ride_xp(base))
    knacked = _by(
        compute_ride_xp(
            RideRewardInput(
                character_class="EXPLORER",
                new_cells=30,
                distance_meters=45_000,
                far_new_cells=12,
                xp_mods={"FIRST_CELLS": 10, "FAR_CELLS": 0.1, "LONG_DISTANCE": 0.2},
            )
        )
    )
    assert knacked["PATHFINDER"] == 10 * rules["newCell"]
    assert knacked["FAR_WANDERER"] == round(12 * rules["newCell"] * 0.1)
    assert knacked["LONG_DISTANCE_ADVENTURE"] == round(plain["LONG_DISTANCE_ADVENTURE"] * 1.2)

    found = RideRewardInput(character_class="SCRIBE", discovery_categories=["HISTORICAL"])
    with_note = RideRewardInput(
        character_class="SCRIBE",
        discovery_categories=["HISTORICAL"],
        wrote_note=True,
        xp_mods={"DISCOVERY_WITH_NOTE": 0.2},
    )
    assert _by(compute_ride_xp(with_note))["DISCOVERY_FOUND"] == round(
        _by(compute_ride_xp(found))["DISCOVERY_FOUND"] * 1.2
    )


def test_welcome_back_after_a_fortnight_pays_the_first_kilometre_twice():
    def ride(days):
        return compute_ride_xp(
            RideRewardInput(character_class="EXPLORER", new_cells=20, distance_meters=4000, days_away=days)
        )

    assert "WELCOME_BACK" not in _by(ride(13))
    back = _by(ride(14))
    rest = sum(xp for source, xp in back.items() if source != "WELCOME_BACK")
    assert back["WELCOME_BACK"] == round(rest / 4)
    assert "WELCOME_BACK" not in _by(ride(None)), "a first outing is not a return"


def test_the_day_caps_what_is_taken_by_hand():
    cap = load_xp_rules()["caps"]["perDayTotal"]
    lines = [XPLine("CHEST_OPENED", 60), XPLine("SET_COMPLETED", 150)]
    assert cap_to_day(lines, 0) == lines
    assert sum(line.xp for line in cap_to_day(lines, cap - 100)) <= 100
    assert sum(line.xp for line in cap_to_day(lines, cap)) == 0


def test_endings_are_paid_whole_and_boxes_pay_the_knack():
    lines = compute_ride_ac(
        distance_meters=400_000,
        new_cells=500,
        claims=[{"id": "x", "kind": "CHEST", "rewardAC": 100, "name": "box"}],
        extra_lines=[ACLine("STORY_ARC", 200), ACLine("SET_COMPLETED", 50), ACLine("STREAK", 30)],
        coin_pct={"CHEST": 0.1},
    )
    by_kind = {line.kind: line.ac for line in lines}
    assert by_kind["STORY_ARC"] == 200 and by_kind["SET_COMPLETED"] == 50 and by_kind["STREAK"] == 30
    capped = [line for line in lines if line.kind not in ("STORY_ARC", "SET_COMPLETED", "STREAK")]
    assert sum(line.ac for line in capped) == 800
    uncapped = compute_ride_ac(
        distance_meters=1000,
        new_cells=0,
        claims=[{"id": "x", "kind": "CHEST", "rewardAC": 100}],
        coin_pct={"CHEST": 0.1},
    )
    assert {line.kind: line.ac for line in uncapped}["CHEST_OPENED"] == 110
