"""Places from OpenStreetMap: categories, tiles, one import per area, retries, and quests anywhere."""

from __future__ import annotations

from datetime import timedelta

from sqlalchemy import select, update

from app.core.security import utcnow
from app.db.session import get_session_factory
from app.discoveries import osm_import
from app.discoveries.models import Discovery, PoiImportArea

ELEMENTS = [
    {"type": "node", "id": 1, "lat": 48.8712, "lon": 2.3857,
     "tags": {"name": "Belvédère de Belleville", "tourism": "viewpoint"}},
    {"type": "way", "id": 2, "center": {"lat": 48.8809, "lon": 2.3828},
     "tags": {"name": "Parc des Buttes-Chaumont", "leisure": "park"}},
    {"type": "node", "id": 3, "lat": 48.8542, "lon": 2.3326, "tags": {"name": "Café de Flore", "amenity": "cafe"}},
    {"type": "node", "id": 4, "lat": 48.8540, "lon": 2.3330, "tags": {"amenity": "cafe"}},
    {"type": "node", "id": 5, "lat": 48.8580, "lon": 2.3488,
     "tags": {"name": "Tour Saint-Jacques", "historic": "monument", "tourism": "attraction"}},
    {"type": "node", "id": 6, "lat": 48.8550, "lon": 2.3500, "tags": {"name": "Boulangerie", "shop": "bakery"}},
    {"type": "node", "id": 7, "lat": 48.8551, "lon": 2.3501, "tags": {"name": "Le Bistro", "amenity": "restaurant"}},
    {"type": "way", "id": 8, "center": {"lat": 48.8600, "lon": 2.3600},
     "tags": {"name": "Promenade Plantée", "highway": "path"}},
    {"type": "way", "id": 9, "center": {"lat": 48.8610, "lon": 2.3650},
     "tags": {"name": "Promenade Plantée", "highway": "path"}},
    {"type": "relation", "id": 10, "center": {"lat": 48.8700, "lon": 2.3700},
     "tags": {"name": "Véloroute de la Seine", "route": "bicycle"}},
]  # fmt: skip


def test_places_are_categorised_from_their_osm_tags():
    places = osm_import.parse_elements(ELEMENTS, 9)
    assert {p["name"]: p["category"] for p in places} == {
        "Belvédère de Belleville": "VIEWPOINT",
        "Parc des Buttes-Chaumont": "NATURE",
        "Café de Flore": "CAFE",
        "Tour Saint-Jacques": "HISTORICAL",
        # Lunch and trails were parseable for months and never imported.
        "Boulangerie": "FOOD",
        "Le Bistro": "FOOD",
        # A named path is dozens of OSM ways; the rider wants the path once.
        "Promenade Plantée": "TRAIL",
        "Véloroute de la Seine": "TRAIL",
    }
    park = next(p for p in places if p["osm_id"] == "w2")
    assert (park["latitude"], park["longitude"]) == (48.8809, 2.3828)
    assert park["tags"] == {"leisure": "park"}


def test_tiles_cover_the_point_then_its_neighbours():
    assert osm_import.tile_key(48.8566, 2.3522) == "v2:488:23"
    assert osm_import.tile_key(51.0, -0.03) == "v2:510:-1"
    assert osm_import.tile_bbox("v2:488:23") == (48.8, 2.3, 48.9, 2.4)
    assert osm_import.tile_bbox("488:23") == (48.8, 2.3, 48.9, 2.4), "keys from before the version prefix still parse"
    around = osm_import.tiles_around(48.8566, 2.3522)
    assert around[0] == "v2:488:23"
    assert len(set(around)) == 9


def test_a_leg_is_covered_by_the_tiles_it_crosses():
    """Rotherhithe to a point 12 km east crosses two tiles; a 200 m hop crosses one."""
    keys = osm_import.tiles_along(51.4906, -0.0316, 51.4906, 0.1414)
    assert keys[0] == "v2:514:-1"
    assert keys[-1] == "v2:514:1"
    assert len(keys) <= 3
    assert osm_import.tiles_along(51.4906, -0.0316, 51.4920, -0.0300) == ["v2:514:-1"]


async def test_the_corridor_import_stops_waiting_when_its_budget_is_spent(engine, settings, monkeypatch):
    """The plan cannot wait forever for Overpass; what is left carries on behind it."""
    monkeypatch.setattr(settings, "poi_import_enabled", True)
    started: list = []

    async def slow_fetch(bbox):
        started.append(bbox)
        await osm_import.asyncio.sleep(0.3)
        return ELEMENTS

    before = osm_import.asyncio.get_running_loop().time()
    await osm_import.ensure_pois_along(settings, 51.4906, -0.0316, 51.4906, 0.1414, budget_s=0.1, fetch=slow_fetch)
    assert osm_import.asyncio.get_running_loop().time() - before < 0.25, "the budget was not honoured"
    await osm_import.drain()
    assert len(started) == len(osm_import.tiles_along(51.4906, -0.0316, 51.4906, 0.1414)), "the rest never imported"


async def test_an_area_is_imported_once(engine, settings, monkeypatch):
    monkeypatch.setattr(settings, "poi_import_enabled", True)
    calls = []

    async def fetch(bbox):
        calls.append(bbox)
        return ELEMENTS

    await osm_import.ensure_pois(settings, 48.8566, 2.3522, fetch=fetch)
    await osm_import.drain()
    assert len(calls) == 9  # the tile under the rider, then its eight neighbours
    assert calls[0] == osm_import.tile_bbox("488:23")
    async with get_session_factory()() as db:
        names = set((await db.execute(select(Discovery.name))).scalars())
        areas = (await db.execute(select(PoiImportArea))).scalars().all()
    assert names == {
        "Belvédère de Belleville",
        "Parc des Buttes-Chaumont",
        "Café de Flore",
        "Tour Saint-Jacques",
        "Boulangerie",
        "Le Bistro",
        "Promenade Plantée",
        "Véloroute de la Seine",
    }
    assert len(areas) == 9
    assert {a.status for a in areas} == {"OK"}

    await osm_import.ensure_pois(settings, 48.8566, 2.3522, fetch=fetch)
    await osm_import.drain()
    assert len(calls) == 9


async def test_a_failed_area_is_retried_after_a_while(engine, settings, monkeypatch):
    monkeypatch.setattr(settings, "poi_import_enabled", True)

    async def overloaded(bbox):
        raise RuntimeError("HTTP 504 Gateway Timeout")

    await osm_import.ensure_pois(settings, 45.4642, 9.19, fetch=overloaded)
    await osm_import.drain()
    calls = []

    async def fetch(bbox):
        calls.append(bbox)
        return []

    await osm_import.ensure_pois(settings, 45.4642, 9.19, fetch=fetch)
    await osm_import.drain()
    assert calls == []  # not refetched inside the retry window

    async with get_session_factory()() as db:
        assert {a.status for a in (await db.execute(select(PoiImportArea))).scalars()} == {"FAILED"}
        stale = utcnow() - osm_import.RETRY_AFTER - timedelta(minutes=1)
        await db.execute(update(PoiImportArea).values(imported_at=stale))
        await db.commit()
    await osm_import.ensure_pois(settings, 45.4642, 9.19, fetch=fetch)
    await osm_import.drain()
    assert len(calls) == 9


async def test_quests_are_built_from_places_where_the_rider_is(explorer_client, settings, monkeypatch):
    monkeypatch.setattr(settings, "poi_import_enabled", True)
    spots = [
        (0.02, 0.03, {"tourism": "viewpoint"}),
        (0.08, 0.02, {"historic": "castle"}),
        (0.05, 0.08, {"leisure": "park"}),
    ]

    async def fetch(bbox):
        south, west, _, _ = bbox
        base = round(south * 10) * 100_000 + round(west * 10)
        return [
            {"type": "node", "id": base * 10 + i, "lat": south + dy, "lon": west + dx,
             "tags": {"name": f"Place {base}-{i}", **tags}}
            for i, (dy, dx, tags) in enumerate(spots)
        ]  # fmt: skip

    monkeypatch.setattr(osm_import, "overpass_fetcher", lambda _settings: fetch)
    r = await explorer_client.get("/quests", params={"latitude": 45.4642, "longitude": 9.19, "status": "AVAILABLE"})
    assert r.status_code == 200, r.text
    assert r.json()["items"]
    # Milan had no places before the request; the tile under the rider was imported before generating.
    async with get_session_factory()() as db:
        in_tile = (
            (
                await db.execute(
                    select(Discovery).where(
                        Discovery.latitude.between(45.4, 45.5), Discovery.longitude.between(9.1, 9.2)
                    )
                )
            )
            .scalars()
            .all()
        )
    assert len(in_tile) == 3
    await osm_import.drain()
