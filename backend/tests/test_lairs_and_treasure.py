"""Lairs and treasure maps (docs/ROADMAP.md 0.8.0)."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import func, select

from app.characters.models import Character
from app.core.config import get_settings
from app.core.geo import destination_point, haversine_m
from app.db.session import get_session_factory
from app.discoveries.models import Discovery
from app.economy.models import WalletTransaction
from app.exploration.cells import cell_center, traverse
from app.inventory import loot, treasure
from app.inventory import service as inventory
from app.inventory.models import Loadout, RuneHolding
from app.lore.voice import violations
from app.users.models import User
from app.world_objects import lairs
from app.world_objects.models import HIDDEN, WorldObject
from tests.test_first_playable_journey import ORIGIN
from tests.test_world_objects import ride

NOW = datetime.now(UTC)


async def character() -> Character:
    async with get_session_factory()() as db:
        user = await db.scalar(select(User).where(User.apple_subject == "dev:tester"))
        return await db.scalar(select(Character).where(Character.user_id == user.id))


async def set_level(level: int) -> None:
    me = await character()
    async with get_session_factory()() as db:
        row = await db.get(Character, me.id)
        row.overall_level = level
        await db.commit()


async def place(name: str, category: str, at: tuple[float, float], **tags) -> str:
    async with get_session_factory()() as db:
        d = Discovery(name=name, category=category, latitude=at[0], longitude=at[1], source="OSM", tags=tags)
        db.add(d)
        await db.commit()
        return str(d.id)


async def offer(now: datetime | None = None) -> WorldObject | None:
    async with get_session_factory()() as db:
        me = await db.get(Character, (await character()).id)
        lair = await lairs.ensure_offered(db, get_settings(), me, near=ORIGIN, now=now)
        await db.commit()
        return lair


def through(stops: list[tuple[float, float]], ends_ago: timedelta = timedelta(seconds=1)) -> list[dict]:
    """A journey through these points, a fix every 20 m, ending a little while ago."""
    pts: list[dict] = []
    for a, b in zip(stops, stops[1:], strict=False):
        steps = max(1, int(haversine_m(a[0], a[1], b[0], b[1]) / 20))
        for k in range(steps):
            f = k / steps
            pts.append({"latitude": a[0] + (b[0] - a[0]) * f, "longitude": a[1] + (b[1] - a[1]) * f})
    pts.append({"latitude": stops[-1][0], "longitude": stops[-1][1]})
    start = datetime.now(UTC) - ends_ago - timedelta(seconds=4 * (len(pts) - 1))
    for i, p in enumerate(pts):
        p.update(
            timestamp=(start + timedelta(seconds=4 * i)).isoformat(),
            altitudeMeters=10,
            horizontalAccuracyMeters=5,
            speedMps=5.0,
        )
    return pts


def entered(pts: list[dict], cells: list[str]) -> set[str]:
    return set(traverse([(p["latitude"], p["longitude"]) for p in pts], 9).cells) & set(cells)


# --- lairs ------------------------------------------------------------------------


async def test_a_lair_is_offered_from_level_eight_at_a_park_two_to_six_km_out(explorer_client):
    park = destination_point(ORIGIN[0], ORIGIN[1], 60, 3000)
    await place("Near Park", "NATURE", destination_point(ORIGIN[0], ORIGIN[1], 60, 1000), leisure="park")
    await place("Far Park", "NATURE", park, leisure="park")
    await place("A Lake", "NATURE", destination_point(ORIGIN[0], ORIGIN[1], 120, 3000), natural="water")
    assert await offer() is None, "not before level 8"
    await set_level(8)
    lair = await offer()
    assert lair is not None and lair.kind == "LAIR" and lair.payload["anchorName"] == "Far Park"
    assert len(lair.payload["cells"]) == 7 and lair.payload["need"] == 5 and lair.payload["visited"] == []
    assert lair.expires_at - lair.spawned_at == timedelta(days=14)
    assert len(lair.seed) <= 96 and len(lair.kind) <= 12
    # One at a time: asking again gives the same one.
    assert (await offer()).id == lair.id
    r = await explorer_client.get(
        "/world/objects", params={"latitude": ORIGIN[0], "longitude": ORIGIN[1], "radiusMeters": 6000}
    )
    out = next(o for o in r.json() if o["kind"] == "LAIR")
    assert out["name"] == "The lair at Far Park" and out["lair"]["need"] == 5 and out["lair"]["visited"] == []
    assert len(out["lair"]["cells"]) == 7 and out["lair"]["endsAt"]
    r = await explorer_client.post(
        f"/world/objects/{out['id']}/claim", json={"latitude": park[0], "longitude": park[1]}
    )
    assert r.status_code == 409 and not violations(r.json()["error"]["message"], glossary=True)


async def test_a_new_lair_only_once_a_fortnight(explorer_client):
    await place("Far Park", "NATURE", destination_point(ORIGIN[0], ORIGIN[1], 60, 3000), leisure="park")
    await place("Other Park", "NATURE", destination_point(ORIGIN[0], ORIGIN[1], 240, 4000), leisure="garden")
    await set_level(9)
    first = await offer()
    async with get_session_factory()() as db:
        row = await db.get(WorldObject, first.id)
        row.status = "CLAIMED"
        await db.commit()
    assert await offer() is None, "done early, the next waits for the fortnight"
    later = await offer(now=NOW + timedelta(days=15))
    assert later is not None and later.id != first.id and later.anchor_discovery_id != first.anchor_discovery_id


async def test_five_of_seven_tiles_open_the_great_chest_and_the_first_holds_ingwaz(explorer_client):
    await place("Far Park", "NATURE", destination_point(ORIGIN[0], ORIGIN[1], 60, 3000), leisure="park")
    await set_level(8)
    lair = await offer(now=NOW - timedelta(hours=2))
    cells = list(lair.payload["cells"])
    centres = [cell_center(c) for c in cells]
    # Into the middle tile and one neighbour first.
    first_pts = through(
        [destination_point(*centres[0], 270, 1200), centres[0], centres[1]], ends_ago=timedelta(minutes=30)
    )
    seen = entered(first_pts, cells)
    summary = await ride(explorer_client, first_pts)
    progress = summary["lair"]
    assert progress["visited"] == len(seen) and progress["need"] == 5 and not progress["done"]
    assert progress["rewards"] is None and progress["line"] == f"{len(seen)} / 5 of the lair's tiles visited."
    # Round the rest of it.
    second_pts = through(
        [destination_point(*centres[0], 270, 1200), *centres[2:], centres[2]], ends_ago=timedelta(minutes=5)
    )
    summary = await ride(explorer_client, second_pts)
    done = summary["lair"]
    assert done["done"] and done["visited"] >= 5
    rewards = done["rewards"]
    assert rewards["coins"] == 250 and rewards["rune"]["rune"] == "ingwaz"
    assert {i["rarity"] or i["consumable"] for i in rewards["items"]} == {"RARE", "SEALED_CHEST_RARE"}
    assert {"kind": "LAIR", "ac": 250, "detail": {"name": "The lair at Far Park"}} in summary["acBreakdown"]
    assert done["line"].endswith("The great chest is yours!")
    async with get_session_factory()() as db:
        row = await db.get(WorldObject, lair.id)
        assert row.status == "CLAIMED"
        me = await character()
        held = await db.scalar(select(RuneHolding).where(RuneHolding.character_id == me.id))
        assert held.rune_id == "ingwaz"
        paid = await db.scalar(select(func.count(WalletTransaction.id)).where(WalletTransaction.kind == "LAIR"))
        assert paid == 1
    r = await explorer_client.get(
        "/world/objects", params={"latitude": ORIGIN[0], "longitude": ORIGIN[1], "radiusMeters": 6000}
    )
    assert not any(o["kind"] == "LAIR" for o in r.json()), "claimed, it leaves the map"


async def test_only_the_first_great_chest_holds_ingwaz_and_each_pays_once(explorer_client):
    me = await character()
    async with get_session_factory()() as db:
        rows = []
        for n in range(2):
            row = WorldObject(
                user_id=me.user_id, kind="LAIR", status="CLAIMED", tier=1, latitude=ORIGIN[0], longitude=ORIGIN[1],
                seed=f"lair:{n}", reward_ac=250, payload={"name": f"The lair at Park {n}", "cells": [], "visited": []},
                spawned_at=NOW, expires_at=NOW + timedelta(days=14),
            )  # fmt: skip
            db.add(row)
            rows.append(row)
        await db.flush()
        hero = await db.get(Character, me.id)
        first = await lairs._open_great_chest(db, hero, rows[0], None)
        second = await lairs._open_great_chest(db, hero, rows[1], None)
        again = await lairs._open_great_chest(db, hero, rows[0], None)
        await db.commit()
    assert first["rune"]["rune"] == "ingwaz" and first["rune"]["name"] == "Ingwaz"
    assert second["rune"] is None and second["coins"] == 250
    assert again is None


# --- treasure maps ----------------------------------------------------------------


def test_a_clue_is_facts_never_names():
    clue = treasure.compose_clue({"GREEN", "WATER"}, 2100, 45)
    assert clue == "Buried by water, in a green place, about 2 km north-east of here."
    assert treasure.compose_clue({"OLD"}, 800, 215) == "Buried near something old, about 1 km south-west of here."
    assert treasure.direction(200) == "south" and treasure.direction(337.6) == "north"
    assert treasure.compose_clue({"HIGH"}, 3740, 359) == "Buried up on high ground, about 3.5 km north of here."
    assert treasure.features_of("NATURE", {"leisure": "park", "natural": "water"}) == {"GREEN", "WATER"}
    assert treasure.features_of("HISTORICAL", {}) == {"OLD"}
    assert treasure.features_of("PUB", {"amenity": "pub"}) == set()
    for line in (clue, "You found the buried treasure!"):
        assert not violations(line, glossary=True, celebration=True)


def test_a_tier_three_chest_holds_a_map_about_three_times_in_ten():
    hits = sum(loot.treasure_map_drops(str(uuid.UUID(int=i)), "CHEST", 3) for i in range(2000))
    assert 500 <= hits <= 700
    assert not any(loot.treasure_map_drops(str(uuid.UUID(int=i)), "CHEST", 2) for i in range(200))
    assert not any(loot.treasure_map_drops(str(uuid.UUID(int=i)), "MONSTER", 3) for i in range(200))
    assert loot.treasure_map_drops("same", "CHEST", 3) == loot.treasure_map_drops("same", "CHEST", 3)


async def give_maps(count: int) -> None:
    me = await character()
    async with get_session_factory()() as db:
        await inventory.add_consumables(db, await db.get(Character, me.id), {"TREASURE_MAP": count})
        await db.commit()


async def test_a_treasure_map_buries_a_chest_that_nothing_shows_and_a_journey_finds(explorer_client):
    spot = destination_point(ORIGIN[0], ORIGIN[1], 45, 2000)
    await place("Riverside Park", "NATURE", spot, leisure="park")
    await place("The Mill Stream", "NATURE", destination_point(spot[0], spot[1], 0, 80), waterway="stream")
    await place("Corner Café", "CAFE", destination_point(ORIGIN[0], ORIGIN[1], 90, 2500), amenity="cafe")
    await give_maps(2)
    use = "/inventory/consumables/TREASURE_MAP/use"
    r = await explorer_client.post(use, json={})
    assert r.status_code == 409 and r.json()["error"]["code"] == "NEEDS_LOCATION"
    r = await explorer_client.post(use, json={"latitude": ORIGIN[0], "longitude": ORIGIN[1]})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["clue"] == "Buried by water, in a green place, about 2 km north-east of here."
    assert "Riverside" not in body["clue"] and "Mill" not in body["clue"]
    treasure_id = body["treasureId"]
    assert next(c for c in body["inventory"]["consumables"] if c["id"] == "TREASURE_MAP")["count"] == 1
    clues = (await explorer_client.get("/inventory/treasure")).json()
    assert [c["treasureId"] for c in clues] == [treasure_id] and clues[0]["clue"] == body["clue"]
    assert set(clues[0]) == {"treasureId", "clue", "buriedAt", "fromLatitude", "fromLongitude"}
    # Never on the map, never looked up.
    r = await explorer_client.get(
        "/world/objects", params={"latitude": spot[0], "longitude": spot[1], "radiusMeters": 3000}
    )
    assert treasure_id not in {o["id"] for o in r.json()}
    r = await explorer_client.get("/world", params={"latitude": spot[0], "longitude": spot[1], "radiusMeters": 3000})
    assert treasure_id not in str(r.json())
    assert (await explorer_client.get(f"/world/objects/{treasure_id}")).status_code == 404
    # One clue at a time.
    r = await explorer_client.post(use, json={"latitude": ORIGIN[0], "longitude": ORIGIN[1]})
    assert r.status_code == 409 and r.json()["error"]["code"] == "ONE_AT_A_TIME"
    assert not violations(r.json()["error"]["message"], glossary=True)
    # A journey passing within 40 m opens it.
    stream = destination_point(spot[0], spot[1], 0, 80)
    summary = await ride(explorer_client, through([ORIGIN, spot, stream], ends_ago=timedelta(0)))
    found = summary["treasureFound"]
    assert found["id"] == treasure_id and found["coins"] == 120 and found["item"]["kind"] == "GEAR"
    assert found["line"] == "You found the buried treasure!"
    assert {"kind": "TREASURE", "ac": 120, "detail": {"name": "Buried treasure"}} in summary["acBreakdown"]
    assert (await explorer_client.get("/inventory/treasure")).json() == []
    async with get_session_factory()() as db:
        row = await db.get(WorldObject, uuid.UUID(treasure_id))
        assert row.status == "CLAIMED" and row.claimed_ride_id is not None
        # Run again, it is not found twice.
        me = await db.get(Character, (await character()).id)
        again = await treasure.open_on_ride(db, me, None, [ORIGIN, spot], NOW)
        assert again is None


async def test_a_map_with_nowhere_to_bury_keeps_the_map(explorer_client):
    await place("Corner Café", "CAFE", destination_point(ORIGIN[0], ORIGIN[1], 90, 2500), amenity="cafe")
    await give_maps(1)
    r = await explorer_client.post(
        "/inventory/consumables/TREASURE_MAP/use", json={"latitude": ORIGIN[0], "longitude": ORIGIN[1]}
    )
    assert r.status_code == 409 and r.json()["error"]["code"] == "NO_PLACE_FOR_TREASURE"
    me = await character()
    async with get_session_factory()() as db:
        loadout = await db.scalar(select(Loadout).where(Loadout.character_id == me.id))
        assert loadout.consumables["TREASURE_MAP"] == 1
        assert not (await db.execute(select(WorldObject).where(WorldObject.status == HIDDEN))).scalars().all()


async def test_a_tier_three_chest_passed_on_a_journey_may_leave_a_map(explorer_client):
    chest_id = next(i for i in range(5000) if loot.treasure_map_drops(str(uuid.UUID(int=i)), "CHEST", 3))
    me = await character()
    async with get_session_factory()() as db:
        db.add(
            WorldObject(
                id=uuid.UUID(int=chest_id), user_id=me.user_id, kind="CHEST", status="SPAWNED", tier=3,
                latitude=ORIGIN[0], longitude=ORIGIN[1], seed="test-chest", reward_ac=40,
                payload={"name": "Old chest"}, spawned_at=NOW - timedelta(hours=3), expires_at=NOW + timedelta(days=1),
            )
        )  # fmt: skip
        await db.commit()
    start = destination_point(ORIGIN[0], ORIGIN[1], 270, 800)
    summary = await ride(explorer_client, through([start, ORIGIN, destination_point(*ORIGIN, 90, 800)]))
    assert any(i.get("consumable") == "TREASURE_MAP" for i in summary["itemsFound"])


@pytest.mark.parametrize("kind", ["LEGEND", "LAIR", "TREASURE"])
def test_the_new_coin_and_item_kinds_fit_their_columns(kind):
    from app.economy.models import WalletTransaction as W
    from app.inventory.models import InventoryItem

    assert len(kind) <= W.__table__.c.kind.type.length
    assert len(kind) <= InventoryItem.__table__.c.source.type.length
