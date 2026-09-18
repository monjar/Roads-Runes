"""Finding people to ride with."""

from __future__ import annotations

import pytest
from httpx import ASGITransport, AsyncClient

from tests.conftest import sign_in


async def another(app, subject: str, name: str) -> AsyncClient:
    """A second signed-in person. `client` and `explorer_client` are one object."""
    other = AsyncClient(transport=ASGITransport(app=app), base_url="http://test/api/v1")
    await sign_in(other, subject=subject, name=name)
    return other


@pytest.mark.anyio
async def test_people_are_found_by_name_not_by_id(app, explorer_client):
    """The app asked for a friend's user id, which nobody knows. A name is enough,
    it is never one's own, and a partial match will do."""
    client = await another(app, "oona", "Oona Ferrier")
    r = await client.get("/users/search", params={"q": "ferr"})
    assert r.status_code == 200, r.text
    assert r.json() == []  # only oneself matches, and oneself is never offered

    r = await explorer_client.get("/users/search", params={"q": "FERR"})
    assert r.status_code == 200, r.text
    names = [p["displayName"] for p in r.json()]
    assert names == ["Oona Ferrier"], names
    assert set(r.json()[0]) >= {"id", "displayName"}

    r = await explorer_client.get("/users/search", params={"q": "o"})
    assert r.status_code == 400, "two letters at least, or the whole world comes back"


@pytest.mark.anyio
async def test_someone_blocked_is_not_found(app, explorer_client):
    client = await another(app, "tam", "Tamsin Rook")
    me = (await client.get("/users/me")).json()["id"]
    explorer = (await explorer_client.get("/users/me")).json()["id"]
    r = await client.post(f"/friends/{explorer}/block")
    assert r.status_code == 204, r.text
    r = await explorer_client.get("/users/search", params={"q": "tamsin"})
    assert r.status_code == 200 and r.json() == [], r.json()
    assert me  # still exists; just not offered to the person they blocked
