"""Ride requests that name a place and a number of stops.

The case that prompted this: "a biker ride in notting hill with about 5 pubs"
used to parse to nothing but "pubs", so the ride stayed at the rider's door.
"""

from __future__ import annotations

import uuid

import httpx
import pytest

from app.core.geo import bearing_deg, destination_point, haversine_m
from app.core.schemas import Coordinate
from app.db.session import get_session_factory
from app.discoveries.models import Discovery
from app.routing import geocode, service
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


TOWER_BRIDGE = (51.5055, -0.0754)  # ~3.5 km from HOME


async def seed_cafes_on_the_way(start: tuple[float, float], end: tuple[float, float], count: int = 6) -> None:
    """Cafés strung along the line from A to B, a little off it on alternate sides."""
    async with get_session_factory()() as db:
        for i in range(count):
            along = (i + 0.5) / count
            lat = start[0] + (end[0] - start[0]) * along
            lon = start[1] + (end[1] - start[1]) * along
            lat, lon = destination_point(lat, lon, 90 if i % 2 else 270, 150)
            db.add(
                Discovery(
                    name=f"Test Coffee {i}",
                    category="CAFE",
                    latitude=lat,
                    longitude=lon,
                    source="OSM",
                    osm_id=f"n{uuid.uuid4().int % 10**9}",
                    tags={"amenity": "cafe"},
                    moderation_status="APPROVED",
                    cycling_accessible=True,
                )
            )
        await db.commit()


def test_asking_for_kinds_of_stop_is_not_naming_a_place():
    """The rider's own words. "through" introduces a place as often as a shopping
    list, and "3 top cafes" used to be geocoded as if it were a neighbourhood."""
    prefs = parse_rules("I want the ride to be through 3 top cafes or cultural").preferences
    assert prefs.area is None
    assert prefs.poi["count"] == 3
    assert prefs.poi["categories"] == ["CAFE", "CULTURAL"]


def test_counts_written_as_words():
    assert parse_rules("three cafes and a museum").preferences.poi["count"] == 3
    assert parse_rules("a ride through two pubs").preferences.poi["count"] == 2
    assert parse_rules("three cafes and a museum").preferences.area is None


@pytest.mark.anyio
async def test_a_ride_to_a_place_still_goes_through_the_stops_asked_for(explorer_client):
    """The rider searched for a place, then asked for cafés on the way there.

    A destination used to cancel the stops outright, so the typed request changed
    nothing and the same route came back.
    """
    await seed_cafes_on_the_way(HOME, TOWER_BRIDGE)

    r = await explorer_client.post(
        "/routes/generate",
        json={
            "origin": {"latitude": HOME[0], "longitude": HOME[1]},
            "destination": {"latitude": TOWER_BRIDGE[0], "longitude": TOWER_BRIDGE[1]},
            "request": "I want the ride to be through 3 top cafes or cultural",
        },
    )
    assert r.status_code == 200, r.text
    body = r.json()
    parsed = body["parsedRequest"]
    assert parsed["poi"]["count"] == 3
    assert parsed.get("area") is None
    assert len(parsed["stops"]) == 3

    # The stops are in the order they will be reached, not scattered back and forth.
    distances = [haversine_m(HOME[0], HOME[1], stop["latitude"], stop["longitude"]) for stop in parsed["stops"]]
    assert distances == sorted(distances)

    for route in body["alternatives"]:
        requested = [poi for poi in route["pois"] if poi.get("requested")]
        assert {poi["name"] for poi in requested} == {stop["name"] for stop in parsed["stops"]}
        for stop in parsed["stops"]:
            assert any(
                abs(c[1] - stop["latitude"]) < 0.005 and abs(c[0] - stop["longitude"]) < 0.005
                for c in route["coordinates"]
            ), f"{stop['name']} is not on the {route['label']} route"
        # It is still a ride to the place the rider picked.
        longitude, latitude = route["coordinates"][-1][:2]
        assert abs(latitude - TOWER_BRIDGE[0]) < 0.01 and abs(longitude - TOWER_BRIDGE[1]) < 0.01


@pytest.mark.anyio
async def test_the_first_kind_of_stop_asked_for_is_preferred(explorer_client):
    """ "3 cafés or museums" fills up with cafés while they are roughly as convenient;
    something of the second kind sitting right on the line can still win."""
    bearing = bearing_deg(HOME[0], HOME[1], TOWER_BRIDGE[0], TOWER_BRIDGE[1])
    async with get_session_factory()() as db:
        for name, category, along, offset in (
            ("Near Cafe", "CAFE", 0.25, 120),
            ("Near Museum", "CULTURAL", 0.25, 50),
            ("Far Cafe", "CAFE", 0.75, 400),
            ("Line Museum", "CULTURAL", 0.75, 20),
        ):
            lat = HOME[0] + (TOWER_BRIDGE[0] - HOME[0]) * along
            lon = HOME[1] + (TOWER_BRIDGE[1] - HOME[1]) * along
            lat, lon = destination_point(lat, lon, bearing + 90, offset)
            db.add(
                Discovery(
                    name=name,
                    category=category,
                    latitude=lat,
                    longitude=lon,
                    source="OSM",
                    osm_id=f"n{uuid.uuid4().int % 10**9}",
                    tags={},
                    moderation_status="APPROVED",
                    cycling_accessible=True,
                )
            )
        await db.commit()

    async with get_session_factory()() as db:
        stops = await service._pick_stops_between(
            db,
            Coordinate(latitude=HOME[0], longitude=HOME[1]),
            Coordinate(latitude=TOWER_BRIDGE[0], longitude=TOWER_BRIDGE[1]),
            ["CAFE", "CULTURAL"],
            2,
        )
    assert [stop.name for stop in stops] == ["Near Cafe", "Line Museum"]
