"""Starting over: the character goes, the rides stay."""

from __future__ import annotations

from tests.test_wallet import ride_out_and_back


async def test_a_reset_wipes_the_character_and_keeps_the_rides(explorer_client):
    c = explorer_client
    summary = await ride_out_and_back(c)
    assert summary["acAwarded"] > 0 and summary["xpAwarded"] > 0

    r = await c.delete("/character")
    assert r.status_code == 204, r.text
    r = await c.get("/character")
    assert r.status_code == 404 and r.json()["error"]["code"] == "NO_CHARACTER"
    assert (await c.get("/users/me")).json()["hasCharacter"] is False
    assert (await c.get("/wallet")).json() == {"balance": 0, "lifetimeEarned": 0}
    assert (await c.get("/world/exploration/stats")).json()["cellsVisited"] == 0

    # The ride happened; it is still in the journal, and a new character starts at nothing.
    entries = (await c.get("/journal/adventures")).json()["items"]
    assert [e["ride"]["id"] for e in entries] == [summary["ride"]["id"]]
    r = await c.post("/character", json={"name": "Again", "characterClass": "SCRIBE"})
    assert r.status_code == 201, r.text
    assert r.json()["overallXP"] == 0 and r.json()["activeCoins"] == 0 and r.json()["classChanges"] == 0
    r = await c.delete("/character")
    assert r.status_code == 204
    assert (await c.delete("/character")).status_code == 404
