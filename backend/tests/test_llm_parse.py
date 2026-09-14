"""What the planner does with what the model read.

Claude reads the sentence; this file is the guard rail around its answer. A
model that returns a number out of range, a category nobody imports, or a null
where a float was expected must narrow the ride, never break it — every case
here was a real request that fell over.
"""

from __future__ import annotations

from typing import Any

import pytest

from app.core.llm import NullLLM
from app.routing.preferences import RoutePreferences, parse_request
from tests.conftest import parse, stops


class StubLLM:
    enabled = True

    def __init__(self, reply: Any) -> None:
        self.reply = reply

    async def extract(self, system: str, user: str, schema: dict) -> Any:
        return self.reply

    async def complete_json(self, system: str, user: str, schema_hint: str) -> Any:
        return None


@pytest.mark.anyio
async def test_a_read_request_becomes_preferences():
    parsed = await parse_request(
        "quiet 30 km loop with 2 cafes",
        StubLLM(
            parse(
                trafficAversion=0.95,
                distanceKm={"target": 30, "tolerance": None},
                stops=stops("CAFE", count=2),
                loop=True,
            )
        ),
    )
    prefs = parsed.preferences
    assert parsed.source == "llm"
    assert prefs.trafficAversion == 0.95
    assert prefs.distanceKm == {"target": 30.0, "tolerance": 4.5}  # filled in when the model leaves it out
    assert prefs.poi == {"category": "CAFE", "preferredPosition": 0.5, "count": 2}
    assert prefs.loop is True


@pytest.mark.anyio
async def test_what_the_sentence_did_not_say_keeps_the_rider_profile():
    """Nulls are the point: a request about distance must not reset how this
    rider likes to ride."""
    base = RoutePreferences(trafficAversion=0.2, gravelPreference=0.8, hillTolerance=0.9)
    parsed = await parse_request("20 km", StubLLM(parse(distanceKm={"target": 20, "tolerance": 3})), base)
    assert parsed.preferences.trafficAversion == 0.2
    assert parsed.preferences.gravelPreference == 0.8
    assert parsed.preferences.hillTolerance == 0.9


@pytest.mark.anyio
async def test_a_null_position_does_not_take_the_request_down():
    """float(None) raised straight out of the request path the first time this happened."""
    parsed = await parse_request("a ride with a pub", StubLLM(parse(stops=stops("PUB"))))
    assert parsed.preferences.poi["preferredPosition"] == 0.5


@pytest.mark.anyio
async def test_a_kind_of_stop_nobody_imports_is_dropped():
    parsed = await parse_request("a ride past a spaceport", StubLLM(parse(stops=stops("SPACEPORT", count=2))))
    assert parsed.preferences.poi is None


@pytest.mark.anyio
async def test_numbers_outside_the_range_are_refused_not_clamped():
    """A 900 km "ride" is a misread, and riding 400 of it is not the fix."""
    parsed = await parse_request("a short spin", StubLLM(parse(distanceKm={"target": 900, "tolerance": 10})))
    assert parsed.preferences.distanceKm is None


@pytest.mark.anyio
async def test_preferences_outside_the_range_are_pulled_back_in():
    parsed = await parse_request("as quiet as possible", StubLLM(parse(trafficAversion=4.0)))
    assert parsed.preferences.trafficAversion == 1.0


@pytest.mark.anyio
async def test_riding_to_somewhere_is_not_a_loop_unless_they_said_so():
    parsed = await parse_request("to the pier", StubLLM(parse(destination={"query": "the pier"})))
    assert parsed.preferences.loop is False
    parsed = await parse_request("to the pier and back", StubLLM(parse(destination={"query": "the pier"}, loop=True)))
    assert parsed.preferences.loop is True


@pytest.mark.anyio
async def test_the_same_name_is_not_both_a_destination_and_an_area():
    parsed = await parse_request(
        "greenwich park",
        StubLLM(parse(destination={"query": "Greenwich Park"}, area={"query": "greenwich park"})),
    )
    assert parsed.preferences.destination == {"query": "Greenwich Park"}
    assert parsed.preferences.area is None


@pytest.mark.anyio
async def test_a_sentence_the_model_read_as_nothing_says_nothing():
    parsed = await parse_request("zxq blorp", StubLLM(parse()))
    assert parsed.source == "llm" and parsed.matched == []
    assert parsed.preferences.poi is None and parsed.preferences.area is None


@pytest.mark.anyio
async def test_an_unreadable_answer_leaves_the_ride_alone():
    for reply in (None, "not json", {"stops": "everywhere"}):
        parsed = await parse_request("a hilly 40 km ride", StubLLM(reply))
        assert parsed.preferences.poi is None
        assert parsed.preferences.distanceKm is None


@pytest.mark.anyio
async def test_with_no_provider_nothing_read_it_and_it_says_so():
    """The keyword parser used to be the floor. There isn't one, so the honest
    answer is that the sentence went unread."""
    parsed = await parse_request("a quiet 30 km loop with 2 pubs", NullLLM())
    assert parsed.source == "unavailable"
    assert parsed.matched == []
    assert parsed.read_by_nobody
