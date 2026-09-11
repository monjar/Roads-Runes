"""The adventure summary while a ride is still being processed."""

from __future__ import annotations

import uuid


class HeldQueue:
    """Accepts jobs and never runs them, so the ride stays unprocessed."""

    def __init__(self) -> None:
        self.jobs: list[tuple[str, dict]] = []

    async def enqueue(self, name: str, payload: dict) -> None:
        self.jobs.append((name, payload))


async def test_summary_is_202_while_the_ride_is_processing(explorer_client, app):
    app.state.jobs = HeldQueue()
    r = await explorer_client.post(
        "/rides", json={"clientRideId": str(uuid.uuid4()), "startedAt": "2026-06-01T09:00:00Z"}
    )
    assert r.status_code == 201, r.text
    ride = r.json()
    r = await explorer_client.post(
        f"/rides/{ride['id']}/complete",
        json={"endedAt": "2026-06-01T09:30:00Z", "distanceMeters": 0, "durationSeconds": 1800, "points": []},
    )
    assert r.status_code == 200, r.text
    assert [name for name, _ in app.state.jobs.jobs] == ["process_ride"]

    # Before the fix this was a 500: None failed validation against AdventureSummary.
    r = await explorer_client.get(f"/rides/{ride['id']}/summary")
    assert r.status_code == 202, r.text
    assert r.content == b""
