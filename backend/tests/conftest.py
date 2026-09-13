"""Test harness: SQLite (aiosqlite) + synthetic router + inline jobs.

Integration tests (marked `integration`) run against a real PostGIS via
DATABASE_URL and are skipped otherwise.
"""

from __future__ import annotations

import os
from collections.abc import AsyncIterator

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import create_async_engine
from sqlalchemy.pool import NullPool

os.environ.setdefault("ENVIRONMENT", "test")
os.environ.setdefault("DEV_AUTH_ENABLED", "true")
os.environ.setdefault("JOB_QUEUE", "inline")
os.environ.setdefault("JWT_SECRET", "test-secret")
os.environ.setdefault("LLM_PROVIDER", "none")
os.environ.setdefault("POI_IMPORT_ENABLED", "false")  # tests opt in with a fake fetcher
os.environ.setdefault("GEOCODING_ENABLED", "false")  # tests opt in with a mock transport

from app.core.config import get_settings  # noqa: E402
from app.db.models import Base  # noqa: E402
from app.db.postgis import apply_postgis  # noqa: E402
from app.db.session import configure_engine, make_engine  # noqa: E402
from app.jobs.handlers import HANDLERS  # noqa: E402
from app.jobs.queue import InlineJobQueue  # noqa: E402
from app.main import create_app  # noqa: E402

TEST_DB_URL = os.environ.get("TEST_DATABASE_URL", "sqlite+aiosqlite:///./test.db")


@pytest.fixture(scope="session")
def settings():
    get_settings.cache_clear()
    s = get_settings()
    s.database_url = TEST_DB_URL
    return s


@pytest.fixture
async def engine(settings):
    # asyncpg connections belong to the event loop that opened them and every test runs in
    # its own loop, so on PostgreSQL no pooled connection may outlive a test.
    if TEST_DB_URL.startswith("postgresql"):
        eng = create_async_engine(TEST_DB_URL, poolclass=NullPool)
    else:
        eng = make_engine(TEST_DB_URL)
    async with eng.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
        if eng.dialect.name == "postgresql":
            await conn.run_sync(apply_postgis)
    configure_engine(eng)
    yield eng
    await eng.dispose()


@pytest.fixture
async def app(engine, settings):
    application = create_app(settings)
    # Build state eagerly (lifespan is not run by ASGITransport).
    from app.main import build_state

    await build_state(application, settings)
    application.state.jobs = InlineJobQueue(HANDLERS, background=False)
    yield application


@pytest.fixture
async def client(app) -> AsyncIterator[AsyncClient]:
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test/api/v1") as c:
        yield c


async def sign_in(client: AsyncClient, subject: str = "tester", name: str = "Tester") -> dict:
    r = await client.post("/auth/dev", json={"subject": subject, "displayName": name})
    assert r.status_code == 200, r.text
    data = r.json()
    client.headers["Authorization"] = f"Bearer {data['accessToken']}"
    return data


@pytest.fixture
async def user_client(client: AsyncClient) -> AsyncClient:
    await sign_in(client)
    return client


@pytest.fixture
async def explorer_client(user_client: AsyncClient) -> AsyncClient:
    r = await user_client.post("/character", json={"name": "Rowan", "characterClass": "EXPLORER"})
    assert r.status_code == 201, r.text
    r = await user_client.post("/character/bikes", json={"name": "Boardman ADV 8.8", "bikeType": "GRAVEL"})
    assert r.status_code == 201, r.text
    return user_client
