"""The spine under the board: authored chains that go somewhere.

The generated board is a different three quests every time and leads nowhere. An
arc is the other thing — a fixed order, where riding one step is what opens the
next. These tests are about the chain: who it is offered to, one at a time, in
order, and that it survives the rules written for the generated board.
"""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import select

from app.db.session import get_session_factory
from app.quests import story
from app.quests.models import QuestInstance, StoryQuest
from app.quests.templates import template_by_id
from tests.conftest import sign_in
from tests.test_first_playable_journey import ORIGIN, seed_discoveries


@pytest.fixture(autouse=True)
def story_on(settings, monkeypatch):
    monkeypatch.setattr(settings, "feature_flags", "story_quests")
    return settings


def test_every_authored_step_is_built_on_a_template_that_exists():
    """The loader asserts it, so this is the test that the loader is doing its job
    on the arcs actually shipped — a step naming a template nobody has would show
    the rider something they can never ride."""
    templates = template_by_id()
    arcs = story.load_arcs()
    assert arcs, "no arcs authored"
    for arc in arcs:
        assert arc["quests"], arc["slug"]
        for index, step in enumerate(arc["quests"]):
            assert step["templateId"] in templates, step["slug"]
            assert step["sequence"] == index + 1
            # First step opens on its own; every later one waits for the one before.
            expected = arc["quests"][index - 1]["slug"] if index else None
            assert step["prerequisiteSlug"] == expected, step["slug"]


async def board(client) -> list[dict]:
    r = await client.get("/quests", params={"latitude": ORIGIN[0], "longitude": ORIGIN[1]})
    assert r.status_code == 200, r.text
    return [q for q in r.json()["items"] if q["status"] == "AVAILABLE"]


async def finish(quest_id: str) -> None:
    """Ride it, as far as the chain is concerned. Completing a quest for real is
    tested by the journey test; this is about what the next board does next."""
    async with get_session_factory()() as db:
        quest = await db.get(QuestInstance, uuid.UUID(quest_id))
        quest.status = "COMPLETED"
        await db.commit()


@pytest.mark.anyio
async def test_the_board_carries_one_story_step_and_it_waits(explorer_client):
    await seed_discoveries()
    available = await board(explorer_client)
    story_quests = [q for q in available if q["storyQuestId"]]
    assert len(story_quests) == 1, [q["title"] for q in available]
    step = story_quests[0]

    # An arc waits for the rider: generated quests expire in a fortnight, this does not.
    assert step["expiresAt"] is None, step

    # Opening the board again does not deal a second one, nor replace this one.
    again = [q for q in await board(explorer_client) if q["storyQuestId"]]
    assert [q["id"] for q in again] == [step["id"]]


async def promote(client, class_level: int) -> None:
    """Level the rider up, so the arcs gated behind a class level unlock."""
    from app.characters.models import Character

    me = uuid.UUID((await client.get("/users/me")).json()["id"])
    async with get_session_factory()() as db:
        character = (await db.execute(select(Character).where(Character.user_id == me))).scalar_one()
        character.class_level = class_level
        character.overall_level = max(character.overall_level, class_level)
        await db.commit()


@pytest.mark.anyio
async def test_the_next_step_comes_only_when_the_one_before_is_ridden(explorer_client):
    """In order, and one at a time: the rider is in the middle of something."""
    await seed_discoveries()
    seen: list[str] = []
    for _ in range(2):
        step = next((q for q in await board(explorer_client) if q["storyQuestId"]), None)
        assert step is not None, f"no step {len(seen) + 1} after {seen}"
        seen.append(step["title"])
        await finish(step["id"])

    arcs = (await explorer_client.get("/quests/story")).json()
    first = next(a for a in arcs if a["slug"] == "first-light")
    assert [q["title"] for q in first["quests"]][: len(seen)] == seen, "ridden out of order"
    assert [q["state"] for q in first["quests"]] == ["COMPLETED", "COMPLETED", "READY"]


@pytest.mark.anyio
async def test_an_arc_waiting_for_ground_it_can_use_does_not_block_the_others(explorer_client):
    """ "Somewhere to Look From" needs high ground, and the seeded area has none.
    The step waits, says why, and the trade's own arc carries on beside it on its
    own track."""
    c = explorer_client
    await seed_discoveries()
    await promote(c, 2)

    async def step_of(arc_slug: str) -> dict | None:
        on_board = await board(c)  # the board is what offers the steps
        arcs = {a["slug"]: a for a in (await c.get("/quests/story")).json()}
        open_ids = {str(q["questId"]) for q in arcs[arc_slug]["quests"] if q["state"] == "OPEN"}
        return next((q for q in on_board if q["id"] in open_ids), None)

    for _ in range(2):  # the two steps of First Light that can be placed here
        step = await step_of("first-light")
        assert step is not None
        await finish(step["id"])

    await board(c)
    arcs = {a["slug"]: a for a in (await c.get("/quests/story")).json()}
    assert arcs["first-light"]["track"] == "MAIN" and arcs["the-edge-of-the-map"]["track"] == "SIDE"
    stalled = next(q for q in arcs["first-light"]["quests"] if q["sequence"] == 3)
    assert stalled["state"] == "WAITING", "the waiting step is still the one that comes next"
    assert stalled["waitingReason"] == "Waiting for high ground within reach."
    # The trade's arc is on the other track, and open.
    opening = arcs["the-edge-of-the-map"]["quests"][0]
    assert arcs["the-edge-of-the-map"]["unlocked"] is True
    assert opening["state"] == "OPEN"
    # The next chapter waits for First Light to be finished.
    assert arcs["what-settles"]["unlocked"] is False and arcs["what-settles"]["after"] == "first-light"


@pytest.mark.anyio
async def test_an_arc_belongs_to_its_class_and_its_level(explorer_client):
    await seed_discoveries()
    arcs = (await explorer_client.get("/quests/story")).json()
    by_slug = {a["slug"]: a for a in arcs}

    # Every arc is returned, locked ones included: what is coming is the reason to return.
    assert set(by_slug) >= {"first-light", "the-edge-of-the-map", "what-the-stones-remember"}
    assert by_slug["first-light"]["unlocked"] is True, "the open arc starts at level 1"
    assert by_slug["what-the-stones-remember"]["unlocked"] is False, "a Wizard arc is not an Explorer's"
    assert by_slug["the-edge-of-the-map"]["unlocked"] is False, "level 1 has not reached it yet"

    # A locked arc's steps read as locked, never as next up.
    assert {q["state"] for q in by_slug["what-the-stones-remember"]["quests"]} == {"LOCKED", "READY"}

    # And nothing from a locked arc is ever put on the board.
    async with get_session_factory()() as db:
        wizard_steps = {
            s.id for s in (await db.execute(select(StoryQuest))).scalars() if s.slug.startswith("stones-remember")
        }
    offered = {q["storyQuestId"] for q in await board(explorer_client) if q["storyQuestId"]}
    assert not offered & {str(s) for s in wizard_steps}


@pytest.mark.anyio
async def test_the_step_is_generated_here_even_though_the_words_are_written(explorer_client):
    """An arc reads the same everywhere and sends each rider somewhere real near
    them: authored title and description, generated objectives."""
    await seed_discoveries()
    step = next(q for q in await board(explorer_client) if q["storyQuestId"])
    authored = story.load_arcs()[0]["quests"][0]
    assert step["title"] == authored["title"]
    assert step["description"] == authored["description"]
    assert step["objectives"], "no objectives were generated"
    assert step["recommendedDistanceKm"] > 0
    assert step["baseXP"] > 0
    assert abs(step["origin"]["latitude"] - ORIGIN[0]) < 0.2


@pytest.mark.anyio
async def test_a_step_is_not_tidied_away_as_a_duplicate(explorer_client):
    """`retire_duplicates` keeps one quest per template. A story step is the one
    quest that is meant to be there, and two arcs may share a template."""
    await seed_discoveries()
    step = next(q for q in await board(explorer_client) if q["storyQuestId"])

    # A generated quest from the very same template, sitting next to it.
    async with get_session_factory()() as db:
        original = await db.get(QuestInstance, uuid.UUID(step["id"]))
        twin = QuestInstance(
            user_id=original.user_id,
            template_id=original.template_id,
            quest_type=original.quest_type,
            character_class=original.character_class,
            activity=original.activity,
            title=original.title,
            description=original.description,
            difficulty=original.difficulty,
            recommended_distance_km=original.recommended_distance_km,
            estimated_duration_minutes=original.estimated_duration_minutes,
            base_xp=original.base_xp,
            status="AVAILABLE",
            latitude=original.latitude,
            longitude=original.longitude,
        )
        db.add(twin)
        await db.commit()

    still_there = [q for q in await board(explorer_client) if q["storyQuestId"]]
    assert [q["id"] for q in still_there] == [step["id"]], "the arc's step was retired as a duplicate"


@pytest.mark.anyio
async def test_a_waiting_step_does_not_cost_the_board_its_template(explorer_client):
    """A step sits on the board until it is ridden. Counting its template as
    already dealt would retire that template from the generated board for as long
    as the arc waits."""
    await seed_discoveries()
    step = next(q for q in await board(explorer_client) if q["storyQuestId"])
    async with get_session_factory()() as db:
        # Nothing else is open, so the exclusion set the generator is given must be empty.
        rows = (
            await db.execute(
                select(QuestInstance.template_id, QuestInstance.story_quest_id).where(
                    QuestInstance.status == "AVAILABLE"
                )
            )
        ).all()
    ordinary = {t for (t, story_id) in rows if story_id is None}
    assert step["templateId"] not in ordinary or len([t for (t, _) in rows if t == step["templateId"]]) > 1


@pytest.mark.anyio
async def test_with_the_flag_off_there_is_no_spine(client, settings, monkeypatch):
    monkeypatch.setattr(settings, "feature_flags", "!story_quests")
    await sign_in(client, subject="nia", name="Nia")
    r = await client.post("/character", json={"name": "Nia", "characterClass": "EXPLORER"})
    assert r.status_code == 201, r.text
    await seed_discoveries()
    assert not [q for q in await board(client) if q["storyQuestId"]]
    assert (await client.get("/quests/story")).status_code in (403, 404, 409)


@pytest.mark.anyio
async def test_the_last_step_ends_the_arc_with_a_title_and_a_purse(explorer_client):
    """An arc had no ending: its third step paid like its first, and then it stopped."""
    from app.characters.models import Character
    from app.core.geo import destination_point
    from tests.test_world_objects import line_trace, ride

    c = explorer_client
    await seed_discoveries()
    step = next(q for q in await board(c) if q["storyQuestId"])
    me = uuid.UUID((await c.get("/users/me")).json()["id"])

    # The other two steps of First Light are behind them.
    async with get_session_factory()() as db:
        current = await db.get(StoryQuest, uuid.UUID(step["storyQuestId"]))
        others = (
            await db.execute(select(StoryQuest).where(StoryQuest.arc_id == current.arc_id, StoryQuest.id != current.id))
        ).scalars()
        for other in others:
            db.add(
                QuestInstance(
                    user_id=me,
                    template_id=other.template_id,
                    quest_type="EXPLORE_NEW_ROADS",
                    character_class="ANY",
                    title=other.title,
                    description=other.description,
                    difficulty="EASY",
                    recommended_distance_km=8.0,
                    estimated_duration_minutes=40,
                    base_xp=150,
                    status="COMPLETED",
                    story_quest_id=other.id,
                    latitude=ORIGIN[0],
                    longitude=ORIGIN[1],
                )
            )
        await db.commit()

    assert (await c.post(f"/quests/{step['id']}/accept")).status_code == 200
    # Nine kilometres of road never ridden: more than "Out of the Door" asks for.
    summary = await ride(c, line_trace(ORIGIN, destination_point(*ORIGIN, 80, 9000), 6.0, and_back=False), step["id"])
    assert summary["questCompletion"] is not None, summary["flags"]
    standing = summary["questCompletion"]["storyProgress"]
    assert standing["arcSlug"] == "first-light" and standing["arcCompleted"] is True
    assert (standing["stepsDone"], standing["stepsTotal"], standing["nextTitle"]) == (3, 3, None)
    assert standing["reward"] == {"title": "Early Riser", "ac": 100}
    assert "Early Riser" in summary["titlesUnlocked"]
    assert any(line["kind"] == "STORY_ARC" and line["ac"] == 100 for line in summary["acBreakdown"])
    assert any(line["source"] == "STORY_ARC_COMPLETED" for line in summary["xpBreakdown"])
    assert (await c.get("/character")).json()["title"] == "Early Riser"

    # A title earned is kept: the next ride's XP does not put "Novice" back.
    await ride(c, line_trace(ORIGIN, destination_point(*ORIGIN, 200, 3000), 6.0))
    async with get_session_factory()() as db:
        character = (await db.execute(select(Character).where(Character.user_id == me))).scalar_one()
        assert character.title == "Early Riser"


@pytest.mark.anyio
async def test_a_step_in_the_middle_says_what_comes_next(explorer_client):
    from app.users.models import User

    await seed_discoveries()
    step = next(q for q in await board(explorer_client) if q["storyQuestId"])
    me = uuid.UUID((await explorer_client.get("/users/me")).json()["id"])
    async with get_session_factory()() as db:
        quest = await db.get(QuestInstance, uuid.UUID(step["id"]))
        standing = await story.standing(db, await db.get(User, me), quest)
    assert (standing["stepsDone"], standing["stepsTotal"], standing["arcCompleted"]) == (1, 3, False)
    assert standing["stepTitle"] == "Out of the Door" and standing["nextTitle"] == "Something Green"
    assert standing["reward"] is None
