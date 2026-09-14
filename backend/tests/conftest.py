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
    application.state.llm = FakeLLM()
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


# --- Reading a rider's sentence ------------------------------------------------
#
# There is no keyword parser any more: Claude reads the request (see
# app/routing/preferences.py). These tests are about what the planner *does* with
# a reading, so the model is scripted rather than called — the script says what
# it read, in the same shape the schema asks for.
#
# Whether the real model reads a sentence correctly is a different question, and
# tests/test_request_reading.py asks it against the live API.

PARSE_FIELDS = (
    "destination",
    "area",
    "via",
    "distanceKm",
    "stops",
    "trafficAversion",
    "cyclewayPreference",
    "gravelPreference",
    "scenicPreference",
    "hillTolerance",
    "loop",
)


def parse(**fields) -> dict:
    """A model reply: everything the sentence did not say comes back null."""
    unknown = set(fields) - set(PARSE_FIELDS)
    assert not unknown, f"not in the schema: {unknown}"
    return {name: None for name in PARSE_FIELDS} | fields


def stops(*categories, count=None, position=None, quality=False) -> dict:
    return {
        "categories": list(categories),
        "count": count,
        "preferredPosition": position,
        "quality": quality,
    }


# What the model reads for each sentence the tests use. A sentence that is not
# here comes back unread, so a test using a new one fails loudly instead of
# quietly planning a ride from nothing.
SCRIPT: dict[str, dict] = {
    "quiet roads": parse(trafficAversion=0.95),
    "a quiet 20 km loop": parse(trafficAversion=0.95, distanceKm={"target": 20, "tolerance": 3}, loop=True),
    "a 12 km loop": parse(distanceKm={"target": 12, "tolerance": 3}, loop=True),
    "through 3 cafes": parse(stops=stops("CAFE", count=3)),
    "a biker ride in notting hill with about 5 pubs": parse(
        area={"query": "notting hill"}, stops=stops("PUB", count=5)
    ),
    "I want the ride to be through 3 top cafes or cultural": parse(
        stops=stops("CAFE", "CULTURAL", count=3, quality=True)
    ),
    "I want to go to the Aragon Tower and 2 pubs on the way": parse(
        destination={"query": "aragon tower"}, stops=stops("PUB", count=2, position=0.5), loop=False
    ),
    "go to the Emerald Spire of Deptford": parse(destination={"query": "Emerald Spire of Deptford"}, loop=False),
    # A named pub is that pub, so it is somewhere to pass through — not "a pub",
    # which is whichever one suits the route.
    "Visit the moby dick pub then to aragon tower": parse(
        via=[{"query": "the moby dick"}], destination={"query": "aragon tower"}, loop=False
    ),
    "ride past the Hidden Chapel of Deptford to the Aragon Tower": parse(
        via=[{"query": "Hidden Chapel of Deptford"}], destination={"query": "aragon tower"}, loop=False
    ),
    "A gravel heavy ride with 1 nice cafe stop": parse(
        gravelPreference=0.9, stops=stops("CAFE", count=1, quality=True)
    ),
    "a gravel heavy 10 km loop with 3 pubs": parse(
        gravelPreference=0.9, distanceKm={"target": 10, "tolerance": 3}, stops=stops("PUB", count=3), loop=True
    ),
    "around 25 km, quiet roads, a pub near the end": parse(
        distanceKm={"target": 25, "tolerance": 4},
        trafficAversion=0.95,
        stops=stops("PUB", count=1, position=0.8),
    ),
    # Nothing a planner can use, which is itself an answer.
    "zxq blorp": parse(),
}


class FakeLLM:
    """Claude's seat in the tests. `reply` overrides the script for one test."""

    enabled = True

    def __init__(self, reply: dict | None = None, *, use_script: bool = True) -> None:
        self.reply = reply
        self.use_script = use_script
        self.asked: list[str] = []

    async def extract(self, system: str, user: str, schema: dict) -> dict | None:
        self.asked.append(user)
        if self.reply is not None:
            return self.reply
        return SCRIPT.get(user) if self.use_script else None

    async def complete_json(self, system: str, user: str, schema_hint: str) -> dict | None:
        return None


@pytest.fixture
def reading(app):
    """Swap in what the model read, for one test: `reading(parse(loop=True))`."""

    def use(reply: dict | None = None, *, use_script: bool = False) -> FakeLLM:
        fake = FakeLLM(reply, use_script=use_script)
        app.state.llm = fake
        return fake

    return use
