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
