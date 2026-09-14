"""End-to-end test of the first playable journey (spec §96) through the HTTP API."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from httpx import AsyncClient

from app.db.session import get_session_factory
from app.discoveries.models import Discovery

ORIGIN = (51.4900, -0.0400)


async def seed_discoveries():
    async with get_session_factory()() as db:
        db.add_all(
            [
                Discovery(
                    name="Greenwich Park",
                    category="NATURE",
                    latitude=51.4769,
                    longitude=0.0005,
                    source="OSM",
                    tags={"leisure": "park"},
                    h3_index=None,
                ),
                Discovery(
                    name="Old Station",
                    category="LANDMARK",
                    latitude=51.5210,
                    longitude=-0.0650,
                    source="OSM",
                    tags={},
                ),
                Discovery(
                    name="Stave Hill",
                    category="VIEWPOINT",
                    latitude=51.4990,
                    longitude=-0.0480,
                    source="OSM",
                    tags={},
                ),
                Discovery(
                    name="The Crown",
                    category="PUB",
                    latitude=51.4950,
                    longitude=-0.0450,
                    source="OSM",
                    tags={},
                ),
                Discovery(
                    name="Thames Path",
                    category="TRAIL",
                    latitude=51.4985,
                    longitude=-0.0300,
                    source="OSM",
                    tags={"water": "river"},
                ),
                Discovery(
                    name="Deptford Creek",
                    category="NATURE",
                    latitude=51.4830,
                    longitude=-0.0230,
                    source="OSM",
                    tags={"natural": "water"},
                ),
            ]
        )
        await db.commit()


def trace_to(target: tuple[float, float], start=ORIGIN, n=120, loop=True):
    """Straight out-and-back GPS trace at ~5 m/s with plausible timestamps."""
    t0 = datetime(2026, 6, 1, 9, 0, tzinfo=UTC)
    pts = []
    total = n if not loop else 2 * n
    for i in range(total + 1):
        frac = i / n if i <= n else (2 * n - i) / n
        lat = start[0] + (target[0] - start[0]) * frac
        lon = start[1] + (target[1] - start[1]) * frac
        pts.append(
            {
                "latitude": lat,
                "longitude": lon,
                "timestamp": (t0 + timedelta(seconds=i * 20)).isoformat(),
                "altitudeMeters": 10 + 30 * frac,
                "horizontalAccuracyMeters": 6,
                "speedMps": 5.0,
            }
        )
    return pts


@pytest.mark.anyio
async def test_first_playable_journey(explorer_client: AsyncClient):
    c = explorer_client
    await seed_discoveries()

    # 6-7. World map with fog; nothing explored yet.
    r = await c.get("/world", params={"latitude": ORIGIN[0], "longitude": ORIGIN[1], "radiusMeters": 3000})
    assert r.status_code == 200, r.text
    world = r.json()
    assert world["h3Resolution"] == 9 and world["cells"] == []
    assert any(d["name"] == "The Crown" for d in world["discoveries"])

    # 8. App offers three quests.
    r = await c.get("/quests", params={"latitude": ORIGIN[0], "longitude": ORIGIN[1]})
    assert r.status_code == 200, r.text
    quests = r.json()["items"]
    assert len(quests) >= 3
    # The board is the Explorer's, plus one quest anyone can take.
    assert all(q["status"] == "AVAILABLE" and q["characterClass"] in ("EXPLORER", "ANY") for q in quests), [
        (q["templateId"], q["status"], q["characterClass"]) for q in quests
    ]
    assert any(q["characterClass"] == "ANY" for q in quests), [(q["templateId"], q["status"]) for q in quests]
    # Regions/POIs targeted by quests are revealed on the map as DISCOVERED.
    r = await c.get("/world", params={"latitude": ORIGIN[0], "longitude": ORIGIN[1], "radiusMeters": 30000})
    if any(o.get("latitude") is not None for q in quests for o in q["objectives"]):
        assert any(cell["state"] == "DISCOVERED" for cell in r.json()["cells"]), [q["templateId"] for q in quests]

    # 9. Choose a quest with a concrete destination.
    def located(q, types):
        return next((o for o in q["objectives"] if o["objectiveType"] in types and o.get("latitude") is not None), None)

    def choose(offered):
        single = [(q, located(q, ("VISIT_POI", "VISIT_REGION", "VISIT_LOCATION"))) for q in offered]
        single = [(q, o) for q, o in single if o is not None]
        if single:
            return single[0]
        multi = [(q, located(q, ("VISIT_MULTIPLE_LOCATIONS",))) for q in offered]
        multi = [(q, o) for q, o in multi if o is not None]
        return multi[0] if multi else None

    chosen = choose(quests)
    if chosen is None:
        # A board can be all distance and monsters; ask for more until one points somewhere.
        r = await c.post("/quests/generate", json={"latitude": ORIGIN[0], "longitude": ORIGIN[1], "count": 6})
        assert r.status_code == 200, r.text
        chosen = choose(r.json()["items"])
    assert chosen is not None, "no quest points anywhere"
    quest, target_obj = chosen
    target = (target_obj["latitude"], target_obj["longitude"])
    multi = target_obj["objectiveType"] == "VISIT_MULTIPLE_LOCATIONS"

    # Cannot skip the state machine.
    r = await c.post(f"/quests/{quest['id']}/complete", json={})
    assert r.status_code == 409 and r.json()["error"]["code"] == "QUEST_INVALID_TRANSITION"

    r = await c.post(f"/quests/{quest['id']}/accept")
    assert r.status_code == 200 and r.json()["status"] == "ACCEPTED"

    # 10-11. Three routes; pick "Adventure" (or the best available).
    r = await c.post(
        "/routes/generate",
        json={
            "origin": {"latitude": ORIGIN[0], "longitude": ORIGIN[1]},
            "questId": quest["id"],
            "request": "around 25 km, quiet roads, a pub near the end",
        },
    )
    assert r.status_code == 200, r.text
    alts = r.json()["alternatives"]
    assert len(alts) == 3
    labels = {a["label"] for a in alts}
    assert "Route 1" not in labels and len(labels) == 3
    assert r.json()["parsedRequest"]["poi"]["category"] == "PUB"
    for a in alts:
        assert a["distanceMeters"] > 0 and a["instructions"] and a["elevationSamples"] and "paved" in a["surface"]
        assert 0 <= a["score"] <= 1
    chosen = next((a for a in alts if a["label"] == "Adventure"), alts[0])

    # 12. Download route package.
    r = await c.get(f"/routes/{chosen['id']}/package")
    assert r.status_code == 200 and r.json()["quest"]["id"] == quest["id"] and r.json()["route"]["encodedPolyline"]

    # 13. Start ride (activates quest).
    client_ride_id = str(uuid.uuid4())
    r = await c.post(
        "/rides",
        json={
            "clientRideId": client_ride_id,
            "startedAt": "2026-06-01T09:00:00Z",
            "questId": quest["id"],
            "routeId": chosen["id"],
        },
    )
    assert r.status_code == 201, r.text
    ride = r.json()
    r = await c.post("/rides", json={"clientRideId": client_ride_id, "startedAt": "2026-06-01T09:00:00Z"})
    assert r.json()["id"] == ride["id"]  # idempotent
    r = await c.get(f"/quests/{quest['id']}")
    assert r.json()["status"] == "ACTIVE"

    # 14-16. GPS points batched during the ride; objective completes at target.
    pts = trace_to(target)
    r = await c.post(f"/rides/{ride['id']}/points", json={"points": pts[:100]})
    assert r.status_code == 200
    r = await c.post(f"/rides/{ride['id']}/exploration", json={"cellsVisited": ["notacell"]})
    assert r.status_code == 200
    r = await c.post(
        f"/quests/{quest['id']}/progress",
        json={
            "events": [
                {
                    "objectiveId": target_obj["id"],
                    "occurredAt": pts[120]["timestamp"],
                    "latitude": target[0],
                    "longitude": target[1],
                }
            ]
        },
    )
    assert r.status_code == 200
    progressed = next(o for o in r.json()["objectives"] if o["id"] == target_obj["id"])
    if multi:
        assert progressed["progress"]["current"] >= 1
    else:
        assert progressed["provisional"] is True

    # 18-19. Ride completes with the rest of the points.
    distance = 2 * 111_195 * abs(target[0] - ORIGIN[0]) + 2 * 70_000 * abs(target[1] - ORIGIN[1])
    r = await c.post(
        f"/rides/{ride['id']}/complete",
        json={
            "endedAt": pts[-1]["timestamp"],
            "distanceMeters": distance,
            "durationSeconds": 240 * 20,
            "elevationGainMeters": 30,
            "activeCalories": 500,
            "points": pts[100:],
        },
    )
    assert r.status_code == 200, r.text

    # 20-23. Server validated exploration; XP; level-up; new ability available.
    r = await c.get(f"/rides/{ride['id']}/summary")
    assert r.status_code == 200, r.text
    summary = r.json()
    assert summary["ride"]["status"] == "PROCESSED", summary["flags"]
    assert summary["newCells"] > 5
    assert summary["xpAwarded"] > 0
    sources = {b["source"] for b in summary["xpBreakdown"]}
    assert "NEW_AREA_EXPLORED" in sources and "CLASS_BONUS" in sources

    r = await c.get(f"/quests/{quest['id']}")
    q = r.json()
    validated = next(o for o in q["objectives"] if o["id"] == target_obj["id"])
    assert validated["provisional"] is False
    if multi:
        assert validated["progress"]["current"] >= 1
    else:
        assert validated["status"] == "COMPLETED"

    r = await c.get("/character")
    character = r.json()
    assert character["overallXP"] == summary["xpAwarded"]
    assert character["overallLevel"] >= 2

    # 24. Journal records the adventure.
    r = await c.get("/journal/adventures")
    entries = r.json()["items"]
    assert len(entries) == 1 and entries[0]["xpAwarded"] == summary["xpAwarded"]
    r = await c.get("/journal/stats")
    assert (
        r.json()["cellsVisited"] == summary["newCells"] + summary.get("upgradedCells", 0)
        or r.json()["cellsVisited"] >= summary["newCells"]
    )

    # 25. World map permanently shows explored territory.
    r = await c.get("/world", params={"latitude": ORIGIN[0], "longitude": ORIGIN[1], "radiusMeters": 3000})
    states = {cell["state"] for cell in r.json()["cells"]}
    assert "VISITED" in states or "EXPLORED" in states

    # Ride export works.
    r = await c.get(f"/rides/{ride['id']}/export", params={"format": "gpx"})
    assert r.status_code == 200 and b"<trkpt" in r.content


@pytest.mark.anyio
async def test_quest_completion_awards_quest_xp(explorer_client: AsyncClient):
    """A quest whose objectives are all met by the trace completes and grants quest XP."""
    c = explorer_client
    await seed_discoveries()
    r = await c.post("/quests/generate", json={"latitude": ORIGIN[0], "longitude": ORIGIN[1], "count": 6})
    quests = r.json()["items"]
    quest = next(
        (
            q
            for q in quests
            if q["templateId"]
            in (
                "EXPLORER_UNVISITED_PARK",
                "EXPLORER_LANDMARK",
                "EXPLORER_WATERSIDE",
                "EXPLORER_CAFE_FRONTIER",
            )
        ),
        None,
    )
    if quest is None:
        pytest.skip("no single-POI quest generated for this seed")
    target_obj = next(o for o in quest["objectives"] if o["objectiveType"] == "VISIT_POI")
    await c.post(f"/quests/{quest['id']}/accept")
    r = await c.post(
        "/rides",
        json={
            "clientRideId": str(uuid.uuid4()),
            "startedAt": "2026-06-01T09:00:00Z",
            "questId": quest["id"],
        },
    )
    ride = r.json()
    pts = trace_to((target_obj["latitude"], target_obj["longitude"]))
    r = await c.post(
        f"/rides/{ride['id']}/complete",
        json={
            "endedAt": pts[-1]["timestamp"],
            "distanceMeters": 20000,
            "durationSeconds": 4800,
            "elevationGainMeters": 40,
            "points": pts,
        },
    )
    assert r.status_code == 200, r.text
    summary = (await c.get(f"/rides/{ride['id']}/summary")).json()
    assert summary["ride"]["status"] == "PROCESSED", summary
    assert summary["questCompletion"] is not None, summary
    assert summary["questCompletion"]["quest"]["status"] == "COMPLETED"
    assert any(b["source"] == "QUEST_COMPLETED" for b in summary["xpBreakdown"])
    assert any(d["name"] == target_obj["extra"]["poiName"] for d in summary["discoveries"])
    r = await c.get("/quests", params={"status": "COMPLETED"})
    assert r.json()["items"][0]["id"] == quest["id"]
