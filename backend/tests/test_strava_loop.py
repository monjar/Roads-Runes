"""The Strava loop, closed: a processed ride goes to Strava on its own when the
rider asked for that, and where it got to is written on the ride — sent, with
the activity to open; failed, with Strava's reason; or never sent."""

from __future__ import annotations

import json
import uuid
from datetime import UTC, datetime, timedelta

import httpx
import pytest

from app.db.session import get_session_factory
from app.integrations import strava
from app.integrations.models import StravaConnection
from tests.test_first_playable_journey import ORIGIN, trace_to

TARGET = (ORIGIN[0] + 0.01, ORIGIN[1] + 0.01)


async def a_processed_ride(client) -> dict:
    pts = trace_to(TARGET)
    r = await client.post("/rides", json={"clientRideId": str(uuid.uuid4()), "startedAt": "2026-06-01T09:00:00Z"})
    assert r.status_code == 201, r.text
    ride = r.json()
    r = await client.post(
        f"/rides/{ride['id']}/complete",
        json={
            "endedAt": pts[-1]["timestamp"],
            "distanceMeters": 3000,
            "durationSeconds": len(pts),
            "elevationGainMeters": 10,
            "points": pts,
        },
    )
    assert r.status_code == 200, r.text
    r = await client.get(f"/rides/{ride['id']}")
    assert r.json()["status"] == "PROCESSED", r.json()
    return r.json()


async def connect(user_id: uuid.UUID) -> None:
    async with get_session_factory()() as db:
        db.add(
            StravaConnection(
                user_id=user_id,
                athlete_id="42",
                athlete_name="Brenna",
                access_token="fresh",
                refresh_token="refresh",
                expires_at=datetime.now(UTC) + timedelta(days=1),
                scope="activity:write,read",
            )
        )
        await db.commit()


def fake_strava(*, activity_after: int = 1, fail_with: int | None = None):
    """Strava's upload endpoint: the file is taken at once, the activity comes
    on the `activity_after`-th status poll."""
    calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(f"{request.method} {request.url.path}")
        if request.method == "POST":
            if fail_with:
                return httpx.Response(fail_with, json={"message": "Bad Request", "errors": [{"code": "invalid"}]})
            return httpx.Response(
                201, json={"id": 987, "activity_id": None, "status": "Your activity is still being processed."}
            )
        polls = sum(1 for c in calls if c.startswith("GET"))
        if polls >= activity_after:
            return httpx.Response(200, json={"id": 987, "activity_id": 123456, "status": "Your activity is ready."})
        return httpx.Response(
            200, json={"id": 987, "activity_id": None, "status": "Your activity is still being processed."}
        )

    return httpx.MockTransport(handler), calls


async def my_id(client) -> uuid.UUID:
    return uuid.UUID((await client.get("/users/me")).json()["id"])


@pytest.mark.anyio
async def test_a_sent_ride_knows_its_activity(explorer_client, settings, monkeypatch):
    monkeypatch.setattr(strava, "UPLOAD_POLL_SECONDS", 0.0)
    ride = await a_processed_ride(explorer_client)
    await connect(await my_id(explorer_client))
    transport, calls = fake_strava(activity_after=2)

    async with get_session_factory()() as db:
        result = await strava.upload_ride(db, settings, uuid.UUID(ride["id"]), transport=transport)
        await db.commit()
    assert result == "123456"
    assert calls[0].startswith("POST") and sum(1 for c in calls if c.startswith("GET")) == 2

    r = await explorer_client.get(f"/rides/{ride['id']}")
    body = r.json()
    assert body["stravaUploadStatus"] == "UPLOADED"
    assert body["stravaActivityId"] == "123456"
    assert body["stravaError"] is None


@pytest.mark.anyio
async def test_a_failed_send_says_why_and_stays_retryable(explorer_client, settings, monkeypatch):
    monkeypatch.setattr(strava, "UPLOAD_POLL_SECONDS", 0.0)
    ride = await a_processed_ride(explorer_client)
    await connect(await my_id(explorer_client))
    transport, _ = fake_strava(fail_with=400)

    async with get_session_factory()() as db:
        with pytest.raises(httpx.HTTPStatusError):
            await strava.upload_ride(db, settings, uuid.UUID(ride["id"]), transport=transport)
        await db.commit()

    body = (await explorer_client.get(f"/rides/{ride['id']}")).json()
    assert body["stravaUploadStatus"] == "FAILED"
    assert "Bad Request" in body["stravaError"]
    assert body["stravaActivityId"] is None


@pytest.mark.anyio
async def test_automatic_upload_follows_processing_only_when_asked_for(explorer_client, settings, monkeypatch):
    """AUTO and connected: sent without a tap. Anything else: untouched, and never
    a reason for the ride's own processing to fail."""
    monkeypatch.setattr(strava, "UPLOAD_POLL_SECONDS", 0.0)
    monkeypatch.setattr(settings, "feature_flags", "strava")
    transport, calls = fake_strava()
    real_upload = strava.upload_ride

    async def upload_with_fake(db, settings_, ride_id, transport_=None):
        return await real_upload(db, settings_, ride_id, transport=transport)

    monkeypatch.setattr(strava, "upload_ride", upload_with_fake)

    # NEVER (the default): a processed ride is left alone even when connected.
    await connect(await my_id(explorer_client))
    ride = await a_processed_ride(explorer_client)
    async with get_session_factory()() as db:
        assert await strava.upload_after_processing(db, settings, uuid.UUID(ride["id"])) is False
    assert not calls
    assert (await explorer_client.get(f"/rides/{ride['id']}")).json()["stravaUploadStatus"] is None

    # AUTO: the processing job sends it on its own — by the time the ride reads
    # PROCESSED it is already on Strava, with nothing tapped.
    r = await explorer_client.patch("/users/me", json={"settings": {"stravaUploadMode": "AUTO"}})
    assert r.status_code == 200, r.text
    ride = await a_processed_ride(explorer_client)
    assert ride["stravaUploadStatus"] == "UPLOADED", ride
    assert ride["stravaActivityId"] == "123456"
    assert sum(1 for c in calls if c.startswith("POST")) == 1

    # Sent once: processing again (a re-run job) does not send it twice.
    async with get_session_factory()() as db:
        assert await strava.upload_after_processing(db, settings, uuid.UUID(ride["id"])) is False
    assert sum(1 for c in calls if c.startswith("POST")) == 1


@pytest.mark.anyio
async def test_a_ride_can_be_sent_by_hand_when_connected(explorer_client, settings, monkeypatch):
    monkeypatch.setattr(settings, "feature_flags", "strava")
    monkeypatch.setattr(settings, "strava_client_id", "id")
    monkeypatch.setattr(settings, "strava_client_secret", "secret")
    ride = await a_processed_ride(explorer_client)

    # Not connected: told so, nothing queued.
    r = await explorer_client.post(f"/integrations/strava/upload/{ride['id']}")
    assert r.status_code in (403, 409, 422), r.text
    assert (await explorer_client.get(f"/rides/{ride['id']}")).json()["stravaUploadStatus"] is None

    await connect(await my_id(explorer_client))
    transport, _ = fake_strava()
    real_upload = strava.upload_ride

    async def upload_with_fake(db, settings_, ride_id, transport_=None):
        return await real_upload(db, settings_, ride_id, transport=transport)

    monkeypatch.setattr(strava, "upload_ride", upload_with_fake)
    r = await explorer_client.post(f"/integrations/strava/upload/{ride['id']}")
    assert r.status_code == 200, r.text
    # The job queue runs inline in tests, so the answer is already on the ride.
    body = (await explorer_client.get(f"/rides/{ride['id']}")).json()
    assert body["stravaUploadStatus"] == "UPLOADED", body
    assert body["stravaActivityId"] == "123456"


def test_the_reason_is_stravas_own_message():
    request = httpx.Request("POST", strava.STRAVA_UPLOAD)
    response = httpx.Response(401, request=request, content=json.dumps({"message": "Authorization Error"}).encode())
    assert strava._reason(httpx.HTTPStatusError("boom", request=request, response=response)) == "Authorization Error"
    assert strava._reason(RuntimeError("")) == "RuntimeError"
