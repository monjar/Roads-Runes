"""Active Coins: a ride fills the purse, the ledger explains it, and XP is untouched."""

from __future__ import annotations

import uuid

from sqlalchemy import select

from app.db.session import get_session_factory
from app.economy import service as economy
from app.economy.rules import ACLine, apply_cap, compute_ride_ac
from app.users.models import User
from tests.test_first_playable_journey import ORIGIN, trace_to

NEARBY = (ORIGIN[0] + 0.02, ORIGIN[1] + 0.01)


async def ride_out_and_back(c, target=NEARBY):
    pts = trace_to(target)
    r = await c.post("/rides", json={"clientRideId": str(uuid.uuid4()), "startedAt": pts[0]["timestamp"]})
    assert r.status_code == 201, r.text
    ride = r.json()
    r = await c.post(f"/rides/{ride['id']}/points", json={"points": pts[:100]})
    assert r.status_code == 200, r.text
    distance = 2 * 111_195 * abs(target[0] - ORIGIN[0]) + 2 * 70_000 * abs(target[1] - ORIGIN[1])
    r = await c.post(
        f"/rides/{ride['id']}/complete",
        json={
            "endedAt": pts[-1]["timestamp"],
            "distanceMeters": distance,
            "durationSeconds": 240 * 20,
            "elevationGainMeters": 30,
            "points": pts[100:],
        },
    )
    assert r.status_code == 200, r.text
    r = await c.get(f"/rides/{ride['id']}/summary")
    assert r.status_code == 200, r.text
    return r.json()


async def test_a_ride_earns_coins_and_the_ledger_explains_them(explorer_client):
    c = explorer_client
    assert (await c.get("/wallet")).json() == {"balance": 0, "lifetimeEarned": 0}
    summary = await ride_out_and_back(c)
    assert summary["ride"]["status"] == "PROCESSED", summary["flags"]
    assert summary["acAwarded"] > 0
    kinds = {line["kind"] for line in summary["acBreakdown"]}
    assert {"RIDE_DISTANCE", "NEW_CELLS"} <= kinds
    assert sum(line["ac"] for line in summary["acBreakdown"]) == summary["acAwarded"]
    assert summary["walletBalance"] == summary["acAwarded"]

    # The same total on the character card, the wallet, and the ledger.
    assert (await c.get("/character")).json()["activeCoins"] == summary["acAwarded"]
    wallet = (await c.get("/wallet")).json()
    assert wallet == {"balance": summary["acAwarded"], "lifetimeEarned": summary["acAwarded"]}
    ledger = (await c.get("/wallet/transactions")).json()
    assert sum(t["amount"] for t in ledger["items"]) == summary["acAwarded"]
    assert all(t["rideId"] == summary["ride"]["id"] for t in ledger["items"])

    # Coins are not XP: nothing about them leaks into the XP breakdown.
    assert not any("AC" in b["source"] or "COIN" in b["source"] for b in summary["xpBreakdown"])


async def test_spending_more_than_you_have_is_refused(explorer_client):
    c = explorer_client
    me = (await c.get("/users/me")).json()
    async with get_session_factory()() as db:
        user = await db.scalar(select(User).where(User.id == uuid.UUID(me["id"])))
        await economy.credit(db, user.id, 30, "ADJUSTMENT", payload={"why": "test"})
        try:
            await economy.debit(db, user.id, 50, "LURE")
        except Exception as exc:  # noqa: BLE001
            assert getattr(exc, "code", None) == "INSUFFICIENT_AC"
            assert exc.details == {"cost": 50, "balance": 30}
        else:
            raise AssertionError("a debit beyond the balance went through")
        await economy.debit(db, user.id, 30, "LURE")
        await db.commit()
    assert (await c.get("/wallet")).json() == {"balance": 0, "lifetimeEarned": 30}
    kinds = [t["kind"] for t in (await c.get("/wallet/transactions")).json()["items"]]
    assert kinds == ["LURE", "ADJUSTMENT"], "newest first"


def test_the_rules_are_arithmetic():
    lines = compute_ride_ac(distance_meters=12_400, new_cells=7, quest_completed=True, quest_difficulty="HARD")
    assert [(line.kind, line.ac) for line in lines] == [
        ("RIDE_DISTANCE", 24),
        ("NEW_CELLS", 7),
        ("QUEST_COMPLETED", 70),
    ]
    assert compute_ride_ac(activity="RUN", distance_meters=5_000, new_cells=0)[0].ac == 25
    assert compute_ride_ac(distance_meters=200, new_cells=0) == []

    # A cap scales every line and still sums exactly.
    capped = apply_cap([ACLine("A", 600), ACLine("B", 600)], 800)
    assert sum(line.ac for line in capped) == 800
    assert all(line.detail.get("capped") for line in capped)
