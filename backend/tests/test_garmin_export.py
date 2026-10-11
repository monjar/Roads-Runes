"""Routes and journeys as files for a Garmin (docs/GARMIN.md, plan step 1).

A planned route is a FIT course: the line and its heights, turns named for the
street, and the places the phone already shows. A journey is a FIT activity of
the fixes processing keeps, which the rider imports into Garmin Connect by hand.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

from garmin_fit_sdk import Decoder, Stream

from app.core import fit
from app.db.session import get_session_factory
from app.quests.models import QuestInstance
from app.quests.schemas import ObjectiveOut, ObjectiveProgress
from app.routing.export import Course, course_name, to_fit_course, to_gpx_course
from app.routing.models import Route
from tests.conftest import sign_in
from tests.test_first_playable_journey import ORIGIN, seed_discoveries, trace_to
from tests.test_sealed_quest import ask

HERE = {"latitude": ORIGIN[0], "longitude": ORIGIN[1]}
WHEN = datetime(2026, 10, 8, 9, 0, tzinfo=UTC)


def decode(body: bytes) -> dict:
    assert Decoder(Stream.from_byte_array(bytearray(body))).check_integrity()
    messages, errors = Decoder(Stream.from_byte_array(bytearray(body))).read()
    assert errors == []
    return messages


def degrees(semicircles: int) -> float:
    return semicircles * 180.0 / 2**31


def a_route(**overrides) -> Route:
    """East along a street, a left, north, then east to a pub: about 1.35 km."""
    route = Route(
        label="Scenic",
        activity="RIDE",
        distance_meters=1350.0,
        estimated_duration_seconds=324,
        elevation_gain_meters=2.0,
        elevation_loss_meters=2.0,
        coordinates=[[-0.040, 51.490, 10.0], [-0.035, 51.490, 12.0], [-0.035, 51.495, 11.0], [-0.030, 51.495, 10.0]],
        instructions=[
            {"sign": "CONTINUE", "coordinateIndex": 0, "streetName": "Salter Road"},
            {"sign": "LEFT", "coordinateIndex": 1, "streetName": "Rotherhithe Street"},
            {"sign": "CONTINUE", "coordinateIndex": 2, "streetName": "Rotherhithe Street"},
            {"sign": "ROUNDABOUT", "coordinateIndex": 2, "streetName": ""},
            {"sign": "FINISH", "coordinateIndex": 3, "streetName": ""},
        ],
        pois=[{"name": "The Mayflower", "category": "PUB", "routePositionMeters": 1340.0}],
    )
    route.created_at = WHEN
    for key, value in overrides.items():
        setattr(route, key, value)
    return route


def objective(title: str, lat: float | None, lon: float | None, status: str = "ACTIVE") -> ObjectiveOut:
    return ObjectiveOut(
        id=uuid.uuid4(),
        objectiveType="VISIT_POI",
        title=title,
        latitude=lat,
        longitude=lon,
        required=True,
        order=0,
        completionRule="ARRIVE",
        status=status,
        progress=ObjectiveProgress(current=0, target=1),
    )


def test_a_route_is_a_course_with_its_line_turns_and_stops():
    route = a_route()
    messages = decode(to_fit_course(Course(route=route, name="Scenic ride 8 Oct", objectives=[]), created=WHEN))
    assert messages["file_id_mesgs"][0]["type"] == "course"
    assert messages["file_id_mesgs"][0]["manufacturer"] == "development"
    assert messages["course_mesgs"] == [{"name": "Scenic ride 8 Oct", "sport": "cycling"}]
    records = messages["record_mesgs"]
    assert len(records) == len(route.coordinates)
    for record, (lon, lat, ele) in zip(records, route.coordinates, strict=True):
        assert abs(degrees(record["position_lat"]) - lat) < 1e-6 and abs(degrees(record["position_long"]) - lon) < 1e-6
        assert record["altitude"] == ele
    # Distance and time only go forward, paced by the route's own estimate.
    assert [r["distance"] for r in records] == sorted(r["distance"] for r in records)
    assert records[0]["timestamp"] == WHEN and records[-1]["timestamp"] > WHEN
    [lap] = messages["lap_mesgs"]
    assert lap["total_distance"] == records[-1]["distance"] and lap["total_ascent"] == 2
    assert [(e["event"], e["event_type"]) for e in messages["event_mesgs"]] == [
        ("timer", "start"),
        ("timer", "stop_disable_all"),
    ]
    # The left turn named for its street (cut at a word), the roundabout, then the
    # pub; no point for a street changing its name, the start or the finish.
    points = messages["course_point_mesgs"]
    assert [(p["type"], p["name"]) for p in points] == [
        ("left", "Rotherhithe"),
        ("generic", "Roundabout"),
        ("food", "The Mayflower"),
    ]
    assert points[0]["distance"] == records[1]["distance"] and points[0]["timestamp"] == records[1]["timestamp"]
    assert points[2]["distance"] == records[3]["distance"]


def test_a_course_shows_only_the_objectives_the_phone_shows():
    on_the_way = objective("Find the old stairs", 51.4951, -0.0351)
    hidden = objective("A riddle's place", None, None)
    done = objective("Already found", 51.4901, -0.0399, status="COMPLETED")
    far_off = objective("Across the river", 51.51, -0.05)
    course = Course(route=a_route(pois=[]), name="Act I", objectives=[on_the_way, hidden, done, far_off])
    points = decode(to_fit_course(course, created=WHEN))["course_point_mesgs"]
    assert ("checkpoint", "Find the old") in [(p["type"], p["name"]) for p in points]
    assert [p["name"] for p in points if p["type"] == "checkpoint"] == ["Find the old"]


def test_a_course_on_foot_and_with_no_estimate_still_has_its_sport_and_times():
    route = a_route(activity="WALK", estimated_duration_seconds=0)
    messages = decode(to_fit_course(Course(route=route, name="Riverside walk", objectives=[]), created=WHEN))
    assert messages["course_mesgs"][0]["sport"] == "walking"
    # At a walk's usual 4.8 km/h, about 1.35 km takes about 17 minutes.
    span = messages["record_mesgs"][-1]["timestamp"] - WHEN
    assert timedelta(minutes=15) < span < timedelta(minutes=19)


def test_a_route_as_gpx_is_a_track_with_its_places_and_no_turns():
    gpx = to_gpx_course(Course(route=a_route(), name="Scenic ride 8 Oct", objectives=[]))
    assert gpx.count("<trkpt") == 4 and "<type>cycling</type>" in gpx and 'creator="Roads &amp; Runes"' in gpx
    assert "<wpt" in gpx and "The Mayflower" in gpx and "Rotherhithe" not in gpx


def test_a_course_is_named_for_its_quest_or_its_kind_and_day():
    assert course_name(a_route(), None) == "Scenic ride 8 Oct"
    assert course_name(a_route(label="As asked", activity="RUN"), None) == "Your run 8 Oct"


def test_a_filename_is_one_a_share_sheet_takes():
    assert fit.filename("Scenic ride 8 Oct", "fit") == "Scenic ride 8 Oct.fit"
    assert fit.filename('The "Ley Line" / Act I', "fit") == "The Ley Line Act I.fit"
    assert fit.filename("Café loop", "gpx") == "Cafe loop.gpx"
    assert fit.filename("???", "fit") == "Roads and Runes.fit"


async def test_a_planned_route_downloads_as_a_course(explorer_client, client):
    c = explorer_client
    r = await c.post("/routes/generate", json={"origin": HERE, "distanceTargetKm": 8, "loop": True})
    assert r.status_code == 200, r.text
    route = r.json()["alternatives"][0]

    r = await c.get(f"/routes/{route['id']}/export")
    assert r.status_code == 200, r.text
    assert r.headers["content-type"] == "application/vnd.ant.fit"
    assert r.headers["content-disposition"].startswith('attachment; filename="')
    assert r.headers["content-disposition"].endswith('.fit"')
    messages = decode(r.content)
    assert messages["file_id_mesgs"][0]["type"] == "course"
    assert len(messages["record_mesgs"]) == len(route["coordinates"])

    r = await c.get(f"/routes/{route['id']}/export", params={"format": "gpx"})
    assert r.status_code == 200 and r.headers["content-type"].startswith("application/gpx+xml")
    assert r.content.count(b"<trkpt") == len(route["coordinates"])

    r = await c.get(f"/routes/{route['id']}/export", params={"format": "kml"})
    assert r.status_code == 400


async def test_someone_elses_route_does_not_download(explorer_client, client):
    r = await explorer_client.post("/routes/generate", json={"origin": HERE, "distanceTargetKm": 5, "loop": True})
    route_id = r.json()["alternatives"][0]["id"]
    await sign_in(client, subject="someone-else", name="Someone")
    r = await client.get(f"/routes/{route_id}/export")
    assert r.status_code == 404


async def test_a_sealed_quest_keeps_its_way_off_the_garmin_until_it_is_done(explorer_client):
    c = explorer_client
    await seed_discoveries()
    quest = await ask(c, 40)
    r = await c.get(f"/routes/{quest['suggestedRouteId']}/export")
    assert r.status_code == 409 and r.json()["error"]["code"] == "ROUTE_SEALED"
    assert "secret" in r.json()["error"]["message"]

    async with get_session_factory()() as db:
        (await db.get(QuestInstance, uuid.UUID(quest["id"]))).status = "COMPLETED"
        await db.commit()
    r = await c.get(f"/routes/{quest['suggestedRouteId']}/export")
    assert r.status_code == 200, r.text
    assert decode(r.content)["course_mesgs"][0]["name"] == "Sealed quest (40 min)"


async def record(c, pts: list[dict], activity: str = "RIDE") -> str:
    r = await c.post(
        "/rides", json={"clientRideId": str(uuid.uuid4()), "startedAt": pts[0]["timestamp"], "activity": activity}
    )
    assert r.status_code == 201, r.text
    ride_id = r.json()["id"]
    r = await c.post(
        f"/rides/{ride_id}/complete",
        json={
            "endedAt": pts[-1]["timestamp"],
            "distanceMeters": 2400.0,
            "durationSeconds": (len(pts) - 1) * 20,
            "elevationGainMeters": 30,
            "points": pts,
        },
    )
    assert r.status_code == 200, r.text
    return ride_id


async def test_a_journey_downloads_as_a_fit_activity_of_the_fixes_kept(explorer_client):
    c = explorer_client
    pts = trace_to((ORIGIN[0] + 0.01, ORIGIN[1]), n=30)
    for i, p in enumerate(pts):
        p["heartRateBpm"] = 120 + i % 20
    # One fix the phone was unsure of by 400 m: processing drops it, and so does the file.
    pts[10] = {**pts[10], "horizontalAccuracyMeters": 400}
    ride_id = await record(c, pts)

    r = await c.get(f"/rides/{ride_id}/export", params={"format": "fit"})
    assert r.status_code == 200, r.text
    assert r.headers["content-type"] == "application/vnd.ant.fit"
    assert r.headers["content-disposition"] == 'attachment; filename="Ride 1 Jun 2026.fit"'
    messages = decode(r.content)
    assert messages["file_id_mesgs"][0]["type"] == "activity"
    records = messages["record_mesgs"]
    assert len(records) == len(pts) - 1
    assert records[0]["timestamp"] == datetime.fromisoformat(pts[0]["timestamp"])
    assert records[0]["heart_rate"] == 120 and records[0]["altitude"] == 10.0 and records[0]["speed"] == 5.0
    assert [r["distance"] for r in records] == sorted(r["distance"] for r in records)
    [session] = messages["session_mesgs"]
    [lap] = messages["lap_mesgs"]
    [activity] = messages["activity_mesgs"]
    assert session["sport"] == "cycling" and session["num_laps"] == 1 and activity["num_sessions"] == 1
    assert lap["total_distance"] == session["total_distance"] and session["total_timer_time"] == (len(pts) - 1) * 20
    assert session["max_heart_rate"] == max(p["heartRateBpm"] for i, p in enumerate(pts) if i != 10)

    # GPX and TCX carry the same kept fixes.
    r = await c.get(f"/rides/{ride_id}/export", params={"format": "gpx"})
    assert r.content.count(b"<trkpt") == len(pts) - 1 and b'creator="Roads &amp; Runes"' in r.content


async def test_a_run_is_exported_as_a_run(explorer_client):
    c = explorer_client
    ride_id = await record(c, trace_to((ORIGIN[0] + 0.004, ORIGIN[1]), n=30), activity="RUN")
    r = await c.get(f"/rides/{ride_id}/export", params={"format": "fit"})
    assert decode(r.content)["session_mesgs"][0]["sport"] == "running"
    r = await c.get(f"/rides/{ride_id}/export", params={"format": "gpx"})
    assert b"<type>running</type>" in r.content
    r = await c.get(f"/rides/{ride_id}/export", params={"format": "tcx"})
    assert b'Sport="Running"' in r.content


async def test_a_journey_with_no_track_says_so(explorer_client):
    r = await explorer_client.post("/rides", json={"clientRideId": str(uuid.uuid4()), "startedAt": WHEN.isoformat()})
    r = await explorer_client.get(f"/rides/{r.json()['id']}/export", params={"format": "fit"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "NO_TRACK"
