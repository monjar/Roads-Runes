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
    """A Warrior at level 1 has three templates of their own against eight open ones;
    the board still carries one of each."""
    from tests.conftest import sign_in

    await sign_in(client, subject="brenna", name="Brenna")
    r = await client.post("/character", json={"name": "Brenna", "characterClass": "WARRIOR"})
    assert r.status_code == 201, r.text
    await seed_discoveries()
    for attempt in range(3):
        r = await client.post(
            "/quests/generate", json={"latitude": ORIGIN[0], "longitude": ORIGIN[1] + attempt * 0.001, "count": 3}
        )
        assert r.status_code == 200, r.text
        classes = [q["characterClass"] for q in r.json()["items"]]
        assert "WARRIOR" in classes and ANY_CLASS in classes, classes


def test_a_class_keeps_its_place_once_its_templates_are_all_on_the_board():
    """A board excludes the templates the rider already has open, and a class
    holds only a handful early on, so the second board in one place could find
    none of its own left and go out all-open. Which boards that hit depended on
    the seed, which is the user's id — here every class template is excluded and
    every seed is checked, so it is not a matter of luck either way.
    """
    from dataclasses import replace

    from app.quests.generator import generate
    from tests.test_class_quests import context

    for character_class in ("EXPLORER", "WIZARD", "WARRIOR", "SCRIBE"):
        own = {t["id"] for t in templates_for(character_class, 1) if t["characterClass"] != ANY_CLASS}
        assert own, character_class
        for seed in range(8):
            ctx = replace(context(character_class, class_level=1), seed=f"exhausted:{seed}")
            board = generate(ctx, count=3, exclude_template_ids=own)
            classes = [q.character_class for q in board]
            assert character_class in classes, f"{character_class} seed {seed}: {classes}"
            assert ANY_CLASS in classes, f"{character_class} seed {seed}: {classes}"
