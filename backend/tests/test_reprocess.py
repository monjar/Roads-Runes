"""A ride whose processing failed can be run again, once, and is paid once."""

from __future__ import annotations

import uuid

import pytest

from app.core.errors import RideInvalidState
from app.db.session import get_session_factory
from app.jobs.handlers import process_ride_job
from app.jobs.reprocess import reprocess
from app.rides import processing
from app.rides.models import Ride
from tests.test_first_playable_journey import ORIGIN
from tests.test_world_objects import line_trace


class HeldQueue:
    def __init__(self) -> None:
        self.jobs: list[tuple[str, dict]] = []

    async def enqueue(self, name: str, payload: dict) -> None:
        self.jobs.append((name, payload))


async def upload(c, pts) -> str:
    r = await c.post("/rides", json={"clientRideId": str(uuid.uuid4()), "startedAt": pts[0]["timestamp"]})
    assert r.status_code == 201, r.text
    ride_id = r.json()["id"]
    r = await c.post(
        f"/rides/{ride_id}/complete",
        json={"endedAt": pts[-1]["timestamp"], "distanceMeters": 3000, "durationSeconds": 900, "points": pts},
    )
    assert r.status_code == 200, r.text
    return ride_id


async def ride_row(ride_id: str) -> Ride:
    async with get_session_factory()() as db:
        return await db.get(Ride, uuid.UUID(ride_id))


async def test_a_ride_that_failed_is_run_again_and_paid(explorer_client, app, monkeypatch):
    app.state.jobs = HeldQueue()
    ride_id = await upload(explorer_client, line_trace(ORIGIN, (51.5035, -0.0400), speed_mps=5))

    async def broken(*args, **kwargs):
        raise RuntimeError("a bug in some new code")

    monkeypatch.setattr(processing, "discoveries_along", broken)
    with pytest.raises(RuntimeError):
        await process_ride_job({"rideId": ride_id})
    ride = await ride_row(ride_id)
    assert ride.status == "FLAGGED"
    assert "PROCESSING_ERROR" in ride.flags
    assert ride.processing_result["xpAwarded"] == 0

    monkeypatch.undo()
    await reprocess(uuid.UUID(ride_id))
    ride = await ride_row(ride_id)
    assert ride.status == "PROCESSED", ride.flags
    assert "PROCESSING_ERROR" not in (ride.flags or [])
    assert ride.processing_result["xpAwarded"] > 0

    # A ride that processed is never run again: it would be paid twice.
    with pytest.raises(RideInvalidState):
        await reprocess(uuid.UUID(ride_id))
