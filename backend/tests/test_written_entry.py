"""The model-written entry (docs/ROADMAP.md 0.7.2, flag chronicle_llm). The model
is never called here: a scripted one stands in."""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import select

from app.chronicle import written
from app.db.session import get_session_factory
from app.rides.models import Ride
from tests.test_first_playable_journey import ORIGIN
from tests.test_world_objects import line_trace, ride

SUMMARY = {
    "worldObjects": {
        "claimed": [{"kind": "CHEST", "name": "Old chest"}, {"kind": "MONSTER", "name": "Culvert Troll"}],
        "fights": [
            {"name": "Culvert Troll", "speciesId": "fen-troll", "outcome": "SEEN_OFF"},
            {"name": "Mossy Hedge Dragon", "speciesId": "hedge-dragon", "outcome": "LOOSENED"},
        ],
    },
    "newCells": 12,
    "questCompleted": False,
    "streak": {"days": 3},
}


def test_the_model_is_given_categories_never_names_of_places():
    facts = written.facts_for("RIDE", 18_400, SUMMARY)
    assert facts == {
        "activity": "ride",
        "distance": "medium",
        "creaturesDefeated": ["Fen Troll"],
        "creaturesWeakened": ["Hedge Dragon"],
        "chestsOpened": 1,
        "newTiles": 12,
        "questDone": False,
        "streakDays": 3,
    }
    assert written.distance_band("WALK", 3000) == "medium" and written.distance_band("RIDE", 3000) == "short"
    prompt = written.prompt_for(facts)
    assert "Culvert" not in prompt and "Mayflower" not in prompt


def test_what_the_model_wrote_is_checked_before_it_is_kept():
    facts = written.facts_for("RIDE", 18_400, SUMMARY)
    good = written.sentences(
        "A ride of middling length, with 12 new tiles explored along the way. "
        "The Fen Troll was defeated and a chest was opened! Your streak is 3 days now."
    )
    assert len(good) == 3 and written.problems(good, facts) == []
    assert written.problems(written.sentences("Just one sentence here."), facts)
    named = written.sentences("A ride past Greenwich today. The Fen Troll was defeated.")
    assert any("Greenwich" in p for p in written.problems(named, facts))
    counted = written.sentences("You rode 18 km today. The Fen Troll was defeated.")
    assert any("18" in p for p in written.problems(counted, facts))
    worded = written.sentences("Seven chests were opened. The Fen Troll was defeated.")
    assert any("Seven" in p for p in written.problems(worded, facts))
    jargon = written.sentences("You found loot in a chest on the ride. The Fen Troll was slain.")
    assert len(written.problems(jargon, facts)) >= 2
    quiet = {**facts, "creaturesDefeated": [], "questDone": False}
    cheer = written.sentences("A short ride today! Nothing much happened.")
    assert written.problems(cheer, quiet), "an exclamation mark is for a celebration only"


class Scripted:
    enabled = True

    def __init__(self, reply: str | None) -> None:
        self.reply = reply
        self.asked: list[str] = []

    async def write(self, system: str, user: str, *, max_tokens: int = 200, timeout: float = 8.0) -> str | None:
        assert max_tokens == 200 and timeout == 8.0
        self.asked.append(user)
        return self.reply


@pytest.fixture
def chronicle_on(settings, monkeypatch):
    monkeypatch.setattr(settings, "feature_flags", "chronicle_llm")
    return settings


async def a_ride(c) -> uuid.UUID:
    start = ORIGIN
    from app.core.geo import destination_point

    end = destination_point(start[0], start[1], 90, 2500)
    summary = await ride(c, line_trace(start, end, speed_mps=5))
    assert summary["entry"]
    return uuid.UUID(summary["ride"]["id"])


async def test_a_passing_entry_is_kept_beside_the_composed_one(explorer_client, settings, monkeypatch):
    c = explorer_client
    ride_id = await a_ride(c)
    model = Scripted("A short ride on known roads. The streak goes on for 1 day.")
    async with get_session_factory()() as db:
        assert await written.write_entry(db, settings, model, ride_id) is None, "the flag is off"
    assert model.asked == []
    monkeypatch.setattr(settings, "feature_flags", "chronicle_llm")
    async with get_session_factory()() as db:
        kept = await written.write_entry(db, settings, model, ride_id)
        await db.commit()
    assert kept == {"lines": ["A short ride on known roads.", "The streak goes on for 1 day."], "by": "model"}
    assert "Rotherhithe" not in model.asked[0]
    summary = (await c.get(f"/rides/{ride_id}/summary")).json()
    assert summary["entryWritten"] == kept and summary["entry"], "the composed entry stays"
    assert summary["ride"]["entryWritten"] == kept
    journal = (await c.get("/journal/adventures")).json()["items"]
    assert journal[0]["entryWritten"] == kept
    # Asked once per ride.
    async with get_session_factory()() as db:
        assert await written.write_entry(db, settings, Scripted("Other words. Other lines."), ride_id) == kept


async def test_a_failing_entry_is_not_kept_and_six_a_day_is_the_most(explorer_client, chronicle_on):
    c = explorer_client
    ride_id = await a_ride(c)
    async with get_session_factory()() as db:
        assert (
            await written.write_entry(db, chronicle_on, Scripted("A ride through Deptford. Lovely."), ride_id) is None
        )
        await db.commit()
    summary = (await c.get(f"/rides/{ride_id}/summary")).json()
    assert summary["entryWritten"] is None and summary["entry"]
    async with get_session_factory()() as db:
        row = await db.get(Ride, ride_id)
        assert row.processing_result["entryTried"] is True
        user_id = row.user_id
    # Five more tries today, and the seventh ride is not asked about.
    for _ in range(5):
        await a_ride(c)
    async with get_session_factory()() as db:
        for row in (await db.execute(select(Ride).where(Ride.user_id == user_id))).scalars():
            row.processing_result = {**row.processing_result, "entryTried": True}
        await db.commit()
        assert await written.written_today(db, user_id) == 6
    last = await a_ride(c)
    model = Scripted("A short ride. A good one.")
    async with get_session_factory()() as db:
        assert await written.write_entry(db, chronicle_on, model, last) is None
    assert model.asked == []


async def test_the_job_runs_after_the_ride_is_processed(explorer_client, chronicle_on, monkeypatch):
    from app.jobs import handlers

    asked: list[str] = []

    async def fake_write_entry(payload):
        asked.append(payload["rideId"])

    monkeypatch.setitem(handlers.HANDLERS, "write_entry", fake_write_entry)
    ride_id = await a_ride(explorer_client)
    assert asked == [str(ride_id)]


async def test_a_model_that_times_out_leaves_the_composed_entry(explorer_client, chronicle_on):

    class Slow(Scripted):
        async def write(self, system, user, *, max_tokens=200, timeout=8.0):
            raise TimeoutError

    ride_id = await a_ride(explorer_client)
    async with get_session_factory()() as db:
        assert await written.write_entry(db, chronicle_on, Slow(None), ride_id) is None
