"""Rune rides, the two new objectives, and Act II (docs/ROADMAP.md, 0.7.0)."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select

from app.core.geo import destination_point, haversine_m
from app.db.session import get_session_factory
from app.inventory import service as inventory
from app.quests import story
from app.quests.models import QuestInstance, QuestObjective, StoryQuest
from app.rides.processing import _stopped_at, evaluate_objectives
from app.rides.validation import CleanPoint
from app.routing.rune_rides import shape
from tests.test_first_playable_journey import ORIGIN, seed_discoveries

NOW = datetime.now(UTC)


def trace_through(vertices: list[tuple[float, float]], spacing: float = 10.0) -> list[CleanPoint]:
    """Fixes every `spacing` metres along straight legs between the vertices."""
    out: list[CleanPoint] = []
    t = NOW
    for a, b in zip(vertices, vertices[1:], strict=False):
        legs = max(1, int(haversine_m(a[0], a[1], b[0], b[1]) / spacing))
        for k in range(legs):
            f = k / legs
            out.append(CleanPoint(a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, t, 10.0))
            t += timedelta(seconds=2)
    out.append(CleanPoint(vertices[-1][0], vertices[-1][1], t, 10.0))
    return out


def objective(kind: str, at: tuple[float, float], **extra) -> QuestObjective:
    return QuestObjective(
        id=uuid.uuid4(),
        quest_id=uuid.uuid4(),
        objective_type=kind,
        title=kind,
        required=True,
        order=1,
        status="PENDING",
        latitude=at[0],
        longitude=at[1],
        radius_meters=extra.pop("radius", None),
        progress_current=0,
        progress_target=1,
        provisional=False,
        completion_rule="AUTO",
        extra=extra,
    )


def judge(o: QuestObjective, points: list[CleanPoint], events: list[dict] | None = None) -> bool:
    quest = QuestInstance(id=uuid.uuid4(), objectives=[o])
    done = evaluate_objectives(
        quest,
        points,
        distance_m=0,
        duration_s=0,
        elevation_gain_m=0,
        new_roads_m=0,
        new_cells=set(),
        resolution=9,
        client_events=events or [],
    )
    return o in done


# --- the shapes -----------------------------------------------------------------------


@pytest.mark.parametrize("form", ["TRIANGLE", "SQUARE", "LOOP"])
def test_a_rune_ride_shape_reads_as_its_rune(form):
    """The waypoints a rune ride routes through make the shape the matcher reads."""
    from app.world_objects.claims import match_rune

    waypoints, closed = shape(form, ORIGIN, 30.0, 2400)
    assert closed
    path = trace_through([ORIGIN, *waypoints, ORIGIN])
    match = match_rune([(p.latitude, p.longitude) for p in path], ORIGIN, threshold=0.25, search_radius_m=2000)
    assert match is not None and match.shape == form


def test_inscribe_rune_wants_its_own_form_round_the_place():
    place = destination_point(ORIGIN[0], ORIGIN[1], 0, 300)
    waypoints, _ = shape("TRIANGLE", ORIGIN, 30.0, 2400)
    triangle = trace_through([ORIGIN, *waypoints, ORIGIN])
    assert judge(objective("INSCRIBE_RUNE", place, radius=1500, roadForm="TRIANGLE", rune="kenaz"), triangle)
    assert not judge(objective("INSCRIBE_RUNE", place, radius=1500, roadForm="SQUARE", rune="dagaz"), triangle)


def test_carry_is_a_then_b_and_never_b_then_a():
    a = destination_point(ORIGIN[0], ORIGIN[1], 90, 500)
    b = destination_point(ORIGIN[0], ORIGIN[1], 90, 1500)
    there = trace_through([ORIGIN, a, b])
    back = trace_through([b, a, ORIGIN])
    carry = {"to": {"latitude": b[0], "longitude": b[1], "name": "B"}}
    assert judge(objective("CARRY", a, radius=80, **carry), there)
    assert not judge(objective("CARRY", a, radius=80, **carry), back), "B first, then A, is not carrying it"


def test_a_stop_is_staying_put_long_enough():
    still = [CleanPoint(ORIGIN[0], ORIGIN[1], NOW + timedelta(seconds=10 * i), 10.0) for i in range(35)]
    assert _stopped_at(still, ORIGIN, 120, 300)
    assert not _stopped_at(still[:20], ORIGIN, 120, 300)


def test_a_note_at_the_place_is_ansuz():
    o = objective("INSCRIBE_RUNE", ORIGIN, radius=120, roadForm="NOTE", rune="ansuz")
    near = {"objectiveId": str(o.id), "latitude": ORIGIN[0], "longitude": ORIGIN[1], "note": "A bench and a pigeon."}
    assert judge(o, [], [near])
    o2 = objective("INSCRIBE_RUNE", ORIGIN, radius=120, roadForm="NOTE", rune="ansuz")
    assert not judge(o2, [], [{**near, "objectiveId": str(o2.id), "note": "x"}]), "a word or two is not a note"


# --- rune rides -------------------------------------------------------------------------


async def test_a_rune_ride_routes_the_shape_and_keeps_to_its_activity(explorer_client):
    c = explorer_client
    r = await c.post("/routes/rune", json={"origin": {"latitude": ORIGIN[0], "longitude": ORIGIN[1]}, "rune": "raido"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["roadForm"] == "LOOP" and body["hint"].startswith("Cut Raido here: a loop")
    assert body["alternatives"] and body["alternatives"][0]["label"].startswith("Raido")
    r = await c.post(
        "/routes/rune",
        json={"origin": {"latitude": ORIGIN[0], "longitude": ORIGIN[1]}, "rune": "raido", "activity": "WALK"},
    )
    assert r.status_code == 409 and r.json()["error"]["code"] == "RUNE_NOT_FOR_ACTIVITY"
    r = await c.post("/routes/rune", json={"origin": {"latitude": ORIGIN[0], "longitude": ORIGIN[1]}, "rune": "ansuz"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "RUNE_NOT_A_SHAPE"


# --- Act II -----------------------------------------------------------------------------


def test_act_two_is_five_cuts_after_the_crossing():
    act_two = [a for a in story.load_arcs() if a.get("act") == 2]
    assert [a["reward"]["rune"] for a in act_two] == ["kenaz", "ansuz", "wunjo", "sowilo", "dagaz"]
    assert act_two[0]["after"] == "the-rune-at-the-crossing"
    assert all(len(a["quests"]) == 4 for a in act_two)
    assert story.acts()[1]["title"] == "Five More Cuts"


async def test_a_notice_remembers_the_way_home_and_a_chapter_teaches_its_rune(explorer_client, settings, monkeypatch):
    from app.characters.models import Character

    monkeypatch.setattr(settings, "feature_flags", "story_quests")
    c = explorer_client
    await seed_discoveries()
    user_id = uuid.UUID((await c.get("/users/me")).json()["id"])
    async with get_session_factory()() as db:
        await story.sync(db)
        character = (await db.execute(select(Character).where(Character.user_id == user_id))).scalar_one()
        assert story._wording("cut-of-ansuz-fetch-and-carry", character) is None
        fetch = (
            await db.execute(select(StoryQuest).where(StoryQuest.slug == "cut-of-kenaz-fetch-and-carry"))
        ).scalar_one()
        quest = QuestInstance(
            user_id=user_id,
            template_id="ANY_FETCH",
            quest_type="CARRY",
            character_class="ANY",
            title="Fetch and Carry",
            description="…",
            difficulty="EASY",
            recommended_distance_km=5,
            estimated_duration_minutes=30,
            base_xp=150,
            status="COMPLETED",
            story_quest_id=fetch.id,
            latitude=ORIGIN[0],
            longitude=ORIGIN[1],
        )
        quest.objectives = [
            QuestObjective(objective_type="CARRY", title="x", required=True, order=1, status="COMPLETED",
                           progress_current=2, progress_target=2, completion_rule="AUTO", provisional=False),
            QuestObjective(objective_type="RETURN_TO_START", title="y", required=False, order=2, status="COMPLETED",
                           progress_current=1, progress_target=1, completion_rule="AUTO", provisional=False),
        ]  # fmt: skip
        db.add(quest)
        await db.flush()
        await story.note_flags(db, character, quest)
        assert character.story_flags == ["came-home-the-other-way"]
        assert story._wording("cut-of-ansuz-fetch-and-carry", character).startswith("Posted for whoever came home")
        # Finishing the chapter teaches Kenaz.
        steps = (
            (
                await db.execute(
                    select(StoryQuest).where(StoryQuest.slug.like("cut-of-kenaz-%")).order_by(StoryQuest.sequence)
                )
            )
            .scalars()
            .all()
        )
        for step in steps:
            if step.id == fetch.id:
                continue
            db.add(QuestInstance(
                user_id=user_id, template_id=step.template_id, quest_type="VISIT_POI", character_class="ANY",
                title=step.title, description="…", difficulty="EASY", recommended_distance_km=5,
                estimated_duration_minutes=30, base_xp=150, status="COMPLETED", story_quest_id=step.id,
                latitude=ORIGIN[0], longitude=ORIGIN[1],
            ))  # fmt: skip
        await db.flush()
        from app.users.models import User

        user = await db.get(User, user_id)
        settled = await story.settle_arc(db, user, character, quest)
        assert settled["arcCompleted"] and settled["reward"]["rune"] == "kenaz"
        held = await inventory.holdings(db, character)
        assert held["kenaz"].rank == 1
        again = await story.settle_arc(db, user, character, quest)
        assert again["reward"] is None, "a chapter's ending is paid once"
        await db.commit()
