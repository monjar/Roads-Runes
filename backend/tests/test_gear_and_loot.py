"""Gear, loot and every level paying, without the API (docs/ROADMAP.md 0.7.2):
the rules merge, what drops is seeded, once, with pity and one of each Legendary,
and a full bag sells on the spot."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import select

from app.characters.models import Character
from app.characters.sheet import SHEET_VERSION, CharacterSheet, build_sheet
from app.db.session import get_session_factory
from app.economy import service as economy
from app.economy.models import WalletTransaction
from app.economy.rules import compute_ride_ac
from app.inventory import catalog, gear, loot, service
from app.inventory.models import InventoryItem, ItemEvent
from app.lore.voice import violations
from app.progression import levels
from app.progression.engine import RideRewardInput, compute_ride_xp
from app.world_objects.models import WorldObject
from app.world_objects.service import combat_config
from tests.test_first_playable_journey import ORIGIN

NOW = datetime.now(UTC)


# --- the catalogue and the rules ---------------------------------------------------------


def test_fifteen_items_one_per_slot_and_rarity_each_saying_what_it_does():
    assert len(gear.book()["items"]) == 15
    assert [s["opensAtLevel"] for s in gear.book()["slots"]] == [1, 3, 5, 13, 21]
    for item in gear.book()["items"]:
        assert not violations(item["text"], glossary=True), item["id"]
        assert not violations(item["name"], glossary=True), item["id"]
    for c in gear.book()["consumables"]:
        assert not violations(c["text"], glossary=True) and not violations(c["name"], glossary=True), c["id"]
    assert gear.item_for("BELL", "LEGENDARY") == "unrung-bell"
    assert gear.legendaries() == {
        "unrung-bell", "wreckers-light", "poachers-pocket", "cartographers-atlas", "runesmiths-nail",
    }  # fmt: skip


def test_rules_from_runes_and_gear_merge_by_kind():
    merged = gear.merge_rules(
        {"CARRIED_SCALE": 2.0, "RUNE_REACH_M": 2000, "REVEAL_RINGS": 1},
        {"CARRIED_SCALE": 1.25, "RUNE_REACH_M": 1500, "NEW_TILE_RINGS": 1, "COIN_PCT.CHEST": 0.2},
        {"NEW_TILE_RINGS": 1, "FINISH_UNDER": 0.1, "COIN_PCT.CHEST": 0.05, "SELL_SCALE": 1.5},
        {"FINISH_UNDER": 0.05, "SELL_SCALE": 2.0},
    )
    assert merged["CARRIED_SCALE"] == 2.5, "scales multiply"
    assert merged["RUNE_REACH_M"] == 2000 and merged["FINISH_UNDER"] == 0.1, "reach and finish take the largest"
    assert merged["NEW_TILE_RINGS"] == 2, "rings add"
    assert merged["COIN_PCT.CHEST"] == 0.25 and merged["SELL_SCALE"] == 3.0
    assert merged["REVEAL_RINGS"] == 1, "a rule only one source makes is kept"


def character(level: int = 30, trade: str = "EXPLORER") -> Character:
    return Character(character_class=trade, overall_level=level, class_level=1, abilities=[])


def test_the_sheet_counts_gear_worn_in_an_open_slot_only():
    worn = {
        "BELL": "drovers-bell",
        "LANTERN": "candle-stub",
        "BAG": "tinkers-satchel",
        "MAP_CASE": "folded-map",
        "KEEPSAKE": "hagstone",
    }
    sheet = build_sheet(character(level=4), {"raido": 1}, worn)
    assert sheet.version == SHEET_VERSION == 4
    assert sheet.gear == {"BELL": "drovers-bell", "LANTERN": "candle-stub"}, "Bag opens at 5, Map case at 13"
    assert sheet.rules["CARRIED_SCALE"] == 2.5, "Raido × the Drover's Bell"
    assert sheet.rules["NEW_TILE_RINGS"] == 1
    assert "COIN_PCT.CHEST" not in sheet.rules and "CHEST" not in sheet.coin_pct
    full = build_sheet(character(level=30), {}, worn)
    assert full.coin_pct["CHEST"] == 0.2 and full.rules["SELL_SCALE"] == 1.5
    assert full.rules["BOARD_EXTRA"] == 1
    assert full.rune_threshold == 0.30, "the Hagstone matches as kindly as a Wizard"
    assert build_sheet(character(trade="WIZARD"), {}, {}).rune_threshold == 0.30
    # An item in the wrong slot, or one that does not exist, counts for nothing.
    assert build_sheet(character(), {}, {"BELL": "hagstone", "BAG": "nothing"}).gear == {}


def test_coin_and_xp_yields_and_better_finds():
    sheet = build_sheet(character(), {}, {"BAG": "saddle-roll", "KEEPSAKE": "rowan-twig"})
    assert sheet.coin_pct["RIDE_DISTANCE"] == 0.1
    assert sheet.rune_reach_m == 1500
    plain = compute_ride_ac(distance_meters=20_000, new_cells=0)
    rolled = compute_ride_ac(distance_meters=20_000, new_cells=0, coin_pct=sheet.coin_pct)
    assert plain[0].ac == 40 and rolled[0].ac == 44
    pocket = build_sheet(character(), {}, {"BAG": "poachers-pocket"})
    assert pocket.loot_find_pct == 0.1
    assert CharacterSheet.from_dict(pocket.to_dict()) == pocket
    base = compute_ride_xp(RideRewardInput("EXPLORER", objectives_completed_optional=2))
    double = compute_ride_xp(RideRewardInput("EXPLORER", objectives_completed_optional=2, optional_xp_scale=2.0))
    assert double[0].xp == 2 * base[0].xp


def test_gear_changes_the_fight_and_the_nail_wakes_a_rune_deeper():
    cfg = combat_config()
    sheet = build_sheet(character(), {"raido": 1}, {"BELL": "unrung-bell", "MAP_CASE": "cartographers-atlas"})
    changed = sheet.fight_cfg(cfg)
    assert changed["finishUnder"] == 0.1 and changed["groundCellScale"] == 1.25
    nailed = build_sheet(character(), {"raido": 1}, {"KEEPSAKE": "runesmiths-nail"})
    woken = nailed.woken("raido")
    assert woken.inscribed["raido"] == 3, "woken is one rank deeper, the Nail one more"
    assert woken.rules["CARRIED_SCALE"] == catalog.value("raido", 3)
    assert woken.rules["WOKEN_EXTRA"] == 1, "the gear's rules stay"


# --- what drops ------------------------------------------------------------------------


def test_a_drop_is_seeded_by_what_it_came_from():
    ids = [str(uuid.uuid4()) for _ in range(200)]
    first = [loot.roll(i, "MONSTER", 2) for i in ids]
    assert first == [loot.roll(i, "MONSTER", 2) for i in ids]
    assert all(loot.roll(i, "COLLECTABLE", 3) is None for i in ids), "a piece never drops anything"
    dropped = [d for d in first if d is not None]
    assert 0.45 < len(dropped) / len(ids) < 0.75, "a tier-2 creature drops six times in ten"
    assert all(loot.roll(i, "MONSTER", 3) is not None for i in ids), "an old one always drops"
    assert loot.drop_chance("MONSTER", 1, bounty=True) == 0.6
    assert loot.drop_chance("CHEST", 1, mossy=True) == 0.5
    assert loot.drop_chance("MONSTER", 1, grudge=True) == 1.0
    assert loot.drop_chance("MONSTER", 1, loot_find=0.1) == 0.35 * 1.1


def test_better_finds_move_weight_from_common_to_rare():
    assert loot.rarity_weights(1) == [85, 14, 1]
    assert loot.rarity_weights(1, 0.1) == [75, 24, 1]
    sealed = [loot.roll(str(i), "MONSTER", 3) for i in range(400)]
    assert any(d and d.consumable == "SEALED_CHEST_RARE" for d in sealed), "a tier-3 sealed chest is Rare"
    assert not any(d and d.consumable == "SEALED_CHEST_COMMON" for d in sealed)


def test_a_legendary_is_one_of_each_ever():
    ids = [str(i) for i in range(3000)]
    legend = next(i for i in ids if (d := loot.roll(i, "MONSTER", 3)) and d.rarity == "LEGENDARY")
    drop = loot.roll(legend, "MONSTER", 3)
    had = loot.roll(legend, "MONSTER", 3, had_legendaries={drop.item_id})
    assert had.rarity == "RARE"
    assert gear.by_id()[had.item_id]["slot"] == gear.by_id()[drop.item_id]["slot"], "the Rare of the same slot"


def test_pity_forces_a_rare_find():
    nothing = next(str(i) for i in range(500) if loot.roll(str(i), "CHEST", 1) is None)
    forced = loot.roll(nothing, "CHEST", 1, pity_due=True)
    assert forced is not None and forced.kind == "GEAR" and forced.rarity in ("RARE", "LEGENDARY") and forced.pity


def test_quests_offer_items_by_difficulty():
    assert loot.quest_reward("q1", "EASY") is None and loot.quest_reward("q1", "MODERATE") is None
    hard = loot.quest_reward("q1", "HARD")
    assert hard["rarity"] == "RARE" and set(hard) == {"itemId", "name", "rarity", "icon", "slot"}
    epics = [loot.quest_reward(f"q{i}", "EPIC")["rarity"] for i in range(400)]
    assert set(epics) == {"RARE", "LEGENDARY"}
    assert 0.15 < epics.count("LEGENDARY") / len(epics) < 0.35
    assert loot.quest_reward("q7", "EPIC") == loot.quest_reward("q7", "EPIC")


# --- every level pays --------------------------------------------------------------------


def test_every_level_pays_something():
    table = levels.table()
    assert len(table) == 50
    assert all(row["rewards"] for row in table[1:]), "every level from 2 to 50 pays"
    texts = {r["text"] for r in levels.rewards_for_level(3)}
    assert texts == {"Lantern slot opens", "The stall opens"}
    assert "Title: Roadwise" in {r["text"] for r in levels.rewards_for_level(10)}
    assert "A sealed chest (Rare)" in {r["text"] for r in levels.rewards_for_level(10)}
    assert levels.rewards_for_level(2) == [
        {"kind": "CONSUMABLE", "text": "2 lamps", "icon": "lantern", "consumable": "LAMP", "count": 2}
    ]
    consumables = [r["consumable"] for n in range(2, 51) for r in levels.rewards_for_level(n) if r.get("consumable")]
    assert {"LAMP", "MAP_FRAGMENT", "REST_TOKEN", "SEALED_CHEST_COMMON", "SEALED_CHEST_RARE"} <= set(consumables)
    for row in table:
        for reward in row["rewards"]:
            assert not violations(reward["text"], glossary=True), reward


# --- the single writer --------------------------------------------------------------------


async def make_character(level: int = 10) -> Character:
    from app.users.models import User

    async with get_session_factory()() as db:
        user = User(apple_subject=f"dev:{uuid.uuid4()}", display_name="Rowan")
        db.add(user)
        await db.flush()
        row = Character(user_id=user.id, name="Rowan", character_class="EXPLORER", overall_level=level)
        db.add(row)
        await db.commit()
        return row


async def creature(db, character: Character, tier: int = 3, id: uuid.UUID | None = None, **payload) -> WorldObject:
    obj = WorldObject(
        id=id or uuid.uuid4(),
        user_id=character.user_id,
        kind=payload.pop("kind", "MONSTER"),
        status="CLAIMED",
        tier=tier,
        latitude=ORIGIN[0],
        longitude=ORIGIN[1],
        seed=str(uuid.uuid4()),
        reward_ac=60,
        payload={"name": "Fen Troll", "speciesId": "fen-troll", **payload},
        spawned_at=NOW - timedelta(hours=2),
        expires_at=NOW + timedelta(days=1),
    )
    db.add(obj)
    await db.flush()
    return obj


async def test_a_drop_is_given_once_and_counts_towards_pity(engine):
    character = await make_character()
    async with get_session_factory()() as db:
        row = await db.get(Character, character.id)
        obj = await creature(db, row, tier=3)
        found = await service.drop_for(db, row, obj)
        assert found is not None and found["source"] == "MONSTER" and found["fromName"] == "Fen Troll"
        assert await service.drop_for(db, row, obj) is None, "a rerun drops nothing new"
        keys = (await db.execute(select(ItemEvent.key).where(ItemEvent.user_id == row.user_id))).scalars().all()
        assert keys.count(f"drop:{obj.id}") == 1
        # A piece drops nothing and does not count.
        piece = await creature(db, row, kind="COLLECTABLE")
        before = (await service.loadout(db, row)).finishes_since_rare
        assert await service.drop_for(db, row, piece) is None
        assert (await service.loadout(db, row)).finishes_since_rare == before
        await db.commit()


async def test_five_finishes_without_a_rare_force_one(engine):
    character = await make_character()
    async with get_session_factory()() as db:
        row = await db.get(Character, character.id)
        (await service.loadout(db, row)).finishes_since_rare = 5
        chest = await creature(db, row, tier=1, kind="CHEST", name="Old chest")
        found = await service.drop_for(db, row, chest)
        assert found["kind"] == "GEAR" and found["rarity"] in ("RARE", "LEGENDARY")
        assert (await service.loadout(db, row)).finishes_since_rare == 0
        await db.commit()


def rolling(want, source: str = "MONSTER", tier: int = 3) -> uuid.UUID:
    """An object id whose seeded roll is what a test needs."""
    return next(u for u in (uuid.UUID(int=i) for i in range(20000)) if want(loot.roll(str(u), source, tier)))


async def test_a_legendary_once_had_drops_as_a_rare(engine):
    character = await make_character()
    legend = rolling(lambda d: d is not None and d.rarity == "LEGENDARY")
    async with get_session_factory()() as db:
        row = await db.get(Character, character.id)
        got = await service.drop_for(db, row, await creature(db, row, id=legend))
        assert got["kind"] == "GEAR" and got["rarity"] == "LEGENDARY"
        await service.sell(db, row, uuid.UUID(got["inventoryItemId"]))
        assert await service.legendaries_had(db, row.user_id) == {got["itemId"]}, "sold is still had"
        # The same roll again, for someone who has had it: the Rare of that slot.
        had = await service.legendaries_had(db, row.user_id)
        second = loot.roll(str(legend), "MONSTER", 3, had_legendaries=had)
        assert second.rarity == "RARE"
        assert gear.by_id()[second.item_id]["slot"] == gear.by_id()[got["itemId"]]["slot"]
        await db.commit()


async def test_a_full_bag_sells_the_find_on_the_spot(engine):
    character = await make_character()
    async with get_session_factory()() as db:
        row = await db.get(Character, character.id)
        for i in range(gear.bag_size()):
            await service.add_gear(db, row, "tin-bell", source="STALL", key=f"test:{i}")
        assert len(await service.bag(db, row)) == 20
        gear_drop = rolling(lambda d: d is not None and d.kind == "GEAR", "CHEST", 3)
        chest = await creature(db, row, tier=3, id=gear_drop, kind="CHEST", name="Gilded chest")
        before = await economy.balance(db, row.user_id)
        found = await service.drop_for(db, row, chest)
        assert found["soldOnTheSpot"] is True and found["soldFor"] == gear.sell_price(found["rarity"])
        assert await economy.balance(db, row.user_id) == before + found["soldFor"]
        assert len(await service.bag(db, row)) == 20
        sale = await db.scalar(select(WalletTransaction).where(WalletTransaction.kind == "ITEM_SOLD"))
        assert sale.amount == found["soldFor"]
        await db.commit()


async def test_levels_are_paid_once_and_the_ones_before_are_caught_up(engine):
    character = await make_character(level=7)
    async with get_session_factory()() as db:
        row = await db.get(Character, character.id)
        paid = await service.catch_up_levels(db, row)
        assert {r["level"] for r in paid} == {2, 3, 4, 5, 6, 7}
        assert await service.catch_up_levels(db, row) == []
        counts = await service.consumable_counts(db, row)
        expected: dict[str, int] = {}
        for n in range(2, 8):
            for cid, k in levels.consumables_for_level(n).items():
                expected[cid] = expected.get(cid, 0) + k
        assert {k: v for k, v in counts.items() if v} == expected
        assert await service.pay_level(db, row, 7) is None
        await db.commit()


async def test_a_level_up_pays_through_grant(engine):
    from app.progression.engine import XPLine
    from app.progression.service import grant

    character = await make_character(level=1)
    async with get_session_factory()() as db:
        row = await db.get(Character, character.id)
        outcome = await grant(db, row, [XPLine("ADJUSTMENT", 700)])
        overall = next(lu for lu in outcome.level_ups if lu["kind"] == "OVERALL")
        assert overall["from"] == 1 and overall["to"] == 3
        assert {r["text"] for r in overall["rewards"]} >= {"2 lamps", "Lantern slot opens", "The stall opens"}
        assert (await service.consumable_counts(db, row))["LAMP"] == 2
        assert await service.catch_up_levels(db, row) == [], "already paid on the way up"
        await db.commit()


async def test_item_widths_fit_their_columns(engine):
    """Postgres holds a string to its column's width; SQLite does not."""
    widths = {c.name: c.type.length for c in InventoryItem.__table__.columns if getattr(c.type, "length", None)}
    assert all(len(i) <= widths["item_id"] for i in gear.by_id())
    assert all(len(r) <= widths["rarity"] for r in gear.RARITIES)
    assert all(len(s) <= widths["source"] for s in ("MONSTER", "BOUNTY", "CHEST", "QUEST", "STALL", "SEALED_CHEST"))
    longest = max(
        [f"drop:{uuid.uuid4()}", f"quest-item:{uuid.uuid4()}:9", "stall:2026-W41:w41-3",
         "open:SEALED_CHEST_COMMON:9999", "level:50"],
        key=len,
    )  # fmt: skip
    assert len(longest) <= widths["source_key"]
    event_widths = {c.name: c.type.length for c in ItemEvent.__table__.columns if getattr(c.type, "length", None)}
    assert all(len(k) <= event_widths["kind"] for k in ("DROP", "QUEST_ITEM", "LEVEL", "WEAR", "SELL", "USE",
                                                         "OPEN", "STALL"))  # fmt: skip
    assert len(f"use:SEALED_CHEST_COMMON:{uuid.uuid4().hex}") <= event_widths["key"]
    assert len(f"wear:MAP_CASE:{NOW.isoformat()}") <= event_widths["key"]


def test_price_check_reads_a_weekly_average_from_the_ledger():
    import importlib.util
    from pathlib import Path

    spec = importlib.util.spec_from_file_location(
        "price_check", Path(__file__).parent.parent / "scripts" / "price_check.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    now = datetime(2026, 10, 4, 12, tzinfo=UTC)
    rows = [
        (now - timedelta(days=1), 120, "RIDE_DISTANCE"),
        (now - timedelta(days=9), 80, "CHEST_OPENED"),
        (now - timedelta(days=9), -50, "LURE"),
        (now - timedelta(days=2), 500, "ADJUSTMENT"),
        (now - timedelta(days=60), 999, "MONSTER_SLAIN"),
    ]
    found = module.weekly(rows, 2, now)
    assert found["earned"] == 200 and found["perWeek"] == 100 and found["spent"] == 50
    assert found["byKind"] == {"RIDE_DISTANCE": 120, "CHEST_OPENED": 80}
