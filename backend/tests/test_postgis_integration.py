"""Runs only against PostGIS (CI integration job). Verifies the spatial layer
the SQLite fallback cannot: generated geography columns, GiST indexes,
ST_DWithin radius queries and the route linestring trigger."""

from __future__ import annotations

import pytest
from sqlalchemy import select, text

from app.db.session import get_session_factory
from app.discoveries.models import Discovery
from app.discoveries.service import nearby
from app.routing.models import Route
from tests.test_first_playable_journey import ORIGIN, seed_discoveries

pytestmark = pytest.mark.integration


def _is_postgres(engine) -> bool:
    return engine.dialect.name == "postgresql"


@pytest.mark.anyio
async def test_geography_columns_and_radius_query(engine):
    if not _is_postgres(engine):
        pytest.skip("PostGIS only")
    await seed_discoveries()
    async with get_session_factory()() as db:
        count = await db.scalar(
            text(
                "SELECT count(*) FROM discoveries WHERE geog IS NOT NULL AND ST_DWithin(geog, ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography, 1000)"
            ).bindparams(lon=ORIGIN[1], lat=ORIGIN[0])
        )
        assert count >= 1
        rows = await nearby(db, ORIGIN[0], ORIGIN[1], 1500)
        names = {r.name for r in rows}
        assert "The Crown" in names and "Old Station" not in names
        indexes = (
            (await db.execute(text("SELECT indexname FROM pg_indexes WHERE tablename = 'discoveries'"))).scalars().all()
        )
        assert "ix_discoveries_geog" in indexes


@pytest.mark.anyio
async def test_route_linestring_trigger(engine, explorer_client):
    if not _is_postgres(engine):
        pytest.skip("PostGIS only")
    r = await explorer_client.post(
        "/routes/generate", json={"origin": {"latitude": ORIGIN[0], "longitude": ORIGIN[1]}, "distanceTargetKm": 10}
    )
    assert r.status_code == 200, r.text
    route_id = r.json()["alternatives"][0]["id"]
    async with get_session_factory()() as db:
        route = await db.get(Route, __import__("uuid").UUID(route_id))
        assert route is not None
        length = await db.scalar(text("SELECT ST_Length(geom) FROM routes WHERE id = :id").bindparams(id=route.id))
        assert length is not None and length > 1000
        assert (await db.execute(select(Discovery.id).limit(1))) is not None
