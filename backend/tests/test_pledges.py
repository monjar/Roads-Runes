"""The pledge (0.7.3): a creature or quest promised for a day. Kept, Journey's end
says so; missed, nothing is ever said."""

from __future__ import annotations

import uuid
from datetime import UTC, date, datetime, timedelta

import pytest
from sqlalchemy import delete, func, select

from app.between import pledges
from app.between.models import Letter, Pledge
from app.core.config import Settings
from app.db.session import get_session_factory
from app.lore.voice import violations
from app.quests.models import QuestInstance, QuestObjective
from app.rides.models import Ride, RideRoute
from tests.test_effort_combat import past, place_monster
from tests.test_first_playable_journey import ORIGIN

TODAY = datetime.now(UTC).date()
TOMORROW = TODAY + timedelta(days=1)


@pytest.fixture
def pledge_on(settings, monkeypatch):
    monkeypatch.setattr(settings, "feature_flags", "pledge,effort_combat")
    return settings


async def ride(c, pts: list[dict], *, local_date: date | None = None, quest_id: str | None = None,
               events: list[dict] | None = None) -> dict:  # fmt: skip
    from app.core.geo import haversine_m

    body = {"clientRideId": str(uuid.uuid4()), "startedAt": pts[0]["timestamp"]}
    if local_date is not None:
        body["localDate"] = local_date.isoformat()
    if quest_id:
        body["questId"] = quest_id
    r = await c.post("/rides", json=body)
    assert r.status_code == 201, r.text
    ride_id = r.json()["id"]
    distance = sum(haversine_m(a["latitude"], a["longitude"], b["latitude"], b["longitude"])
                   for a, b in zip(pts, pts[1:], strict=False))  # fmt: skip
    r = await c.post(f"/rides/{ride_id}/complete", json={
        "endedAt": pts[-1]["timestamp"], "distanceMeters": distance, "durationSeconds": len(pts) * 5,
        "elevationGainMeters": 0, "points": pts, "encounterEvents": events or []})  # fmt: skip
    assert r.status_code == 200, r.text
    r = await c.get(f"/rides/{ride_id}/summary")
    assert r.status_code == 200, r.text
    return r.json()


def word_at(object_id: str, pts: list[dict]) -> list[dict]:
    """A note left at the creature halfway: with effort combat, the word it wants."""
    middle = pts[len(pts) // 2]
    return [{"objectId": object_id, "method": "LORE", "occurredAt": middle["timestamp"],
             "latitude": middle["latitude"], "longitude": middle["longitude"],
             "note": "A troll asleep by the water, snoring."}]  # fmt: skip


async def a_troll() -> str:
    return await place_monster("fen-troll", tier=3, wants=["ROAD", "WORD"], minds=["CLIMB"], holdMax=100)


async def put(c, day: date, kind: str, target_id: str, remind_at: str | None = None):
    body = {"day": day.isoformat(), "targetKind": kind, "targetId": target_id}
    if remind_at:
        body["remindAt"] = remind_at
    return await c.put("/pledge", json=body)


async def a_quest(c, status: str = "ACCEPTED", metres: float = 500) -> str:
    user_id = uuid.UUID((await c.get("/users/me")).json()["id"])
    async with get_session_factory()() as db:
        quest = QuestInstance(
            user_id=user_id, template_id="TEST", quest_type="DISTANCE", character_class="ANY",
            title="The Long Way", description="Go the long way.", difficulty="EASY", status=status,
            recommended_distance_km=2, estimated_duration_minutes=20, base_xp=100, latitude=ORIGIN[0],
            longitude=ORIGIN[1], rewards={"xp": 100, "ac": 20, "items": [], "titles": []},
        )  # fmt: skip
        quest.objectives.append(
            QuestObjective(
                objective_type="COMPLETE_DISTANCE",
                title="Ride 500 m",
                target_meters=metres,
                progress_target=metres,
                required=True,
                order=1,
                extra={},
            )  # fmt: skip
        )
        db.add(quest)
        await db.commit()
        return str(quest.id)


def test_the_flag_is_on_where_the_game_is_made_and_off_elsewhere():
    assert Settings(environment="development").flags["pledge"] is True
    assert Settings(environment="development", feature_flags="!pledge").flags["pledge"] is False
    assert Settings(environment="production").flags["pledge"] is False
    assert Settings(environment="production", feature_flags="pledge").flags["pledge"] is True
    for env in ("development", "production", "test"):
        assert Settings(environment=env).flags["parchment_map"] is False


async def test_config_lists_both_new_flags(client):
    flags = (await client.get("/config")).json()["featureFlags"]
    assert flags["pledge"] is False and flags["parchment_map"] is False  # the test environment


async def test_the_pledge_is_behind_its_flag(explorer_client):
    r = await explorer_client.get("/pledge", params={"today": TODAY.isoformat()})
    assert r.status_code == 403 and r.json()["error"]["code"] == "FEATURE_DISABLED"


async def test_a_creature_pledged_for_tomorrow_is_read_back_and_a_second_replaces_it(explorer_client, pledge_on):
    c = explorer_client
    troll = await a_troll()
    r = await put(c, TOMORROW, "CREATURE", troll, "07:30")
    assert r.status_code == 200, r.text
    assert r.json() == {"day": TOMORROW.isoformat(), "targetKind": "CREATURE", "targetId": troll,
                        "targetName": "Fen Troll", "icon": "troll", "remindAt": "07:30", "status": "PLEDGED"}  # fmt: skip
    r = await c.get("/pledge", params={"today": TODAY.isoformat()})
    assert r.status_code == 200, r.text
    assert r.json()["today"] is None and r.json()["tomorrow"]["targetId"] == troll
    quest = await a_quest(c)
    r = await put(c, TOMORROW, "QUEST", quest)
    assert r.status_code == 200, r.text
    assert r.json()["targetName"] == "The Long Way" and r.json()["icon"] == "scroll" and r.json()["remindAt"] is None
    async with get_session_factory()() as db:
        assert await db.scalar(select(func.count(Pledge.id))) == 1
    # Seen from tomorrow, it is today's.
    r = await c.get("/pledge", params={"today": TOMORROW.isoformat()})
    assert r.json()["today"]["targetId"] == quest and r.json()["tomorrow"] is None
    r = await c.delete(f"/pledge/{TOMORROW.isoformat()}")
    assert r.status_code == 204
    assert (await c.get("/pledge", params={"today": TODAY.isoformat()})).json() == {"today": None, "tomorrow": None}
    assert (await c.delete(f"/pledge/{TOMORROW.isoformat()}")).status_code == 204


async def test_only_a_live_creature_or_an_open_quest_and_only_today_or_tomorrow(explorer_client, pledge_on):
    c = explorer_client
    for kind, target in (("CREATURE", str(uuid.uuid4())), ("QUEST", await a_quest(c, status="COMPLETED"))):
        r = await put(c, TODAY, kind, target)
        assert r.status_code == 404, r.text
        assert r.json()["error"]["message"] == "That creature or quest isn't on your map any more. Pick another."
    troll = await a_troll()
    r = await put(c, TODAY + timedelta(days=5), "CREATURE", troll)
    assert r.status_code == 400 and r.json()["error"]["code"] == "PLEDGE_DAY"
    r = await put(c, TODAY, "CREATURE", troll, "25:00")
    assert r.status_code == 400 and r.json()["error"]["code"] == "VALIDATION_ERROR"


async def test_defeating_the_creature_keeps_the_pledge_and_says_so(explorer_client, pledge_on):
    c = explorer_client
    troll = await a_troll()
    assert (await put(c, TODAY, "CREATURE", troll)).status_code == 200
    pts = past(800, 1600)
    summary = await ride(c, pts, local_date=TODAY, events=word_at(troll, pts))
    assert summary["worldObjects"]["fights"][0]["outcome"] == "SEEN_OFF"
    kept = summary["pledge"]
    assert kept["kept"] is True and kept["targetName"] == "Fen Troll" and kept["icon"] == "troll"
    assert kept["line"] == "You said you would. You did."
    state = (await c.get("/pledge", params={"today": TODAY.isoformat()})).json()
    assert state["today"]["status"] == "KEPT"
    # Counted again, the same journey keeps the same pledge.
    from app.rides.processing import process_ride

    async with get_session_factory()() as db:
        row = await db.scalar(select(Ride).where(Ride.status == "PROCESSED"))
        row.status = "UPLOADED"
        await db.execute(delete(RideRoute).where(RideRoute.ride_id == row.id))
        await db.commit()
    async with get_session_factory()() as db:
        again = await process_ride(db, pledge_on, row.id)
        await db.commit()
    assert again["pledge"]["targetId"] == troll


async def test_the_phone_s_own_date_picks_the_day(explorer_client, pledge_on):
    c = explorer_client
    troll = await a_troll()
    assert (await put(c, TODAY, "CREATURE", troll)).status_code == 200
    assert (await put(c, TOMORROW, "CREATURE", troll)).status_code == 200
    pts = past(800, 1600)
    summary = await ride(c, pts, local_date=TOMORROW, events=word_at(troll, pts))
    assert summary["pledge"]["day"] == TOMORROW.isoformat()
    state = (await c.get("/pledge", params={"today": TODAY.isoformat()})).json()
    assert state["today"]["status"] == "PLEDGED" and state["tomorrow"]["status"] == "KEPT"


async def test_finishing_the_quest_keeps_its_pledge(explorer_client, pledge_on):
    c = explorer_client
    quest = await a_quest(c)
    assert (await put(c, TODAY, "QUEST", quest)).status_code == 200
    summary = await ride(c, past(800, 1600), local_date=TODAY, quest_id=quest)
    assert summary["questCompletion"] is not None
    assert summary["pledge"]["targetKind"] == "QUEST" and summary["pledge"]["targetName"] == "The Long Way"


async def test_a_missed_pledge_is_never_mentioned(explorer_client, pledge_on):
    c = explorer_client
    troll = await a_troll()
    yesterday = TODAY - timedelta(days=1)
    assert (await put(c, yesterday, "CREATURE", troll)).status_code == 200
    state = (await c.get("/pledge", params={"today": TODAY.isoformat()})).json()
    assert state == {"today": None, "tomorrow": None}
    async with get_session_factory()() as db:
        assert (await db.scalar(select(Pledge))).status == "MISSED"
    # A journey today that does not reach it says nothing of it, and charges nothing.
    summary = await ride(c, past(800, 300, bearing=0), local_date=TODAY)
    assert "pledge" not in summary or summary["pledge"] is None
    assert not any("PLEDGE" in str(line).upper() for line in summary["acBreakdown"] + summary["xpBreakdown"])


async def test_a_journey_counted_after_midnight_still_keeps_its_day(explorer_client, pledge_on):
    """Marked missed by a look at the board after midnight, then counted: kept."""
    c = explorer_client
    troll = await a_troll()
    yesterday = TODAY - timedelta(days=1)
    assert (await put(c, yesterday, "CREATURE", troll)).status_code == 200
    await c.get("/pledge", params={"today": TODAY.isoformat()})
    pts = past(800, 1600)
    summary = await ride(c, pts, local_date=yesterday, events=word_at(troll, pts))
    assert summary["pledge"]["day"] == yesterday.isoformat()


async def test_a_failure_keeping_the_pledge_never_loses_the_journey(explorer_client, pledge_on, monkeypatch):
    c = explorer_client
    troll = await a_troll()
    assert (await put(c, TODAY, "CREATURE", troll)).status_code == 200

    async def broken(*args, **kwargs):
        raise RuntimeError("the pledge book is wet")

    monkeypatch.setattr(pledges, "keep", broken)
    pts = past(800, 1600)
    summary = await ride(c, pts, local_date=TODAY, events=word_at(troll, pts))
    assert summary["ride"]["status"] == "PROCESSED" and summary["xpAwarded"] > 0
    assert summary.get("pledge") is None and summary["letters"] == []


async def test_a_new_character_starts_without_pledges_or_letters(explorer_client, pledge_on):
    c = explorer_client
    assert (await put(c, TODAY, "CREATURE", await a_troll())).status_code == 200
    r = await c.post("/letters", json={"latitude": ORIGIN[0], "longitude": ORIGIN[1], "text": "Hello, later me."})
    assert r.status_code == 201, r.text
    assert (await c.delete("/character")).status_code == 204
    async with get_session_factory()() as db:
        assert await db.scalar(select(func.count(Pledge.id))) == 0
        assert await db.scalar(select(func.count(Letter.id))) == 0


def test_the_pledge_s_words_keep_the_voice_and_fit_their_columns():
    for line in (pledges.KEPT_LINE, pledges.TARGET_GONE, pledges.WRONG_DAY):
        assert not violations(line, glossary=True), line
    widths = {c.name: c.type.length for c in Pledge.__table__.c if getattr(c.type, "length", None)}
    assert widths == {"target_kind": 12, "target_name": 160, "remind_at": 5, "status": 10}
    assert all(len(k) <= widths["target_kind"] for k in ("CREATURE", "QUEST"))
    assert all(len(s) <= widths["status"] for s in ("PLEDGED", "KEPT", "MISSED"))
    assert len("23:59") == widths["remind_at"]
