"""Letters to your future self (0.7.3): left at a place, found again a season later."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace

from sqlalchemy import select

from app.between import letters
from app.between.models import Letter
from app.core.geo import destination_point
from app.db.session import get_session_factory
from app.discoveries.models import Discovery
from app.lore.voice import violations
from tests.conftest import sign_in
from tests.test_effort_combat import past
from tests.test_first_playable_journey import ORIGIN
from tests.test_pledges import ride


async def write(c, text: str, at=ORIGIN):
    return await c.post("/letters", json={"latitude": at[0], "longitude": at[1], "text": text})


async def age(letter_id: str, days: int) -> None:
    async with get_session_factory()() as db:
        row = await db.get(Letter, uuid.UUID(letter_id))
        row.written_at = datetime.now(UTC) - timedelta(days=days)
        await db.commit()


async def test_a_letter_is_trimmed_named_by_the_place_beside_it_and_listed_newest_first(explorer_client):
    c = explorer_client
    near = destination_point(ORIGIN[0], ORIGIN[1], 45, 50)
    async with get_session_factory()() as db:
        db.add(Discovery(name="The Mayflower", category="PUB", latitude=near[0], longitude=near[1], source="OSM"))
        await db.commit()
    r = await write(c, "  The bench by the river gets the sun at four.  ")
    assert r.status_code == 201, r.text
    first = r.json()
    assert first["text"] == "The bench by the river gets the sun at four."
    assert first["placeName"] == "The Mayflower" and first["shownAt"] is None
    far = destination_point(ORIGIN[0], ORIGIN[1], 0, 3000)
    second = (await write(c, "x" * 140, at=far)).json()
    assert second["placeName"] is None and len(second["text"]) == 140
    listed = (await c.get("/letters")).json()
    assert [row["id"] for row in listed] == [second["id"], first["id"]]
    assert (await c.delete(f"/letters/{second['id']}")).status_code == 204
    r = await c.delete(f"/letters/{second['id']}")
    assert r.status_code == 404 and r.json()["error"]["message"] == letters.GONE
    assert [row["id"] for row in (await c.get("/letters")).json()] == [first["id"]]


async def test_an_empty_or_long_letter_is_refused_in_plain_words(explorer_client):
    c = explorer_client
    r = await write(c, "   ")
    assert r.status_code == 400 and r.json()["error"]["code"] == "LETTER_EMPTY"
    r = await write(c, "y" * 141)
    assert r.status_code == 400 and r.json()["error"]["code"] == "LETTER_TOO_LONG"
    for line in (letters.EMPTY, letters.TOO_LONG, letters.GONE):
        assert not violations(line, glossary=True), line


async def test_someone_else_s_letter_is_not_yours_to_read_or_delete(explorer_client):
    c = explorer_client
    mine = (await write(c, "Only for me.")).json()
    await sign_in(c, subject="other", name="Other")
    assert (await c.get("/letters")).json() == []
    assert (await c.delete(f"/letters/{mine['id']}")).status_code == 404


async def test_a_letter_a_season_old_is_found_once_by_a_journey_that_passes_it(explorer_client):
    c = explorer_client
    beside = (await write(c, "Remember the heron.", at=destination_point(ORIGIN[0], ORIGIN[1], 0, 40))).json()
    too_far = (await write(c, "Too far off.", at=destination_point(ORIGIN[0], ORIGIN[1], 0, 200))).json()
    too_new = (await write(c, "Too new.", at=destination_point(ORIGIN[0], ORIGIN[1], 180, 30))).json()
    await age(beside["id"], 120)
    await age(too_far["id"], 120)
    await age(too_new["id"], 30)
    summary = await ride(c, past(600, 1200))
    [found] = summary["letters"]
    assert found["id"] == beside["id"] and found["text"] == "Remember the heron."
    assert found["line"].startswith("You wrote this here in ") and found["line"].endswith(".")
    listed = {row["id"]: row for row in (await c.get("/letters")).json()}
    assert listed[beside["id"]]["shownAt"] is not None and listed[beside["id"]]["shownRideId"] == summary["ride"]["id"]
    assert listed[too_far["id"]]["shownAt"] is None and listed[too_new["id"]]["shownAt"] is None
    # Shown once: the next journey past it says nothing.
    again = await ride(c, past(600, 1200))
    assert again["letters"] == []


async def test_how_old_a_letter_must_be_is_configured(explorer_client, settings, monkeypatch):
    c = explorer_client
    letter = (await write(c, "Ten days on.")).json()
    await age(letter["id"], 10)
    assert (await ride(c, past(600, 1200)))["letters"] == []
    monkeypatch.setattr(settings, "letter_min_age_days", 7)
    assert [row["id"] for row in (await ride(c, past(600, 1200)))["letters"]] == [letter["id"]]
    assert (await c.get("/config")).json()["letterMinAgeDays"] == 7


async def test_a_failure_finding_letters_never_loses_the_journey(explorer_client, monkeypatch):
    """A database error in the savepoint, not only a Python one: the journey still counts."""
    from app.between.models import Pledge

    c = explorer_client
    letter = (await write(c, "Still here?")).json()
    await age(letter["id"], 120)

    async def broken(db, settings, ride_row, points, ended):
        db.add(Pledge(user_id=ride_row.user_id, day=None, target_kind="QUEST", target_id=uuid.uuid4(),
                      target_name="x", status="PLEDGED"))  # fmt: skip
        await db.flush()  # NOT NULL: the savepoint is rolled back

    monkeypatch.setattr(letters, "found_on", broken)
    summary = await ride(c, past(600, 1200))
    assert summary["ride"]["status"] == "PROCESSED" and summary["xpAwarded"] > 0
    assert summary.get("letters") is None
    async with get_session_factory()() as db:
        assert (await db.scalar(select(Letter))).shown_at is None
        assert (await db.scalar(select(Pledge))) is None


def test_the_found_line_names_the_month_and_the_year_only_when_it_was_another():
    ride_day = datetime(2026, 10, 5, 9, tzinfo=UTC)
    assert letters.found_line(datetime(2026, 6, 1, tzinfo=UTC), ride_day) == "You wrote this here in June."
    assert letters.found_line(datetime(2025, 10, 3, tzinfo=UTC), ride_day) == "You wrote this here in October 2025."
    assert not violations(letters.found_line(datetime(2026, 6, 1, tzinfo=UTC), ride_day), glossary=True)


def test_a_fast_pass_between_two_fixes_still_finds_the_letter():
    a = SimpleNamespace(latitude=ORIGIN[0], longitude=ORIGIN[1])
    b_lat, b_lon = destination_point(ORIGIN[0], ORIGIN[1], 90, 400)
    b = SimpleNamespace(latitude=b_lat, longitude=b_lon)
    mid = destination_point(*destination_point(ORIGIN[0], ORIGIN[1], 90, 200), 0, 45)
    assert letters._passed_within(mid[0], mid[1], [a, b], 60)
    off = destination_point(*destination_point(ORIGIN[0], ORIGIN[1], 90, 200), 0, 75)
    assert not letters._passed_within(off[0], off[1], [a, b], 60)


def test_a_letter_fits_its_columns():
    widths = {c.name: c.type.length for c in Letter.__table__.c if getattr(c.type, "length", None)}
    assert widths == {"text": letters.TEXT_WIDTH, "place_name": letters.PLACE_WIDTH}
    assert letters.TEXT_WIDTH == 140 and letters.PLACE_WIDTH == Discovery.__table__.c.name.type.length
