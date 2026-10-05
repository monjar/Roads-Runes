"""Districts (docs/ROADMAP.md 0.9.0, Appendix J): the import, which district a tile is
in, the honest %, titles, progress on a journey, yours and its pay, the ledger and
the API."""

from __future__ import annotations

import uuid
from datetime import UTC, date, datetime, timedelta

import pytest
from sqlalchemy import func, select

from app.characters.models import Character
from app.core.config import get_settings
from app.core.geo import destination_point
from app.db.session import get_session_factory
from app.discoveries import osm_import
from app.discoveries.models import Discovery, PoiImportArea, UserDiscovery
from app.districts import geo, titles, ways
from app.districts import service as districts
from app.districts.models import Region, UserRegion
from app.economy.models import WalletTransaction
from app.exploration.cells import cell_for, traverse
from app.inventory.models import RuneCut
from app.lore.voice import violations
from app.quests.models import QuestInstance, QuestObjective
from app.users.models import User
from app.world_objects.models import WorldObject
from tests.test_first_playable_journey import ORIGIN
from tests.test_lairs_and_treasure import through
from tests.test_world_objects import ride

EAST = destination_point(ORIGIN[0], ORIGIN[1], 90, 1200)
BERMONDSEY = destination_point(ORIGIN[0], ORIGIN[1], 270, 3000)


# --- which district a tile is in ------------------------------------------------------


def node(name: str, at: tuple[float, float]) -> geo.Node:
    return geo.Node(name, at[0], at[1], name)


def test_a_tile_joins_the_nearest_district_within_4_km():
    here = node("here", ORIGIN)
    there = node("there", BERMONDSEY)
    assigner = geo.Assigner([here, there])
    assert assigner.region_of(cell_for(*EAST, 9)) == "here"
    near_there = destination_point(BERMONDSEY[0], BERMONDSEY[1], 270, 500)
    assert assigner.region_of(cell_for(*near_there, 9)) == "there"
    # Beyond 4 km of every node a tile is in no district.
    far = destination_point(ORIGIN[0], ORIGIN[1], 90, 4500)
    assert assigner.region_of(cell_for(*far, 9)) is None
    assert geo.nearest(*destination_point(ORIGIN[0], ORIGIN[1], 0, 3900), [here]) is here
    assert geo.nearest(*destination_point(ORIGIN[0], ORIGIN[1], 0, 4100), [here]) is None


def test_districts_in_the_neighbouring_tiles_are_in_reach_and_a_new_one_is_never_missed():
    # A node just over a tile boundary from the tile.
    edge_lat = 51.5
    inside = (edge_lat - 0.002, -0.04)
    over = (edge_lat + 0.003, -0.04)
    assert geo.tile_of(*inside) != geo.tile_of(*over)
    assert geo.tile_of(*over) in geo.tiles_near(*inside)
    cell = cell_for(*inside, 9)
    far = node("far", destination_point(inside[0], inside[1], 180, 3000))
    assert geo.Assigner([far]).region_of(cell) == "far"
    # The cache is keyed by the districts in reach: one imported later wins at once.
    assert geo.Assigner([far, node("over", over)]).region_of(cell) == "over"


def test_a_district_is_its_own_tiles_and_its_edge_is_their_border():
    here = node("here", ORIGIN)
    assigner = geo.Assigner([here, node("there", BERMONDSEY)])
    tiles = assigner.catchment(here, 9)
    assert cell_for(*ORIGIN, 9) in tiles and cell_for(*EAST, 9) in tiles
    assert cell_for(*BERMONDSEY, 9) not in tiles
    edge = geo.edge_cells(tiles)
    assert edge and edge < tiles and cell_for(*ORIGIN, 9) not in edge


def test_a_closed_loop_ends_near_where_it_began():
    loop = [destination_point(ORIGIN[0], ORIGIN[1], b, 1000) for b in range(0, 361, 10)]
    assert geo.is_closed_loop(loop, 6300)
    assert not geo.is_closed_loop(loop[:20], 3000), "half way round is not a loop"
    assert not geo.is_closed_loop(loop, 500), "a loop that went nowhere"


def test_ways_are_sampled_every_50_m():
    a, b = ORIGIN, destination_point(ORIGIN[0], ORIGIN[1], 90, 1000)
    cells = geo.way_cells_along([[a, b]], 9)
    walked = set(traverse([destination_point(a[0], a[1], 90, d) for d in range(0, 1001, 10)], 9).cells)
    assert cells == walked


# --- titles ---------------------------------------------------------------------------


def places(*spec: tuple[int, str | None, dict]) -> list[tuple[str, str | None, dict]]:
    out = []
    for n, category, tags in spec:
        out += [(f"Place {category} {i}", category, dict(tags)) for i in range(n)]
    return out


@pytest.mark.parametrize(
    ("spec", "title"),
    [
        (places((3, "NATURE", {"natural": "water"}), (7, "CAFE", {})), "the Riverlands"),
        (places((2, "VIEWPOINT", {"tourism": "viewpoint"}), (8, "CAFE", {})), "the Highlands"),
        (places((3, "HISTORICAL", {"historic": "castle"}), (9, "CAFE", {})), "the Old Stones"),
        (places((4, "NATURE", {"leisure": "park"}), (3, "CAFE", {}), (3, "PUB", {})), "the Greenwood"),
        (places((3, "PUB", {}), (2, "CAFE", {}), (2, "LANDMARK", {})), "the Tavern Quarter"),
        (places((2, "CAFE", {}), (2, "FOOD", {}), (1, "PUB", {})), "the Market Quarter"),
        # Pubs the top single kind come first, even when cafés and food together are more.
        (places((2, "CAFE", {}), (2, "FOOD", {}), (3, "PUB", {})), "the Tavern Quarter"),
        (places((2, "TRAIL", {}), (1, "CAFE", {}), (1, "PUB", {}), (6, "LANDMARK", {})), "the Back Lanes"),
        (places((2, "CULTURAL", {}), (1, "PUB", {}), (1, "CAFE", {}), (9, "LANDMARK", {})), "the Museum Quarter"),
        (places((2, "LANDMARK", {}), (2, "CYCLING", {})), "the Quiet End"),
        (places(), "the Quiet End"),
        (places((9, "LANDMARK", {}), (1, "PUB", {})), None),
    ],
)
def test_each_title_rule(spec, title):
    assert titles.title_for(titles.count_places(spec)) == title


def test_the_first_rule_that_applies_wins_and_sensitive_history_does_not_count():
    # Water and history both apply: water comes first.
    spec = places((3, "NATURE", {"waterway": "river"}), (3, "HISTORICAL", {"historic": "ruins"}), (4, "CAFE", {}))
    assert titles.title_for(titles.count_places(spec)) == "the Riverlands"
    graves = [(f"War memorial {i}", "HISTORICAL", {"historic": "memorial"}) for i in range(5)]
    counts = titles.count_places([*graves, *places((5, "LANDMARK", {}))])
    assert counts["groups"]["historical"] == 0
    assert titles.title_for(counts) != "the Old Stones"


def test_a_title_is_after_a_comma_and_the_fog_hides_it_under_10_percent():
    assert titles.display_name("Rotherhithe", "the Riverlands", 47.0) == "Rotherhithe, the Riverlands"
    assert titles.display_name("Rotherhithe", "the Riverlands", 9.9) == "Rotherhithe, in the fog"
    assert titles.display_name("Rotherhithe", "the Riverlands", None) == "Rotherhithe, in the fog"
    assert titles.shown_title("the Riverlands", 9.9) is None
    assert titles.display_name("Rotherhithe", None, 40.0) == "Rotherhithe"
    for rule in titles.book()["rules"]:
        assert len(rule["title"]) <= Region.__table__.c.epithet.type.length
        assert not violations(rule["title"], glossary=True)


# --- yours, by the rules -----------------------------------------------------------------


def test_yours_is_half_explored_and_passed_in_the_last_30_days_or_othalas():
    now = datetime(2026, 10, 5, tzinfo=UTC)
    assert districts.is_yours(50.0, now - timedelta(days=30), now)
    assert not districts.is_yours(49.9, now, now)
    assert not districts.is_yours(None, now, now), "no % yet, so not yours"
    assert not districts.is_yours(80.0, now - timedelta(days=31), now)
    othala = {"DISTRICT_KEEP_DAYS": 45.0}
    assert districts.is_yours(80.0, now - timedelta(days=40), now, districts.keep_days(othala))
    assert districts.weekly_coins({}) == 5 and districts.weekly_coins({"DISTRICT_PAY_EXTRA": 3.0}) == 8


# --- the import ------------------------------------------------------------------------

PLACES = [
    {"type": "node", "id": 101, "lat": 51.4995, "lon": -0.0525, "tags": {"name": "Rotherhithe", "place": "suburb"}},
    {"type": "node", "id": 102, "lat": 51.4980, "lon": -0.0700, "tags": {"name": "Bermondsey", "place": "neighbourhood"}},
    {"type": "node", "id": 103, "lat": 51.4900, "lon": -0.0600, "tags": {"place": "hamlet"}},
    {"type": "node", "id": 104, "lat": 51.4900, "lon": -0.0600, "tags": {"name": "A City", "place": "city"}},
    {"type": "way", "id": 105, "center": {"lat": 51.49, "lon": -0.05}, "tags": {"name": "W", "place": "suburb"}},
    {"type": "node", "id": 106, "lat": 51.4950, "lon": -0.0500, "tags": {"name": "Café", "amenity": "cafe"}},
]  # fmt: skip


def test_place_nodes_with_a_name_are_districts_and_never_places():
    regions = osm_import.parse_regions(PLACES)
    assert [(r["osm_id"], r["name"], r["kind"], r["tile"]) for r in regions] == [
        ("n101", "Rotherhithe", "suburb", "514:-1"),
        ("n102", "Bermondsey", "neighbourhood", "514:-1"),
    ]
    assert {p["name"] for p in osm_import.parse_elements(PLACES, 9)} == {"Café"}
    assert "place~" in osm_import.overpass_query((51.4, -0.1, 51.5, 0.0))
    assert osm_import.places_query((51.4, -0.1, 51.5, 0.0)).count("node[place~") == 1
    assert osm_import.regions_key("v4:514:-1") == "regions:v1:514:-1"
    assert osm_import.TILE_VERSION == "v4"
    for r in regions:
        assert len(r["osm_id"]) <= 32 and len(r["kind"]) <= 20 and len(r["tile"]) <= 32
    assert len(osm_import.regions_key("v4:-900:-1800")) <= PoiImportArea.__table__.c.key.type.length


async def test_a_new_tile_brings_its_districts_with_its_places(engine, settings, monkeypatch):
    monkeypatch.setattr(settings, "poi_import_enabled", True)
    calls: list = []

    async def fetch(bbox):
        calls.append(bbox)
        return PLACES if bbox == osm_import.tile_bbox("514:-1") else []

    await osm_import.ensure_pois(settings, 51.49, -0.05, fetch=fetch)
    await osm_import.drain()
    assert len(calls) == 9
    async with get_session_factory()() as db:
        names = set((await db.execute(select(Region.name))).scalars())
        keys = set((await db.execute(select(PoiImportArea.key))).scalars())
    assert names == {"Rotherhithe", "Bermondsey"}
    assert osm_import.regions_key("514:-1") in keys and "v4:514:-1" in keys
    await osm_import.ensure_pois(settings, 51.49, -0.05, fetch=fetch)
    await osm_import.drain()
    assert len(calls) == 9, "nothing fetched twice"


async def test_a_tile_imported_before_fetches_only_its_districts_once(engine, settings, monkeypatch):
    monkeypatch.setattr(settings, "poi_import_enabled", True)
    async with get_session_factory()() as db:
        for key in osm_import.tiles_around(51.49, -0.05):
            db.add(PoiImportArea(key=key, status="OK", poi_count=0, imported_at=datetime.now(UTC)))
        await db.commit()
    full: list = []
    only: list = []

    async def fetch(bbox):
        full.append(bbox)
        return []

    async def places_only(bbox):
        only.append(bbox)
        return PLACES if bbox == osm_import.tile_bbox("514:-1") else []

    await osm_import.ensure_pois(settings, 51.49, -0.05, fetch=fetch, places_fetch=places_only)
    await osm_import.drain()
    assert full == [] and len(only) == 9
    async with get_session_factory()() as db:
        assert await db.scalar(select(func.count(Region.id))) == 2
        assert await db.scalar(select(func.count(Discovery.id))) == 0
    await osm_import.ensure_pois(settings, 51.49, -0.05, fetch=fetch, places_fetch=places_only)
    await osm_import.drain()
    assert len(only) == 9, "once"


# --- helpers for the journeys ----------------------------------------------------------


async def add_region(name: str, at: tuple[float, float], osm_id: str | None = None, **extra) -> uuid.UUID:
    async with get_session_factory()() as db:
        region = Region(
            osm_id=osm_id or f"n{abs(hash(name)) % 10**9}",
            name=name,
            kind="suburb",
            latitude=at[0],
            longitude=at[1],
            tile=geo.tile_of(*at),
            place_counts=extra.pop("place_counts", {}),
            **extra,
        )
        db.add(region)
        await db.commit()
        return region.id


async def set_ways(region_id: uuid.UUID, cells: list[str]) -> None:
    async with get_session_factory()() as db:
        region = await db.get(Region, region_id)
        region.way_cells = sorted(cells)
        region.way_cells_fetched_at = datetime.now(UTC)
        await db.commit()


async def me() -> Character:
    async with get_session_factory()() as db:
        user = await db.scalar(select(User).where(User.apple_subject == "dev:tester"))
        return await db.scalar(select(Character).where(Character.user_id == user.id))


def east_line() -> list[dict]:
    return through([ORIGIN, EAST])


def line_cells() -> set[str]:
    pts = east_line()
    return set(traverse([(p["latitude"], p["longitude"]) for p in pts], 9).cells)


async def catchment_of(region_id: uuid.UUID) -> set[str]:
    async with get_session_factory()() as db:
        return await districts.catchment(db, await db.get(Region, region_id), 9)


# --- progress on a journey ----------------------------------------------------------------


async def test_a_journey_brings_its_districts_up_to_date_and_pays_completion_once(explorer_client):
    rid = await add_region("Rotherhithe", ORIGIN)
    await add_region("Bermondsey", BERMONDSEY)
    first = await ride(explorer_client, east_line())
    [row] = first["districts"]
    assert row["name"] == "Rotherhithe" and row["percent"] is None and row["newTiles"] >= 5
    assert row["displayName"] == "Rotherhithe, in the fog" and row["title"] is None
    assert not row["becameYours"] and not row["completed"]
    assert "_firstPassedAt" not in row
    ridden = line_cells()
    tiles = await catchment_of(rid)
    others = sorted(tiles - ridden)[: len(ridden)]
    # Its roads are known now: half of them are the ones ridden.
    await set_ways(rid, sorted(ridden | set(others)))
    second = await ride(explorer_client, east_line())
    [row] = second["districts"]
    assert row["percent"] == 50.0 and row["becameYours"] and not row["completed"] and row["newTiles"] == 0
    assert row["title"] == "the Quiet End" and row["displayName"] == "Rotherhithe, the Quiet End"
    # Its first journey of the week as yours pays the week.
    doubled = second["districtPay"]["doubled"]  # round a festival, by today's date
    assert second["districtPay"] == {"coins": 10 if doubled else 5, "districts": ["Rotherhithe"], "doubled": doubled}
    assert {"kind": "DISTRICT_PAY", "ac": second["districtPay"]["coins"], "detail": {"districts": ["Rotherhithe"]}} in (
        second["acBreakdown"]
    )
    # Now only the ridden ones are roads: 100%, complete.
    await set_ways(rid, sorted(ridden))
    third = await ride(explorer_client, east_line())
    [row] = third["districts"]
    assert row["completed"] and row["percent"] == 100.0 and not row["becameYours"]
    assert "districtPay" not in third or third["districtPay"] is None, "paid once a week"
    assert {"kind": "DISTRICT", "ac": 200, "detail": {"name": "Rotherhithe"}} in third["acBreakdown"]
    assert any(line["source"] == "REGION_COMPLETED" for line in third["xpBreakdown"])
    assert "Warden of Rotherhithe" in third["titlesUnlocked"]
    fourth = await ride(explorer_client, east_line())
    assert not fourth["districts"][0]["completed"]
    assert not any(line["source"] == "REGION_COMPLETED" for line in fourth["xpBreakdown"])
    async with get_session_factory()() as db:
        paid = await db.scalar(select(func.count(WalletTransaction.id)).where(WalletTransaction.kind == "DISTRICT"))
    assert paid == 1
    r = await explorer_client.get("/character/titles")
    warden = next(t for t in r.json() if t["name"] == "Warden of Rotherhithe")
    assert warden["earned"] and warden["source"] == "DISTRICT" and warden["worn"]
    r = await explorer_client.put("/character/title", json={"slug": warden["slug"]})
    assert r.status_code in (200, 204), r.text


async def test_a_flagged_journey_moves_no_district(explorer_client):
    await add_region("Rotherhithe", ORIGIN)
    pts = east_line()
    # Every 20 m in half a second: 40 m/s, which no bike does.
    start = datetime.now(UTC) - timedelta(minutes=5)
    for i, p in enumerate(pts):
        p["timestamp"] = (start + timedelta(seconds=0.5 * i)).isoformat()
    out = await ride(explorer_client, pts)
    assert out["ride"]["status"] == "FLAGGED"
    assert out["districts"] == []
    async with get_session_factory()() as db:
        assert await db.scalar(select(func.count(UserRegion.id))) == 0


# --- the week's pay -----------------------------------------------------------------------


async def yours_rows(n: int, *, pct_ways: int = 2) -> list[uuid.UUID]:
    """n districts that are the tester's: explored 50% (1 of 2 roads), passed today."""
    character = await me()
    ids = []
    for i in range(n):
        at = destination_point(ORIGIN[0], ORIGIN[1], 360 * i / max(1, n), 9000 + 200 * i)
        rid = await add_region(f"District {i:02d}", at, osm_id=f"n9{i:03d}")
        cell = cell_for(*at, 9)
        await set_ways(rid, [cell, cell_for(*destination_point(at[0], at[1], 0, 600), 9)][:pct_ways])
        async with get_session_factory()() as db:
            db.add(
                UserRegion(
                    user_id=character.user_id,
                    region_id=rid,
                    explored_cells=1,
                    way_cells_explored=1,
                    first_passed_at=datetime.now(UTC),
                    last_passed_at=datetime.now(UTC),
                    yours_since=datetime.now(UTC),
                )
            )
            await db.commit()
        ids.append(rid)
    return ids


async def pay(day: date, rules: dict | None = None) -> dict | None:
    async with get_session_factory()() as db:
        character = await db.get(Character, (await me()).id)
        paid = await districts.pay_week(
            db, character, None, day=day, ended=datetime.now(UTC), rules=rules or {}, south=False
        )
        await db.commit()
        return paid


async def test_the_week_pays_once_for_at_most_ten_districts(explorer_client):
    await yours_rows(12)
    monday = date(2026, 10, 5)
    paid = await pay(monday)
    assert paid["coins"] == 50 and len(paid["districts"]) == 10 and not paid["doubled"]
    assert await pay(monday + timedelta(days=3)) is None, "once an ISO week"
    again = await pay(monday + timedelta(days=7))
    assert again is not None and again["week"] == "2026-W42"
    async with get_session_factory()() as db:
        rows = list(
            (await db.execute(select(WalletTransaction).where(WalletTransaction.kind == "DISTRICT_PAY"))).scalars()
        )
    assert [r.amount for r in rows] == [50, 50]


async def test_the_week_pays_double_round_a_festival_and_fehu_adds(explorer_client):
    await yours_rows(2)
    # Harvest is 29 September; the 30th is the day after.
    paid = await pay(date(2026, 9, 30), {"DISTRICT_PAY_EXTRA": 2.0})
    assert paid["doubled"] and paid["coins"] == 2 * (5 + 2) * 2


async def test_nothing_is_paid_when_nothing_is_yours_and_lapsing_takes_nothing(explorer_client):
    [rid] = await yours_rows(1)
    character = await me()
    async with get_session_factory()() as db:
        row = await districts.row_for(db, character.user_id, rid)
        row.last_passed_at = datetime.now(UTC) - timedelta(days=31)
        await db.commit()
    assert await pay(date(2026, 10, 5)) is None
    async with get_session_factory()() as db:
        row = await districts.row_for(db, character.user_id, rid)
        region = await db.get(Region, rid)
        out = districts.district_out(region, row, datetime.now(UTC))
    assert not out["yours"] and out["wasYours"] and out["percent"] == 50.0 and row.way_cells_explored == 1
    # Othala keeps it yours for longer.
    assert await pay(date(2026, 10, 5), {"DISTRICT_KEEP_DAYS": 45.0}) is not None


# --- the honest % ----------------------------------------------------------------------------


async def test_the_ways_are_fetched_once_and_the_percent_is_null_until_then(explorer_client, settings):
    rid = await add_region("Rotherhithe", ORIGIN)
    await ride(explorer_client, east_line())
    r = await explorer_client.get(f"/districts/{rid}")
    assert r.json()["percent"] is None and r.json()["wayTiles"] is None and r.json()["exploredTiles"] >= 5
    calls: list = []
    a, b = ORIGIN, EAST
    far = (destination_point(ORIGIN[0], ORIGIN[1], 0, 2000), destination_point(ORIGIN[0], ORIGIN[1], 0, 3000))

    async def fetch(bbox):
        calls.append(bbox)
        return [[a, b], list(far)]

    async def broken(bbox):
        raise RuntimeError("HTTP 504")

    async with get_session_factory()() as db:
        assert await ways.fetch_ways(db, settings, rid, fetch=broken) is None
        await db.commit()
    async with get_session_factory()() as db:
        region = await db.get(Region, rid)
        assert region.way_cells is None and not ways.due(region), "a failure waits an hour"
        region.way_cells_fetched_at = datetime.now(UTC) - timedelta(hours=2)
        await db.commit()
    async with get_session_factory()() as db:
        assert ways.due(await db.get(Region, rid))
        count = await ways.fetch_ways(db, settings, rid, fetch=fetch)
        await db.commit()
    assert count and len(calls) == 1
    south, west, north, east = calls[0]
    assert south < ORIGIN[0] < north and west < ORIGIN[1] < east
    async with get_session_factory()() as db:
        assert await ways.fetch_ways(db, settings, rid, fetch=fetch) is None
    assert len(calls) == 1, "once per district"
    r = await explorer_client.get(f"/districts/{rid}")
    body = r.json()
    assert body["wayTiles"] == count and body["percent"] is not None and 0 < body["percent"] < 100


def test_the_ways_query_leaves_out_motorways_trunk_roads_and_private_ways():
    q = ways.ways_query((51.4, -0.1, 51.5, 0.0))
    assert "motorway|trunk|motorway_link|trunk_link" in q and "access!=private" in q and "out geom" in q
    parsed = ways.parse_ways(
        [
            {"type": "way", "tags": {"highway": "residential"}, "geometry": [{"lat": 1, "lon": 2}, {"lat": 1, "lon": 3}]},
            {"type": "way", "tags": {"highway": "motorway"}, "geometry": [{"lat": 1, "lon": 2}]},
            {"type": "way", "tags": {"highway": "service", "access": "private"}, "geometry": [{"lat": 1, "lon": 2}]},
        ]
    )  # fmt: skip
    assert parsed == [[(1.0, 2.0), (1.0, 3.0)]]


# --- the ledger and the API -------------------------------------------------------------------


async def test_the_ledger_counts_what_was_done_inside_the_district(explorer_client):
    rid = await add_region("Rotherhithe", ORIGIN)
    await add_region("Bermondsey", BERMONDSEY)
    await ride(explorer_client, east_line())
    character = await me()
    inside = destination_point(ORIGIN[0], ORIGIN[1], 45, 400)
    outside = destination_point(BERMONDSEY[0], BERMONDSEY[1], 270, 300)
    now = datetime.now(UTC)
    async with get_session_factory()() as db:
        for at, name in ((inside, "In"), (outside, "Out")):
            d = Discovery(name=f"{name} park", category="NATURE", latitude=at[0], longitude=at[1], source="OSM")
            db.add(d)
            await db.flush()
            db.add(UserDiscovery(user_id=character.user_id, discovery_id=d.id, discovered_at=now))
            db.add(
                WorldObject(user_id=character.user_id, kind="MONSTER", status="CLAIMED", tier=1, latitude=at[0],
                            longitude=at[1], seed=f"m-{name}", payload={"name": "Fen Troll"}, spawned_at=now,
                            expires_at=now + timedelta(days=1), claimed_at=now)
            )  # fmt: skip
            db.add(
                RuneCut(user_id=character.user_id, rune_id="raido", latitude=at[0], longitude=at[1], source="WAKING",
                        cut_at=now)
            )  # fmt: skip
            quest = QuestInstance(
                user_id=character.user_id, template_id="ANY_GREEN_HOUR", quest_type="VISIT_POI",
                character_class="ANY", title="A quest", description="A quest.", difficulty="EASY",
                recommended_distance_km=5, estimated_duration_minutes=30, base_xp=100, status="COMPLETED",
                latitude=ORIGIN[0], longitude=ORIGIN[1],
            )  # fmt: skip
            db.add(quest)
            await db.flush()
            db.add(
                QuestObjective(quest_id=quest.id, objective_type="VISIT_POI", title="Go", latitude=at[0],
                               longitude=at[1])
            )  # fmt: skip
        await db.commit()
    r = await explorer_client.get(f"/districts/{rid}")
    assert r.status_code == 200, r.text
    ledger = r.json()["ledger"]
    assert ledger["placesFound"] == 1 and ledger["creaturesDefeated"] == 1
    assert ledger["runesCut"] == 1 and ledger["questsDone"] == 1
    assert ledger["firstPassed"] and ledger["lastPassed"]


async def test_the_districts_api(explorer_client):
    rid = await add_region("Rotherhithe", ORIGIN)
    bid = await add_region("Bermondsey", BERMONDSEY)
    r = await explorer_client.get("/districts")
    assert r.status_code == 200 and r.json() == []
    await ride(explorer_client, east_line())
    r = await explorer_client.get("/districts")
    [out] = r.json()
    assert out["id"] == str(rid) and out["name"] == "Rotherhithe" and out["kind"] == "suburb"
    assert out["percent"] is None and out["exploredTiles"] >= 5 and out["weeklyCoins"] == 5
    assert not out["yours"] and not out["wasYours"] and not out["completed"]
    assert out["displayName"] == "Rotherhithe, in the fog" and out["firstPassed"] and out["lastPassed"]
    r = await explorer_client.get("/districts/here", params={"lat": BERMONDSEY[0], "lon": BERMONDSEY[1]})
    assert r.status_code == 200 and r.json()["id"] == str(bid) and r.json()["exploredTiles"] == 0
    far = destination_point(ORIGIN[0], ORIGIN[1], 90, 20_000)
    r = await explorer_client.get("/districts/here", params={"lat": far[0], "lon": far[1]})
    assert r.status_code == 200 and r.json() is None
    r = await explorer_client.get(f"/districts/{uuid.uuid4()}")
    assert r.status_code == 404 and not violations(r.json()["error"]["message"], glossary=True)


async def test_a_reset_forgets_the_districts_explored_but_keeps_the_districts(explorer_client):
    await add_region("Rotherhithe", ORIGIN)
    await ride(explorer_client, east_line())
    r = await explorer_client.delete("/character")
    assert r.status_code == 204, r.text
    async with get_session_factory()() as db:
        assert await db.scalar(select(func.count(UserRegion.id))) == 0
        assert await db.scalar(select(func.count(Region.id))) == 1


def test_the_string_widths_hold_what_is_written_into_them():
    from app.economy.models import WalletTransaction as Tx
    from app.inventory.models import ItemEvent
    from app.progression.models import CharacterTitle

    assert len("district-pay:2026-W53") <= ItemEvent.__table__.c.key.type.length
    assert len("DISTRICT_PAY") <= ItemEvent.__table__.c.kind.type.length
    assert len("DISTRICT_PAY") <= Tx.__table__.c.kind.type.length
    assert len(f"warden:{uuid.uuid4()}") <= CharacterTitle.__table__.c.slug.type.length
    assert len("2026-W53") <= UserRegion.__table__.c.last_paid_week.type.length
    assert len("neighbourhood") <= Region.__table__.c.kind.type.length
    assert get_settings().h3_resolution == 9
