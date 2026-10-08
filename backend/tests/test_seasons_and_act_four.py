"""Seasons (the four festivals and their SEASON arcs) and Act IV, "The Parish" (0.9.0)."""

from __future__ import annotations

import uuid
from datetime import UTC, date, datetime, timedelta

import pytest
from sqlalchemy import select

from app.characters.models import Character
from app.core.geo import destination_point
from app.db.session import get_session_factory
from app.districts import service as districts
from app.exploration.cells import traverse
from app.inventory import catalog as runes
from app.inventory.models import RuneHolding
from app.lore.voice import violations
from app.quests import seasons, story
from app.quests.generator import instantiate
from app.quests.models import QuestInstance, QuestObjective, StoryArc, StoryQuest
from app.quests.templates import OBJECTIVE_TYPES, template_by_id
from app.rides.processing import evaluate_objectives
from app.rides.validation import CleanPoint
from app.users.models import User
from tests.test_districts import add_region
from tests.test_first_playable_journey import ORIGIN, seed_discoveries
from tests.test_quest_generation import ctx
from tests.test_story_arcs import board

NOW = datetime.now(UTC)
TODAY = NOW.date()


# --- the festivals -------------------------------------------------------------------


def test_the_festival_days_north_and_south():
    assert seasons.festival_dates(2026) == {
        "SPRING": date(2026, 3, 25),
        "MIDSUMMER": date(2026, 6, 24),
        "HARVEST": date(2026, 9, 29),
        "MIDWINTER": date(2026, 12, 25),
    }
    # South of the equator Spring Festival and Harvest swap, and so do Midsummer and Midwinter.
    assert seasons.festival_dates(2026, south=True) == {
        "SPRING": date(2026, 9, 29),
        "MIDSUMMER": date(2026, 12, 25),
        "HARVEST": date(2026, 3, 25),
        "MIDWINTER": date(2026, 6, 24),
    }
    assert seasons.is_south(-33.9) and not seasons.is_south(51.5) and not seasons.is_south(None)
    assert [seasons.NAMES[s] for s in seasons.SEASONS] == ["Spring Festival", "Midsummer", "Harvest", "Midwinter"]


def test_a_festival_is_open_for_14_days_from_its_day():
    assert seasons.current_festival(date(2026, 9, 28)) is None
    assert seasons.current_festival(date(2026, 9, 29)).season == "HARVEST"
    assert seasons.current_festival(date(2026, 10, 12)).season == "HARVEST"
    assert seasons.current_festival(date(2026, 10, 13)) is None
    # Midwinter runs into the new year.
    winter = seasons.current_festival(date(2027, 1, 3))
    assert winter.season == "MIDWINTER" and winter.day == date(2026, 12, 25)
    assert winter.ends_at == datetime(2027, 1, 8, tzinfo=UTC)
    assert seasons.current_festival(date(2026, 10, 1), south=True).season == "SPRING"
    assert seasons.current_festival(date(2026, 6, 30), south=True).season == "MIDWINTER"
    assert seasons.next_festival(date(2026, 10, 13)).season == "MIDWINTER"


def test_district_pay_is_doubled_the_day_before_to_the_day_after():
    assert [seasons.pay_doubled(date(2026, 9, d)) for d in (27, 28, 29, 30)] == [False, True, True, True]
    assert not seasons.pay_doubled(date(2026, 10, 1))
    assert seasons.pay_doubled(date(2027, 1, 1)) is False and seasons.pay_doubled(date(2026, 12, 26))
    assert seasons.pay_doubled(date(2026, 3, 25), south=True) and not seasons.pay_doubled(
        date(2026, 3, 25) + timedelta(2)
    )


def test_the_four_season_arcs_are_three_plain_steps_each():
    arcs = [a for a in story.load_arcs() if a["track"] == "SEASON"]
    assert sorted(a["season"] for a in arcs) == sorted(seasons.SEASONS)
    assert {a["title"] for a in arcs} == set(seasons.NAMES.values())
    for arc in arcs:
        assert [q["templateId"] for q in arc["quests"]] == ["ANY_GREEN_HOUR", "ANY_UNLOCK_CHEST", "ANY_SLAY_NEARBY"]
        assert arc["reward"]["rune"] in runes.trade_six()
        assert not arc.get("act") and not arc.get("after")
        for text in [arc["title"], arc["description"], *(q["completion"] for q in arc["quests"])]:
            assert not violations(text, celebration=True), text
        for step in arc["quests"]:
            assert not violations(step["description"]) and len(step["slug"]) <= 64


# --- a festival's arc on the board ---------------------------------------------------------


@pytest.fixture
def story_on(settings, monkeypatch):
    monkeypatch.setattr(settings, "feature_flags", "story_quests")
    return settings


def festival_on(monkeypatch, festival: seasons.Festival) -> None:
    async def now(db, user, now=None):
        return festival

    monkeypatch.setattr(story, "_festival_now", now)


async def the_tester() -> tuple[User, Character]:
    async with get_session_factory()() as db:
        user = await db.scalar(select(User).where(User.apple_subject == "dev:tester"))
        return user, await db.scalar(select(Character).where(Character.user_id == user.id))


async def test_a_festivals_arc_is_offered_in_its_window_and_comes_back_next_year(
    explorer_client, story_on, monkeypatch
):
    await seed_discoveries()
    this_year = seasons.Festival("HARVEST", TODAY - timedelta(days=3))
    next_year = seasons.Festival("HARVEST", TODAY + timedelta(days=362))
    # Outside a festival there is no season arc at all.
    r = await explorer_client.get("/quests/story")
    assert not [a for a in r.json() if a["track"] == "SEASON"]
    festival_on(monkeypatch, this_year)
    monkeypatch.setattr(story, "window_of", lambda season, when, south: this_year)
    r = await explorer_client.get("/quests/story")
    [harvest] = [a for a in r.json() if a["track"] == "SEASON"]
    assert harvest["slug"] == "harvest" and harvest["season"] == "HARVEST" and harvest["unlocked"]
    assert harvest["endsAt"].startswith(this_year.ends_at.date().isoformat())
    available = await board(explorer_client)
    season_steps = [q for q in available if q["title"] == "Out in the Fields"]
    assert len(season_steps) == 1, [q["title"] for q in available]
    assert season_steps[0]["expiresAt"].startswith(this_year.ends_at.date().isoformat()), "it goes with the festival"
    # One live step on the track: the board does not deal a second.
    assert len([q for q in await board(explorer_client) if q["title"] == "Out in the Fields"]) == 1
    async with get_session_factory()() as db:
        quest = await db.get(QuestInstance, uuid.UUID(season_steps[0]["id"]))
        quest.status = "COMPLETED"
        await db.commit()
    user, character = await the_tester()
    async with get_session_factory()() as db:
        due = await story.due(db, user, character, "SEASON")
        assert [s.slug for s in due] == ["harvest-chest"]
    # Next year's Harvest starts again from the first step: last year's are not this year's.
    festival_on(monkeypatch, next_year)
    async with get_session_factory()() as db:
        due = await story.due(db, user, character, "SEASON")
        assert [s.slug for s in due] == ["harvest-green"]


async def test_a_festivals_arc_pays_once_a_year(explorer_client):
    user, character = await the_tester()
    async with get_session_factory()() as db:
        await story.sync(db)
        arc = await db.scalar(select(StoryArc).where(StoryArc.slug == "harvest"))
        steps = list((await db.execute(select(StoryQuest).where(StoryQuest.arc_id == arc.id))).scalars())
        await db.commit()
    paid = []
    for when in (datetime(2026, 9, 30, 12, tzinfo=UTC), datetime(2027, 9, 30, 12, tzinfo=UTC)):
        async with get_session_factory()() as db:
            last = None
            for step in sorted(steps, key=lambda s: s.sequence):
                last = QuestInstance(
                    user_id=user.id, template_id=step.template_id, quest_type="VISIT_POI", character_class="ANY",
                    title=step.title, description="A step.", difficulty="EASY", recommended_distance_km=5,
                    estimated_duration_minutes=30, base_xp=100, status="COMPLETED", latitude=ORIGIN[0],
                    longitude=ORIGIN[1], story_quest_id=step.id, created_at=when,
                )  # fmt: skip
                db.add(last)
            await db.flush()
            me = await db.get(Character, character.id)
            owner = await db.get(User, user.id)
            first = await story.settle_arc(db, owner, me, last)
            again = await story.settle_arc(db, owner, me, last)
            paid.append((first["reward"], again["reward"], first.get("window")))
            await db.commit()
    (one, none_1, w1), (two, none_2, w2) = paid
    assert one and one["rune"] == "gebo" and none_1 is None
    assert two and two["rune"] == "gebo" and none_2 is None, "next year's Harvest pays again"
    assert (w1, w2) == ("2026-09-29", "2027-09-29")
    async with get_session_factory()() as db:
        held = await db.scalar(select(RuneHolding).where(RuneHolding.rune_id == "gebo"))
    assert held is not None and held.shards == 1, "the second year's rune is a stone towards its next rank"


# --- Act IV --------------------------------------------------------------------------------


def test_act_four_is_four_chapters_after_act_three_each_giving_a_trade_rune():
    arcs = [a for a in story.load_arcs() if a.get("act") == 4]
    assert [a["slug"] for a in arcs] == ["home-ground", "beating-the-bounds", "the-next-district", "going-quiet"]
    assert [a["chapter"] for a in arcs] == [1, 2, 3, 4]
    assert arcs[0]["after"] == "double-pay" and all(a["track"] == "MAIN" for a in arcs)
    assert [q["templateId"] for a in arcs for q in a["quests"]] == [
        "ANY_HOME_GROUND",
        "ANY_BEATING_THE_BOUNDS",
        "ANY_NEXT_DISTRICT",
        "ANY_GOING_QUIET",
    ]
    assert story.acts()[3]["title"] == "The Parish"
    assert all(a["reward"]["rune"] in runes.trade_six() for a in arcs)
    act_three = {a["slug"]: a["reward"].get("rune") for a in story.load_arcs() if a.get("act") == 3}
    assert act_three == {
        "habits": "mannaz",
        "the-lair": "gebo",
        "the-one-that-stayed": "tiwaz",
        "double-pay": "perthro",
    }
    given = {a["reward"].get("rune") for a in story.load_arcs() if a.get("reward", {}).get("rune")}
    assert set(runes.trade_six()) <= given, "every Trade rune is given somewhere"
    assert {"DISTRICT_TILES", "DISTRICT_LOOP"} <= set(OBJECTIVE_TYPES)
    for arc in arcs:
        for text in [arc["title"], arc["description"], *(q["completion"] for q in arc["quests"])]:
            assert not violations(text, celebration=True), text


HOME = {"id": "d-home", "name": "Rotherhithe", "latitude": 51.4995, "longitude": -0.0525}


def test_home_ground_needs_a_home_district_and_names_it():
    template = template_by_id()["ANY_HOME_GROUND"]
    assert instantiate(template, ctx()) is None, "it waits for a first district"
    assert template["waitingReason"]
    quest = instantiate(template, ctx(home_district=HOME))
    [o] = quest.objectives
    assert o.objective_type == "DISTRICT_TILES" and o.target_count == 10 and o.progress_target == 10
    assert o.extra == {"district": "home", "districtId": "d-home", "districtName": "Rotherhithe"}
    assert o.title == "Explore 10 new tiles in Rotherhithe"
    assert (o.latitude, o.longitude) == (51.4995, -0.0525)


def test_the_other_three_steps_are_built():
    [bounds] = instantiate(template_by_id()["ANY_BEATING_THE_BOUNDS"], ctx()).objectives
    assert bounds.objective_type == "DISTRICT_LOOP" and bounds.progress_target == 60
    [nxt] = instantiate(template_by_id()["ANY_NEXT_DISTRICT"], ctx()).objectives
    assert nxt.objective_type == "DISTRICT_TILES" and nxt.progress_target == 25 and nxt.extra == {"district": "new"}
    assert nxt.title == "Explore 25% of a district you've never been to"
    [walk] = instantiate(template_by_id()["ANY_GOING_QUIET"], ctx(activity="RIDE")).objectives
    assert walk.objective_type == "COMPLETE_DISTANCE" and walk.target_meters == 2000
    assert walk.extra == {"activity": "WALK"} and walk.title == "Walk 2 km"


def objective(kind: str, target: float, extra: dict | None = None) -> QuestObjective:
    return QuestObjective(
        id=uuid.uuid4(), quest_id=uuid.uuid4(), objective_type=kind, title=kind, required=True, order=1,
        status="PENDING", progress_current=0, progress_target=target, provisional=False, completion_rule="AUTO",
        extra=extra or {}, target_meters=target if kind == "COMPLETE_DISTANCE" else None,
    )  # fmt: skip


def judge(o: QuestObjective, *, accepted: datetime = NOW, distance_m: float = 0, **outcome) -> bool:
    quest = QuestInstance(id=uuid.uuid4(), objectives=[o], accepted_at=accepted, created_at=accepted)
    points = [CleanPoint(51.5, -0.05, NOW), CleanPoint(51.501, -0.05, NOW)]
    done = evaluate_objectives(
        quest, points, distance_m=distance_m, duration_s=0, elevation_gain_m=0, new_roads_m=0, new_cells=set(),
        resolution=9, client_events=[], **outcome,
    )  # fmt: skip
    return o in done


def ran(*districts_in: dict) -> dict:
    return {"districts": list(districts_in)}


def test_home_ground_adds_up_new_tiles_in_the_home_district_over_journeys():
    o = objective("DISTRICT_TILES", 10, {"district": "home", "districtId": "d-home"})
    assert not judge(o, districts_done=ran({"id": "d-home", "newTiles": 4}, {"id": "d-next", "newTiles": 30}))
    assert o.progress_current == 4
    assert not judge(o, districts_done=None) and o.progress_current == 4
    assert judge(o, districts_done=ran({"id": "d-home", "newTiles": 7})) and o.progress_current == 10
    anywhere = objective("DISTRICT_TILES", 10, {"district": "any"})
    assert judge(anywhere, districts_done=ran({"id": "a", "newTiles": 6}, {"id": "b", "newTiles": 5}))


def test_the_next_district_is_one_first_passed_since_the_quest_was_taken():
    o = objective("DISTRICT_TILES", 25, {"district": "new"})
    before = NOW - timedelta(days=30)
    after = NOW + timedelta(minutes=5)
    assert not judge(o, districts_done=ran({"id": "old", "percent": 80.0, "_firstPassedAt": before}))
    assert not judge(o, districts_done=ran({"id": "new", "percent": None, "_firstPassedAt": after}))
    assert not judge(o, districts_done=ran({"id": "new", "percent": 20.0, "_firstPassedAt": after}))
    assert o.progress_current == 20
    assert judge(o, districts_done=ran({"id": "new", "percent": 26.0, "_firstPassedAt": after}))


def test_beating_the_bounds_is_a_closed_loop_round_enough_of_the_edge():
    o = objective("DISTRICT_LOOP", 60)
    assert not judge(o, loop={"closed": False, "shares": {"d": {"share": 0.9}}})
    assert o.progress_current == 60, "the best of the edge so far, up to the target"
    o = objective("DISTRICT_LOOP", 60)
    assert not judge(o, loop={"closed": True, "shares": {"d": {"share": 0.5}}}) and o.progress_current == 50
    assert judge(o, loop={"closed": True, "shares": {"d": {"share": 0.3}, "e": {"share": 0.65}}})


def test_going_quiet_is_a_walk_not_a_ride():
    o = objective("COMPLETE_DISTANCE", 2000, {"activity": "WALK"})
    assert not judge(o, distance_m=5000, activity="RIDE") and o.progress_current == 0
    assert not judge(o, distance_m=1500, activity="WALK")
    assert judge(o, distance_m=2100, activity="WALK")
    plain = objective("COMPLETE_DISTANCE", 2000)
    assert judge(plain, distance_m=2100, activity="RIDE"), "an ordinary distance objective is unchanged"


def ring(radius_m: float) -> set[str]:
    pts = [destination_point(ORIGIN[0], ORIGIN[1], b / 4, radius_m) for b in range(0, 1441)]
    return set(traverse(pts, 9).cells)


async def test_a_loop_round_the_edge_touches_it_and_one_inside_does_not(explorer_client):
    await add_region("Lonely Village", ORIGIN)
    async with get_session_factory()() as db:
        edge = await districts.edge_shares(db, ring(3880), 9)
        inner = await districts.edge_shares(db, ring(2000), 9)
    [(_, outer_share)] = edge.items()
    [(_, inner_share)] = inner.items()
    assert outer_share["name"] == "Lonely Village" and outer_share["share"] >= 0.6
    assert inner_share["share"] < 0.1
