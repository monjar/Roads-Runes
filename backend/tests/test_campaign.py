"""Act I, the posters on the board, and the fixes under the campaign
(docs/ROADMAP.md, 0.6.2 b)."""

from __future__ import annotations

import uuid
from datetime import timedelta

import pytest
from sqlalchemy import select

from app.core.security import utcnow
from app.db.session import get_session_factory
from app.lore.catalog import cast_by_id
from app.quests import story
from app.quests.models import QuestInstance, StoryArc, StoryQuest
from app.quests.templates import all_templates
from app.world_objects import service as world_objects
from app.world_objects.models import WorldObject
from tests.test_first_playable_journey import ORIGIN, seed_discoveries
from tests.test_story_arcs import board


@pytest.fixture(autouse=True)
def story_on(settings, monkeypatch):
    monkeypatch.setattr(settings, "feature_flags", "story_quests")
    return settings


async def me(client) -> uuid.UUID:
    return uuid.UUID((await client.get("/users/me")).json()["id"])


async def done(client, *step_slugs: str) -> None:
    """These steps are behind the player."""
    user_id = await me(client)
    async with get_session_factory()() as db:
        await story.sync(db)
        for slug in step_slugs:
            step = (await db.execute(select(StoryQuest).where(StoryQuest.slug == slug))).scalar_one()
            db.add(
                QuestInstance(
                    user_id=user_id,
                    template_id=step.template_id,
                    quest_type="VISIT_POI",
                    character_class="ANY",
                    title=step.title,
                    description=step.description,
                    difficulty="EASY",
                    recommended_distance_km=8.0,
                    estimated_duration_minutes=40,
                    base_xp=150,
                    status="COMPLETED",
                    story_quest_id=step.id,
                    latitude=ORIGIN[0],
                    longitude=ORIGIN[1],
                )
            )
        await db.commit()


async def arc_of(quest: dict) -> str:
    async with get_session_factory()() as db:
        step = await db.get(StoryQuest, uuid.UUID(quest["storyQuestId"]))
        return (await db.get(StoryArc, step.arc_id)).slug


def test_act_one_is_three_chapters_in_order_and_every_step_says_something_when_done():
    main = [a for a in story.load_arcs() if a["track"] == "MAIN" and a.get("act") == 1]
    assert [a["slug"] for a in main] == ["first-light", "what-settles", "the-rune-at-the-crossing"]
    assert [a.get("after") for a in main] == [None, "first-light", "what-settles"]
    assert story.acts()[0]["title"] == "The Board"
    for arc in story.load_arcs():
        for step in arc["quests"]:
            assert step["completion"], step["slug"]
            for word in ("ride", "rider", "riding", "pedal", "saddle", "wheel"):
                assert word not in f" {step['description'].lower()} ", (step["slug"], word)
    for template in all_templates():
        assert template["completion"], template["id"]


async def test_every_notice_carries_who_posted_it(explorer_client):
    await seed_discoveries()
    quests = await board(explorer_client)
    assert quests
    for quest in quests:
        poster = quest["narrative"].get("poster")
        assert poster, quest["title"]
        person = cast_by_id()[poster["castId"]]
        assert poster["name"] == person["name"] and poster["line"] in person["lines"]
        if quest["characterClass"] == "EXPLORER" and not quest["storyQuestId"]:
            assert poster["castId"] == "nell-foss"


async def test_the_next_chapter_waits_for_the_one_before(explorer_client):
    c = explorer_client
    await seed_discoveries()
    arcs = {a["slug"]: a for a in (await c.get("/quests/story")).json()}
    assert arcs["what-settles"]["unlocked"] is False
    assert (arcs["what-settles"]["act"], arcs["what-settles"]["chapter"]) == (1, 2)
    assert arcs["what-settles"]["actTitle"] == "The Board"

    await done(c, *(q["slug"] for q in arcs["first-light"]["quests"]))
    offered = [q for q in await board(c) if q["storyQuestId"]]
    main = [q for q in offered if await arc_of(q) == "what-settles"]
    assert main, "the second chapter follows the first"
    assert main[0]["narrative"]["poster"]["castId"] == "ada-pym"
    assert main[0]["narrative"]["completion"] == "Seen off. The pin comes out of the board."


async def test_the_finale_places_its_elder_and_it_stays_while_the_step_is_open(explorer_client):
    c = explorer_client
    await seed_discoveries()
    before = [
        q["slug"]
        for a in story.load_arcs()
        if a["slug"] in ("first-light", "what-settles", "the-rune-at-the-crossing")
        for q in a["quests"]
    ][:-1]
    await done(c, *before)
    finale = next((q for q in await board(c) if q["storyQuestId"] and q["templateId"] == "ANY_THE_ELDER"), None)
    assert finale is not None, "the finale could not be set"
    target = next(o for o in finale["objectives"] if o["objectiveType"] == "SLAY_MONSTER")
    async with get_session_factory()() as db:
        elder = await db.get(WorldObject, uuid.UUID(target["extra"]["objectId"]))
        assert elder.tier == 3 and elder.payload["storyStep"] == "rune-at-the-crossing-the-one-at-the-crossing"
        assert "RUNE" in elder.payload["species"]["wants"] and elder.payload["species"]["roadForm"] == "LOOP"
        assert world_objects.haversine_m(ORIGIN[0], ORIGIN[1], elder.latitude, elder.longitude) >= 1500 * 0.99
        # Past its time, it stays: the step is open.
        elder.expires_at = utcnow() - timedelta(hours=1)
        await db.commit()
        await world_objects.expire_stale(db, elder.user_id)
        await db.commit()
        again = await db.get(WorldObject, elder.id)
        assert again.status == "SPAWNED" and again.expires_at > utcnow()


def test_every_steps_elder_seed_fits_its_column():
    # SQLite does not hold a string to its width; Postgres refuses it, so the
    # finale failed only on PostGIS.
    width = WorldObject.__table__.c.seed.type.length
    for arc in story.load_arcs():
        for step in arc["quests"]:
            # The longest the spawner makes of it: a retry number, then kind and index.
            seed = f"{world_objects.elder_seed(step['slug'])}:99:MONSTER:99"
            assert len(seed) <= width, step["slug"]


def test_a_riddle_names_its_place_nowhere():
    from app.quests.generator import GeneratedObjective, GeneratedQuest
    from app.quests.models import QuestObjective
    from app.quests.narrative import compose_story
    from app.quests.service import objective_out

    hidden = QuestObjective(
        id=uuid.uuid4(),
        quest_id=uuid.uuid4(),
        completion_rule="AUTO",
        provisional=False,
        objective_type="VISIT_POI",
        title="Find the high place the riddle points to",
        required=True,
        order=1,
        status="PENDING",
        latitude=51.5,
        longitude=-0.05,
        discovery_id=uuid.uuid4(),
        progress_current=0,
        progress_target=1,
        extra={"hidden": True, "poiName": "Stave Hill", "category": "VIEWPOINT"},
    )
    out = objective_out(hidden)
    assert out.latitude is None and out.discoveryId is None
    assert "poiName" not in out.extra and "category" not in out.extra and out.extra["hidden"] is True

    quest = GeneratedQuest(
        template_id="WIZARD_RIDDLE_VIEWPOINT",
        quest_type="VISIT_POI",
        character_class="WIZARD",
        title="The Watcher's Seat",
        description="A high place, and a riddle about it.",
        difficulty="EASY",
        recommended_distance_km=8,
        estimated_duration_minutes=40,
        base_xp=150,
        objectives=[
            GeneratedObjective("VISIT_POI", "Find it", True, 1, extra={"hidden": True, "poiName": "Stave Hill"})
        ],
        narrative={},
        seed="x",
        latitude=51.5,
        longitude=-0.05,
        rewards={},
        variables={"poiName": "Stave Hill", "poiFact": "The map files it as viewpoint."},
    )
    assert "Stave Hill" not in compose_story(quest)


async def test_finishing_enough_of_one_persons_notices_earns_their_title(explorer_client):
    from app.characters.models import Character

    c = explorer_client
    user_id = await me(c)
    async with get_session_factory()() as db:
        for _ in range(5):
            db.add(
                QuestInstance(
                    user_id=user_id,
                    template_id="EXPLORER_NEW_TERRITORY",
                    quest_type="EXPLORE_NEW_ROADS",
                    character_class="EXPLORER",
                    title="x",
                    description="x",
                    difficulty="EASY",
                    recommended_distance_km=8.0,
                    estimated_duration_minutes=40,
                    base_xp=150,
                    status="COMPLETED",
                    narrative={"poster": {"castId": "nell-foss", "name": "Nell Foss", "line": "Past the last lamp."}},
                    latitude=ORIGIN[0],
                    longitude=ORIGIN[1],
                )
            )
        await db.commit()
        character = (await db.execute(select(Character).where(Character.user_id == user_id))).scalar_one()
        assert await story.cast_titles(db, character) == ["Lamp-Lit"]
        assert await story.cast_titles(db, character) == [], "earned once"
        await db.commit()
    titles = {t["slug"]: t for t in (await c.get("/character/titles")).json()}
    assert titles["cast-nell-foss"]["earned"] and not titles["cast-ada-pym"]["earned"]
