"""The Atlas (0.9.0): every trace of a year, the calendar and the year in numbers."""

from __future__ import annotations

import math
from datetime import UTC, datetime, timedelta

from sqlalchemy import select

from app.core.geo import decode_polyline, destination_point
from app.db.session import get_session_factory
from app.districts.models import UserRegion
from app.rides import atlas
from app.world_objects.models import WorldObject
from tests.test_districts import add_region, me
from tests.test_first_playable_journey import ORIGIN
from tests.test_lairs_and_treasure import through
from tests.test_world_objects import ride


def test_a_track_is_simplified_to_200_points_and_keeps_its_shape():
    straight = [destination_point(ORIGIN[0], ORIGIN[1], 90, d) for d in range(0, 5000, 5)]
    line = atlas.simplify(straight)
    assert len(line) <= 3 and line[0] == straight[0] and line[-1] == straight[-1]
    wiggly = [destination_point(ORIGIN[0], ORIGIN[1], (i * 7) % 360, 500 + 300 * math.sin(i / 3)) for i in range(1500)]
    out = atlas.simplify(wiggly)
    assert len(out) <= 200 and out[0] == wiggly[0] and out[-1] == wiggly[-1]
    short = wiggly[:150]
    assert atlas.simplify(short) == short


async def test_the_atlas_has_every_trace_the_calendar_and_the_year(explorer_client, monkeypatch):
    long_way = [ORIGIN, *(destination_point(ORIGIN[0], ORIGIN[1], b, 1500) for b in range(0, 361, 15)), ORIGIN]
    first = await ride(explorer_client, through(long_way, ends_ago=timedelta(minutes=30)))
    second = await ride(explorer_client, through([ORIGIN, destination_point(ORIGIN[0], ORIGIN[1], 0, 800)]))
    year = datetime.now(UTC).year
    r = await explorer_client.get("/journal/atlas", params={"year": year})
    assert r.status_code == 200, r.text
    body = r.json()
    assert [t["rideId"] for t in body["traces"]] == [first["ride"]["id"], second["ride"]["id"]]
    for trace in body["traces"]:
        points = decode_polyline(trace["polyline"])
        assert 2 <= len(points) <= 200 and trace["activity"] == "RIDE" and trace["date"].startswith(str(year))
    total = first["ride"]["distanceMeters"] + second["ride"]["distanceMeters"]
    assert sum(d["journeys"] for d in body["days"]) == 2
    assert abs(sum(d["distanceMeters"] for d in body["days"]) - total) < 1
    the_year = body["year"]
    assert the_year["year"] == year and the_year["journeys"] == 2 and abs(the_year["distanceMeters"] - total) < 1
    assert the_year["newTiles"] == first["newCells"] + second["newCells"]
    longest = next(f for f in the_year["firsts"] if f["kind"] == "LONGEST_JOURNEY")
    assert longest["text"] == f"Longest journey: {first['ride']['distanceMeters'] / 1000:.1f} km."
    assert any(f["kind"] == "HIGHEST_POINT" for f in the_year["firsts"])
    assert the_year["deedsReached"] == [] and the_year["districtsYours"] == 0
    # The default is this year; another year is empty.
    assert (await explorer_client.get("/journal/atlas")).json()["year"]["journeys"] == 2
    empty = (await explorer_client.get("/journal/atlas", params={"year": year - 5})).json()
    assert empty["traces"] == [] and empty["days"] == [] and empty["year"]["firsts"] == []
    # At most 1,000 traces: the newest.
    monkeypatch.setattr(atlas, "MAX_TRACES", 1)
    capped = (await explorer_client.get("/journal/atlas", params={"year": year})).json()
    assert [t["rideId"] for t in capped["traces"]] == [second["ride"]["id"]]
    assert capped["year"]["journeys"] == 2, "the numbers count every journey"


async def test_the_years_firsts(explorer_client):
    character = await me()
    now = datetime.now(UTC)
    rid = await add_region("Rotherhithe", ORIGIN)
    async with get_session_factory()() as db:
        db.add(
            WorldObject(user_id=character.user_id, kind="MONSTER", status="CLAIMED", tier=1, latitude=ORIGIN[0],
                        longitude=ORIGIN[1], seed="first", payload={"name": "Fen Troll"}, spawned_at=now,
                        expires_at=now + timedelta(days=1), claimed_at=now)
        )  # fmt: skip
        db.add(
            UserRegion(user_id=character.user_id, region_id=rid, explored_cells=10, way_cells_explored=9,
                       first_passed_at=now, last_passed_at=now, completed_at=now, yours_since=now)
        )  # fmt: skip
        await db.commit()
    body = (await explorer_client.get("/journal/atlas")).json()["year"]
    texts = {f["kind"]: f["text"] for f in body["firsts"]}
    assert texts["FIRST_CREATURE"] == "First creature defeated: Fen Troll."
    assert texts["FIRST_DISTRICT_COMPLETE"] == "First district complete: Rotherhithe!"
    assert body["creaturesDefeated"] == 1 and body["districtsYours"] == 1
    async with get_session_factory()() as db:
        assert await db.scalar(select(UserRegion.id)) is not None
