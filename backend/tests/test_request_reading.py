"""Does the model actually read a rider's sentence?

Everything else about requests is tested against a scripted reading, because the
planner's job is what it does with one. This file asks the other question, of
the real model, and it is the only test here that costs money — it is skipped
unless ANTHROPIC_API_KEY is set:

    ANTHROPIC_API_KEY=sk-... pytest tests/test_request_reading.py

The cases are the ones that cost a wrong ride. Most were regexes in the keyword
parser this replaced; they are expectations of the prompt now, and a failure
here means `SYSTEM` in app/routing/preferences.py needs the case, not that a
word list needs another word.
"""

from __future__ import annotations

import os

import pytest

from app.core.llm import AnthropicLLM
from app.routing.preferences import parse_request

pytestmark = [
    pytest.mark.llm,
    pytest.mark.skipif(not os.environ.get("ANTHROPIC_API_KEY"), reason="reads requests with the real model"),
]

MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-opus-5")


@pytest.fixture
def llm():
    return AnthropicLLM(os.environ["ANTHROPIC_API_KEY"], MODEL)


async def read(llm, text):
    parsed = await parse_request(text, llm)
    assert parsed.source == "llm", f"nothing read {text!r}"
    return parsed.preferences


@pytest.mark.anyio
@pytest.mark.parametrize(
    ("request_text", "name"),
    [
        ("I want to go to the Aragon Tower and 2 pubs on the way", "aragon tower"),
        ("take me to the Cutty Sark", "cutty sark"),
        ("as far as the old pier and back", "old pier"),
        ("out to Greenwich, 3 cafes on the way", "greenwich"),
    ],
)
async def test_somewhere_to_ride_to(llm, request_text, name):
    prefs = await read(llm, request_text)
    assert prefs.destination is not None, request_text
    assert name in prefs.destination["query"].lower()
    assert prefs.area is None, "a place to ride to is not a place to ride around in"


@pytest.mark.anyio
@pytest.mark.parametrize(
    ("request_text", "name"),
    [
        ("a biker ride in notting hill with about 5 pubs", "notting hill"),
        ("Richmond bike ride", "richmond"),
        ("a scenic ride around richmond park", "richmond park"),
        ("pub ride in shoreditch", "shoreditch"),
        ("hampstead heath", "hampstead heath"),
    ],
)
async def test_somewhere_to_ride_in(llm, request_text, name):
    prefs = await read(llm, request_text)
    assert prefs.area is not None, request_text
    assert name in prefs.area["query"].lower()


@pytest.mark.anyio
@pytest.mark.parametrize(
    "request_text",
    [
        "a quiet 30 km loop",
        "something hilly and fast",
        "pub ride",
        "a scenic gravel ride",
        "quiet roads",
        "gravel trails and hills",
        "I want the ride to be through 3 top cafes or cultural",
        "a 30 km loop in 2 hours",
        "something quick in the morning",
        "I want to go for a 20km ride",
        "up to 40 km, flat and quiet",
    ],
)
async def test_describing_the_riding_names_no_place(llm, request_text):
    """The keyword parser planned a ride in "Roads Wood" for "quiet roads"."""
    prefs = await read(llm, request_text)
    assert prefs.area is None, request_text
    assert prefs.destination is None, request_text


@pytest.mark.anyio
@pytest.mark.parametrize(
    ("request_text", "category", "count"),
    [
        ("a ride through two pubs", "PUB", 2),
        ("three cafes and a museum", "CAFE", 3),
        ("quiet ride with a couple of cafes", "CAFE", 2),
        ("a few pubs on the way home", "PUB", 3),
        ("I want to go to the Aragon Tower and 2 pubs on the way", "PUB", 2),
    ],
)
async def test_how_many_stops_and_of_what(llm, request_text, category, count):
    prefs = await read(llm, request_text)
    assert prefs.poi is not None, request_text
    assert prefs.poi["category"] == category
    assert prefs.poi.get("count") == count


@pytest.mark.anyio
async def test_a_place_in_the_destination_is_not_a_kind_of_stop(llm):
    prefs = await read(llm, "ride to the Old Church and 2 pubs on the way")
    assert prefs.poi["category"] == "PUB"
    assert "church" in (prefs.destination or {}).get("query", "").lower()


@pytest.mark.anyio
async def test_a_refusal_is_a_decision_not_a_gap(llm):
    """ "no cafes" used to parse as "cafes" — the word was all the rules saw."""
    prefs = await read(llm, "45 min spin, no cafes, just riding")
    assert prefs.poi is None
    assert prefs.distanceKm is not None and 8 <= prefs.distanceKm["target"] <= 16


@pytest.mark.anyio
@pytest.mark.parametrize(
    ("request_text", "low", "high"),
    [
        ("a 30 km loop", 28, 32),
        ("about 20 miles", 30, 34),
        ("a couple of hours", 26, 38),
        ("an hour and a half", 20, 28),
        ("90 minutes", 20, 28),
    ],
)
async def test_how_far_however_they_said_it(llm, request_text, low, high):
    prefs = await read(llm, request_text)
    assert prefs.distanceKm is not None, request_text
    assert low <= prefs.distanceKm["target"] <= high, prefs.distanceKm


@pytest.mark.anyio
@pytest.mark.parametrize(
    ("request_text", "field", "low", "high"),
    [
        ("quiet roads please", "trafficAversion", 0.8, 1.0),
        ("fast and direct", "trafficAversion", 0.0, 0.5),
        ("mostly gravel", "gravelPreference", 0.7, 1.0),
        ("no gravel, road bike", "gravelPreference", 0.0, 0.2),
        ("flat, nothing steep", "hillTolerance", 0.0, 0.3),
        ("as hilly as you can make it", "hillTolerance", 0.8, 1.0),
        ("somewhere pretty", "scenicPreference", 0.8, 1.0),
    ],
)
async def test_how_they_want_it_to_ride(llm, request_text, field, low, high):
    prefs = await read(llm, request_text)
    assert low <= getattr(prefs, field) <= high, f"{request_text}: {field}={getattr(prefs, field)}"


@pytest.mark.anyio
async def test_a_good_one_is_worth_a_detour(llm):
    assert (await read(llm, "a ride with a nice cafe")).poi.get("quality") is True
    assert (await read(llm, "a ride with a cafe")).poi.get("quality") is not True


@pytest.mark.anyio
async def test_the_model_never_answers_with_coordinates(llm):
    """A name is resolved by the geocoder; a coordinate would go straight to
    navigation, so it must not be able to invent one (spec §20)."""
    for text in ("ride to 51.5, -0.1", "take me to latitude 51.48 longitude 0.02"):
        prefs = await parse_request(text, llm)
        for place in (prefs.preferences.destination, prefs.preferences.area):
            if place:
                assert not any(c.isdigit() for c in place["query"]), place
