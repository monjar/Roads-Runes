"""What the planner does with a model's answer.

The rules parser is the floor; the model is allowed to overrule it, and each of
these cases cost a real misread before it was handled.
"""

from __future__ import annotations

from typing import Any

import pytest

from app.routing.preferences import parse_request


class StubLLM:
    enabled = True

    def __init__(self, reply: dict[str, Any] | None) -> None:
        self.reply = reply

    async def complete_json(self, system: str, user: str, schema_hint: str) -> dict[str, Any] | None:
        return self.reply


@pytest.mark.anyio
async def test_an_explicit_no_stops_beats_the_word_the_rules_saw():
    """ "45 min spin, no cafes, just riding": the rules only see the word "cafes"."""
    parsed = await parse_request("45 min spin, no cafes, just riding", StubLLM({"poi": None}))
    assert parsed.preferences.poi is None
    assert parsed.preferences.distanceKm["target"] == pytest.approx(12.0)  # the rules still time the ride


@pytest.mark.anyio
async def test_a_model_with_no_opinion_leaves_the_rules_alone():
    parsed = await parse_request("a ride with 3 pubs", StubLLM({}))
    assert parsed.preferences.poi == {"category": "PUB", "preferredPosition": 0.5, "count": 3}


@pytest.mark.anyio
async def test_a_null_position_does_not_take_the_request_down():
    """float(None) raised straight out of the request path the first time this happened."""
    parsed = await parse_request("a ride with a pub", StubLLM({"poi": {"category": "PUB", "preferredPosition": None}}))
    assert parsed.preferences.poi["preferredPosition"] == 0.5


@pytest.mark.anyio
async def test_the_rules_fill_in_what_the_model_leaves_out():
    parsed = await parse_request(
        "quiet 30 km loop with 2 cafes", StubLLM({"poi": {"category": "CAFE"}, "trafficAversion": 0.9})
    )
    assert parsed.preferences.poi["count"] == 2
    assert parsed.preferences.distanceKm["target"] == 30
    assert parsed.preferences.loop is True


@pytest.mark.anyio
async def test_an_unreadable_answer_falls_back_to_the_rules():
    parsed = await parse_request("a hilly 40 km ride", StubLLM(None))
    assert parsed.source == "rules"
    assert parsed.preferences.hillTolerance >= 0.8
