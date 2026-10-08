"""Place lore from Wikidata (0.9.0, flag `place_lore`, off): checked at import, never
per journey."""

from __future__ import annotations

from datetime import UTC, datetime

from sqlalchemy import select

from app.db.session import get_session_factory
from app.discoveries import osm_import, place_lore
from app.discoveries.models import Discovery, PoiImportArea
from app.discoveries.place_lore import lore_ok


def test_a_line_must_claim_nothing_new_about_the_place():
    tags = {"leisure": "park", "wikidata": "Q1"}
    assert lore_ok("public park", "Southwark Park", tags)
    assert lore_ok("park in Southwark", "Southwark Park", tags), "a capital already in its name"
    assert not lore_ok("park in London", "Southwark Park", tags), "a capital it does not say itself"
    assert not lore_ok("park opened in 1869", "Southwark Park", tags), "no numbers"
    assert not lore_ok("x" * 121, "Southwark Park", tags), "at most 120 characters"
    assert not lore_ok("", "Southwark Park", tags) and not lore_ok(None, "Southwark Park", tags)
    assert not lore_ok("church in the park", "Southwark Park", tags), "nothing sensitive"
    assert not lore_ok("public park", "St Mary's Churchyard", {"amenity": "grave_yard"}), "a place left alone"
    assert lore_ok("pub on the Thames", "The Mayflower", {"amenity": "pub", "waterway": "Thames"})


ELEMENTS = [
    {"type": "node", "id": 1, "lat": 51.4920, "lon": -0.0510,
     "tags": {"name": "Southwark Park", "leisure": "park", "wikidata": "Q100"}},
    {"type": "node", "id": 2, "lat": 51.4930, "lon": -0.0520,
     "tags": {"name": "The Mayflower", "amenity": "pub", "wikidata": "Q200"}},
    {"type": "node", "id": 3, "lat": 51.4940, "lon": -0.0530, "tags": {"name": "A Café", "amenity": "cafe"}},
]  # fmt: skip


async def import_with(lore) -> dict[str, dict]:
    async with get_session_factory()() as db:
        await osm_import.import_tile(db, "v4:514:-1", lambda bbox: _elements(), 9, lore=lore)
        await db.commit()
        return {d.name: d.tags for d in (await db.execute(select(Discovery))).scalars()}


async def _elements():
    return ELEMENTS


async def test_lore_is_kept_only_when_it_passes(engine):
    asked: list[list[str]] = []

    async def wikidata(ids):
        asked.append(list(ids))
        return {"Q100": "public park in Southwark", "Q200": "pub built in 1550 in London"}

    tags = await import_with(wikidata)
    assert asked == [["Q100", "Q200"]], "one batch, only places with a wikidata tag"
    assert tags["Southwark Park"]["lore"] == "public park in Southwark"
    assert "lore" not in tags["The Mayflower"] and "lore" not in tags["A Café"]


async def test_a_failed_lookup_is_an_import_without_lore(engine):
    async def broken(ids):
        raise TimeoutError("5 s")

    tags = await import_with(broken)
    assert set(tags) == {"Southwark Park", "The Mayflower", "A Café"}
    assert not any("lore" in t for t in tags.values())
    async with get_session_factory()() as db:
        assert (await db.get(PoiImportArea, "v4:514:-1")).status == "OK"


async def test_at_most_fifty_a_tile(engine):
    many = [
        {"type": "node", "id": 1000 + i, "lat": 51.49 + i / 10_000, "lon": -0.05,
         "tags": {"name": f"Park {i}", "leisure": "park", "wikidata": f"Q{5000 + i}"}}
        for i in range(60)
    ]  # fmt: skip
    asked: list[list[str]] = []

    async def wikidata(ids):
        asked.append(list(ids))
        return {}

    async with get_session_factory()() as db:
        await db.flush()

        async def fetch(bbox):
            return many

        await osm_import.import_tile(db, "v4:514:-1", fetch, 9, lore=wikidata)
        await db.commit()
    assert len(asked) == 1 and len(asked[0]) == place_lore.CAP_PER_TILE == 50


async def test_the_flag_is_off_and_nothing_is_asked_until_it_is_on(engine, settings, monkeypatch):
    assert settings.flags["place_lore"] is False
    monkeypatch.setattr(settings, "poi_import_enabled", True)
    made: list[datetime] = []

    def wikidata_fetcher():
        made.append(datetime.now(UTC))

        async def fetch(ids):
            return {"Q100": "public park in Southwark"}

        return fetch

    monkeypatch.setattr(osm_import, "wikidata_fetcher", wikidata_fetcher)

    async def fetch(bbox):
        return ELEMENTS if bbox == osm_import.tile_bbox("514:-1") else []

    await osm_import.ensure_pois(settings, 51.49, -0.05, fetch=fetch)
    await osm_import.drain()
    assert made == []
    async with get_session_factory()() as db:
        park = await db.scalar(select(Discovery).where(Discovery.name == "Southwark Park"))
        assert "lore" not in park.tags
        await db.execute(PoiImportArea.__table__.delete())
        await db.commit()
    monkeypatch.setattr(settings, "feature_flags", "place_lore")
    await osm_import.ensure_pois(settings, 51.49, -0.05, fetch=fetch)
    await osm_import.drain()
    assert len(made) == 1
    async with get_session_factory()() as db:
        park = await db.scalar(select(Discovery).where(Discovery.name == "Southwark Park"))
        assert park.tags["lore"] == "public park in Southwark"
