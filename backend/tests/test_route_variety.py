"""Plan a ride's cards are different rides, or fewer of them (0.9.2).

On the hosted backend the three cards were 99% the same: every card went through
the same points, only the costing changed, and Valhalla's costings barely differ.
`SameRoadRouter` is that engine: whatever the costing, the same points give the
same road, and the only other ways are the alternates it is asked for.
"""

from __future__ import annotations

import uuid
from dataclasses import replace
from itertools import combinations

import pytest

from app.core.geo import destination_point, haversine_m
from app.db.session import get_session_factory
from app.discoveries.models import Discovery
from app.routing import budget, geocode, overlap, service, shapes
from app.routing.custom_models import valhalla_costing
from app.routing.engine import EngineRequest, EngineRoute, RoutingUnavailable, SyntheticRouter
from app.routing.preferences import RoutePreferences
from app.routing.scoring import scoring_config
from tests.conftest import parse, stops

HOME = (51.4906, -0.0316)
TOWER = (51.4906, 0.0234)  # 3.8 km east
CAMDEN = (51.5392, -0.1428)


class SameRoadRouter(SyntheticRouter):
    """Every costing gives the same road between the same points; asked for
    alternates, it has other ways. Details come with the route only when asked for,
    and cost a request of their own afterwards, as on Valhalla."""

    def __init__(self, *, through: bool = True) -> None:
        self.through = through
        self.requests: list[EngineRequest] = []
        self.details_calls = 0

    async def route(self, request: EngineRequest) -> list[EngineRoute]:
        self.requests.append(request)
        kept = [(p, t) for p, t in zip(request.points, request.types(), strict=True) if self.through or t != "through"]
        same = replace(
            request,
            points=[p for p, _ in kept],
            location_types=[t for _, t in kept],
            seed=2,
            custom_model=None,
            alternatives=1,
        )
        routes = await super().route(same)
        if request.alternatives > 1 and len(request.points) == 2:
            for seed in (5, 8)[: request.alternatives - 1]:
                coords, legs = self._chain(same.points, seed)
                routes.append(self._answer(coords, same))
        if not request.details:
            for route in routes:
                route.details = {}
        return routes

    async def details(self, route: EngineRoute, request: EngineRequest) -> EngineRoute:
        budget.charge()
        self.details_calls += 1
        n = len(route.coordinates)
        route.details = {
            "surface": [[0, n - 1, "asphalt"]],
            "road_class": [[0, n - 1, "residential"]],
            "bike_network": [[0, n - 1, "missing"]],
        }
        return route


def assert_different(cards: list[dict]) -> None:
    """No two cards are the same ride. Direct may run along another card (it is the
    yardstick), but not as the same road at the same length."""
    for a, b in combinations(cards, 2):
        alike = overlap.similarity(a["coordinates"], b["coordinates"])
        if "Direct" in (a["label"], b["label"]):
            longer = max(a["distanceMeters"], b["distanceMeters"])
            same_length = abs(a["distanceMeters"] - b["distanceMeters"]) / longer < shapes.DIRECT_LENGTH_SAME
            assert not (alike >= shapes.DIRECT_SAME and same_length), (a["label"], b["label"], alike)
        else:
            assert alike < shapes.SIMILAR, (a["label"], b["label"], alike)


@pytest.fixture
def same_road(app) -> SameRoadRouter:
    router = SameRoadRouter()
    app.state.router = router
    return router


@pytest.mark.anyio
async def test_a_map_tap_gets_three_ways_from_two_requests(explorer_client, same_road):
    r = await explorer_client.post(
        "/routes/generate",
        json={
            "origin": {"latitude": HOME[0], "longitude": HOME[1]},
            "destination": {"latitude": CAMDEN[0], "longitude": CAMDEN[1]},
            "loop": False,
        },
    )
    assert r.status_code == 200, r.text
    cards = r.json()["alternatives"]
    # The quiet way (the gravel bike's quietest flavour) and Direct are the same road
    # here: Direct is dropped, and the third card is an alternate the two requests
    # already brought back.
    assert sorted(c["label"] for c in cards) == ["Another way", "Gravel"], [c["label"] for c in cards]
    assert_different(cards)
    assert len(same_road.requests) == 2
    assert [rq.alternatives for rq in same_road.requests] == [3, 2]
    assert all(not rq.details for rq in same_road.requests)
    # Details for the two cards kept, none for the one dropped.
    assert same_road.details_calls == 2


@pytest.mark.anyio
async def test_a_ride_to_a_place_offers_another_way_or_says_why_not(explorer_client, reading, monkeypatch, app):
    router = SameRoadRouter(through=False)  # the offset point never reaches a new road
    app.state.router = router

    async def resolve(_settings, query, lat, lon, transport=None, kind="area"):
        return geocode.Area("Aragon Tower", *TOWER)

    monkeypatch.setattr(geocode, "resolve", resolve)
    reading(parse(destination={"query": "aragon tower"}, loop=False))
    r = await explorer_client.post(
        "/routes/generate",
        json={"origin": {"latitude": HOME[0], "longitude": HOME[1]}, "request": "go to the aragon tower"},
    )
    assert r.status_code == 200, r.text
    body = r.json()
    labels = [c["label"] for c in body["alternatives"]]
    # As asked; Direct was the same road; the corridor came back the same road too,
    # so the third card is Direct's alternate — which cost no request.
    assert sorted(labels) == ["Another way", "As asked"], labels
    assert_different(body["alternatives"])
    assert "Direct and As asked are the same road here" in body["parsedRequest"]["notes"]
    assert len(router.requests) == 3  # as asked, Direct (with alternates), the corridor
    assert router.requests[1].alternatives == 3


@pytest.mark.anyio
async def test_the_cards_never_cost_more_than_ten_requests(app, explorer_client, reading, monkeypatch):
    """Everything fails as late as it can: no road through an offset point, a way
    back that only knows the way out, every card the same road."""

    class Stubborn(SyntheticRouter):
        def __init__(self) -> None:
            self.calls = 0

        async def route(self, request: EngineRequest) -> list[EngineRoute]:
            self.calls += 1
            types = request.types()
            if "through" in types:
                budget.charge()
                raise RoutingUnavailable("No path could be found for input", no_path=True)
            # Out and back on one road, whatever it was asked to pass or keep off.
            ends = [(p, t) for p, t in zip(request.points, types, strict=True) if t != "via"]
            return await super().route(
                replace(
                    request,
                    points=[p for p, _ in ends],
                    location_types=[t for _, t in ends],
                    exclude_points=[],
                    seed=2,
                )
            )

    router = Stubborn()
    app.state.router = router

    async def resolve(_settings, query, lat, lon, transport=None, kind="area"):
        return geocode.Area("Aragon Tower", *TOWER)

    monkeypatch.setattr(geocode, "resolve", resolve)
    reading(parse(destination={"query": "aragon tower"}, loop=True))
    with budget.plan_budget(99) as outer:
        r = await explorer_client.post(
            "/routes/generate",
            json={"origin": {"latitude": HOME[0], "longitude": HOME[1]}, "request": "to the aragon tower and back"},
        )
    assert r.status_code == 200, r.text
    assert outer.used == 0  # the plan had a budget of its own
    assert router.calls <= budget.PLAN_CALLS, router.calls


def test_direct_is_the_quick_way_on_valhalla_too():
    """Valhalla's costing range is narrow: at a quiet rider's preferences Direct came
    back on the same roads as As asked."""
    cfg = scoring_config()
    quiet_rider = RoutePreferences(trafficAversion=0.9, cyclewayPreference=0.9)
    variants = service._variants(quiet_rider, RoutePreferences(), [], ["Direct", "Scenic", "Adventure"], cfg, True)
    plain = next(v for v in variants if v.label == "Direct")
    before = valhalla_costing(plain.prefs, "HYBRID", True, False)["use_roads"]
    after = valhalla_costing(service._wider(plain).prefs, "HYBRID", True, False)["use_roads"]
    assert before < 0.6 <= after
    asked = valhalla_costing(quiet_rider, "HYBRID", True, False, living_streets=True)
    assert asked["use_living_streets"] > 0.5
    assert "use_living_streets" not in valhalla_costing(quiet_rider, "HYBRID", True, False)


@pytest.mark.anyio
async def test_the_plan_asks_for_direct_wider_and_as_asked_on_living_streets(
    app, explorer_client, reading, monkeypatch
):
    router = SameRoadRouter()
    app.state.router = router

    async def resolve(_settings, query, lat, lon, transport=None, kind="area"):
        return geocode.Area("Aragon Tower", *TOWER)

    monkeypatch.setattr(geocode, "resolve", resolve)
    reading(parse(destination={"query": "aragon tower"}, trafficAversion=0.95, loop=False))
    r = await explorer_client.post(
        "/routes/generate",
        json={"origin": {"latitude": HOME[0], "longitude": HOME[1]}, "request": "a quiet ride to the aragon tower"},
    )
    assert r.status_code == 200, r.text
    asked, direct = router.requests[0].costing, router.requests[1].costing
    assert direct["use_roads"] >= 0.6 > asked["use_roads"]
    assert "use_living_streets" in asked and "use_living_streets" not in direct


def test_each_card_has_a_label_of_its_own():
    assert shapes.unique_labels(["As asked", "Direct", "As asked"]) == ["As asked", "Direct", "Another way"]
    assert shapes.unique_labels(["The long way", "The long way", "Another way"]) == [
        "The long way",
        "Other stops",
        "Another way",
    ]


def test_a_card_too_like_another_is_a_duplicate_and_direct_is_judged_gently():
    line = [[HOME[1] + 0.0005 * i, HOME[0], 0.0] for i in range(80)]  # about 2.8 km east
    beside = [[c[0], c[1] + 0.0001, 0.0] for c in line]  # 11 m north: the same road
    kept = [("As asked", line, 2800.0)]
    assert shapes.duplicate_of(beside, 2800.0, kept) is not None
    # Direct stays as the yardstick when it is the same road but 300 m shorter...
    assert shapes.duplicate_of(beside, 2500.0, kept, direct=True) is None
    # ...and goes when it is the same road and the same length.
    assert shapes.duplicate_of(beside, 2790.0, kept, direct=True) is not None
    assert shapes.stops_add_only_note(320) == "the stops add only 300 m"
    assert shapes.fewer_cards_note(2) == "only two different ways here"


async def seed_pubs_around(centre: tuple[float, float], count: int, radius_m: float) -> list[uuid.UUID]:
    ids = []
    async with get_session_factory()() as db:
        for i in range(count):
            lat, lon = destination_point(centre[0], centre[1], i * 360 / count, radius_m)
            pub = Discovery(
                name=f"The Ring {i}",
                category="PUB",
                latitude=lat,
                longitude=lon,
                source="OSM",
                osm_id=f"n{uuid.uuid4().int % 10**9}",
                tags={},
                moderation_status="APPROVED",
                cycling_accessible=True,
            )
            db.add(pub)
            await db.flush()
            ids.append(pub.id)
        await db.commit()
    return ids


@pytest.mark.anyio
async def test_other_stops_turn_half_a_sector(explorer_client):
    from app.core.geo import bearing_deg

    await seed_pubs_around(HOME, 12, 1500)
    async with get_session_factory()() as db:
        first = await service._pick_stops(db, *HOME, ["PUB"], 3, 12)
        bearings = [bearing_deg(*HOME, p.latitude, p.longitude) for p in first]
        other = await service._pick_stops(
            db, *HOME, ["PUB"], 3, 12, exclude={p.id for p in first}, avoid_bearings=bearings
        )
    assert len(other) == 3 and not {p.id for p in first} & {p.id for p in other}
    for poi in other:
        bearing = bearing_deg(*HOME, poi.latitude, poi.longitude)
        assert all(service._bearing_gap(bearing, b) >= 30 for b in bearings)


@pytest.mark.anyio
async def test_without_the_flag_a_map_tap_is_three_costings_again(explorer_client, same_road, settings, monkeypatch):
    monkeypatch.setattr(settings, "feature_flags", "!route_shapes")
    r = await explorer_client.post(
        "/routes/generate",
        json={
            "origin": {"latitude": HOME[0], "longitude": HOME[1]},
            "destination": {"latitude": CAMDEN[0], "longitude": CAMDEN[1]},
            "loop": False,
        },
    )
    assert r.status_code == 200, r.text
    assert len(same_road.requests) == 3
    assert all(rq.alternatives == 1 and rq.details for rq in same_road.requests)
    # The same road three times is one card, by its exact line.
    assert len(r.json()["alternatives"]) == 1


@pytest.mark.anyio
async def test_a_loop_through_stops_offers_other_stops(explorer_client, same_road, reading):
    await seed_pubs_around(HOME, 10, 1800)
    reading(parse(stops=stops("PUB", count=3), distanceKm={"target": 12, "tolerance": 3}, loop=True))
    r = await explorer_client.post(
        "/routes/generate",
        json={"origin": {"latitude": HOME[0], "longitude": HOME[1]}, "request": "a 12 km loop through 3 pubs"},
    )
    assert r.status_code == 200, r.text
    cards = {c["label"]: c for c in r.json()["alternatives"]}
    assert set(cards) == {"As asked", "Direct", "Other stops"}, set(cards)
    assert_different(list(cards.values()))
    asked = {p["name"] for p in cards["As asked"]["pois"] if p.get("requested")}
    other = {p["name"] for p in cards["Other stops"]["pois"] if p.get("requested")}
    assert len(asked) == 3 and other and not asked & other
    for card in cards.values():
        assert card["selfOverlap"] is not None
        start_lon, start_lat = card["coordinates"][0][:2]
        assert haversine_m(start_lat, start_lon, *HOME) < 50
