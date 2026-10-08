"""Effort is damage, end to end: behind effort_combat, a ride loosens or sees off
what it passes (docs/ROADMAP.md, 0.6.1)."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select

from app.core.geo import destination_point
from app.db.session import get_session_factory
from app.users.models import User
from app.world_objects import service as world_objects
from app.world_objects.models import WorldObject
from tests.test_first_playable_journey import ORIGIN
from tests.test_world_objects import line_trace, ride

NOW = datetime.now(UTC)


@pytest.fixture(autouse=True)
def effort_on(settings, monkeypatch):
    monkeypatch.setattr(settings, "feature_flags", "effort_combat")
    return settings


async def place_monster(
    species: str = "fen-troll",
    tier: int = 1,
    at=ORIGIN,
    wants=None,
    minds=None,
    road_form=None,
    bounty=False,
    **payload,
) -> str:
    from app.lore import catalog

    entry = catalog.species_by_id()[species]
    async with get_session_factory()() as db:
        user = await db.scalar(select(User).where(User.apple_subject == "dev:tester"))
        obj = WorldObject(
            user_id=user.id,
            kind="MONSTER",
            status="SPAWNED",
            tier=tier,
            latitude=at[0],
            longitude=at[1],
            seed=str(uuid.uuid4()),
            reward_ac=60 * (2 if bounty else 1),
            bounty=bounty,
            payload={
                "name": entry["name"],
                "speciesId": species,
                "hp": 100,
                "species": {
                    "wants": wants or entry["wants"],
                    "minds": minds or entry["minds"],
                    "roadForm": road_form,
                },
                "killMethods": [],
                **payload,
            },
            spawned_at=NOW - timedelta(hours=2),
            expires_at=NOW + timedelta(days=1),
        )
        db.add(obj)
        await db.commit()
        return str(obj.id)


async def row(object_id: str) -> WorldObject:
    async with get_session_factory()() as db:
        return await db.get(WorldObject, uuid.UUID(object_id))


def past(start_m: float, length_m: float, bearing: float = 90.0, speed: float = 5.0):
    """A straight outing that starts `start_m` west of the origin and runs east,
    ridden in the last hour, while the things placed for the test were out."""
    start = destination_point(ORIGIN[0], ORIGIN[1], (bearing + 180) % 360, start_m)
    end = destination_point(start[0], start[1], bearing, length_m)
    pts = line_trace(start, end, speed_mps=speed, and_back=False)
    t0 = datetime.fromisoformat(pts[0]["timestamp"])
    shift = (NOW - timedelta(hours=1)) - t0
    for p in pts:
        p["timestamp"] = (datetime.fromisoformat(p["timestamp"]) + shift).isoformat()
    return pts


async def test_passing_by_loosens_it_and_it_stays_longer(explorer_client):
    object_id = await place_monster("fen-troll", tier=2, wants=["GROUND", "WORD"], minds=["CLIMB"])
    before = await row(object_id)
    summary = await ride(explorer_client, past(950, 1900))
    fights = summary["worldObjects"]["fights"]
    assert len(fights) == 1
    report = fights[0]
    assert report["outcome"] == "LOOSENED"
    assert report["holdBefore"] == 220 and report["holdAfter"] < 220
    # Where it stood, for the reckoning's ink mark.
    assert report["latitude"] == pytest.approx(ORIGIN[0]) and report["longitude"] == pytest.approx(ORIGIN[1])
    after = await row(object_id)
    # A second session reads the wound: it was written, not edited in place.
    assert after.payload["wounds"]["rides"]
    assert after.status == "SPAWNED"
    assert after.expires_at > before.expires_at
    assert after.expires_at <= after.spawned_at + timedelta(days=7)
    missed = {m["id"]: m["reason"] for m in summary["worldObjects"]["missed"]}
    assert missed[object_id] == "LOOSENED"


async def test_a_word_where_it_wants_one_sees_it_off_and_pays_on_the_finish(explorer_client):
    object_id = await place_monster("fen-troll", tier=1, wants=["ROAD", "WORD"], minds=["CLIMB"])
    pts = past(800, 1600)
    middle = pts[len(pts) // 2]
    events = [
        {
            "objectId": object_id,
            "method": "LORE",
            "occurredAt": middle["timestamp"],
            "latitude": middle["latitude"],
            "longitude": middle["longitude"],
            "note": "A troll asleep by the water, snoring.",
        }
    ]
    summary = await ride(explorer_client, pts, encounter_events=events)
    report = summary["worldObjects"]["fights"][0]
    assert report["outcome"] == "SEEN_OFF"
    assert report["wordLanded"] is True
    sources = {line["source"] for line in summary["xpBreakdown"]}
    assert {"MONSTER_BEATEN", "BLOWS_LANDED"} <= sources
    assert any(line["kind"] in ("MONSTER_SLAIN", "BOUNTY") for line in summary["acBreakdown"])
    assert (await row(object_id)).status == "CLAIMED"


async def test_a_short_outing_loosens_nothing(explorer_client):
    object_id = await place_monster("fen-troll", wants=["ROAD", "WORD"], minds=["CLIMB"])
    summary = await ride(explorer_client, past(100, 300))
    assert summary["worldObjects"].get("fights") == []
    assert not (await row(object_id)).payload.get("wounds")


async def test_running_the_same_ride_again_does_not_wound_twice(explorer_client):
    """Wounds are keyed by ride: a rerun replaces, it never adds."""
    object_id = await place_monster("rook-lord", tier=3, wants=["GROUND", "WORD"], minds=["CLIMB"])
    await ride(explorer_client, past(950, 1900))
    first = (await row(object_id)).payload["wounds"]["rides"]
    obj = await row(object_id)
    foe_now = world_objects.foe_of(obj)
    foe_excluding = world_objects.foe_of(obj, excluding_ride=next(iter(first)))
    assert foe_excluding.hold_before == 400
    assert foe_now.hold_before == 400 - next(iter(first.values()))["taken"]


async def test_the_api_gives_an_old_phone_nothing_to_judge_and_a_new_one_the_hold(explorer_client):
    await place_monster("grey-stag", tier=2, road_form="TRIANGLE")
    r = await explorer_client.get(
        "/world", params={"latitude": ORIGIN[0], "longitude": ORIGIN[1], "radiusMeters": 3000}
    )
    monster = next(o for o in r.json()["objects"] if o["kind"] == "MONSTER")["monster"]
    assert monster["killMethods"] == []
    assert monster["holdMax"] == 220 and monster["holdLeft"] == 220
    assert monster["wants"] == ["CLIMB", "RUNE"] and monster["roadForm"] == "TRIANGLE"
    assert monster["rune"] == "kenaz"


async def test_a_monster_from_before_species_blocks_is_still_fought(explorer_client):
    """An old row has only a name and a PACE method; it is read from the catalogue."""
    async with get_session_factory()() as db:
        user = await db.scalar(select(User).where(User.apple_subject == "dev:tester"))
        obj = WorldObject(
            user_id=user.id,
            kind="MONSTER",
            status="SPAWNED",
            tier=1,
            latitude=ORIGIN[0],
            longitude=ORIGIN[1],
            seed=str(uuid.uuid4()),
            reward_ac=60,
            payload={
                "name": "Hollow Knight",
                "hp": 100,
                "killMethods": [{"method": "PACE", "params": {}, "hint": "x"}],
            },
            spawned_at=NOW - timedelta(hours=2),
            expires_at=NOW + timedelta(days=1),
        )
        db.add(obj)
        await db.commit()
        object_id = str(obj.id)
    summary = await ride(explorer_client, past(950, 1900))
    report = next(f for f in summary["worldObjects"]["fights"] if f["id"] == object_id)
    assert report["speciesId"] == "hollow-sentry"
    assert report["outcome"] in ("LOOSENED", "UNTOUCHED")


async def test_a_loosened_bounty_carries_on_at_the_ordinary_purse(explorer_client):
    object_id = await place_monster("fen-troll", tier=2, wants=["GROUND", "WORD"], minds=["CLIMB"], bounty=True)
    await ride(explorer_client, past(950, 1900))
    after = await row(object_id)
    assert after.bounty is False
    assert after.reward_ac == world_objects.load_ac_rules()["monster"]["2"]


async def test_the_ride_carries_the_sheet_it_started_with(explorer_client):
    r = await explorer_client.post("/rides", json={"clientRideId": str(uuid.uuid4()), "startedAt": NOW.isoformat()})
    assert r.status_code == 201
    loadout = r.json()["loadout"]
    assert loadout["characterClass"] == "EXPLORER"
    assert loadout["damagePct"] == {"GROUND": 0.3}
    character = (await explorer_client.get("/character")).json()
    assert character["sheet"]["damagePct"] == {"GROUND": 0.3}


async def test_a_planned_route_places_one_thing_on_its_far_half(explorer_client, settings):
    """Placement, so effort lands on something: the route chosen to ride has one
    thing waiting along its far half, once, at a real place beside it."""
    from tests.test_first_playable_journey import seed_discoveries

    await seed_discoveries()
    # Out east from Rotherhithe past the Thames Path and back towards Stave Hill.
    route = [[-0.0700, 51.4985], [-0.0500, 51.4985], [-0.0300, 51.4985], [-0.0480, 51.4990]]
    async with get_session_factory()() as db:
        user = await db.scalar(select(User).where(User.apple_subject == "dev:tester"))
        route_id = uuid.uuid4()
        placed = await world_objects.place_on_route(
            db, settings, user.id, route_id, route, character_class="EXPLORER", activity="RIDE"
        )
        await db.commit()
        assert placed is not None and placed.kind == "MONSTER"
        assert placed.payload.get("speciesId")
        far = world_objects._far_half(route)
        assert (
            min(world_objects.haversine_m(placed.latitude, placed.longitude, p[0], p[1]) for p in far)
            <= world_objects.ROUTE_REACH_M
        )
        # Asked again for the same route, nothing more comes.
        again = await world_objects.place_on_route(
            db, settings, user.id, route_id, route, character_class="EXPLORER", activity="RIDE"
        )
        assert again is None
