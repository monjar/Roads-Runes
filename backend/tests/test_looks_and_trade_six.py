"""Looks at the stall (route ink, marker and crest frames) and the Trade Six (0.9.0)."""

from __future__ import annotations

from collections import Counter

from sqlalchemy import select

from app.characters.models import Character
from app.characters.sheet import CharacterSheet, build_sheet
from app.db.session import get_session_factory
from app.economy.rules import compute_ride_ac
from app.inventory import catalog as runes
from app.inventory import cosmetics, gear
from app.inventory import service as inventory
from app.inventory.models import CharacterDeed, InventoryItem, RuneHolding
from app.lore.voice import violations
from app.progression.engine import RideRewardInput, compute_ride_xp
from app.world_objects.service import load_config
from tests.test_inventory_api import give, me, set_level

# --- looks -----------------------------------------------------------------------------


def test_the_looks_book():
    inks = [i for i in cosmetics.book()["items"] if i["kind"] == "INK"]
    assert [i["name"] for i in inks] == ["Ink", "Terracotta", "Sage", "Gold", "Wizard Blue", "Scribe Plum"]
    markers = [i["name"] for i in cosmetics.book()["items"] if i["kind"] == "MARKER_FRAME"]
    assert markers == ["Plain", "Rope", "Laurel", "Runic"]
    # The route line has always been terracotta: that stays the default, and plain Ink is free too.
    assert cosmetics.defaults() == {"ink": "ink:terracotta", "markerFrame": "marker:plain", "crestFrame": "crest:plain"}
    assert {"ink:ink", "ink:terracotta"} <= set(cosmetics.free())
    assert all(200 <= i["price"] <= 400 for i in cosmetics.for_sale())
    for item in cosmetics.book()["items"]:
        assert len(item["id"]) <= InventoryItem.__table__.c.item_id.type.length
        assert not violations(item["name"], glossary=True) and not violations(item["text"], glossary=True)
    assert len("COSMETIC") <= InventoryItem.__table__.c.rarity.type.length
    frame = cosmetics.deed_frame("crest:legs-2")
    assert frame["name"] == "Well Travelled" and frame["kind"] == "CREST_FRAME"
    assert cosmetics.deed_frame("crest:legs-9") is None and cosmetics.deed_frame("crest:oak") is None


def test_the_stall_look_is_seeded_and_never_one_already_owned():
    a = cosmetics.stall_offer("someone", "2026-W41", set(cosmetics.free()))
    assert a == cosmetics.stall_offer("someone", "2026-W41", set(cosmetics.free()))
    assert a["id"] == "w41-4" and a["kind"] == "COSMETIC" and a["itemId"] in cosmetics.by_id()
    assert cosmetics.stall_offer("someone", "2026-W41", {a["itemId"]})["itemId"] != a["itemId"]
    assert cosmetics.stall_offer("someone", "2026-W41", {i["id"] for i in cosmetics.book()["items"]}) is None


async def test_a_look_is_bought_at_the_stall_and_worn(explorer_client):
    c = explorer_client
    first = (await c.get("/inventory")).json()
    assert first["look"] == {"ink": "ink:terracotta", "markerFrame": "marker:plain", "crestFrame": "crest:plain"}
    assert {x["itemId"]: x["source"] for x in first["cosmetics"]} == {
        "ink:ink": "DEFAULT",
        "ink:terracotta": "DEFAULT",
        "marker:plain": "DEFAULT",
        "crest:plain": "DEFAULT",
    }
    terracotta = next(x for x in first["cosmetics"] if x["itemId"] == "ink:terracotta")
    assert terracotta == {**terracotta, "kind": "INK", "name": "Terracotta", "color": "#B5583A"}
    await set_level(c, 3)
    await give(c, coins=1000)
    stall = (await c.get("/inventory/stall")).json()
    [look] = [o for o in stall["offers"] if o["kind"] == "COSMETIC"]
    assert 200 <= look["price"] <= 400 and look["cosmeticKind"] == cosmetics.kind_of(look["itemId"])
    assert look["name"] and look["text"] and not look["bought"]
    r = await c.post(f"/inventory/stall/{look['id']}/buy")
    assert r.status_code == 200, r.text
    after = r.json()
    assert after["bag"] == [], "a look never takes a place in the bag"
    assert {x["itemId"]: x["source"] for x in after["cosmetics"]}[look["itemId"]] == "STALL"
    assert (await c.get("/wallet")).json()["balance"] == 1000 - look["price"]
    again = [o for o in (await c.get("/inventory/stall")).json()["offers"] if o["kind"] == "COSMETIC"]
    assert again == [{**look, "bought": True}], "the week's look stays put once bought"
    r = await c.post(f"/inventory/stall/{look['id']}/buy")
    assert r.status_code == 409 and r.json()["error"]["code"] == "ALREADY_BOUGHT"
    field = cosmetics.LOOK_FIELDS[look["cosmeticKind"]]
    r = await c.put("/inventory/look", json={field: look["itemId"]})
    assert r.status_code == 200, r.text
    assert r.json()["look"][field] == look["itemId"]
    # Free looks can be worn too, and a field left out stays as it is.
    other, free_one = ("markerFrame", "marker:plain") if field == "ink" else ("ink", "ink:ink")
    r = await c.put("/inventory/look", json={other: free_one})
    assert r.json()["look"][other] == free_one and r.json()["look"][field] == look["itemId"]
    unowned = next(i["id"] for i in cosmetics.for_sale() if i["kind"] == "INK" and i["id"] != look["itemId"])
    r = await c.put("/inventory/look", json={"ink": unowned})
    assert r.status_code == 409 and r.json()["error"]["code"] == "LOOK_NOT_OWNED"
    assert not violations(r.json()["error"]["message"], glossary=True)
    r = await c.put("/inventory/look", json={"ink": "marker:plain"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "WRONG_LOOK"
    r = await c.put("/inventory/look", json={"ink": None})
    assert r.json()["look"]["ink"] == "ink:terracotta", "null goes back to the default"


async def test_each_deed_tier_reached_is_a_crest_frame(explorer_client):
    c = explorer_client
    character = await me(c)
    async with get_session_factory()() as db:
        db.add(CharacterDeed(user_id=character.user_id, character_id=character.id, deed_id="LEGS", value=300, tier=2))
        await db.commit()
    inv = (await c.get("/inventory")).json()
    frames = {x["itemId"]: x for x in inv["cosmetics"] if x["source"] == "DEED"}
    assert set(frames) == {"crest:legs-1", "crest:legs-2"}
    assert frames["crest:legs-1"]["name"] == "Out and About"
    r = await c.put("/inventory/look", json={"crestFrame": "crest:legs-2"})
    assert r.status_code == 200 and r.json()["look"]["crestFrame"] == "crest:legs-2"
    r = await c.put("/inventory/look", json={"crestFrame": "crest:legs-3"})
    assert r.status_code == 409


# --- the Trade Six ---------------------------------------------------------------------


def test_the_trade_six_can_be_held_and_say_what_they_do():
    assert sorted(runes.trade_six()) == sorted(["fehu", "gebo", "mannaz", "tiwaz", "perthro", "othala"])
    texts = {r: [runes.rule_text(r, rank) for rank in (1, 2, 3, 4)] for r in runes.trade_six()}
    for rune_id, lines in texts.items():
        assert runes.holdable(rune_id) and not runes.by_id()[rune_id].get("ground")
        for text in lines:
            assert "{" not in text and text.endswith("."), text
            assert not violations(text, glossary=True), text
    assert texts["fehu"][:2] == [
        "Each district that's yours pays 1 more coin a week.",
        "Each district that's yours pays 2 more coins a week.",
    ]
    assert texts["perthro"] == [
        f"A sealed chest has a {p}% chance to hold one rarity better." for p in (10, 15, 20, 25)
    ]
    assert texts["othala"][3] == "A district stays yours for 90 days after your last visit (usually 30)."
    rules = {r: runes.by_id()[r]["rule"] for r in runes.trade_six()}
    assert rules == {
        "fehu": "DISTRICT_PAY_EXTRA",
        "gebo": "CHEST_COINS_SCALE",
        "mannaz": "FOOT_XP_SCALE",
        "tiwaz": "QUARRY_CARRIED_SCALE",
        "perthro": "SEALED_UPGRADE",
        "othala": "DISTRICT_KEEP_DAYS",
    }
    assert [runes.value("tiwaz", rank) for rank in (1, 2, 3, 4)] == [1.25, 1.5, 1.75, 2.0]


async def test_gebo_makes_chests_pay_more(explorer_client):
    character = await me(explorer_client)
    async with get_session_factory()() as db:
        row = await db.get(Character, character.id)
        await db.refresh(row, ["abilities"])
        plain = build_sheet(row)
        sheet = build_sheet(row, {"gebo": 2})
    assert sheet.rules["CHEST_COINS_SCALE"] == 1.2 and sheet.coin_pct["CHEST"] == 0.2
    chest = [{"id": "c", "kind": "CHEST", "name": "Old chest", "rewardAC": 25, "bounty": False}]
    with_gebo = compute_ride_ac(distance_meters=0, new_cells=0, claims=chest, coin_pct=sheet.coin_pct)
    without = compute_ride_ac(distance_meters=0, new_cells=0, claims=chest, coin_pct=plain.coin_pct)
    assert [line.ac for line in with_gebo] == [30] and [line.ac for line in without] == [25]


def test_mannaz_pays_more_xp_for_distance_on_foot_only():
    def xp(activity: str, scale: float) -> dict[str, int]:
        lines = compute_ride_xp(
            RideRewardInput(
                character_class="WIZARD", new_roads_meters=5000, distance_meters=45_000, activity=activity,
                foot_xp_scale=scale,
            )
        )  # fmt: skip
        return {line.source: line.xp for line in lines}

    walk, walk_mannaz = xp("WALK", 1.0), xp("WALK", 1.2)
    for source in ("NEW_ROAD_EXPLORED", "LONG_DISTANCE_ADVENTURE", "KNOWN_GROUND"):
        assert walk_mannaz[source] == round(walk[source] * 1.2), source
    assert xp("RIDE", 1.2) == xp("RIDE", 1.0), "a ride is not a run or a walk"


def test_tiwaz_scales_the_opening_blow_on_the_quarry_only():
    cfg = load_config()["combat"]
    sheet = CharacterSheet(rules={"QUARRY_CARRIED_SCALE": 1.5, "ELDER_CARRIED_SCALE": 2.0})
    base = sheet.fight_cfg(cfg)["carriedFraction"]
    assert sheet.foe_cfg(sheet.fight_cfg(cfg), elder=False)["carriedFraction"] == base
    assert sheet.foe_cfg(sheet.fight_cfg(cfg), elder=False, quarry=True)["carriedFraction"] == base * 1.5
    assert sheet.foe_cfg(sheet.fight_cfg(cfg), elder=True, quarry=True)["carriedFraction"] == base * 3.0
    assert sheet.foe_cfg(sheet.fight_cfg(cfg), elder=True, quarry=True)["carriedCap"] == cfg["carriedCap"]
    assert sheet.legend_cfg(sheet.fight_cfg(cfg), quarry=True)["carriedFraction"] == base * 3.0
    assert CharacterSheet().foe_cfg(cfg, elder=False, quarry=True) == cfg, "no Tiwaz, no change"


def test_perthro_sometimes_makes_a_sealed_chest_one_rarity_better():
    assert inventory.sealed_rarity("open:SEALED_CHEST_COMMON:0", "COMMON", 0.0) == "COMMON"
    assert inventory.sealed_rarity("open:SEALED_CHEST_COMMON:0", "COMMON", 1.0) == "RARE"
    assert inventory.sealed_rarity("open:SEALED_CHEST_RARE:0", "RARE", 1.0) == "LEGENDARY"
    assert inventory.sealed_rarity("k", "LEGENDARY", 1.0) == "LEGENDARY"
    rolls = Counter(inventory.sealed_rarity(f"open:SEALED_CHEST_COMMON:{i}", "COMMON", 0.25) for i in range(1000))
    assert 200 <= rolls["RARE"] <= 300
    assert inventory.sealed_rarity("same", "COMMON", 0.25) == inventory.sealed_rarity("same", "COMMON", 0.25)
    assert set(gear.SEALED.values()) == {"COMMON", "RARE"}


async def test_perthro_inscribed_opens_a_better_sealed_chest(explorer_client):
    c = explorer_client
    character = await me(c)
    async with get_session_factory()() as db:
        row = await db.get(Character, character.id)
        await inventory.give_rune(db, row, "perthro", key="test:perthro")
        await db.commit()
    async with get_session_factory()() as db:
        held = await db.scalar(select(RuneHolding).where(RuneHolding.rune_id == "perthro"))
        held.rank = 3
        await db.commit()
    r = await c.put("/runes/inscribed", json={"runes": ["perthro"]})
    assert r.status_code == 200, r.text
    await give(c, consumables={"SEALED_CHEST_COMMON": 12})
    rarities = []
    for _ in range(12):
        r = await c.post("/inventory/consumables/SEALED_CHEST_COMMON/use")
        assert r.status_code == 200, r.text
        rarities.append(r.json()["itemFound"]["rarity"])
    expected = [
        inventory.sealed_rarity(f"open:SEALED_CHEST_COMMON:{i}", "COMMON", runes.value("perthro", 3)) for i in range(12)
    ]
    assert rarities == expected and "RARE" in rarities
