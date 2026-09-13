"""Runners and walkers: the same world, on foot."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

from app.core.activity import comfortable_distance_km, normalise
from app.quests.templates import all_templates, templates_for
from app.rides.validation import validate_points
from app.routing.custom_models import valhalla_costing
from app.routing.preferences import RoutePreferences
from tests.test_first_playable_journey import ORIGIN, seed_discoveries


def _trace(speed_mps: float, seconds: int = 40) -> list[dict]:
    t0 = datetime(2026, 6, 1, 9, 0, tzinfo=UTC)
    return [
        {
            "latitude": 51.49 + i * speed_mps / 111_195,
            "longitude": -0.03,
            "timestamp": (t0 + timedelta(seconds=i)).isoformat(),
            "horizontalAccuracyMeters": 5,
        }
        for i in range(seconds)
    ]


def test_a_run_at_cycling_speed_is_not_a_run():
    thirty_kmh = _trace(8.4)
    assert "IMPOSSIBLE_SPEED" in validate_points(thirty_kmh, activity="RUN").flags
    assert "IMPOSSIBLE_SPEED" not in validate_points(thirty_kmh, activity="RIDE").flags
    assert "IMPOSSIBLE_SPEED" in validate_points(_trace(4.5), activity="WALK").flags
    assert "IMPOSSIBLE_SPEED" not in validate_points(_trace(3.0), activity="WALK").flags


def test_activity_spelling_and_defaults():
    assert normalise("run") == "RUN" and normalise(None) == "RIDE" and normalise("swim") == "RIDE"

    class Profile:
        comfortable_distance_km = 30.0
        run_distance_km = 9.0
        walk_distance_km = 4.0

    assert comfortable_distance_km(Profile(), "RIDE") == 30.0
    assert comfortable_distance_km(Profile(), "RUN") == 9.0
    assert comfortable_distance_km(Profile(), "WALK") == 4.0


def test_feet_get_pedestrian_costing():
    prefs = RoutePreferences(trafficAversion=0.9, hillTolerance=0.3, gravelPreference=0.7)
    foot = valhalla_costing(prefs, "HYBRID", True, False, "RUN")
    assert "bicycle_type" not in foot
    assert foot["walking_speed"] == 9.5 and foot["use_tracks"] == 0.7 and foot["use_hills"] == 0.3
    assert foot["walkway_factor"] < 1.0, "quiet means footways"
    assert "bicycle_type" in valhalla_costing(prefs, "HYBRID", True, False, "RIDE")


def test_templates_say_which_activities_suit_them():
    for_runs = templates_for("EXPLORER", 1, activity="RUN")
    assert for_runs, "nothing for a runner to do"
    assert all("RUN" in t.get("activities", ["RIDE"]) for t in for_runs)
    gravel_only = [t for t in all_templates() if t.get("objectiveRules", {}).get("requiresGravel")]
    assert gravel_only and all(t.get("activities", ["RIDE"]) == ["RIDE"] for t in gravel_only)
    assert {t["id"] for t in templates_for("EXPLORER", 1)} >= {t["id"] for t in for_runs} - {
        t["id"] for t in templates_for("EXPLORER", 1)
    }


async def test_a_run_is_recorded_as_a_run_and_checked_as_one(explorer_client):
    c = explorer_client
    r = await c.post(
        "/rides", json={"clientRideId": str(uuid.uuid4()), "startedAt": "2026-06-01T09:00:00Z", "activity": "RUN"}
    )
    assert r.status_code == 201, r.text
    assert r.json()["activity"] == "RUN"
    assert (await c.get(f"/rides/{r.json()['id']}")).json()["activity"] == "RUN"
    r = await c.post("/rides", json={"clientRideId": str(uuid.uuid4()), "startedAt": "2026-06-01T09:00:00Z"})
    assert r.json()["activity"] == "RIDE", "a ride is still the default"


async def test_quests_for_a_runner_are_run_sized(explorer_client):
    c = explorer_client
    await seed_discoveries()
    r = await c.post(
        "/quests/generate", json={"latitude": ORIGIN[0], "longitude": ORIGIN[1], "count": 3, "activity": "RUN"}
    )
    assert r.status_code == 200, r.text
    quests = r.json()["items"]
    assert quests, "no quests for a runner"
    for quest in quests:
        assert quest["activity"] == "RUN"
        assert quest["recommendedDistanceKm"] <= 15, quest["title"]
        assert "RUN" in next(t for t in all_templates() if t["id"] == quest["templateId"]).get("activities", [])
        for objective in quest["objectives"]:
            assert "Ride" not in objective["title"].split() and "ride" not in objective["title"].split(), objective[
                "title"
            ]


async def test_a_walker_plans_walks_by_default(explorer_client):
    c = explorer_client
    r = await c.get("/character/rider-profile")
    profile = r.json()
    assert profile["defaultActivity"] == "RIDE" and profile["walkDistanceKm"] == 5.0
    profile["defaultActivity"] = "WALK"
    profile["walkDistanceKm"] = 3.0
    r = await c.put("/character/rider-profile", json=profile)
    assert r.status_code == 200 and r.json()["defaultActivity"] == "WALK", r.text

    r = await c.post("/routes/generate", json={"origin": {"latitude": ORIGIN[0], "longitude": ORIGIN[1]}, "loop": True})
    assert r.status_code == 200, r.text
    alternatives = r.json()["alternatives"]
    assert {a["activity"] for a in alternatives} == {"WALK"}
    assert {a["label"] for a in alternatives} <= {
        "Direct",
        "Parks",
        "Longer",
        "As asked",
        "The long way",
        "Another way",
    }
    for a in alternatives:
        # A walk of about three kilometres, timed at walking pace, not a 25 km ride at 15 km/h.
        assert a["distanceMeters"] < 8000, a["distanceMeters"]
        assert abs(a["estimatedDurationSeconds"] - a["distanceMeters"] / (4.8 / 3.6)) < 2

    # Asking for a run overrides the profile for that plan only.
    r = await c.post(
        "/routes/generate",
        json={"origin": {"latitude": ORIGIN[0], "longitude": ORIGIN[1]}, "loop": True, "activity": "RUN"},
    )
    assert r.status_code == 200, r.text
    assert {a["activity"] for a in r.json()["alternatives"]} == {"RUN"}
