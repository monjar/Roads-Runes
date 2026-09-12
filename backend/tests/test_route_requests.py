"""Ride requests that name a place and a number of stops.

The case that prompted this: "a biker ride in notting hill with about 5 pubs"
used to parse to nothing but "pubs", so the ride stayed at the rider's door.
"""

from __future__ import annotations

import uuid

import httpx
import pytest

from app.core.geo import destination_point
from app.db.session import get_session_factory
from app.discoveries.models import Discovery
from app.routing import geocode
from app.routing.preferences import parse_rules

NOTTING_HILL = (51.5109, -0.2055)
HOME = (51.4906, -0.0316)  # Rotherhithe, ~11 km away


def test_a_request_names_a_place_and_how_many_stops():
    prefs = parse_rules("a biker ride in notting hill with about 5 pubs").preferences
    assert prefs.area == {"query": "notting hill"}
    assert prefs.poi == {"category": "PUB", "preferredPosition": 0.5, "count": 5}


def test_a_place_on_its_own_is_still_a_place():
    """ "Richmond bike ride" has no preposition to hang a place on, and used to plan
    a ride wherever the rider was standing."""
    assert parse_rules("Richmond bike ride").preferences.area == {"query": "richmond"}
    assert parse_rules("hampstead heath").preferences.area == {"query": "hampstead heath"}
    assert parse_rules("pub ride in shoreditch").preferences.area == {"query": "shoreditch"}


def test_describing_the_riding_is_not_naming_a_place():
    for request in ("a quiet 30 km loop", "something hilly and fast", "pub ride", "a scenic gravel ride"):
        assert parse_rules(request).preferences.area is None, request


async def test_the_geocoder_ignores_answers_that_are_not_places(settings, monkeypatch):
    """A loose phrase must not turn into a shop or a street."""
    monkeypatch.setattr(settings, "geocoding_enabled", True)
    geocode.clear_cache()

    def handler(request: httpx.Request) -> httpx.Response:
        if "photon" in str(request.url):
            return httpx.Response(
                200,
                json={
                    "features": [
                        {
                            "properties": {"name": "Quiet Street Cafe", "osm_key": "amenity", "osm_value": "cafe"},
                            "geometry": {"coordinates": [-0.02, 51.49]},
                        }
                    ]
                },
            )
        return httpx.Response(
            200, json=[{"lat": "51.49", "lon": "-0.02", "name": "Quiet Street", "category": "highway"}]
        )

    assert await geocode.resolve(settings, "quiet", *HOME, transport=httpx.MockTransport(handler)) is None


def test_times_and_distances_are_not_places():
    assert parse_rules("a 30 km loop in 2 hours").preferences.area is None
    assert parse_rules("something quick in the morning").preferences.area is None
    assert parse_rules("quiet ride with a couple of cafes").preferences.poi["count"] == 2
    assert parse_rules("scenic ride around richmond park").preferences.area == {"query": "richmond park"}


async def test_the_place_is_the_one_near_the_rider(settings, monkeypatch):
    monkeypatch.setattr(settings, "geocoding_enabled", True)
    geocode.clear_cache()
    calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(str(request.url))
        # Photon offers Notting Hill, Melbourne first; it is 16,000 km away.
        return httpx.Response(
            200,
            json={
                "features": [
                    {
                        "properties": {"name": "Notting Hill", "osm_key": "place", "osm_value": "suburb"},
                        "geometry": {"coordinates": [145.13, -37.90]},
                    },
                    {
                        "properties": {"name": "Notting Hill", "osm_key": "place", "osm_value": "suburb"},
                        "geometry": {"coordinates": [-0.2055, 51.5109]},
                    },
                ]
            },
        )

    area = await geocode.resolve(settings, "notting hill", *HOME, transport=httpx.MockTransport(handler))
    assert area is not None
    assert (area.name, round(area.latitude, 3)) == ("Notting Hill", 51.511)

    # Asked once; the answer is cached.
    await geocode.resolve(settings, "notting hill", *HOME, transport=httpx.MockTransport(handler))
    assert len(calls) == 1


async def test_nominatim_answers_when_photon_is_down(settings, monkeypatch):
    monkeypatch.setattr(settings, "geocoding_enabled", True)
    geocode.clear_cache()

    def handler(request: httpx.Request) -> httpx.Response:
        if "photon" in str(request.url):
            return httpx.Response(503, text="down")
        return httpx.Response(200, json=[{"lat": "51.5109", "lon": "-0.2055", "name": "Notting Hill"}])

    area = await geocode.resolve(settings, "notting hill", *HOME, transport=httpx.MockTransport(handler))
    assert area is not None and area.name == "Notting Hill"


async def test_a_phrase_that_is_not_a_place_resolves_to_nothing(settings, monkeypatch):
    monkeypatch.setattr(settings, "geocoding_enabled", True)
    geocode.clear_cache()

    def handler(request: httpx.Request) -> httpx.Response:
        if "photon" in str(request.url):
            return httpx.Response(200, json={"features": []})
        return httpx.Response(200, json=[])

    assert await geocode.resolve(settings, "the scenic bit", *HOME, transport=httpx.MockTransport(handler)) is None


async def seed_pubs(centre: tuple[float, float], count: int = 8, radius_m: float = 3500) -> None:
    """Pubs spread around the compass, so a loop can thread them."""
    async with get_session_factory()() as db:
        for i in range(count):
            lat, lon = destination_point(centre[0], centre[1], i * (360 / count), radius_m)
            db.add(
                Discovery(
                    name=f"The Test Arms {i}",
                    category="PUB",
                    latitude=lat,
                    longitude=lon,
                    source="OSM",
                    osm_id=f"n{uuid.uuid4().int % 10**9}",
                    tags={"amenity": "pub"},
                    moderation_status="APPROVED",
                    cycling_accessible=True,
                )
            )
        await db.commit()


@pytest.mark.anyio
async def test_a_ride_in_a_named_place_goes_there_with_the_stops_asked_for(explorer_client, settings, monkeypatch):
    monkeypatch.setattr(settings, "geocoding_enabled", True)
    geocode.clear_cache()
    await seed_pubs(NOTTING_HILL)

    async def resolve(_settings, query, lat, lon, transport=None):
        assert query == "notting hill"
        return geocode.Area("Notting Hill", *NOTTING_HILL)

    monkeypatch.setattr(geocode, "resolve", resolve)

    r = await explorer_client.post(
        "/routes/generate",
        json={
            "origin": {"latitude": HOME[0], "longitude": HOME[1]},
            "loop": True,
            "request": "a biker ride in notting hill with about 5 pubs",
        },
    )
    assert r.status_code == 200, r.text
    body = r.json()
    parsed = body["parsedRequest"]

    assert parsed["area"]["name"] == "Notting Hill"
    assert parsed["startsAt"]["latitude"] == pytest.approx(NOTTING_HILL[0])
    assert len(parsed["stops"]) == 5
    assert parsed["poi"]["count"] == 5

    # Every pub the rider asked for is on the route's stop list, not just near the line.
    for route in body["alternatives"]:
        requested = [poi for poi in route["pois"] if poi.get("requested")]
        assert {poi["name"] for poi in requested} == {stop["name"] for stop in parsed["stops"]}

    # The ride is in Notting Hill, not at the rider's door.
    for route in body["alternatives"]:
        longitude, latitude = route["coordinates"][0][:2]
        assert abs(latitude - NOTTING_HILL[0]) < 0.05
        assert abs(longitude - NOTTING_HILL[1]) < 0.05
        # Every requested pub is on the line.
        for stop in parsed["stops"]:
            assert any(
                abs(c[1] - stop["latitude"]) < 0.01 and abs(c[0] - stop["longitude"]) < 0.01
                for c in route["coordinates"]
            ), f"{stop['name']} is not on the {route['label']} route"


@pytest.mark.anyio
async def test_a_request_without_a_place_still_starts_where_the_rider_is(explorer_client, settings, monkeypatch):
    monkeypatch.setattr(settings, "geocoding_enabled", True)
    geocode.clear_cache()
    r = await explorer_client.post(
        "/routes/generate",
        json={"origin": {"latitude": HOME[0], "longitude": HOME[1]}, "loop": True, "request": "a quiet 20 km loop"},
    )
    assert r.status_code == 200, r.text
    assert r.json()["parsedRequest"].get("startsAt") is None
    longitude, latitude = r.json()["alternatives"][0]["coordinates"][0][:2]
    assert abs(latitude - HOME[0]) < 0.02
