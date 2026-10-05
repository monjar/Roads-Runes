"""GET /codex: the world's pages, and what this player has met of it."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

from app.core.config import get_settings
from app.db.session import get_session_factory
from app.users.models import User
from app.world_objects.models import WorldObject


async def place(user_subject: str, kind: str, status: str, payload: dict, tier: int = 1) -> None:
    async with get_session_factory()() as db:
        from sqlalchemy import select

        user = await db.scalar(select(User).where(User.apple_subject == f"dev:{user_subject}"))
        now = datetime.now(UTC)
        db.add(
            WorldObject(
                user_id=user.id,
                kind=kind,
                status=status,
                tier=tier,
                latitude=51.49,
                longitude=-0.04,
                seed=str(uuid.uuid4()),
                reward_ac=10,
                payload=payload,
                spawned_at=now - timedelta(days=1),
                expires_at=now + timedelta(days=2),
                claimed_at=now if status == "CLAIMED" else None,
            )
        )
        await db.commit()


async def test_the_codex_knows_what_was_met_before_species_had_names(explorer_client):
    # A kill from before 0.6.0: the payload has only the old name.
    await place("tester", "MONSTER", "CLAIMED", {"name": "Hollow Knight", "flavour": "x", "hp": 100})
    await place("tester", "MONSTER", "SPAWNED", {"name": "Culvert Troll", "speciesId": "fen-troll"}, tier=2)
    await place("tester", "COLLECTABLE", "CLAIMED", {"name": "Raido (Old Runes)", "setId": "RUNES", "piece": "Raido"})

    r = await explorer_client.get("/codex")
    assert r.status_code == 200, r.text
    codex = r.json()
    creatures = {c["id"]: c for c in codex["creatures"]}
    assert creatures["hollow-sentry"]["state"] == "MET"
    assert creatures["hollow-sentry"]["seenOffCount"] == 1
    assert creatures["fen-troll"]["state"] == "SEEN"
    assert [e["seen"] for e in creatures["fen-troll"]["elders"]] == [True, False]
    assert creatures["grey-stag"]["state"] == "UNSEEN"
    runes = {r["id"]: r for r in codex["runes"]}
    assert runes["raido"]["state"] == "HELD"
    assert runes["fehu"]["state"] == "NOT_FOUND"
    assert codex["counts"] == {
        "creaturesSeenOff": 1,
        "creaturesSeen": 2,
        "creaturesTotal": 24,
        "runesHeld": 1,
        "runesTotal": 24,
    }
    assert codex["entries"][0]["id"] == "the-old-roads"
    assert {p["name"] for p in codex["people"]} >= {"Ada Pym", "Walter Garth"}


async def test_pages_about_fights_wait_for_the_fights(explorer_client, monkeypatch):
    settings = get_settings()
    monkeypatch.setattr(settings, "feature_flags", "!effort_combat")
    ids = {e["id"] for e in (await explorer_client.get("/codex")).json()["entries"]}
    assert "hold" not in ids
    monkeypatch.setattr(settings, "feature_flags", "effort_combat")
    ids = {e["id"] for e in (await explorer_client.get("/codex")).json()["entries"]}
    assert "hold" in ids


async def test_no_codex_when_it_is_switched_off(explorer_client, monkeypatch):
    monkeypatch.setattr(get_settings(), "feature_flags", "!codex")
    r = await explorer_client.get("/codex")
    assert r.status_code == 403
