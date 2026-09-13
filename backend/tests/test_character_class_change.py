"""Changing class keeps the rider; only the class, and what the class earned, moves."""

from __future__ import annotations

import uuid
from datetime import timedelta

from sqlalchemy import select

from app.characters.models import Character
from app.core.security import utcnow
from app.db.session import get_session_factory
from app.economy import service as economy
from tests.test_first_playable_journey import ORIGIN, seed_discoveries


async def _character_row(user_id: str) -> Character:
    async with get_session_factory()() as db:
        return await db.scalar(select(Character).where(Character.user_id == uuid.UUID(user_id)))


async def test_the_first_change_is_free_and_switching_back_restores_the_class(explorer_client):
    c = explorer_client
    me = (await c.get("/users/me")).json()
    async with get_session_factory()() as db:
        character = await db.scalar(select(Character).where(Character.user_id == uuid.UUID(me["id"])))
        character.class_xp, character.class_level = 900, 4
        character.overall_xp, character.overall_level = 1500, 5
        await db.commit()
    before = (await c.get("/character")).json()
    assert before["classChangeCostAC"] == 0 and before["nextClassChangeAt"] is None

    r = await c.patch("/character", json={"characterClass": "WIZARD"})
    assert r.status_code == 200, r.text
    wizard = r.json()
    assert wizard["characterClass"] == "WIZARD"
    assert (wizard["classLevel"], wizard["classXP"]) == (1, 0), "a class never played starts at 1"
    assert (wizard["overallLevel"], wizard["overallXP"]) == (5, 1500), (
        "overall progress is the rider's, not the class's"
    )
    assert wizard["classProgress"] == {"EXPLORER": {"classXp": 900, "classLevel": 4}}
    assert wizard["classChanges"] == 1
    assert wizard["classChangeCostAC"] == 150 and wizard["nextClassChangeAt"] is not None
    assert any(a["ability"]["characterClass"] == "WIZARD" for a in wizard["abilities"])

    # The same class again is not a change.
    r = await c.patch("/character", json={"characterClass": "WIZARD"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "SAME_CLASS"
    # Straight back is a toggle, not a choice: it waits a day.
    r = await c.patch("/character", json={"characterClass": "EXPLORER"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "CLASS_CHANGE_COOLDOWN"
    assert "retryAt" in r.json()["error"]["details"]

    # A day later it costs coins the rider does not have...
    async with get_session_factory()() as db:
        character = await db.scalar(select(Character).where(Character.user_id == uuid.UUID(me["id"])))
        character.class_changed_at = utcnow() - timedelta(days=2)
        await db.commit()
    r = await c.patch("/character", json={"characterClass": "EXPLORER"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "INSUFFICIENT_AC"

    # ...and with them, the Explorer comes back exactly as left.
    async with get_session_factory()() as db:
        await economy.credit(db, uuid.UUID(me["id"]), 200, "ADJUSTMENT")
        await db.commit()
    r = await c.patch("/character", json={"characterClass": "EXPLORER"})
    assert r.status_code == 200, r.text
    explorer = r.json()
    assert (explorer["classLevel"], explorer["classXP"]) == (4, 900)
    assert explorer["classProgress"]["WIZARD"] == {"classXp": 0, "classLevel": 1}
    assert explorer["activeCoins"] == 50
    ledger = (await c.get("/wallet/transactions")).json()["items"]
    assert ledger[0]["kind"] == "CLASS_CHANGE" and ledger[0]["amount"] == -150
    assert ledger[0]["payload"] == {"from": "WIZARD", "to": "EXPLORER"}


async def test_quests_on_offer_for_the_old_class_are_withdrawn(explorer_client):
    c = explorer_client
    await seed_discoveries()
    r = await c.post("/quests/generate", json={"latitude": ORIGIN[0], "longitude": ORIGIN[1]})
    assert r.status_code == 200, r.text
    offered = [q for q in r.json()["items"] if q["status"] == "AVAILABLE"]
    explorer_quests = [q for q in offered if q["characterClass"] == "EXPLORER"]
    open_quests = [q for q in offered if q["characterClass"] == "ANY"]
    assert explorer_quests, "no class quests to withdraw"
    r = await c.patch("/character", json={"characterClass": "WARRIOR"})
    assert r.status_code == 200, r.text
    for quest in explorer_quests:
        assert (await c.get(f"/quests/{quest['id']}")).json()["status"] == "EXPIRED"
    # A quest for anyone is still for the Warrior they have become.
    for quest in open_quests:
        assert (await c.get(f"/quests/{quest['id']}")).json()["status"] == "AVAILABLE"
