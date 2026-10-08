"""Legends (docs/ROADMAP.md 0.8.0): waking, where they live, the fight one phase at a
time, healing and sleep worked out on read, pay once, and the one free move."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import h3
import pytest
from sqlalchemy import func, select

from app.characters.models import Character
from app.core.geo import destination_point, haversine_m
from app.db.session import get_session_factory
from app.discoveries.models import Discovery
from app.economy.models import WalletTransaction
from app.inventory.models import InventoryItem, ItemEvent, Loadout, RuneHolding
from app.legends import anchors, catalog
from app.legends import service as legends
from app.legends.models import AWAKE, DEFEATED, DORMANT, OldOne
from app.lore.voice import violations
from app.rides.models import Ride, RidePoint
from app.rides.validation import CleanPoint
from app.routing.engine import EngineRoute, SyntheticRouter
from app.users.models import User
from app.world_objects.models import WorldObject
from tests.test_first_playable_journey import ORIGIN
from tests.test_world_objects import line_trace, ride

NOW = datetime.now(UTC)


# --- helpers ---------------------------------------------------------------------


async def character() -> Character:
    async with get_session_factory()() as db:
        user = await db.scalar(select(User).where(User.apple_subject == "dev:tester"))
        return await db.scalar(select(Character).where(Character.user_id == user.id))


async def defeat(count: int, when: datetime | None = None) -> None:
    """Creatures defeated (claimed monsters), as rides leave them."""
    when = when or NOW - timedelta(minutes=30)
    async with get_session_factory()() as db:
        user = await db.scalar(select(User).where(User.apple_subject == "dev:tester"))
        for _ in range(count):
            db.add(
                WorldObject(
                    user_id=user.id,
                    kind="MONSTER",
                    status="CLAIMED",
                    tier=1,
                    latitude=ORIGIN[0],
                    longitude=ORIGIN[1],
                    seed=str(uuid.uuid4()),
                    reward_ac=60,
                    payload={"name": "Fen Troll", "speciesId": "fen-troll"},
                    spawned_at=when - timedelta(hours=1),
                    expires_at=when + timedelta(days=1),
                    claimed_at=when,
                )
            )
        await db.commit()


async def place(name: str, category: str, at: tuple[float, float], **tags) -> str:
    async with get_session_factory()() as db:
        d = Discovery(name=name, category=category, latitude=at[0], longitude=at[1], source="OSM", tags=tags)
        db.add(d)
        await db.commit()
        return str(d.id)


async def wake(engine=None, near=ORIGIN, now=None) -> OldOne | None:
    async with get_session_factory()() as db:
        from app.core.config import get_settings

        row = await db.get(Character, (await character()).id)
        woke = await legends.maybe_wake(db, get_settings(), engine or SyntheticRouter(), row, near=near, now=now)
        await db.commit()
        return woke


async def legend_row(species: str = "trail-wyrm", **fields) -> str:
    """A legend awake at the origin, woken two hours ago."""
    me = await character()
    async with get_session_factory()() as db:
        row = OldOne(
            user_id=me.user_id,
            character_id=me.id,
            species_id=species,
            name=catalog.legend(species)["name"],
            latitude=ORIGIN[0],
            longitude=ORIGIN[1],
            anchor_name="Near the river",
            status=AWAKE,
            phase=1,
            phase_hold_max=500,
            phase_hold_left=500,
            wounds={},
            moved=False,
            woke_at=NOW - timedelta(hours=2),
            payload={"round": 1},
        )
        for key, value in fields.items():
            setattr(row, key, value)
        db.add(row)
        await db.commit()
        return str(row.id)


async def get_row(legend_id: str) -> OldOne:
    async with get_session_factory()() as db:
        return await db.get(OldOne, uuid.UUID(legend_id))


async def update_row(legend_id: str, **fields) -> None:
    async with get_session_factory()() as db:
        row = await db.get(OldOne, uuid.UUID(legend_id))
        for key, value in fields.items():
            setattr(row, key, value)
        await db.commit()


def past(
    start_m: float, length_m: float, ends_ago: timedelta = timedelta(minutes=50), bearing: float = 90.0
) -> list[dict]:
    """A straight journey through the origin (east, unless told), ending a little while ago."""
    start = destination_point(ORIGIN[0], ORIGIN[1], (bearing + 180) % 360, start_m)
    end = destination_point(start[0], start[1], bearing, length_m)
    pts = line_trace(start, end, speed_mps=5.0, and_back=False)
    t_end = datetime.fromisoformat(pts[-1]["timestamp"])
    shift = (NOW - ends_ago) - t_end
    for p in pts:
        p["timestamp"] = (datetime.fromisoformat(p["timestamp"]) + shift).isoformat()
    return pts


class Refusing:
    """An engine that cannot reach anywhere within `meters` of the points it refuses."""

    name = "refusing"

    def __init__(self, refuse: list[tuple[float, float]], meters: float = 50.0) -> None:
        self.refuse = refuse
        self.meters = meters
        self.asked: list[tuple[float, float]] = []

    async def healthy(self) -> bool:
        return True

    async def route(self, request):
        end = request.points[-1]
        self.asked.append(end)
        if any(haversine_m(end[0], end[1], r[0], r[1]) <= self.meters for r in self.refuse):
            return []
        return await SyntheticRouter().route(request)


class Snapping:
    """An engine that always ends its route 1 km short: the spot is off its roads."""

    name = "snapping"

    async def healthy(self) -> bool:
        return True

    async def route(self, request):
        start, end = request.points[0], request.points[-1]
        short = destination_point(end[0], end[1], 0, 1000)
        return [EngineRoute([[start[1], start[0], 0.0], [short[1], short[0], 0.0]], 1000.0, 200, [])]


# --- the catalogue -----------------------------------------------------------------


def test_five_legends_in_order_each_with_three_phases_and_a_hard_rune():
    book = catalog.book()
    assert [legend["id"] for legend in book["legends"]] == list(catalog.ORDER)
    assert {legend["rune"] for legend in book["legends"]} == {"hagalaz", "isa", "uruz", "nauthiz", "thurisaz"}
    assert catalog.phase_health() == 500 and catalog.phase_health(2) == 625
    assert catalog.round_name("fog-dragon", 1) == "The Fog Dragon"
    assert catalog.round_name("fog-dragon", 2) == "The Fog Dragon II"
    assert catalog.phase_spec("rune-golem", 2)["rune"] == "dagaz"
    assert catalog.rune_road_form("dagaz") == "SQUARE" and catalog.rune_road_form("ANY") is None
    assert catalog.heal_per_week(500) == 50 and catalog.sleep_after_days() == 28
    for legend in book["legends"]:
        for text in (legend["name"], legend["flavour"], legend["page"], legend["livesAt"]):
            assert not violations(text, glossary=True), text


def test_healing_is_a_tenth_a_week_and_never_more_than_the_phase():
    woke = NOW - timedelta(days=30)
    assert catalog.healed(300, 500, woke, woke + timedelta(days=6)) == 300
    assert catalog.healed(300, 500, woke, woke + timedelta(days=7)) == 350
    assert catalog.healed(300, 500, woke, woke + timedelta(days=15)) == 400
    assert catalog.healed(480, 500, woke, woke + timedelta(days=21)) == 500
    # Asleep after four weeks, and healing stops there.
    assert not catalog.is_asleep(woke, woke + timedelta(days=27))
    assert catalog.is_asleep(woke, woke + timedelta(days=28))
    assert catalog.healed(0, 500, woke, woke + timedelta(days=70)) == 200


def test_the_lines_say_what_happened_plainly():
    say = legends.line_for
    broke = say("The Fog Dragon", damage=40, left=0, broke=True, defeated=False, held_over=False, phase_after=3,
                weak=["GROUND"])  # fmt: skip
    assert broke == "Phase broken! The Fog Dragon is down to its last phase."
    hurt = say("The Fog Dragon", damage=140, left=360, broke=False, defeated=False, held_over=False, phase_after=1,
               weak=["GROUND"])  # fmt: skip
    assert hurt == "The Fog Dragon took 140 damage. 360 left in this phase."
    nothing = say("The Hill King", damage=0, left=500, broke=False, defeated=False, held_over=False, phase_after=2,
                  weak=["CLIMB", "ROAD"])  # fmt: skip
    assert nothing == "The Hill King took no damage this time. This phase it's weak to climbing and distance."
    for line in (broke, hurt, nothing):
        assert not violations(line, glossary=True, celebration=True), line


# --- where they live -----------------------------------------------------------------


def test_the_fog_dragon_lies_at_the_edge_of_the_biggest_unexplored_block():
    c0 = h3.latlng_to_cell(ORIGIN[0], ORIGIN[1], 9)
    ring = set(h3.grid_disk(c0, 8))
    a = h3.grid_disk(c0, 5)[-1]  # a tile five rings out
    big = set(h3.grid_disk(a, 2))
    b = next(c for c in h3.grid_ring(c0, 5) if h3.grid_distance(c, a) >= 7)
    small = set(h3.grid_disk(b, 1))
    explored = ring - big - small
    found = anchors.blocks(ring - explored)
    assert [len(block) for block in found] == [19, 7]
    best = anchors.fog_candidates(ring, explored)[0]
    assert best in big and h3.grid_distance(best, a) == 2, "the big block's edge, beside explored ground"
    # A block with no explored ground beside it: its tile nearest the middle.
    assert anchors.fog_candidates(big, set())[0] == a


async def test_a_legend_wakes_after_three_defeats_and_lives_two_to_eight_km_out(explorer_client):
    await defeat(2)
    assert await wake() is None
    body = (await explorer_client.get("/legends")).json()
    assert body["awake"] is None and body["creaturesUntilNext"] == 1
    await defeat(1)
    woke = await wake()
    assert woke is not None and woke.species_id == "fog-dragon" and woke.name == "The Fog Dragon"
    assert 2000 - 300 <= haversine_m(ORIGIN[0], ORIGIN[1], woke.latitude, woke.longitude) <= 8000 + 300
    assert (woke.phase, woke.phase_hold_max, woke.phase_hold_left, woke.status) == (1, 500, 500, AWAKE)
    body = (await explorer_client.get("/legends")).json()
    assert body["awake"]["id"] == str(woke.id) and body["creaturesUntilNext"] is None
    assert body["awake"]["icon"] == "fogDragon" and body["awake"]["rune"] == "hagalaz"
    assert [p["healthLeft"] for p in body["awake"]["phases"]] == [500, 500, 500]
    assert body["awake"]["healthLeft"] == body["awake"]["healthMax"] == 1500
    assert body["awake"]["healsPerWeek"] == 50 and body["awake"]["sleepsAfterDays"] == 28
    # One at a time: three more defeats wake nothing while it is awake.
    await defeat(3)
    assert await wake() is None


async def test_the_order_skips_the_defeated_and_those_with_nowhere_to_live(explorer_client):
    me = await character()
    async with get_session_factory()() as db:
        db.add(
            OldOne(
                user_id=me.user_id, character_id=me.id, species_id="fog-dragon", name="The Fog Dragon",
                latitude=ORIGIN[0], longitude=ORIGIN[1], status=DEFEATED, phase=3, phase_hold_max=500,
                phase_hold_left=0, wounds={}, moved=False, woke_at=NOW - timedelta(days=9),
                defeated_at=NOW - timedelta(days=2), payload={"round": 1},
            )
        )  # fmt: skip
        await db.commit()
    await defeat(3)
    # No water with a path beside it, so the Water Wyrm cannot live here; a viewpoint is.
    hill = destination_point(ORIGIN[0], ORIGIN[1], 45, 3000)
    await place("Lone Pond", "NATURE", destination_point(ORIGIN[0], ORIGIN[1], 90, 3000), natural="water")
    await place("Low Hill", "VIEWPOINT", destination_point(ORIGIN[0], ORIGIN[1], 0, 2500), natural="peak", ele="40")
    await place("High Hill", "VIEWPOINT", hill, natural="peak", ele="120")
    await place("Too Close", "VIEWPOINT", destination_point(ORIGIN[0], ORIGIN[1], 0, 900), natural="peak", ele="300")
    woke = await wake()
    assert woke.species_id == "hill-king"
    assert haversine_m(woke.latitude, woke.longitude, *hill) < 1, "the highest it can reach, 2 to 8 km out"
    assert woke.anchor_name == "High Hill"


async def test_water_with_a_path_beside_it_is_the_water_wyrms(explorer_client):
    await defeat(3)
    me = await character()
    async with get_session_factory()() as db:
        db.add(
            OldOne(
                user_id=me.user_id, character_id=me.id, species_id="fog-dragon", name="The Fog Dragon",
                latitude=ORIGIN[0], longitude=ORIGIN[1], status=DEFEATED, phase=3, phase_hold_max=500,
                phase_hold_left=0, wounds={}, moved=False, woke_at=NOW - timedelta(days=9),
                defeated_at=NOW - timedelta(days=2), payload={"round": 1},
            )
        )  # fmt: skip
        await db.commit()
    pond = destination_point(ORIGIN[0], ORIGIN[1], 90, 2500)
    canal = destination_point(ORIGIN[0], ORIGIN[1], 180, 3000)
    await place("Mill Pond", "NATURE", pond, natural="water")
    await place("Grand Canal", "NATURE", canal, waterway="canal")
    await place("Towpath", "TRAIL", destination_point(canal[0], canal[1], 0, 120), highway="path")
    woke = await wake()
    assert woke.species_id == "water-wyrm" and woke.anchor_name == "Grand Canal"


async def test_only_somewhere_the_engine_reaches_and_never_a_sensitive_place(explorer_client):
    me = await character()
    async with get_session_factory()() as db:
        for species in ("fog-dragon", "water-wyrm", "hill-king", "trail-wyrm"):
            db.add(
                OldOne(
                    user_id=me.user_id, character_id=me.id, species_id=species, name=catalog.legend(species)["name"],
                    latitude=ORIGIN[0], longitude=ORIGIN[1], status=DEFEATED, phase=3, phase_hold_max=500,
                    phase_hold_left=0, wounds={}, moved=False, woke_at=NOW - timedelta(days=9),
                    defeated_at=NOW - timedelta(days=2), payload={"round": 1},
                )
            )  # fmt: skip
        await db.commit()
    await defeat(3)
    near = destination_point(ORIGIN[0], ORIGIN[1], 0, 2200)
    walled = destination_point(ORIGIN[0], ORIGIN[1], 90, 2600)
    reachable = destination_point(ORIGIN[0], ORIGIN[1], 180, 3500)
    await place("War Memorial", "HISTORICAL", near, historic="memorial")
    await place("Old Abbey Gate", "HISTORICAL", walled, historic="ruins")
    await place("Old Mill", "HISTORICAL", reachable, historic="mill")
    engine = Refusing([walled])
    woke = await wake(engine)
    assert woke.species_id == "rune-golem" and woke.anchor_name == "Old Mill"
    assert not any(haversine_m(near[0], near[1], *asked) < 1 for asked in engine.asked), "never even asked"
    # An engine whose road ends far from the spot cannot reach it.
    assert not await anchors.reachable(Snapping(), ORIGIN, reachable, "RIDE")


async def test_a_sleeping_legend_wakes_again_first_with_its_health(explorer_client):
    legend_id = await legend_row(
        "hill-king", phase=2, phase_hold_left=200, woke_at=NOW - timedelta(days=40),
        last_hit_at=NOW - timedelta(days=30),
    )  # fmt: skip
    body = (await explorer_client.get("/legends")).json()
    assert body["awake"] is None and [s["id"] for s in body["sleeping"]] == [legend_id]
    row = await get_row(legend_id)
    assert row.status == DORMANT and row.phase_hold_left == 400, "four weeks' healing, then it slept"
    # It wakes again only after three more creatures, and before any other legend.
    assert body["creaturesUntilNext"] == 3
    await defeat(3, when=datetime.now(UTC) + timedelta(seconds=1))
    woke = await wake()
    assert str(woke.id) == legend_id and woke.status == AWAKE and woke.phase == 2 and woke.phase_hold_left == 400


async def test_after_all_five_the_second_round_has_more_health(explorer_client):
    me = await character()
    async with get_session_factory()() as db:
        for species in catalog.ORDER:
            db.add(
                OldOne(
                    user_id=me.user_id, character_id=me.id, species_id=species, name=catalog.legend(species)["name"],
                    latitude=ORIGIN[0], longitude=ORIGIN[1], status=DEFEATED, phase=3, phase_hold_max=500,
                    phase_hold_left=0, wounds={}, moved=False, woke_at=NOW - timedelta(days=60),
                    defeated_at=NOW - timedelta(days=50), payload={"round": 1},
                )
            )  # fmt: skip
        await db.commit()
    await defeat(3)
    woke = await wake()
    assert woke.name == "The Fog Dragon II" and woke.phase_hold_max == woke.phase_hold_left == 625
    assert woke.payload["round"] == 2
    body = (await explorer_client.get("/legends")).json()
    assert len(body["defeated"]) == 5 and body["awake"]["healthMax"] == 1875 and body["awake"]["round"] == 2


# --- healing and sleep, on read --------------------------------------------------------


async def test_left_alone_it_heals_a_tenth_a_week_on_read(explorer_client):
    legend_id = await legend_row(phase_hold_left=300, woke_at=NOW - timedelta(days=20),
                                 last_hit_at=NOW - timedelta(days=15))  # fmt: skip
    body = (await explorer_client.get(f"/legends/{legend_id}")).json()
    assert body["phases"][0]["healthLeft"] == 400 and body["healthLeft"] == 1400
    assert (await get_row(legend_id)).phase_hold_left == 300, "worked out on read, not written"


# --- the fight ---------------------------------------------------------------------


async def test_a_journey_hurts_the_current_phase_whether_or_not_effort_is_on(explorer_client):
    legend_id = await legend_row("trail-wyrm")
    summary = await ride(explorer_client, past(950, 1900))
    legend = summary["legend"]
    assert legend["id"] == legend_id and legend["phaseBefore"] == legend["phaseAfter"] == 1
    assert legend["damage"] >= 1 and "ROAD" in legend["kinds"] and not legend["phaseBroken"]
    assert legend["healthMax"] == 1500 and legend["healthLeft"] == 1500 - legend["damage"]
    assert (
        legend["line"] == f"The Trail Wyrm took {legend['damage']} damage. {500 - legend['damage']} left in this phase."
    )
    row = await get_row(legend_id)
    assert row.phase_hold_left == 500 - legend["damage"] and row.last_hit_at is not None
    assert list(row.wounds.values())[0]["phase"] == 1
    detail = (await explorer_client.get(f"/legends/{legend_id}")).json()
    assert detail["journeys"][0]["damage"] == legend["damage"] and detail["journeys"][0]["phase"] == 1


async def test_far_away_it_is_not_met(explorer_client):
    await legend_row("trail-wyrm", latitude=ORIGIN[0] + 0.05)
    summary = await ride(explorer_client, past(950, 1900))
    assert summary["legend"] is None


async def test_one_phase_a_journey_and_the_next_starts_full_then_one_a_day(explorer_client):
    legend_id = await legend_row("trail-wyrm", phase_hold_left=10)
    first = await ride(explorer_client, past(950, 1900, ends_ago=timedelta(minutes=50)))
    legend = first["legend"]
    assert legend["phaseBroken"] and legend["phaseBefore"] == 1 and legend["phaseAfter"] == 2
    assert legend["phaseHealthLeft"] == 500 and legend["healthLeft"] == 1000, "damage past the break is lost"
    assert legend["line"] == "Phase broken! The Trail Wyrm is down to its second phase."
    rewards = legend["rewards"]
    assert rewards["coins"] == 150 and rewards["xp"] == 300 and "_xp" not in rewards
    assert {i["consumable"] or i["rarity"] for i in rewards["items"]} == {"RARE", "TREASURE_MAP"}
    assert {"kind": "LEGEND", "ac": 150, "detail": {"name": "The Trail Wyrm"}} in first["acBreakdown"]
    assert any(line["source"] == "LEGEND_PHASE" and line["xp"] == 300 for line in first["xpBreakdown"])
    row = await get_row(legend_id)
    assert row.phase == 2 and row.phase_hold_left == 500 and row.last_phase_break_day is not None
    # The same day, the next phase (weak to exploring) cannot break: it is left with 1,
    # and says so. North to south, over tiles not yet explored.
    second_points = past(950, 1900, ends_ago=timedelta(minutes=10), bearing=0)
    ends = datetime.fromisoformat(second_points[-1]["timestamp"]).date()
    await update_row(legend_id, phase_hold_left=10, last_phase_break_day=ends)
    second = (await ride(explorer_client, second_points))["legend"]
    assert not second["phaseBroken"] and second["heldOver"] and second["phaseAfter"] == 2
    assert second["damage"] == 9 and second["phaseHealthLeft"] == 1
    assert second["line"] == "The Trail Wyrm took 9 damage. Its next phase can only break tomorrow."


async def test_the_last_phase_is_a_defeat_with_its_rune_and_title(explorer_client):
    legend_id = await legend_row("trail-wyrm", phase=3, phase_hold_left=5)
    summary = await ride(explorer_client, past(950, 1900))
    legend = summary["legend"]
    assert legend["defeated"] and legend["healthLeft"] == 0
    assert legend["line"] == "The Trail Wyrm is defeated!"
    rewards = legend["rewards"]
    assert rewards["coins"] == 400 and rewards["xp"] == 800 and rewards["title"] == "Bane of the Trail Wyrm"
    assert rewards["rune"]["rune"] == "nauthiz" and rewards["rune"]["new"]
    gear = next(i for i in rewards["items"] if i["kind"] == "GEAR")
    assert gear["rarity"] == "LEGENDARY" and gear["source"] == "LEGEND"
    assert "Bane of the Trail Wyrm" in summary["titlesUnlocked"]
    assert any(r["rune"] == "nauthiz" for r in summary["runesFound"])
    row = await get_row(legend_id)
    assert row.status == DEFEATED and row.defeated_at is not None
    me = await character()
    async with get_session_factory()() as db:
        held = await db.scalar(select(RuneHolding).where(RuneHolding.character_id == me.id))
        loadout = await db.scalar(select(Loadout).where(Loadout.character_id == me.id))
    assert held.rune_id == "nauthiz" and loadout.consumables["TREASURE_MAP"] == 1
    body = (await explorer_client.get("/legends")).json()
    assert [d["id"] for d in body["defeated"]] == [legend_id] and body["creaturesUntilNext"] == 3


async def test_a_legendary_already_had_is_a_rare(explorer_client):
    me = await character()
    legend_id = await legend_row("trail-wyrm", phase=3, phase_hold_left=5)
    from app.inventory import gear, loot

    key = f"legend:{legend_id}:phase:3"
    item_id = loot.sealed_item(key, "LEGENDARY")
    async with get_session_factory()() as db:
        db.add(
            InventoryItem(
                user_id=me.user_id, character_id=me.id, item_id=item_id, rarity="LEGENDARY", source="QUEST",
                source_key="before", acquired_at=NOW,
            )
        )  # fmt: skip
        await db.commit()
    legend = (await ride(explorer_client, past(950, 1900)))["legend"]
    found = next(i for i in legend["rewards"]["items"] if i["kind"] == "GEAR")
    assert found["rarity"] == "RARE" and found["slot"] == gear.by_id()[item_id]["slot"]


async def test_running_the_same_journey_again_pays_nothing_twice(explorer_client):
    legend_id = await legend_row("trail-wyrm", phase_hold_left=10)
    summary = await ride(explorer_client, past(950, 1900))
    assert summary["legend"]["phaseBroken"]
    me = await character()
    async with get_session_factory()() as db:
        ride_row = await db.scalar(select(Ride).where(Ride.user_id == me.user_id))
        rows = (await db.execute(select(RidePoint).where(RidePoint.ride_id == ride_row.id))).scalars().all()
        points = [CleanPoint(p.latitude, p.longitude, p.timestamp, p.altitude_meters) for p in rows]
        row = await db.get(Character, me.id)
        from app.characters.sheet import CharacterSheet

        again = await legends.fold_ride(
            db, row, ride_row, points, new_cell_indices=[], sheet=CharacterSheet.neutral(), ended=ride_row.ended_at
        )
        await db.commit()
        assert again["phaseBroken"] and again["rewards"]["coins"] == 150, "what it did stands"
        coins = await db.scalar(
            select(func.count(WalletTransaction.id)).where(
                WalletTransaction.user_id == me.user_id, WalletTransaction.kind == "LEGEND"
            )
        )
        paid = await db.scalar(select(func.count(ItemEvent.id)).where(ItemEvent.key == f"legend:{legend_id}:phase:1"))
    assert coins == 1 and paid == 1
    row = await get_row(legend_id)
    assert row.phase == 2 and row.phase_hold_left == 500 and len(row.wounds) == 1


async def test_a_rerun_on_the_same_phase_replaces_its_wound(explorer_client):
    legend_id = await legend_row("trail-wyrm")
    first = (await ride(explorer_client, past(950, 1900)))["legend"]
    me = await character()
    async with get_session_factory()() as db:
        ride_row = await db.scalar(select(Ride).where(Ride.user_id == me.user_id))
        rows = (await db.execute(select(RidePoint).where(RidePoint.ride_id == ride_row.id))).scalars().all()
        points = [CleanPoint(p.latitude, p.longitude, p.timestamp, p.altitude_meters) for p in rows]
        from app.characters.sheet import CharacterSheet

        again = await legends.fold_ride(
            db, await db.get(Character, me.id), ride_row, points, new_cell_indices=[],
            sheet=CharacterSheet.neutral(), ended=ride_row.ended_at,
        )  # fmt: skip
        await db.commit()
    assert first["damage"] >= 1 and again["damage"] >= 1
    row = await get_row(legend_id)
    assert row.phase_hold_left == 500 - again["damage"] and len(row.wounds) == 1, "replaced, never added"


# --- the one free move ----------------------------------------------------------------


async def test_it_can_be_moved_once(explorer_client):
    await defeat(3)
    woke = await wake()
    r = await explorer_client.post(f"/legends/{woke.id}/move")
    assert r.status_code == 200, r.text
    moved = r.json()
    assert moved["moved"] is True
    assert haversine_m(woke.latitude, woke.longitude, moved["latitude"], moved["longitude"]) > 500
    r = await explorer_client.post(f"/legends/{woke.id}/move")
    assert r.status_code == 409 and r.json()["error"]["code"] == "ALREADY_MOVED"
    assert not violations(r.json()["error"]["message"], glossary=True)
    r = await explorer_client.post(f"/legends/{uuid.uuid4()}/move")
    assert r.status_code == 404 and r.json()["error"]["code"] == "NO_SUCH_LEGEND"


async def test_starting_over_forgets_the_legends(explorer_client):
    await legend_row()
    r = await explorer_client.delete("/character")
    assert r.status_code in (200, 204), r.text
    async with get_session_factory()() as db:
        assert await db.scalar(select(func.count(OldOne.id))) == 0


@pytest.mark.parametrize("species", list(catalog.ORDER))
def test_every_phase_is_a_foe_the_fight_can_fold(species):
    row = OldOne(species_id=species, phase=1, phase_hold_max=500, latitude=ORIGIN[0], longitude=ORIGIN[1])
    for phase in (1, 2, 3):
        row.phase = phase
        foe = legends.foe_for(row, 420)
        spec = catalog.phase_spec(species, phase)
        assert foe.hold_max == 500 and foe.hold_before == 420
        assert foe.wants == tuple(spec["weakTo"]) and foe.minds == tuple(spec["resists"])


async def test_a_journey_that_makes_three_defeats_wakes_one(explorer_client):
    await defeat(3, when=NOW - timedelta(hours=3))
    summary = await ride(explorer_client, past(950, 1900))
    woke = summary["legendWoke"]
    assert woke["speciesId"] == "fog-dragon" and woke["icon"] == "fogDragon"
    assert woke["line"] == "A legend has woken: the Fog Dragon"
    assert (await explorer_client.get("/legends")).json()["awake"]["id"] == woke["id"]


async def test_with_effort_on_too(explorer_client, settings, monkeypatch):
    monkeypatch.setattr(settings, "feature_flags", "effort_combat")
    legend_id = await legend_row("trail-wyrm")
    legend = (await ride(explorer_client, past(950, 1900)))["legend"]
    assert legend["id"] == legend_id and legend["damage"] >= 1


async def test_asking_for_the_legends_wakes_one_that_is_due(explorer_client):
    await defeat(3)
    body = (await explorer_client.get("/legends")).json()
    assert body["awake"] is None, "no journeys counted and no position: nowhere to put it yet"
    where = {"latitude": ORIGIN[0], "longitude": ORIGIN[1]}
    body = (await explorer_client.get("/legends", params=where)).json()
    assert body["awake"]["speciesId"] == "fog-dragon" and body["creaturesUntilNext"] is None
    assert body["awake"]["sleepsAt"] and body["awake"]["status"] == "AWAKE"


async def test_the_fog_dragon_never_lies_at_a_sensitive_place(explorer_client):
    from app.core.config import get_settings

    best = anchors.fog_candidates(anchors.ring_cells(ORIGIN, 9), set())[0]
    centre = h3.cell_to_latlng(best)
    await place("St Mary's Church", "LANDMARK", centre, amenity="place_of_worship")
    me = await character()
    async with get_session_factory()() as db:
        spots = await anchors._fog_spots(db, me.user_id, ORIGIN, get_settings().h3_resolution, limit=3)
    assert spots and all(haversine_m(s.latitude, s.longitude, *centre) > 1 for s in spots)


async def test_a_waking_asks_the_engine_a_dozen_times_at_most(explorer_client):
    await defeat(3)
    for n in range(10):
        bearing = n * 36
        await place(f"Old Cross {n}", "HISTORICAL", destination_point(*ORIGIN, bearing, 3000), historic="ruins")
    engine = Refusing([ORIGIN], meters=10**7)  # reaches nowhere
    assert await wake(engine) is None
    assert len(engine.asked) == catalog.book()["wakeReachTests"] == 12


async def test_passing_without_landing_anything_does_not_heal_it_twice(explorer_client, monkeypatch):
    from app.world_objects import fight

    def untouched(points, foe, **_):
        return fight.FightReport("UNTOUCHED", foe.hold_max, foe.hold_before, foe.hold_before)

    monkeypatch.setattr(legends.fight, "resolve", untouched)
    legend_id = await legend_row(
        "rune-golem", phase_hold_left=300, woke_at=NOW - timedelta(days=20), last_hit_at=NOW - timedelta(days=15)
    )
    legend = (await ride(explorer_client, past(950, 1900)))["legend"]
    assert legend["damage"] == 0 and legend["phaseHealthLeft"] == 400 and legend["healthLeft"] == 1400
    assert legend["line"] == "The Rune Golem took no damage this time. This phase it's weak to a rune shape."
    row = await get_row(legend_id)
    assert row.phase_hold_left == 300 and row.last_hit_at < NOW - timedelta(days=14)
    body = (await explorer_client.get(f"/legends/{legend_id}")).json()
    assert body["phases"][0]["healthLeft"] == 400
