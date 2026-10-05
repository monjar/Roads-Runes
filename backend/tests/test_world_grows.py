"""The world grows (docs/ROADMAP.md 0.7.2): twelve more creatures, each with its
mark; variants; grudges that come back once; trophies on the codex page."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select

from app.core.geo import destination_point
from app.db.session import get_session_factory
from app.discoveries.models import Discovery
from app.economy.rules import load_ac_rules
from app.lore import catalog
from app.lore.voice import violations
from app.world_objects import service as world_objects
from app.world_objects import variants
from app.world_objects.models import WorldObject
from app.world_objects.spawner import Anchor, plan_spawns
from tests.test_first_playable_journey import ORIGIN

NOW = datetime.now(UTC)

NEW = {
    "hedge-dragon": "hedgeDragon", "hill-wyvern": "hillWyvern", "culvert-imp": "culvertImp",
    "bridge-ogre": "bridgeOgre", "stile-boggart": "stileBoggart", "milestone-goblin": "milestoneGoblin",
    "gatehouse-gargoyle": "gatehouseGargoyle", "bramble-wolf": "brambleWolf", "rooftop-griffin": "rooftopGriffin",
    "marsh-wisp": "marshWisp", "stone-giant": "stoneGiant", "tavern-brownie": "tavernBrownie",
}  # fmt: skip


def test_twelve_new_creatures_each_with_its_mark():
    book = catalog.species_by_id()
    assert len(book) == 24
    for sid, icon in NEW.items():
        entry = book[sid]
        assert entry["sigil"]["icon"] == icon
        assert entry["page"].count(". ") + 1 <= 3, f"{sid}: two or three sentences"
        for text in [entry["flavour"], entry["page"], entry["hint"], entry["leaves"],
                     *(e["flavour"] for e in entry["elders"])]:  # fmt: skip
            assert not violations(text), (sid, text)
    old_marks = [book[s]["sigil"]["icon"] for s in ("bog-wraith", "fen-troll", "cinder-hound")]
    assert old_marks == ["ghost", "troll", "wolfHead"]
    assert all(s["sigil"]["icon"] for s in catalog.species())


def anchors(n: int = 60) -> list[Anchor]:
    out = []
    for i in range(n):
        lat, lon = destination_point(ORIGIN[0], ORIGIN[1], (i * 37) % 360, 150 + 120 * i)
        out.append(Anchor(str(uuid.UUID(int=i + 1)), f"Place {i}", "NATURE", lat, lon, None))
    return out


def plans(seed: str = "variants", n: int = 60, tiers=(1, 0, 0), bounty: bool = False):
    cfg = {**world_objects.load_config(), "tierWeights": list(tiers)}
    return plan_spawns(
        seed=seed, kind="MONSTER", indices=list(range(n)), anchors=anchors(n), taken_anchor_ids=set(), occupied=[],
        cfg=cfg, ac_rules=load_ac_rules(), frontier=set(), known={}, character_class="EXPLORER", activity="RIDE",
        bounty=bounty,
    )  # fmt: skip


def test_one_creature_in_five_is_a_variant_and_it_says_what_that_means():
    picks = [variants.pick_variant(f"s:{i}", 1) for i in range(2000)]
    assert picks == [variants.pick_variant(f"s:{i}", 1) for i in range(2000)], "seeded"
    share = sum(1 for p in picks if p) / len(picks)
    assert 0.16 < share < 0.24
    kinds = [p for p in picks if p]
    assert kinds.count("STUBBORN") > kinds.count("SKITTISH") > kinds.count("MOSSY") > 0
    assert variants.pick_variant("s:1", 3) is None, "old ones are never variants"
    assert variants.variant_out("STUBBORN") == {
        "id": "STUBBORN", "name": "Stubborn", "text": "30% more health and 30% more coins.",
    }  # fmt: skip
    assert variants.display_name({"name": "Fen Troll", "variant": "SKITTISH"}) == "Skittish Fen Troll"
    assert variants.display_name({"name": "Fen Troll"}) == "Fen Troll"


def test_a_variant_changes_health_coins_and_how_long_it_stays():
    placed = plans()
    purse = int(load_ac_rules()["monster"]["1"])
    by_kind = {}
    for plan in placed:
        by_kind.setdefault(plan.payload.get("variant"), plan)
    stubborn, skittish = by_kind["STUBBORN"], by_kind["SKITTISH"]
    assert stubborn.payload["holdMax"] == 130 and stubborn.reward_ac == round(purse * 1.3)
    assert skittish.payload["holdMax"] == 70 and skittish.reward_ac == round(purse * 0.8) and skittish.life_days == 1
    assert by_kind[None].payload.get("holdMax") is None and by_kind[None].reward_ac == purse
    assert stubborn.payload["name"] == catalog.species_by_id()[stubborn.payload["speciesId"]]["name"], "plain name"
    assert not any(p.payload.get("variant") for p in plans(bounty=True)), "never a bounty"
    assert plans() == placed


@pytest.fixture
def effort(settings, monkeypatch):
    monkeypatch.setattr(settings, "feature_flags", "effort_combat")
    return settings


async def place(user_id, anchor_id, *, wounded: bool, expired: bool, **extra) -> WorldObject:
    async with get_session_factory()() as db:
        payload = {"name": "Fen Troll", "speciesId": "fen-troll", "hp": 100, "anchorName": "The Mayflower",
                   "species": {"wants": ["ROAD", "RUNE"], "minds": ["WORD"], "roadForm": "SQUARE"},
                   "killMethods": [], **extra}  # fmt: skip
        if wounded:
            payload["wounds"] = {"rides": {str(uuid.uuid4()): {"day": "2026-10-01", "taken": 40}}}
        obj = WorldObject(
            user_id=user_id, kind="MONSTER", status="SPAWNED", tier=1, anchor_discovery_id=anchor_id,
            latitude=ORIGIN[0], longitude=ORIGIN[1], seed=str(uuid.uuid4()), reward_ac=60, payload=payload,
            spawned_at=NOW - timedelta(days=3), expires_at=NOW - timedelta(hours=1) if expired else NOW + timedelta(days=1),
        )  # fmt: skip
        db.add(obj)
        await db.commit()
        return obj


async def grudges(user_id) -> list[WorldObject]:
    async with get_session_factory()() as db:
        rows = await db.execute(
            select(WorldObject).where(WorldObject.user_id == user_id, WorldObject.seed.like("grudge:%"))
        )
        return list(rows.scalars())


async def test_a_creature_that_got_away_twice_comes_back_once_with_a_grudge(explorer_client, effort):
    c = explorer_client
    user_id = uuid.UUID((await c.get("/users/me")).json()["id"])
    async with get_session_factory()() as db:
        anchor = Discovery(name="The Mayflower", category="PUB", latitude=ORIGIN[0], longitude=ORIGIN[1], source="OSM")
        other = Discovery(name="Elsewhere", category="PUB", latitude=ORIGIN[0], longitude=ORIGIN[1], source="OSM")
        db.add_all([anchor, other])
        await db.commit()

    async def expire() -> None:
        async with get_session_factory()() as db:
            await world_objects.expire_stale(db, user_id)
            await db.commit()

    # Untouched, it just leaves; once weakened is not yet a grudge.
    await place(user_id, anchor.id, wounded=False, expired=True)
    await place(user_id, anchor.id, wounded=True, expired=True)
    await expire()
    assert await grudges(user_id) == []
    # Weakened at another place does not count towards this one.
    await place(user_id, other.id, wounded=True, expired=True)
    await expire()
    assert await grudges(user_id) == []
    # Weakened again here: it comes back.
    await place(user_id, anchor.id, wounded=True, expired=True)
    await expire()
    [grudge] = await grudges(user_id)
    epithet = grudge.payload["grudge"]["epithet"]
    assert epithet in variants.book()["grudges"]["epithets"]
    assert grudge.payload["name"] == f"Fen Troll the {epithet}"
    assert grudge.payload["holdMax"] == 125 and grudge.reward_ac == 90
    assert grudge.expires_at.replace(tzinfo=UTC) - NOW > timedelta(days=2, hours=23)
    shown = (await c.get(f"/world/objects/{grudge.id}")).json()
    assert shown["monster"]["grudge"] == {"epithet": epithet, "line": "It got away twice. Now it's back, and grumpier."}
    assert shown["monster"]["holdMax"] == 125 and shown["monster"]["sigil"]["icon"] == "troll"
    # Only once: a third time, and the grudge itself getting away, bring nothing more.
    await place(user_id, anchor.id, wounded=True, expired=True)
    async with get_session_factory()() as db:
        row = await db.get(WorldObject, grudge.id)
        row.expires_at = NOW - timedelta(minutes=1)
        row.payload = {**row.payload, "wounds": {"rides": {"r": {"day": "2026-10-02", "taken": 30}}}}
        await db.commit()
    await expire()
    assert len(await grudges(user_id)) == 1


def test_a_grudge_seed_fits_its_column():
    width = WorldObject.__table__.columns["seed"].type.length
    longest = max(catalog.species_by_id(), key=len)
    assert len(variants.grudge_seed(str(uuid.uuid4()), longest)) <= width == variants.SEED_WIDTH


async def test_a_variant_is_shown_with_its_name_in_front(explorer_client, effort):
    from tests.test_effort_combat import place_monster

    c = explorer_client
    object_id = await place_monster("hedge-dragon", variant="MOSSY")
    shown = (await c.get(f"/world/objects/{object_id}")).json()
    assert shown["name"] == "Hedge Dragon" and shown["displayName"] == "Mossy Hedge Dragon"
    assert shown["monster"]["variant"]["name"] == "Mossy" and shown["monster"]["displayName"] == "Mossy Hedge Dragon"
    assert shown["monster"]["sigil"] == {"body": "wyrm", "feature": "wings", "mark": "tree", "icon": "hedgeDragon"}


async def test_the_codex_counts_what_each_creature_left_behind(explorer_client):
    c = explorer_client
    user_id = uuid.UUID((await c.get("/users/me")).json()["id"])
    async with get_session_factory()() as db:
        for status in ("CLAIMED", "CLAIMED", "SPAWNED"):
            db.add(WorldObject(user_id=user_id, kind="MONSTER", status=status, tier=1, latitude=ORIGIN[0],
                               longitude=ORIGIN[1], seed=str(uuid.uuid4()), reward_ac=60,
                               payload={"name": "Bridge Ogre", "speciesId": "bridge-ogre"},
                               spawned_at=NOW, expires_at=NOW + timedelta(days=1),
                               claimed_at=NOW if status == "CLAIMED" else None))  # fmt: skip
        await db.commit()
    creatures = {x["id"]: x for x in (await c.get("/codex")).json()["creatures"]}
    assert creatures["bridge-ogre"]["trophies"] == {"name": "a toll coin", "count": 2}
    assert creatures["bridge-ogre"]["sigil"]["icon"] == "bridgeOgre"
    assert creatures["fen-troll"]["trophies"] is None
