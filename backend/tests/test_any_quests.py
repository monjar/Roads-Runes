"""Quests for anyone: a class shapes the board, it does not own it."""

from __future__ import annotations

from app.quests.templates import ANY_CLASS, all_templates, templates_for
from tests.test_first_playable_journey import ORIGIN, seed_discoveries


def test_open_templates_are_offered_to_every_class():
    open_ids = {t["id"] for t in all_templates() if t["characterClass"] == ANY_CLASS}
    assert len(open_ids) >= 5
    for character_class in ("EXPLORER", "WIZARD", "WARRIOR", "SCRIBE"):
        offered = {t["id"] for t in templates_for(character_class, 1)}
        assert open_ids <= offered, character_class
        assert offered - open_ids, f"{character_class} lost its own quests"
    # And on foot: the open quests are run- and walk-shaped too.
    assert {t["id"] for t in templates_for("WARRIOR", 1, activity="RUN")} & open_ids


async def test_every_board_has_a_quest_for_anyone(explorer_client):
    c = explorer_client
    await seed_discoveries()
    r = await c.get("/quests", params={"latitude": ORIGIN[0], "longitude": ORIGIN[1]})
    assert r.status_code == 200, r.text
    board = [q for q in r.json()["items"] if q["status"] == "AVAILABLE"]
    assert len(board) >= 3
    open_quests = [q for q in board if q["characterClass"] == ANY_CLASS]
    assert open_quests, [q["templateId"] for q in board]
    for quest in open_quests:
        assert quest["activity"] == "RIDE"
        assert quest["rewards"]["ac"] > 0 and quest["baseXP"] > 0
        assert "{" not in quest["title"] and "{" not in quest["description"]
        for objective in quest["objectives"]:
            assert "{" not in objective["title"]

    # Asking for the open quests alone gives only those.
    r = await c.post(
        "/quests/generate", json={"latitude": ORIGIN[0], "longitude": ORIGIN[1], "count": 2, "activity": "WALK"}
    )
    assert r.status_code == 200, r.text
    assert any(q["characterClass"] == ANY_CLASS for q in r.json()["items"])


async def test_a_board_is_the_classs_and_everyones(client):
    """A Warrior at level 1 has three templates of their own against eight open
    ones; the board still carries one of each. The *board* — a second batch in
    the same town has no need of a second Warrior quest while the first is open,
    and making one meant dealing a template twice."""
    from tests.conftest import sign_in

    await sign_in(client, subject="brenna", name="Brenna")
    r = await client.post("/character", json={"name": "Brenna", "characterClass": "WARRIOR"})
    assert r.status_code == 201, r.text
    await seed_discoveries()
    dealt: list[str] = []
    for attempt in range(3):
        r = await client.post(
            "/quests/generate", json={"latitude": ORIGIN[0], "longitude": ORIGIN[1] + attempt * 0.001, "count": 3}
        )
        assert r.status_code == 200, r.text
        dealt += [q["templateId"] for q in r.json()["items"]]
        r = await client.get("/quests", params={"latitude": ORIGIN[0], "longitude": ORIGIN[1]})
        board = [q["characterClass"] for q in r.json()["items"] if q["status"] == "AVAILABLE"]
        assert "WARRIOR" in board and ANY_CLASS in board, board
    assert len(dealt) == len(set(dealt)), dealt


async def test_the_board_never_holds_the_same_quest_twice(client):
    """Ask for more than there are templates and the answer is fewer, then none —
    not The Old Stones again, a street over. Every board the rider opens is also
    tidied of any repeats an older server dealt."""
    from app.db.session import get_session_factory
    from app.quests.models import QuestInstance
    from tests.conftest import sign_in

    await sign_in(client, subject="idris", name="Idris")
    r = await client.post("/character", json={"name": "Idris", "characterClass": "WIZARD"})
    assert r.status_code == 201, r.text
    await seed_discoveries()
    for attempt in range(6):
        r = await client.post(
            "/quests/generate", json={"latitude": ORIGIN[0], "longitude": ORIGIN[1] + attempt * 0.002, "count": 3}
        )
        assert r.status_code == 200, r.text
    r = await client.get("/quests", params={"latitude": ORIGIN[0], "longitude": ORIGIN[1], "status": "AVAILABLE"})
    templates = [q["templateId"] for q in r.json()["items"]]
    assert templates and len(templates) == len(set(templates)), templates

    # A repeat already on the board — dealt before this rule — goes when the board is next opened.
    async with get_session_factory()() as db:
        first = (await db.execute(__import__("sqlalchemy").select(QuestInstance).limit(1))).scalar_one()
        columns = {c.name: getattr(first, c.name) for c in QuestInstance.__table__.columns}
        for key in ("id", "created_at", "updated_at"):
            columns.pop(key, None)
        db.add(QuestInstance(**columns))
        await db.commit()
        repeated = first.template_id
    r = await client.get("/quests", params={"latitude": ORIGIN[0], "longitude": ORIGIN[1], "status": "AVAILABLE"})
    assert [q["templateId"] for q in r.json()["items"]].count(repeated) == 1


def test_a_batch_tops_up_the_board_not_itself():
    """With the class's quests all still open, a new batch owes the board nothing
    of that class — and deals none of those templates again. With nothing open,
    it carries one of each."""
    from dataclasses import replace

    from app.quests.generator import generate
    from tests.test_class_quests import context

    for character_class in ("EXPLORER", "WIZARD", "WARRIOR", "SCRIBE"):
        own = {t["id"] for t in templates_for(character_class, 1) if t["characterClass"] != ANY_CLASS}
        for seed in range(6):
            ctx = replace(context(character_class, class_level=1), seed=f"board:{seed}")
            batch = generate(ctx, count=3, exclude_template_ids=own, board_classes={character_class})
            assert batch, f"{character_class} seed {seed}"
            assert not {q.template_id for q in batch} & own, f"{character_class} seed {seed} dealt a repeat"
            assert all(q.character_class == ANY_CLASS for q in batch)

            fresh = generate(ctx, count=3)
            classes = {q.character_class for q in fresh}
            assert {character_class, ANY_CLASS} <= classes, f"{character_class} seed {seed}: {classes}"
