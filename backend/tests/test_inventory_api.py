"""The inventory API (docs/ROADMAP.md 0.7.2): gear worn and sold, consumables used,
the stall, what each level pays, and what a journey finds."""

from __future__ import annotations

import uuid
from datetime import UTC, date, datetime, timedelta

import pytest
from sqlalchemy import func, select

from app.characters.models import Character
from app.db.session import get_session_factory
from app.discoveries.models import Discovery
from app.economy import service as economy
from app.economy.models import UserStreak
from app.economy.streaks import update_streak
from app.inventory import gear, loot, service
from app.inventory.models import InventoryItem
from app.rides.models import Ride
from tests.test_effort_combat import past, place_monster
from tests.test_first_playable_journey import ORIGIN
from tests.test_world_objects import ride

NOW = datetime.now(UTC)


async def me(c) -> Character:
    user_id = uuid.UUID((await c.get("/users/me")).json()["id"])
    async with get_session_factory()() as db:
        return (await db.execute(select(Character).where(Character.user_id == user_id))).scalar_one()


async def set_level(c, level: int) -> Character:
    character = await me(c)
    async with get_session_factory()() as db:
        row = await db.get(Character, character.id)
        row.overall_level = level
        await db.commit()
    return character


async def give(c, *item_ids: str, consumables: dict[str, int] | None = None, coins: int = 0) -> list[str]:
    """Items into the bag (their inventory ids), consumables, coins."""
    character = await me(c)
    out = []
    async with get_session_factory()() as db:
        row = await db.get(Character, character.id)
        for item_id in item_ids:
            item = await service.add_gear(db, row, item_id, source="STALL", key=f"test:{uuid.uuid4()}")
            out.append(str(item.id))
        if consumables:
            await service.add_consumables(db, row, consumables)
        if coins:
            await economy.credit(db, row.user_id, coins, "ADJUSTMENT")
        await db.commit()
    return out


def counts(inventory: dict) -> dict[str, int]:
    return {c["id"]: c["count"] for c in inventory["consumables"]}


async def test_the_inventory_and_the_levels_reached_before_are_paid_once(explorer_client):
    c = explorer_client
    first = (await c.get("/inventory")).json()
    assert [s["slot"] for s in first["slots"]] == list(gear.SLOTS)
    assert [s["open"] for s in first["slots"]] == [True, False, False, False, False]
    assert first["bag"] == [] and first["bagSize"] == 20 and first["finishesSinceRare"] == 0
    assert [c["id"] for c in first["consumables"]] == list(gear.CONSUMABLES)
    assert set(counts(first).values()) == {0}
    assert first["levelRewardsPaid"] == [], "level 1 pays nothing more than the start"
    await set_level(c, 7)
    caught_up = (await c.get("/inventory")).json()
    assert {r["level"] for r in caught_up["levelRewardsPaid"]} == {2, 3, 4, 5, 6, 7}
    assert {"Lantern slot opens", "Bag slot opens", "The stall opens", "Title: Familiar Face"} <= {
        r["text"] for r in caught_up["levelRewardsPaid"]
    }
    assert counts(caught_up)["LAMP"] >= 2
    again = (await c.get("/inventory")).json()
    assert again["levelRewardsPaid"] == [] and counts(again) == counts(caught_up)
    table = (await c.get("/inventory/levels")).json()
    assert len(table) == 50 and [row["reached"] for row in table[:8]] == [True] * 7 + [False]
    assert table[2]["rewards"][0] == {
        "kind": "SLOT", "text": "Lantern slot opens", "icon": "candleStub", "consumable": None, "count": None,
        "slot": "LANTERN", "level": None,
    }  # fmt: skip


async def test_gear_is_worn_in_its_own_open_slot_and_not_changed_on_a_journey(explorer_client):
    c = explorer_client
    bell, lantern, satchel = await give(c, "tin-bell", "candle-stub", "tinkers-satchel")
    r = await c.put("/inventory/gear", json={"slot": "BELL", "itemId": lantern})
    assert r.status_code == 409 and r.json()["error"]["code"] == "WRONG_SLOT"
    assert r.json()["error"]["message"] == "That goes in the Lantern slot. Wear it there instead."
    r = await c.put("/inventory/gear", json={"slot": "LANTERN", "itemId": lantern})
    assert r.status_code == 409 and r.json()["error"]["code"] == "SLOT_LOCKED"
    assert r.json()["error"]["message"] == "That slot opens at level 3."
    r = await c.put("/inventory/gear", json={"slot": "BELL", "itemId": bell})
    assert r.status_code == 200, r.text
    worn = r.json()
    assert worn["slots"][0]["item"]["itemId"] == "tin-bell" and worn["slots"][0]["item"]["equipped"]
    assert {i["itemId"] for i in worn["bag"]} == {"candle-stub", "tinkers-satchel"}
    sheet = (await c.get("/character")).json()["sheet"]
    assert sheet["version"] == 5 and sheet["gear"] == {"BELL": "tin-bell"} and sheet["rules"]["SIGHT_M"] == 500
    assert sheet["lootFindPct"] == 0
    # A ride starts with what it carries, and nothing changes until it is over.
    r = await c.post("/rides", json={"clientRideId": str(uuid.uuid4()), "startedAt": NOW.isoformat()})
    assert r.status_code == 201 and r.json()["loadout"]["gear"] == {"BELL": "tin-bell"}
    ride_id = r.json()["id"]
    r = await c.put("/inventory/gear", json={"slot": "BELL", "itemId": None})
    assert r.status_code == 409 and r.json()["error"]["code"] == "LOADOUT_LOCKED"
    await c.delete(f"/rides/{ride_id}")
    async with get_session_factory()() as db:
        row = await db.get(Ride, uuid.UUID(ride_id))
        row.status = "DISCARDED"
        await db.commit()
    r = await c.put("/inventory/gear", json={"slot": "BELL", "itemId": None})
    assert r.status_code == 200 and r.json()["slots"][0]["item"] is None
    assert len(r.json()["bag"]) == 3
    assert satchel in {i["id"] for i in r.json()["bag"]}


async def test_selling_pays_coins_and_never_what_is_worn(explorer_client):
    c = explorer_client
    await set_level(c, 5)
    bell, rare, satchel = await give(c, "tin-bell", "drovers-bell", "tinkers-satchel")
    assert (await c.put("/inventory/gear", json={"slot": "BELL", "itemId": bell})).status_code == 200
    r = await c.post(f"/inventory/items/{bell}/sell")
    assert r.status_code == 409 and r.json()["error"]["code"] == "TAKE_OFF_FIRST"
    assert r.json()["error"]["message"] == "Take it off before you sell it."
    r = await c.post(f"/inventory/items/{rare}/sell")
    assert r.status_code == 200 and r.json()["soldFor"] == 120 and r.json()["walletBalance"] == 120
    assert rare not in {i["id"] for i in r.json()["bag"]}
    # The Tinker's Satchel worn: items sell for half as much again.
    assert (await c.put("/inventory/gear", json={"slot": "BAG", "itemId": satchel})).status_code == 200
    common = (await give(c, "candle-stub"))[0]
    r = await c.post(f"/inventory/items/{common}/sell")
    assert r.json()["soldFor"] == 60
    r = await c.post(f"/inventory/items/{common}/sell")
    assert r.status_code == 404, "sold is gone"
    history = (await c.get("/wallet/transactions")).json()["items"]
    assert [t["kind"] for t in history[:2]] == ["ITEM_SOLD", "ITEM_SOLD"]


async def test_the_stall_opens_at_level_3_with_four_offers_a_week(explorer_client):
    c = explorer_client
    closed = (await c.get("/inventory/stall")).json()
    assert closed["open"] is False and closed["opensAtLevel"] == 3 and len(closed["offers"]) == 4
    offer = closed["offers"][0]["id"]
    r = await c.post(f"/inventory/stall/{offer}/buy")
    assert r.status_code == 409 and r.json()["error"]["code"] == "STALL_CLOSED"
    assert r.json()["error"]["message"] == "The stall opens at level 3."
    await set_level(c, 3)
    stall = (await c.get("/inventory/stall")).json()
    assert stall == {**stall, "open": True, "week": service.iso_week(datetime.now(UTC))}
    assert stall["offers"] == (await c.get("/inventory/stall")).json()["offers"], "computed on read, the same all week"
    kinds = [o["kind"] for o in stall["offers"]]
    assert kinds == ["GEAR", "GEAR", "CONSUMABLE", "CONSUMABLE"]
    assert all(o["rarity"] in ("COMMON", "RARE") for o in stall["offers"] if o["kind"] == "GEAR")
    gear_offer = stall["offers"][0]
    r = await c.post(f"/inventory/stall/{gear_offer['id']}/buy")
    assert r.status_code == 409 and r.json()["error"]["code"] == "INSUFFICIENT_AC"
    await give(c, coins=1000)
    r = await c.post(f"/inventory/stall/{gear_offer['id']}/buy")
    assert r.status_code == 200, r.text
    assert [i["itemId"] for i in r.json()["bag"]] == [gear_offer["itemId"]]
    assert (await c.get("/wallet")).json()["balance"] == 1000 - gear_offer["price"]
    r = await c.post(f"/inventory/stall/{gear_offer['id']}/buy")
    assert r.status_code == 409 and r.json()["error"]["code"] == "ALREADY_BOUGHT"
    consumable = stall["offers"][2]
    r = await c.post(f"/inventory/stall/{consumable['id']}/buy")
    assert counts(r.json())[consumable["consumable"]] >= 1
    bought = {o["id"]: o["bought"] for o in (await c.get("/inventory/stall")).json()["offers"]}
    assert bought == {o["id"]: o["id"] in (gear_offer["id"], consumable["id"]) for o in stall["offers"]}
    assert (await c.post("/inventory/stall/w1-9/buy")).json()["error"]["code"] == "NO_SUCH_OFFER"
    history = [t["kind"] for t in (await c.get("/wallet/transactions")).json()["items"]]
    assert history.count("STALL") == 2


def test_the_stall_is_seeded_by_player_and_week():
    a = loot.stall_offers("someone", "2026-W41")
    assert a == loot.stall_offers("someone", "2026-W41")
    assert a != loot.stall_offers("someone", "2026-W42") or a != loot.stall_offers("someone else", "2026-W41")
    assert [o["id"] for o in a] == ["w41-0", "w41-1", "w41-2", "w41-3"]
    for week in range(1, 53):
        offers = loot.stall_offers("someone", f"2026-W{week:02d}")
        assert len({o.get("itemId") or o.get("consumable") for o in offers}) == 4
        assert not any(o.get("rarity") == "LEGENDARY" for o in offers)
    monday = service.week_resets_at(datetime(2026, 10, 7, 15, 0, tzinfo=UTC))
    assert monday == datetime(2026, 10, 12, tzinfo=UTC)


async def test_a_sealed_chest_opens_once_the_journey_is_over(explorer_client):
    c = explorer_client
    r = await c.post("/inventory/consumables/SEALED_CHEST_RARE/use")
    assert r.status_code == 409 and r.json()["error"]["code"] == "NONE_LEFT"
    assert r.json()["error"]["message"] == "You don't have any of those. Find them on journeys or at the stall."
    assert (await c.post("/inventory/consumables/NOTHING/use")).json()["error"]["code"] == "NONE_LEFT"
    await give(c, consumables={"SEALED_CHEST_RARE": 1, "LAMP": 1, "REST_TOKEN": 1})
    assert (await c.post("/inventory/consumables/LAMP/use")).json()["error"]["code"] == "NOT_USED_HERE"
    assert (await c.post("/inventory/consumables/REST_TOKEN/use")).json()["error"]["code"] == "NOT_USED_HERE"
    r = await c.post("/rides", json={"clientRideId": str(uuid.uuid4()), "startedAt": NOW.isoformat()})
    ride_id = r.json()["id"]
    r = await c.post("/inventory/consumables/SEALED_CHEST_RARE/use")
    assert r.status_code == 409 and r.json()["error"]["code"] == "OPEN_LATER"
    assert r.json()["error"]["message"] == "Open it when your journey is over."
    async with get_session_factory()() as db:
        (await db.get(Ride, uuid.UUID(ride_id))).status = "DISCARDED"
        await db.commit()
    r = await c.post("/inventory/consumables/SEALED_CHEST_RARE/use")
    assert r.status_code == 200, r.text
    found = r.json()["itemFound"]
    assert found["kind"] == "GEAR" and found["rarity"] == "RARE" and not found["soldOnTheSpot"]
    assert counts(r.json()["inventory"])["SEALED_CHEST_RARE"] == 0
    assert [i["itemId"] for i in r.json()["inventory"]["bag"]] == [found["itemId"]]


async def test_a_map_piece_shows_the_nearest_hidden_place(explorer_client, settings):
    c = explorer_client
    await give(c, consumables={"MAP_FRAGMENT": 1})
    where = {"latitude": ORIGIN[0], "longitude": ORIGIN[1]}
    r = await c.post("/inventory/consumables/MAP_FRAGMENT/use", json=where)
    assert r.status_code == 409 and r.json()["error"]["code"] == "NO_HIDDEN_PLACE"
    assert r.json()["error"]["message"] == "No hidden places near here. Try it somewhere new."
    async with get_session_factory()() as db:
        db.add(Discovery(name="Stave Hill", category="VIEWPOINT", latitude=ORIGIN[0] + 0.01,
                         longitude=ORIGIN[1], source="OSM", tags={}))  # fmt: skip
        db.add(Discovery(name="Far Hill", category="VIEWPOINT", latitude=ORIGIN[0] + 0.2,
                         longitude=ORIGIN[1], source="OSM", tags={}))  # fmt: skip
        await db.commit()
    r = await c.post("/inventory/consumables/MAP_FRAGMENT/use", json=where)
    assert r.status_code == 200, r.text
    used = r.json()
    assert used["placeName"] == "Stave Hill" and used["revealedTiles"] == 19, "two rings round its tile"
    assert counts(used["inventory"])["MAP_FRAGMENT"] == 0
    cells = (await c.get("/world/exploration/stats")).status_code
    assert cells == 200


async def test_a_lamp_in_the_bag_is_lit_before_coins(explorer_client):
    from app.world_objects import service as world_objects
    from tests.test_first_playable_journey import seed_discoveries

    c = explorer_client
    await seed_discoveries()
    world_objects.forget_checks()
    await give(c, consumables={"LAMP": 1}, coins=100)
    at = {"latitude": 51.4769, "longitude": 0.0005}
    check = (await c.get("/world/objects/lure", params=at)).json()
    assert check["ok"] and check["cost"] == 0 and check["lampsInBag"] == 1
    assert check["message"] == "Uses a lamp from your bag."
    r = await c.post("/world/objects/lure", json=at)
    assert r.status_code == 200, r.text
    assert (await c.get("/wallet")).json()["balance"] == 100, "no coins taken"
    assert counts((await c.get("/inventory")).json())["LAMP"] == 0


async def test_a_rest_token_keeps_the_streak_over_one_missed_day(explorer_client):
    c = explorer_client
    character = await me(c)
    day = date(2026, 10, 4)
    async with get_session_factory()() as db:
        db.add(UserStreak(user_id=character.user_id, current_days=4, longest_days=4,
                          last_activity_date=day - timedelta(days=2)))  # fmt: skip
        await db.commit()
    await give(c, consumables={"REST_TOKEN": 1})
    async with get_session_factory()() as db:
        kept = await update_streak(db, character.user_id, day, 5000)
        assert kept.days == 5 and kept.rest_token_used and kept.to_dict()["restTokenUsed"] is True
        # Two days missed: no token can carry that, and none is spent.
        row = await db.get(Character, character.id)
        await service.add_consumables(db, row, {"REST_TOKEN": 1})
        later = await update_streak(db, character.user_id, day + timedelta(days=3), 5000)
        assert later.days == 1 and not later.rest_token_used
        assert (await service.consumable_counts(db, row))["REST_TOKEN"] == 1
        # One day missed and no token: it starts again.
        await service.take_consumable(db, row, "REST_TOKEN", why="test")
        again = await update_streak(db, character.user_id, day + timedelta(days=5), 5000)
        assert again.days == 1 and not again.rest_token_used
        await db.commit()


@pytest.fixture
def effort(settings, monkeypatch):
    monkeypatch.setattr(settings, "feature_flags", "effort_combat")
    return settings


async def test_a_journey_finds_items_once_and_says_so(explorer_client, effort):
    c = explorer_client
    object_id = await place_monster("fen-troll", tier=3, wants=["ROAD", "WORD"], minds=["CLIMB"], holdMax=100)
    pts = past(800, 1600)
    middle = pts[len(pts) // 2]
    events = [{"objectId": object_id, "method": "LORE", "occurredAt": middle["timestamp"],
               "latitude": middle["latitude"], "longitude": middle["longitude"],
               "note": "A troll asleep by the water, snoring."}]  # fmt: skip
    summary = await ride(c, pts, encounter_events=events)
    assert summary["worldObjects"]["fights"][0]["outcome"] == "SEEN_OFF"
    assert len(summary["itemsFound"]) == 1, "an old one always leaves something"
    found = summary["itemsFound"][0]
    assert found["source"] == "MONSTER" and found["fromName"] == "Fen Troll" and found["soldOnTheSpot"] is False
    assert summary["streak"]["restTokenUsed"] is False
    # Processed again, it finds nothing more.
    async with get_session_factory()() as db:
        from sqlalchemy import delete

        from app.rides.models import RideRoute

        ride_row = await db.scalar(select(Ride).where(Ride.status == "PROCESSED"))
        ride_row.status = "UPLOADED"
        await db.execute(delete(RideRoute).where(RideRoute.ride_id == ride_row.id))
        await db.commit()
        before = await db.scalar(select(func.count(InventoryItem.id)))
    from app.rides.processing import process_ride

    async with get_session_factory()() as db:
        again = await process_ride(db, effort, ride_row.id)
        await db.commit()
        assert again["itemsFound"] == []
        assert await db.scalar(select(func.count(InventoryItem.id))) == before


async def test_a_chest_opened_by_hand_may_hold_an_item(explorer_client):
    from app.world_objects.models import WorldObject

    c = explorer_client
    character = await me(c)
    chest_id = next(u for u in (uuid.UUID(int=i) for i in range(5000)) if loot.roll(str(u), "CHEST", 3) is not None)
    async with get_session_factory()() as db:
        db.add(WorldObject(id=chest_id, user_id=character.user_id, kind="CHEST", status="SPAWNED", tier=3,
                           latitude=ORIGIN[0], longitude=ORIGIN[1], seed=str(uuid.uuid4()), reward_ac=150,
                           payload={"name": "Gilded chest", "anchorName": "The Mayflower"},
                           spawned_at=NOW - timedelta(hours=1), expires_at=NOW + timedelta(days=1)))  # fmt: skip
        await db.commit()
    r = await c.post(f"/world/objects/{chest_id}/claim", json={"latitude": ORIGIN[0], "longitude": ORIGIN[1]})
    assert r.status_code == 200, r.text
    found = r.json()["itemFound"]
    assert found is not None and found["source"] == "CHEST" and found["fromName"] == "Gilded chest"


async def test_a_hard_quest_offers_an_item_and_gives_it_once(explorer_client):
    from app.quests.models import QuestInstance

    c = explorer_client
    character = await me(c)
    async with get_session_factory()() as db:
        quest = QuestInstance(
            user_id=character.user_id, template_id="TEST", quest_type="EXPLORE", character_class="ANY",
            title="The Long Way", description="Go the long way.", difficulty="HARD", status="ACTIVE",
            recommended_distance_km=12, estimated_duration_minutes=60, base_xp=100, latitude=ORIGIN[0],
            longitude=ORIGIN[1],
            rewards={"xp": 100, "ac": 70, "items": [loot.item_out("drovers-bell")], "titles": []},
        )  # fmt: skip
        db.add(quest)
        await db.commit()
    r = await c.post(f"/quests/{quest.id}/complete", json={})
    assert r.status_code == 200, r.text
    items = r.json()["itemsFound"]
    assert [(i["itemId"], i["source"], i["fromName"]) for i in items] == [("drovers-bell", "QUEST", "The Long Way")]
    async with get_session_factory()() as db:
        row = await db.get(QuestInstance, quest.id)
        again = await service.grant_quest_items(db, await db.get(Character, character.id), row)
        assert again == []


async def wear_now(c, item_id: str, slot: str, level: int = 30) -> None:
    await set_level(c, level)
    [inventory_id] = await give(c, item_id)
    r = await c.put("/inventory/gear", json={"slot": slot, "itemId": inventory_id})
    assert r.status_code == 200, r.text


async def a_chest(c, metres_north: float):
    from app.core.geo import destination_point
    from app.world_objects.models import WorldObject

    character = await me(c)
    lat, lon = destination_point(ORIGIN[0], ORIGIN[1], 0, metres_north)
    async with get_session_factory()() as db:
        obj = WorldObject(user_id=character.user_id, kind="CHEST", status="SPAWNED", tier=1, latitude=lat,
                          longitude=lon, seed=str(uuid.uuid4()), reward_ac=25,
                          payload={"name": "Old chest", "anchorName": "A bench"},
                          spawned_at=NOW - timedelta(hours=2), expires_at=NOW + timedelta(days=1))  # fmt: skip
        db.add(obj)
        await db.commit()
        return str(obj.id)


async def test_the_wreckers_light_opens_chests_from_further_off(explorer_client):
    c = explorer_client
    near, far = await a_chest(c, 120), await a_chest(c, 400)
    plain = await ride(c, past(500, 1000))
    assert not {near, far} & {o["id"] for o in plain["worldObjects"]["claimed"]}, "50 m is a chest's reach"
    await wear_now(c, "wreckers-light", "LANTERN")
    lit = await ride(c, past(500, 1000))
    claimed = {o["id"] for o in lit["worldObjects"]["claimed"]}
    assert near in claimed and far not in claimed


async def test_a_candle_stub_explores_a_ring_round_each_new_tile(explorer_client):
    from app.exploration.models import UserExplorationCell

    c = explorer_client
    await wear_now(c, "candle-stub", "LANTERN")
    await ride(c, past(500, 1500))
    character = await me(c)
    async with get_session_factory()() as db:
        ringed = await db.scalar(
            select(func.count(UserExplorationCell.id)).where(
                UserExplorationCell.user_id == character.user_id, UserExplorationCell.discovered_via == "CARTOGRAPHER"
            )
        )
    assert ringed, "no ring explored round the new tiles"


async def test_a_folded_map_puts_one_more_quest_on_the_board(explorer_client, settings, monkeypatch):
    from app.quests import service as quests

    c = explorer_client
    asked: list[int] = []

    async def generate(db, settings, llm, user, character, latitude, longitude, count, **kw):
        asked.append(count)
        return []

    monkeypatch.setattr(quests, "generate_quests", generate)
    character = await me(c)
    from app.users.models import User

    async with get_session_factory()() as db:
        user = await db.get(User, character.user_id)
        await quests.ensure_available(db, settings, None, user, await db.get(Character, character.id), *ORIGIN)
    await wear_now(c, "folded-map", "MAP_CASE")
    async with get_session_factory()() as db:
        user = await db.get(User, character.user_id)
        await quests.ensure_available(db, settings, None, user, await db.get(Character, character.id), *ORIGIN)
    assert asked[0] == 3 and asked[-1] == 4
