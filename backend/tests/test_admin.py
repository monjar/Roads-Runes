"""/admin: signed in with ADMIN_TOKEN only, flag overrides over FEATURE_FLAGS that reach
every reader of `settings.flags`, and the numbers across every rider."""

from __future__ import annotations

import time
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from httpx import ASGITransport, AsyncClient

from app.admin import flags
from app.admin.models import FeatureFlagOverride
from app.admin.router import form_token
from app.admin.stats import collect
from app.characters.models import Character
from app.core.config import RUNTIME_FLAG_OVERRIDES, Settings
from app.db.session import get_session_factory
from app.economy.models import Wallet, WalletTransaction
from app.exploration.models import UserExplorationCell
from app.quests.models import QuestInstance
from app.rides.models import Ride
from app.users.models import User
from app.world_objects.models import WorldObject

TOKEN = "a-test-admin-token-of-32-chars-x"
NOW = datetime(2026, 10, 12, 12, 0, tzinfo=UTC)


@pytest.fixture(autouse=True)
def no_overrides_left_behind():
    RUNTIME_FLAG_OVERRIDES.clear()
    yield
    RUNTIME_FLAG_OVERRIDES.clear()


@pytest.fixture
def admin_on(settings, monkeypatch):
    monkeypatch.setattr(settings, "admin_token", TOKEN)
    return settings


@pytest.fixture
async def admin(app, admin_on):
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test", auth=("dev", TOKEN)) as c:
        yield c


async def switch(admin: AsyncClient, name: str, action: str, note: str = "", token: str = form_token(TOKEN)):
    return await admin.post("/admin/flags", data={"name": name, "action": action, "note": note, "token": token})


@pytest.mark.anyio
async def test_off_without_a_token_and_closed_without_the_right_one(app, settings, monkeypatch):
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as anon:
        assert (await anon.get("/admin")).status_code == 404  # ADMIN_TOKEN unset: no page at all
        monkeypatch.setattr(settings, "admin_token", TOKEN)
        r = await anon.get("/admin")
        assert r.status_code == 401 and r.headers["www-authenticate"].startswith("Basic")
        assert (await anon.get("/admin", auth=("dev", TOKEN[:-1] + "y"))).status_code == 401
        assert (await anon.get("/admin/stats.json")).status_code == 401
        r = await anon.post("/admin/flags", data={"name": "codex", "action": "off", "token": form_token(TOKEN)})
        assert r.status_code == 401
        assert "codex" not in RUNTIME_FLAG_OVERRIDES


@pytest.mark.anyio
async def test_a_player_token_does_not_open_it(user_client: AsyncClient, app, admin_on):
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        c.headers["Authorization"] = user_client.headers["Authorization"]
        assert (await c.get("/admin")).status_code == 401


def test_a_short_token_is_refused():
    with pytest.raises(RuntimeError, match="ADMIN_TOKEN"):
        Settings(admin_token="short").validate_for_environment()
    Settings(admin_token=TOKEN).validate_for_environment()


@pytest.mark.anyio
async def test_an_override_wins_over_feature_flags_and_reaches_the_game(
    admin: AsyncClient, user_client: AsyncClient, settings, monkeypatch
):
    monkeypatch.setattr(settings, "feature_flags", "codex")
    assert (await user_client.get("/codex")).status_code == 200

    r = await switch(admin, "codex", "off", note="hiding it for the demo")
    assert r.status_code == 303 and r.headers["location"] == "/admin?days=7#flags"
    assert settings.flags["codex"] is False and settings.env_flags["codex"] is True
    r = await user_client.get("/codex")
    assert r.status_code == 403 and r.json()["error"]["code"] == "FEATURE_DISABLED"
    assert (await user_client.get("/config")).json()["featureFlags"]["codex"] is False

    async with get_session_factory()() as db:
        row = (await flags.load(db))["codex"]
        assert (row.enabled, row.note) == (False, "hiding it for the demo")
    page = (await admin.get("/admin")).text
    assert "hiding it for the demo" in page and '<span class="source override">override</span>' in page

    assert (await switch(admin, "codex", "clear")).status_code == 303
    assert settings.flags["codex"] is True
    assert (await user_client.get("/codex")).status_code == 200
    async with get_session_factory()() as db:
        assert await flags.load(db) == {}


@pytest.mark.anyio
async def test_a_form_must_carry_the_token_and_name_a_real_flag(admin: AsyncClient):
    assert (await switch(admin, "codex", "off", token="0" * 64)).status_code == 403
    assert (await switch(admin, "no_such_flag", "on")).status_code == 400
    assert (await switch(admin, "codex", "maybe")).status_code == 400
    assert RUNTIME_FLAG_OVERRIDES == {}


@pytest.mark.anyio
async def test_another_process_s_override_arrives_on_the_next_refresh(client: AsyncClient):
    async with get_session_factory()() as db:
        db.add(FeatureFlagOverride(name="party_quests", enabled=True))
        db.add(FeatureFlagOverride(name="a_retired_flag", enabled=True))
        await db.commit()
    await client.get("/health")
    assert "party_quests" not in RUNTIME_FLAG_OVERRIDES  # loaded at startup, not due yet

    flags._loaded_at = time.monotonic() - flags.REFRESH_SECONDS - 1
    cfg = (await client.get("/config")).json()
    assert cfg["featureFlags"]["party_quests"] is True
    assert RUNTIME_FLAG_OVERRIDES == {"party_quests": True}  # a retired flag's row is inert


@pytest.mark.anyio
async def test_an_unreadable_table_keeps_the_last_overrides(client: AsyncClient, engine):
    RUNTIME_FLAG_OVERRIDES["codex"] = False
    async with engine.begin() as conn:
        await conn.exec_driver_sql("DROP TABLE feature_flag_overrides")
    await flags.refresh(force=True)
    assert RUNTIME_FLAG_OVERRIDES == {"codex": False}


@pytest.mark.anyio
async def test_the_page_escapes_what_it_shows(admin: AsyncClient):
    assert (await switch(admin, "pledge", "on", note="<script>alert(1)</script>")).status_code == 303
    r = await admin.get("/admin?days=30")
    assert r.status_code == 200 and r.headers["cache-control"] == "no-store"
    assert "frame-ancestors 'none'" in r.headers["content-security-policy"]
    assert "<script>alert(1)" not in r.text and "&lt;script&gt;alert(1)" in r.text
    assert form_token(TOKEN) in r.text and 'aria-current="page">30 days' in r.text
    assert (await admin.get("/admin?days=91")).status_code == 400


async def seed() -> dict[str, uuid.UUID]:
    day = lambda d, h=10: datetime(2026, 10, d, h, tzinfo=UTC)  # noqa: E731
    ids = {}
    async with get_session_factory()() as db:
        for name, created in (("a", datetime(2026, 9, 1, tzinfo=UTC)), ("b", day(10)), ("c", day(2))):
            user = User(apple_subject=f"dev:{name}", display_name=name, created_at=created)
            db.add(user)
            await db.flush()
            ids[name] = user.id
        a, b, c = ids["a"], ids["b"], ids["c"]
        db.add_all(
            [
                Character(user_id=a, name="Rowan", character_class="EXPLORER"),
                Character(user_id=b, name="Merlin", character_class="WIZARD"),
            ]
        )

        def ride(user, started, status="PROCESSED", km=0.0, activity="RIDE", flags=(), **kw):
            return Ride(
                user_id=user,
                client_ride_id=uuid.uuid4(),
                status=status,
                activity=activity,
                started_at=started,
                distance_meters=km * 1000,
                moving_seconds=int(km * 180),
                flags=list(flags),
                **kw,
            )

        db.add_all(
            [
                ride(a, day(7), km=12),
                ride(a, day(11), "FLAGGED", km=3, flags=["PROCESSING_ERROR"]),
                ride(b, day(10), km=8, activity="RUN"),
                ride(a, day(1), km=5),  # the week before
                ride(c, day(3), km=4),  # the week before
                ride(b, day(10, 8), "RECORDING"),  # never finished
                ride(a, day(12, 8), "PROCESSING", updated_at=day(12, 9)),  # stuck
            ]
        )

        def quest(user, status, **kw):
            return QuestInstance(
                user_id=user,
                template_id="t",
                quest_type="REACH",
                character_class="EXPLORER",
                title="q",
                description="q",
                difficulty="EASY",
                recommended_distance_km=5,
                estimated_duration_minutes=20,
                base_xp=50,
                latitude=51.5,
                longitude=-0.1,
                status=status,
                **kw,
            )

        db.add_all(
            [
                quest(a, "COMPLETED", accepted_at=day(7), completed_at=day(8)),
                quest(a, "EXPIRED", updated_at=day(9)),
                quest(b, "ACTIVE", accepted_at=day(10)),
                quest(a, "COMPLETED", accepted_at=day(1), completed_at=day(2)),  # the week before
            ]
        )
        wallet = Wallet(user_id=a, balance=40)
        db.add(wallet)
        await db.flush()
        db.add_all(
            [
                WalletTransaction(user_id=a, wallet_id=wallet.id, amount=50, kind="RIDE", created_at=day(7)),
                WalletTransaction(user_id=a, wallet_id=wallet.id, amount=-10, kind="STALL", created_at=day(8)),
                WalletTransaction(user_id=a, wallet_id=wallet.id, amount=5, kind="RIDE", created_at=day(1)),
            ]
        )

        def thing(kind, spawned, status="SPAWNED"):
            return WorldObject(
                user_id=a,
                kind=kind,
                status=status,
                latitude=51.5,
                longitude=-0.1,
                seed=str(uuid.uuid4()),
                spawned_at=spawned,
                expires_at=spawned + timedelta(days=3),
            )

        db.add_all(
            [
                thing("MONSTER", day(7), "CLAIMED"),
                thing("MONSTER", day(8)),
                thing("CHEST", day(9), "CLAIMED"),
                thing("MONSTER", day(1), "CLAIMED"),  # the week before
            ]
        )

        def cell(n, visited):
            return UserExplorationCell(
                user_id=a,
                h3_index=f"89{n:014x}",
                resolution=9,
                state="EXPLORED",
                latitude=51.5,
                longitude=-0.1,
                first_visited_at=visited,
            )

        db.add_all([cell(1, day(7)), cell(2, day(7)), cell(3, day(8)), cell(4, day(2)), cell(5, day(3))])
        await db.commit()
    return ids


@pytest.mark.anyio
async def test_the_numbers_across_every_rider(engine):
    await seed()
    async with get_session_factory()() as db:
        s = await collect(db, 7, now=NOW)

    assert s["since"] == "2026-10-06T00:00:00+00:00"
    assert s["riders"] == {
        "total": 3,
        "new": 1,
        "newBefore": 1,
        "active": 2,
        "activeBefore": 2,
        "returning": 1,
        "classes": {"EXPLORER": 1, "WIZARD": 1},
        "strava": 0,
    }
    rides = s["rides"]
    assert (rides["outings"], rides["outingsBefore"], rides["km"], rides["kmBefore"]) == (3, 2, 23.0, 9.0)
    assert rides["byActivity"] == {"RIDE": 2, "RUN": 1}
    assert rides["byStatus"] == {"PROCESSED": 2, "FLAGGED": 1, "RECORDING": 1, "PROCESSING": 1}
    assert (rides["failed"], rides["stuck"], rides["unfinished"]) == (1, 1, 1)
    assert s["exploration"] == {"newCells": 3, "newCellsBefore": 2}
    assert s["quests"] == {
        "accepted": 2,
        "ended": {"COMPLETED": 1, "FAILED": 0, "ABANDONED": 0, "EXPIRED": 1},
        "storySteps": 0,
        "completionRate": 0.5,
    }
    assert s["coins"] == {
        "earned": 50,
        "spent": 10,
        "balances": 40,
        "byKind": [{"kind": "RIDE", "amount": 50, "count": 1}, {"kind": "STALL", "amount": -10, "count": 1}],
    }
    assert s["world"] == [
        {"kind": "CHEST", "placed": 1, "claimed": 1, "rate": 1.0},
        {"kind": "MONSTER", "placed": 2, "claimed": 1, "rate": 0.5},
    ]
    daily = {d["date"]: d for d in s["daily"]}
    assert list(daily)[0] == "2026-10-06" and list(daily)[-1] == "2026-10-12" and len(daily) == 7
    assert daily["2026-10-07"] == {"date": "2026-10-07", "outings": 1, "riders": 1, "km": 12.0, "signups": 0}
    assert daily["2026-10-10"] == {"date": "2026-10-10", "outings": 1, "riders": 1, "km": 8.0, "signups": 1}
    assert sum(d["outings"] for d in s["daily"]) == 3


@pytest.mark.anyio
async def test_the_page_and_its_json_with_riders_in_it(admin: AsyncClient):
    await seed()
    r = await admin.get("/admin/stats.json?days=90")
    assert r.status_code == 200 and r.json()["riders"]["total"] == 3 and len(r.json()["daily"]) == 90
    page = (await admin.get("/admin?days=90")).text
    assert "Active riders" in page and "Outings per day" in page
    assert "uploaded or processing for over an hour" in page and "failed processing" in page
    assert page.count('<form class="flag"') == len(flags.ALL_FEATURE_FLAGS)
