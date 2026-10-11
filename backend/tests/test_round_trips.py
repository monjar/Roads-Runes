"""To a place and back is a loop, not a line ridden twice (0.9.2).

The report: "From Aragon Tower to Westminster and back, checking out some pubs"
rode the same road both ways, with no pubs at all. One request `[O, D, O]` left
the way back free to retrace the way out, every pub sat on the way out, and
"some pubs" (no number) meant none.

The synthetic router bends a leg there and its leg back the same way, so it
reproduces the line; these tests show the loop.
"""

from __future__ import annotations

import uuid

import pytest

from app.core.geo import haversine_m
from app.core.schemas import Coordinate
from app.db.session import get_session_factory
from app.discoveries.models import Discovery
from app.routing import budget, geocode, overlap, service, shapes
from app.routing.engine import EngineRequest, RoutingUnavailable, SyntheticRouter
from app.routing.pois import cumulative_distances
from tests.conftest import parse, stops

HOME = (51.4906, -0.0316)  # where the rider is
ARAGON = (51.4906, 0.0234)  # a stand-in, 3.8 km east: "from Aragon Tower" moves the start
WESTMINSTER = (51.5004, -0.1265)
REQUEST = "From Aragon Tower to Westminster and back, checking out some pubs"
READING = parse(origin={"query": "Aragon Tower"}, destination={"query": "Westminster"}, stops=stops("PUB"), loop=True)
PLACES = {"aragon tower": ("Aragon Tower", *ARAGON), "westminster": ("Westminster", *WESTMINSTER)}


@pytest.fixture
def places(monkeypatch):
    async def resolve(_settings, query, lat, lon, transport=None, kind="area"):
        found = PLACES.get(query.lower())
        return geocode.Area(*found) if found else None

    monkeypatch.setattr(geocode, "resolve", resolve)


def at(along: float, offset_m: float, start=ARAGON, end=WESTMINSTER) -> tuple[float, float]:
    """A point `along` the line and `offset_m` to its left (+) or right (−)."""
    return service._offset_point(
        Coordinate(latitude=start[0], longitude=start[1]),
        Coordinate(latitude=end[0], longitude=end[1]),
        along,
        offset_m,
    )


async def seed_pubs(spots: list[tuple[str, float, float]]) -> None:
    async with get_session_factory()() as db:
        for name, along, offset_m in spots:
            lat, lon = at(along, offset_m)
            db.add(
                Discovery(
                    name=name,
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


# Four pubs on one side of the line, three on the other, about 1.2 km off it.
PUBS = [
    ("The Left Arms 1", 0.2, 1200),
    ("The Left Arms 2", 0.4, 1300),
    ("The Left Arms 3", 0.6, 1100),
    ("The Left Arms 4", 0.8, 1250),
    ("The Right Arms 1", 0.3, -1200),
    ("The Right Arms 2", 0.55, -1150),
    ("The Right Arms 3", 0.75, -1300),
]


def turn_of(route: dict) -> int:
    coords = route["coordinates"]
    return min(range(len(coords)), key=lambda i: haversine_m(*WESTMINSTER, coords[i][1], coords[i][0]))


async def plan(client, **extra) -> dict:
    r = await client.post(
        "/routes/generate",
        json={
            "origin": {"latitude": HOME[0], "longitude": HOME[1]},
            "distanceTargetKm": 25,
            "request": REQUEST,
            **extra,
        },
    )
    assert r.status_code == 200, r.text
    return r.json()


@pytest.mark.anyio
async def test_to_westminster_and_back_with_some_pubs_is_a_loop(explorer_client, reading, places):
    await seed_pubs(PUBS)
    reading(READING)
    body = await plan(explorer_client)
    parsed = body["parsedRequest"]

    # Read as asked: from the tower, to Westminster, three pubs for "some", a loop.
    assert parsed["startsAt"]["name"] == "Aragon Tower"
    assert parsed["understood"][:3] == ["from Aragon Tower", "to Westminster", "3 pubs"]
    assert parsed["poi"]["countImplied"] is True
    assert len(parsed["stops"]) == 3
    assert not any(note.startswith("only") for note in parsed["notes"]), parsed["notes"]

    cards = body["alternatives"]
    assert len(cards) == 3 and len({c["label"] for c in cards}) == 3
    for card in cards:
        start_lon, start_lat = card["coordinates"][0][:2]
        assert haversine_m(start_lat, start_lon, *ARAGON) < 50, card["label"]
        # The way back is not the way out.
        assert card["selfOverlap"] is not None and card["selfOverlap"] < 0.4, (card["label"], card["selfOverlap"])
        assert overlap.self_overlap(card["coordinates"], turn_of(card)) < 0.4, card["label"]

    asked = next(c for c in cards if c["label"] == "As asked")
    requested = [poi for poi in asked["pois"] if poi.get("requested")]
    assert {poi["name"] for poi in requested} == {stop["name"] for stop in parsed["stops"]}
    # Out on one side and back on the other: a pub comes after Westminster.
    turn_at = cumulative_distances(asked["coordinates"])[turn_of(asked)]
    assert any(poi["routePositionMeters"] > turn_at for poi in requested), (turn_at, requested)
    assert {poi["name"].split(" ")[1] for poi in requested} == {"Left", "Right"}

    # The cheap card is still a loop, just without the stops.
    direct = next(c for c in cards if c["label"] == "Direct")
    assert not [poi for poi in direct["pois"] if poi.get("requested")]


@pytest.mark.anyio
async def test_without_the_flag_it_plans_as_it_did(explorer_client, reading, places, settings, monkeypatch):
    """FEATURE_FLAGS=!route_shapes is the way back to 0.9.1's planner."""
    monkeypatch.setattr(settings, "feature_flags", "!route_shapes")
    await seed_pubs(PUBS)
    reading(READING)
    body = await plan(explorer_client)
    parsed = body["parsedRequest"]
    assert parsed.get("startsAt") is None and parsed["origin"] is None
    assert "pubs" in parsed["understood"] and not parsed.get("stops")
    for card in body["alternatives"]:
        assert card["selfOverlap"] is None
        start_lon, start_lat = card["coordinates"][0][:2]
        assert haversine_m(start_lat, start_lon, *HOME) < 50
    # The line ridden twice, as reported.
    asked = next(c for c in body["alternatives"] if c["label"] == "As asked")
    assert overlap.self_overlap(asked["coordinates"], turn_of(asked)) > 0.8


@pytest.mark.anyio
async def test_a_loop_with_no_stops_comes_back_another_way(explorer_client, reading, places):
    reading(parse(destination={"query": "Westminster"}, loop=True))
    r = await explorer_client.post(
        "/routes/generate",
        json={"origin": {"latitude": ARAGON[0], "longitude": ARAGON[1]}, "request": "to westminster and back"},
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert len(body["alternatives"]) >= 2
    for card in body["alternatives"]:
        assert card["selfOverlap"] < 0.4, (card["label"], card["selfOverlap"])
    # The target is the loop's own length, not 2.4× the crow's flight.
    direct_km = haversine_m(*ARAGON, *WESTMINSTER) / 1000
    asked = next(card for card in body["alternatives"] if card["label"] == "As asked")
    assert 2.0 * direct_km < asked["distanceMeters"] / 1000 < 3.0 * direct_km


@pytest.mark.anyio
async def test_a_start_where_the_rider_already_is_is_named_but_moves_nothing(explorer_client, reading, places):
    reading(READING)
    r = await explorer_client.post(
        "/routes/generate",
        json={"origin": {"latitude": ARAGON[0] + 0.001, "longitude": ARAGON[1]}, "request": REQUEST},
    )
    parsed = r.json()["parsedRequest"]
    assert parsed.get("startsAt") is None
    assert parsed["origin"]["name"] == "Aragon Tower"
    assert parsed["understood"][0] == "from Aragon Tower"


@pytest.mark.anyio
async def test_a_start_nobody_can_find_is_said_out_loud(explorer_client, reading, places):
    reading(parse(origin={"query": "the Emerald Spire"}, destination={"query": "Westminster"}, loop=True))
    r = await explorer_client.post(
        "/routes/generate",
        json={"origin": {"latitude": HOME[0], "longitude": HOME[1]}, "request": "from the emerald spire and back"},
    )
    parsed = r.json()["parsedRequest"]
    assert parsed["origin"] is None and parsed.get("startsAt") is None
    assert any("emerald spire" in note.lower() and "starting from here" in note for note in parsed["notes"])


@pytest.mark.anyio
async def test_the_stops_split_by_side_of_the_line(explorer_client):
    await seed_pubs(PUBS)
    start = Coordinate(latitude=ARAGON[0], longitude=ARAGON[1])
    end = Coordinate(latitude=WESTMINSTER[0], longitude=WESTMINSTER[1])
    async with get_session_factory()() as db:
        out, back, side = await service._pick_stops_loop(db, start, end, ["PUB"], 3)
        assert side == 1  # four on the left, three on the right
        assert [p.name.split(" ")[1] for p in out] == ["Left", "Left"]
        assert [p.name.split(" ")[1] for p in back] == ["Right"]
        progress = [service._signed_offset(p.latitude, p.longitude, start, end)[1] for p in out]
        assert progress == sorted(progress)  # in the order they are reached

        # Four stops: two out, two back, the way back in the order it reaches them.
        out, back, _ = await service._pick_stops_loop(db, start, end, ["PUB"], 4)
        progress = [service._signed_offset(p.latitude, p.longitude, start, end)[1] for p in back]
        assert len(out) == 2 and len(back) == 2 and progress == sorted(progress, reverse=True)

        # The other card's stops: none of the first card's, the way out on the other side.
        first = {p.id for p in out + back}
        out2, back2, side2 = await service._pick_stops_loop(db, start, end, ["PUB"], 3, exclude=first, swap=True)
        assert not first & {p.id for p in out2 + back2}
        assert side2 == -1


class IgnoresOffsets(SyntheticRouter):
    """An engine on roads that never reach the offset point and send the way back
    along the way out unless told what to keep off."""

    requests: list[EngineRequest]

    def __init__(self) -> None:
        self.requests = []

    async def route(self, request: EngineRequest):
        self.requests.append(request)
        if request.exclude_points:
            return await super().route(request)
        kept = [(p, t) for p, t in zip(request.points, request.types(), strict=True) if t != "through"]
        trimmed = EngineRequest(
            [p for p, _ in kept],
            request.profile,
            seed=request.seed,
            location_types=[t for _, t in kept],
            custom_model=request.custom_model,
        )
        return await super().route(trimmed)


@pytest.mark.anyio
async def test_a_way_back_that_retraces_is_asked_for_again_off_the_way_out(app, explorer_client, reading, places):
    router = IgnoresOffsets()
    app.state.router = router
    reading(parse(destination={"query": "Westminster"}, loop=True))
    r = await explorer_client.post(
        "/routes/generate",
        json={"origin": {"latitude": ARAGON[0], "longitude": ARAGON[1]}, "request": "to westminster and back"},
    )
    assert r.status_code == 200, r.text
    second = [request for request in router.requests if request.exclude_points]
    assert second, "no second attempt"
    assert all(0 < len(request.exclude_points) <= 25 for request in second)
    # The way back on its own: from Westminster, home.
    assert second[0].points[0] == pytest.approx(WESTMINSTER, abs=1e-6)
    assert second[0].points[-1] == pytest.approx(ARAGON, abs=1e-6)
    asked = next(card for card in r.json()["alternatives"] if card["label"] == "As asked")
    assert asked["selfOverlap"] < 0.4


@pytest.mark.anyio
async def test_an_offset_point_the_road_missed_is_tried_on_the_other_side(
    app, explorer_client, reading, places, monkeypatch
):
    """It landed in the river: the engine routed round it, nowhere near."""

    class MissesTheLeftSide(SyntheticRouter):
        def __init__(self) -> None:
            self.offsets: list[tuple[float, float]] = []

        async def route(self, request: EngineRequest):
            types = request.types()
            if "through" in types:
                spot = request.points[types.index("through")]
                self.offsets.append(spot)
                start = Coordinate(latitude=ARAGON[0], longitude=ARAGON[1])
                end = Coordinate(latitude=WESTMINSTER[0], longitude=WESTMINSTER[1])
                if service._signed_offset(*spot, start, end)[0] > 0:
                    kept = [(p, t) for p, t in zip(request.points, types, strict=True) if t != "through"]
                    request = EngineRequest(
                        [p for p, _ in kept], request.profile, seed=request.seed, location_types=[t for _, t in kept]
                    )
            return await super().route(request)

    router = MissesTheLeftSide()
    app.state.router = router
    reading(parse(destination={"query": "Westminster"}, loop=True))

    async def left(db, start, destination, seed):
        return 1  # the asked-for card aims left first

    monkeypatch.setattr(service, "_return_side", left)
    r = await explorer_client.post(
        "/routes/generate",
        json={"origin": {"latitude": ARAGON[0], "longitude": ARAGON[1]}, "request": "to westminster and back"},
    )
    assert r.status_code == 200, r.text
    start = Coordinate(latitude=ARAGON[0], longitude=ARAGON[1])
    end = Coordinate(latitude=WESTMINSTER[0], longitude=WESTMINSTER[1])
    sides = [service._signed_offset(*spot, start, end)[0] > 0 for spot in router.offsets]
    assert sides[:2] == [True, False], sides  # missed on the left, tried again mirrored
    asked = next(card for card in r.json()["alternatives"] if card["label"] == "As asked")
    mirrored = router.offsets[1]
    assert min(haversine_m(*mirrored, c[1], c[0]) for c in asked["coordinates"]) < shapes.SNAP_OFF_LINE_M


@pytest.mark.anyio
async def test_a_destination_up_a_dead_end_may_turn_back_after_all(app, explorer_client, reading, places):
    class DeadEnd(SyntheticRouter):
        def __init__(self) -> None:
            self.types: list[list[str]] = []

        async def route(self, request: EngineRequest):
            self.types.append(request.types())
            if "break_through" in request.types():
                budget.charge()
                raise RoutingUnavailable("No path could be found for input", no_path=True)
            return await super().route(request)

    router = DeadEnd()
    app.state.router = router
    reading(parse(destination={"query": "Westminster"}, loop=True))
    r = await explorer_client.post(
        "/routes/generate",
        json={"origin": {"latitude": ARAGON[0], "longitude": ARAGON[1]}, "request": "to westminster and back"},
    )
    assert r.status_code == 200, r.text
    first, then = router.types[0], router.types[1]
    assert "break_through" in first and "through" in first
    assert "break_through" not in then and "through" not in then and then.count("break") == 3
