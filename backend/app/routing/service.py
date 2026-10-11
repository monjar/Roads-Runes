"""Route generation orchestration (spec §25–32)."""

from __future__ import annotations

import bisect
import hashlib
import math
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, replace
from time import monotonic
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from app.characters.models import Bike, RiderProfile
from app.characters.service import default_bike, get_rider_profile, maybe_character
from app.core.activity import ASSUMED_SPEED_KMH, DISTANCE_SCALE, comfortable_distance_km, is_foot, normalise
from app.core.config import Settings
from app.core.errors import NotFound, RouteGenerationFailed
from app.core.feature_flags import is_enabled
from app.core.geo import bearing_deg, encode_polyline, haversine_m
from app.core.llm import LLMClient
from app.core.logging import EVENT_ROUTE_GENERATED, EVENT_ROUTE_GENERATION_FAILED, get_logger
from app.core.schemas import Coordinate
from app.core.security import utcnow
from app.discoveries import osm_import
from app.discoveries.models import Discovery
from app.discoveries.service import nearby as discoveries_nearby
from app.exploration.cells import cell_for
from app.exploration.service import known_cells
from app.quests.models import QuestInstance
from app.quests.service import quest_out
from app.routing import budget, geocode, overlap, shapes
from app.routing.analysis import (
    analyse_elevation,
    bounding_box,
    cycleway_fraction,
    elevation_samples_from_coordinates,
    surface_composition,
    traffic_exposure,
)
from app.routing.custom_models import build_custom_model, strip_internal, valhalla_costing
from app.routing.engine import (
    PROFILE_FOR_BIKE,
    EngineRequest,
    EngineRoute,
    RoutingEngine,
    RoutingUnavailable,
    downgraded,
    head_of,
    join_routes,
)
from app.routing.models import Route
from app.routing.pois import attach_pois, cumulative_distances
from app.routing.preferences import RoutePreferences, parse_request
from app.routing.schemas import (
    InstructionOut,
    RerouteRequest,
    RouteGenerateRequest,
    RouteOptionOut,
    RoutePackageOut,
)
from app.routing.scoring import RiderLimits, RouteMetrics, score_route, scoring_config
from app.users.models import User

log = get_logger(__name__)


@dataclass
class QuestTargets:
    points: list[tuple[float, float, float]]  # lat, lon, radius
    return_to_start: bool


def _quest_targets(quest: QuestInstance | None, done: set[uuid.UUID] | None = None) -> QuestTargets:
    """Where the quest still has to go: an objective already done is not ridden to
    again. `done` is what the phone has seen completed and the server not yet."""
    if quest is None:
        return QuestTargets([], False)
    points = []
    rts = False
    for o in quest.objectives:
        if o.status == "COMPLETED" or (done and o.id in done):
            continue
        if o.objective_type == "RETURN_TO_START":
            rts = True
        elif o.objective_type == "VISIT_MULTIPLE_LOCATIONS" and o.extra.get("cells"):
            for c in o.extra["cells"]:
                points.append((float(c["latitude"]), float(c["longitude"]), o.radius_meters or 250.0))
        elif o.latitude is not None and o.longitude is not None:
            points.append((o.latitude, o.longitude, o.radius_meters or 60.0))
    return QuestTargets(points, rts)


def _coverage(coords: list[list[float]], targets: QuestTargets) -> float:
    if not targets.points:
        return 1.0
    from app.core.geo import haversine_m

    hit = 0
    for lat, lon, radius in targets.points:
        if any(haversine_m(lat, lon, c[1], c[0]) <= radius * 1.5 for c in coords[::2]):
            hit += 1
    return hit / len(targets.points)


def _new_territory_fraction(
    coords: list[list[float]], known: dict[str, str], resolution: int, unique: bool = False
) -> float:
    if len(coords) < 2:
        return 0.0
    cells = [cell_for(c[1], c[0], resolution) for c in coords]
    if unique:
        # A loop that rides a street twice has not found twice as much (0.9.2).
        cells = list(dict.fromkeys(cells))
    unknown = sum(1 for c in cells if known.get(c) not in ("VISITED", "EXPLORED"))
    return round(unknown / len(cells), 3)


def route_out(route: Route, components: dict[str, float] | None = None) -> RouteOptionOut:
    return RouteOptionOut(
        id=route.id,
        label=route.label,
        engine=route.engine,
        activity=normalise(route.activity),
        distanceMeters=route.distance_meters,
        estimatedDurationSeconds=route.estimated_duration_seconds,
        elevationGainMeters=route.elevation_gain_meters,
        elevationLossMeters=route.elevation_loss_meters,
        highestPointMeters=route.highest_point_meters,
        maxGradientPercent=route.max_gradient_percent,
        averageClimbGradientPercent=route.average_climb_gradient_percent,
        longestClimb=route.longest_climb,
        surface=route.surface,
        cyclewayFraction=route.cycleway_fraction,
        trafficExposure=route.traffic_exposure,
        newTerritoryFraction=route.new_territory_fraction,
        questObjectiveCoverage=route.quest_objective_coverage,
        score=route.score,
        scoreComponents=components or route.request.get("scoreComponents", {}),
        detailsMissing=bool((route.request or {}).get("detailsMissing")),
        selfOverlap=(route.request or {}).get("selfOverlap"),
        pois=route.pois,
        coordinates=route.coordinates,
        encodedPolyline=route.encoded_polyline,
        instructions=[InstructionOut(**i) for i in route.instructions],
        elevationSamples=route.elevation_samples,
        climbs=route.climbs,
        boundingBox={
            "minLat": route.min_lat,
            "minLon": route.min_lon,
            "maxLat": route.max_lat,
            "maxLon": route.max_lon,
        },
        createdAt=route.created_at,
    )


def _route_row(
    *,
    user: User,
    quest: QuestInstance | None,
    bike_id: uuid.UUID | None,
    label: str,
    profile: str,
    activity: str,
    er: EngineRoute,
    speed_mps: float,
    pois: list[dict[str, Any]],
    request: dict[str, Any],
    surface: dict[str, Any] | None = None,
    cycleway: float = 0.0,
    traffic: float = 0.0,
    new_fraction: float = 0.0,
    coverage: float = 0.0,
) -> Route:
    """An engine's answer as a stored route: its geometry, its hills and its box."""
    coords = er.coordinates
    samples = elevation_samples_from_coordinates(coords)
    elev = analyse_elevation(samples)
    min_lat, min_lon, max_lat, max_lon = bounding_box(coords)
    return Route(
        user_id=user.id,
        quest_id=quest.id if quest else None,
        bike_id=bike_id,
        label=label,
        profile=profile,
        activity=activity,
        engine=er.engine,
        distance_meters=round(er.distance_m, 1),
        estimated_duration_seconds=int(er.distance_m / speed_mps),
        elevation_gain_meters=elev.total_ascent,
        elevation_loss_meters=elev.total_descent,
        highest_point_meters=elev.highest_point,
        max_gradient_percent=elev.max_gradient_percent,
        average_climb_gradient_percent=elev.average_climb_gradient_percent,
        longest_climb=elev.longest_climb.to_dict() if elev.longest_climb else None,
        surface=surface or {},
        cycleway_fraction=cycleway,
        traffic_exposure=traffic,
        new_territory_fraction=new_fraction,
        quest_objective_coverage=coverage,
        coordinates=[[round(c[0], 6), round(c[1], 6), round(c[2], 1)] for c in coords],
        encoded_polyline=encode_polyline((c[1], c[0]) for c in coords),
        instructions=er.instructions,
        elevation_samples=samples,
        climbs=[c.to_dict() for c in elev.climbs],
        pois=pois,
        request=request,
        min_lat=min_lat,
        min_lon=min_lon,
        max_lat=max_lat,
        max_lon=max_lon,
    )


ASKED_LABEL = "As asked"
# The rider is told what each way costs, so one of them has to be the cheap one.
DIRECT_LABEL = "Direct"
# How far a stated preference is pushed on the "more of it" card.
MORE_OF_IT = 0.25
# Naming the card after the thing the rider asked for reads better than "Adventure".
LOUDER = {
    "gravelPreference": ("More gravel", "Less gravel"),
    "hillTolerance": ("Hillier", "Flatter"),
    "trafficAversion": ("Quieter", "Faster roads"),
    "scenicPreference": ("More scenic", "Plainer"),
    "cyclewayPreference": ("More cycleways", "Fewer cycleways"),
}


@dataclass
class Variant:
    """One alternative: the preferences it rides on and the stops it carries."""

    label: str
    prefs: RoutePreferences
    stops: list[Discovery]
    distance_factor: float


def _overlay(base: RoutePreferences, overlay: dict[str, Any]) -> RoutePreferences:
    prefs = RoutePreferences(
        **{
            **base.to_dict(),
            **{k: v for k, v in overlay.items() if k in RoutePreferences.__dataclass_fields__},
        }
    ).clamp()
    prefs.distanceKm, prefs.poi, prefs.area = base.distanceKm, base.poi, base.area
    return prefs


def _stated(asked: RoutePreferences, usual: RoutePreferences) -> dict[str, float]:
    """Which preferences the rider actually expressed, and by how much.

    Everything has a value whether they said anything or not, so "stated" means
    "far enough from what this rider always gets to have been a choice".
    """
    return {
        field: getattr(asked, field) - getattr(usual, field)
        for field in LOUDER
        if abs(getattr(asked, field) - getattr(usual, field)) >= 0.15
    }


def _variants(
    base: RoutePreferences,
    usual: RoutePreferences,
    stops: list[Discovery],
    labels: list[str],
    cfg: dict[str, Any],
    asked: bool = False,
) -> list[Variant]:
    """Three ways to answer, and what separates them.

    With nothing asked for, the three are the bike's usual flavours. Once the rider
    has asked for something — gravel, quiet, a café — the labels stop being flavours
    and start being a trade-off: straight there, what you asked for, and more of it.
    Presets used to overwrite the request outright, so "gravel heavy" came back on
    two cards with the gravel taken out.

    `asked` is true when the request was understood at all. "Through 3 cafés" in a
    town with no cafés imported yet used to come back as the three usual flavours,
    which is exactly what the rider saw before typing anything.
    """
    stated = _stated(base, usual)
    if not stated and not stops and not asked:
        return [
            Variant(label, _overlay(base, cfg["labels"][label]), stops, cfg["labels"][label].get("distanceFactor", 1.0))
            for label in labels
        ]

    direct = _overlay(usual, cfg["labels"][DIRECT_LABEL])
    # "Direct" is the plain way there: paved, whatever the rider usually rides. At
    # 0.1 the preference still mapped to a costing that took the park path, so the
    # card offered no choice at all next to the one that asked for gravel.
    direct.gravelPreference = 0.0
    variants = [
        Variant(ASKED_LABEL, _overlay(base, {}), stops, 1.0),
        Variant(DIRECT_LABEL, direct, [], cfg["labels"][DIRECT_LABEL].get("distanceFactor", 1.0)),
    ]

    more = _overlay(base, {})
    for field, difference in stated.items():
        value = getattr(more, field)
        setattr(more, field, min(1.0, value + MORE_OF_IT) if difference > 0 else max(0.0, value - MORE_OF_IT))
    if not stated:
        variants.append(Variant("Scenic", _overlay(base, cfg["labels"]["Scenic"]).clamp(), stops, 1.0))
        return variants
    field = max(stated, key=lambda f: abs(stated[f]))
    if more.to_dict() == base.to_dict():
        # They already asked for all of it; there is no more to give, so the third
        # card offers the other thing a rider might want: the same ride, longer.
        variants.append(Variant("The long way", _overlay(base, {}), stops, 1.25))
    else:
        variants.append(Variant(LOUDER[field][0 if stated[field] > 0 else 1], more.clamp(), stops, 1.0))
    return variants


# How a kind of stop reads in the "understood" line. Plain ASCII on purpose: the
# line is what the rider checks the plan against, and "3 cafes" is easy to scan.
STOP_WORDS = {
    "CAFE": "cafe",
    "PUB": "pub",
    "FOOD": "food stop",
    "CULTURAL": "cultural stop",
    "HISTORICAL": "historic stop",
    "NATURE": "green stop",
    "VIEWPOINT": "viewpoint",
    "LANDMARK": "landmark",
    "TRAIL": "trail",
    "CYCLING": "bike shop",
}


def _plural(word: str, count: int) -> str:
    return word if count == 1 else f"{word}s"


def _understood(prefs: RoutePreferences, usual: RoutePreferences, wanted: int, categories: list[str]) -> list[str]:
    """What the planner made of the request, so a misread is visible on the card.

    The app used to reconstruct this from the parsed preferences and came up empty
    for "quiet roads", which changes the routes without naming a place or a stop.
    """
    parts: list[str] = []
    origin = prefs.origin or {}
    if origin.get("name") or origin.get("query"):
        parts.append("from " + str(origin.get("name") or origin.get("query")))
    for place in prefs.via or []:
        parts.append("via " + str(place.get("name") or place.get("query")))
    destination = prefs.destination or {}
    if destination.get("name") or destination.get("query"):
        parts.append("to " + str(destination.get("name") or destination.get("query")))
    area = prefs.area or {}
    if area.get("name") or area.get("query"):
        parts.append(str(area.get("name") or area.get("query")))
    kinds = [STOP_WORDS.get(c, c.lower()) for c in categories]
    if len(kinds) == 1:
        parts.append(f"{wanted} {_plural(kinds[0], wanted)}" if wanted else _plural(kinds[0], 2))
    elif kinds:
        parts.append((f"{wanted} stops: " if wanted else "stops: ") + " or ".join(_plural(k, 2) for k in kinds))
    for field, difference in _stated(prefs, usual).items():
        parts.append(LOUDER[field][0 if difference > 0 else 1].lower())
    target = (prefs.distanceKm or {}).get("target")
    if target:
        parts.append(f"{int(round(float(target)))} km")
    if prefs.loop is True:
        parts.append("loop")
    elif prefs.loop is False:
        parts.append("one way")
    return parts


CANNOT_READ = "couldn't read that — try 'through 2 cafes' or 'mostly gravel'"
# There is no keyword parser behind the model any more, so "no provider" means a
# typed request goes unread. Saying so beats a ride that ignores the sentence.
NO_READER = "typed requests can't be read here yet — planned from your profile instead"
# The corridor import runs only when stops were asked for and none were found, and
# only for tiles never fetched, so a known area costs nothing.
CORRIDOR_IMPORT_BUDGET_S = 25.0


def _unpaved(route: Route) -> float:
    return float(route.surface.get("gravel", 0.0)) + float(route.surface.get("trail", 0.0))


# What each label promises, checked against the route that came back. Riders read
# the label, not the surface bar, and routing is not monotonic: asking for more
# gravel can hand back a longer way round with less of it.
CLAIMS: dict[str, Any] = {
    "More gravel": lambda route, asked: _unpaved(route) > _unpaved(asked) + 0.02,
    "Less gravel": lambda route, asked: _unpaved(route) < _unpaved(asked) - 0.02,
    "Hillier": lambda route, asked: route.elevation_gain_meters > asked.elevation_gain_meters * 1.1,
    "Flatter": lambda route, asked: route.elevation_gain_meters < asked.elevation_gain_meters * 0.9,
    "Quieter": lambda route, asked: route.traffic_exposure < asked.traffic_exposure - 0.03,
    "Faster roads": lambda route, asked: route.traffic_exposure > asked.traffic_exposure + 0.03,
    "More cycleways": lambda route, asked: route.cycleway_fraction > asked.cycleway_fraction + 0.03,
    "Fewer cycleways": lambda route, asked: route.cycleway_fraction < asked.cycleway_fraction - 0.03,
}


def _shortfalls(
    prefs: RoutePreferences, stops: list[Discovery], wanted: int, routes: list[Route], implied: bool = False
) -> list[str]:
    """What the rider asked for that the ground could not give.

    Asking for a gravel-heavy ride in a city and getting tarmac is not a bug, but
    saying nothing about it looks like one. "Some pubs" named no number (`implied`),
    so two of the three the planner aimed for is not a shortfall; none is.
    """
    notes: list[str] = []
    if wanted and len(stops) < wanted:
        found = len(stops)
        if not found:
            notes.append("no stops like that nearby")
        elif not implied:
            notes.append(f"only {found} of those nearby")
    if prefs.gravelPreference >= 0.7 and max(_unpaved(route) for route in routes) < 0.1:
        notes.append("hardly any gravel around here")
    if prefs.hillTolerance >= 0.8 and max(route.elevation_gain_meters for route in routes) < 150:
        notes.append("not much to climb around here")
    return notes


def _keep_labels_honest(results: list[tuple[Route, dict[str, float]]]) -> None:
    """Renames a card whose promise the roads did not keep."""
    asked = next((route for route, _ in results if route.label == ASKED_LABEL), None)
    if asked is None:
        return
    for route, _ in results:
        claim = CLAIMS.get(route.label)
        if claim is None or claim(route, asked):
            continue
        route.label = "The long way" if route.distance_meters > asked.distance_meters * 1.05 else "Another way"


AREA_TAKEOVER_M = 2000.0
# "From Aragon Tower" moves the start only when the tower is not where the rider is.
ORIGIN_TAKEOVER_M = 300.0
NEIGHBOURHOOD_RIDE_KM = 14.0


# Names that mean "the one by the roundabout" rather than "the nice one".
CHAINS = (
    "costa",
    "starbucks",
    "pret a manger",
    "greggs",
    "caffe nero",
    "caffè nero",
    "mcdonald",
    "burger king",
    "kfc",
    "subway",
    "wetherspoon",
    "harvester",
    "toby carvery",
    "gail's",
    "leon",
    "itsu",
    "pizza express",
    "coffee republic",
)


def _appeal_m(poi: Discovery) -> float:
    """How far a rider would sensibly go out of their way for this place, in metres.

    OpenStreetMap has no ratings. What it has is how much somebody bothered to
    record: an article, a website, opening hours and no brand is somebody's café;
    a brand and nothing else is the one in the petrol station.
    """
    tags = poi.tags or {}
    appeal = 0.0
    if tags.get("wikidata") or tags.get("wikipedia"):
        appeal += 500
    if tags.get("website"):
        appeal += 200
    if tags.get("opening_hours"):
        appeal += 150
    if tags.get("outdoor_seating") == "yes":
        appeal += 100
    if tags.get("brand") or any(chain in (poi.name or "").lower() for chain in CHAINS):
        appeal -= 600
    return appeal


def _stop_categories(poi: dict[str, Any] | None) -> list[str]:
    """The kinds of stop asked for, best first ("3 cafés or somewhere cultural")."""
    if not poi:
        return []
    categories = [str(c) for c in (poi.get("categories") or []) if c]
    first = poi.get("category")
    if first and str(first) not in categories:
        categories.insert(0, str(first))
    return categories[:3]


def _quotas(count: int, kinds: int) -> list[int]:
    """How many stops each kind gets: three stops over two kinds is two, then one.

    Ranking by distance alone answered "3 cafés or somewhere cultural" with three
    sculptures and no café, because the sculptures sit on the riverside path and the
    cafés are a street inland. The kind named first gets the larger share; a kind
    with nothing nearby gives its share back.
    """
    base, extra = divmod(count, max(1, kinds))
    return [base + (1 if index < extra else 0) for index in range(max(1, kinds))]


async def _candidates(
    db: AsyncSession, latitude: float, longitude: float, radius_m: float, categories: list[str]
) -> list[Discovery]:
    """Places of any of the asked-for kinds, nearest first, each one once."""
    pool: list[Discovery] = []
    seen: set[Any] = set()
    for category in categories:
        for poi in await discoveries_nearby(db, latitude, longitude, radius_m, category=category, limit=200):
            if poi.id not in seen:
                seen.add(poi.id)
                pool.append(poi)
    return pool


async def _pick_stops(
    db: AsyncSession,
    latitude: float,
    longitude: float,
    categories: list[str],
    count: int,
    target_km: float,
    max_ring_m: float | None = None,
    appeal_weight: float = 0.25,
    *,
    exclude: set[Any] | frozenset[Any] = frozenset(),
    avoid_bearings: list[float] | None = None,
) -> list[Discovery]:
    """`count` places around a centre, spread around the compass.

    Picking the nearest few would send the rider up and down the same street; one
    per sector of the circle gives a loop that actually goes somewhere. When the
    rider named a neighbourhood, `max_ring_m` keeps the stops inside it — five pubs
    "in Notting Hill" must not be spread across half of London.

    "Other stops" (0.9.2) leaves out the first card's (`exclude`) and keeps at least
    a quarter of a sector from each of their bearings (`avoid_bearings`), so the
    second loop is the first turned half a sector rather than the same one again.
    """
    ring = max(400.0, target_km * 1000 / (2 * math.pi) * 0.8)
    if max_ring_m is not None:
        ring = min(ring, max_ring_m)
    candidates = [p for p in await _candidates(db, latitude, longitude, ring * 2.5, categories) if p.id not in exclude]
    if avoid_bearings:
        quarter = 360 / max(1, count) / 4
        away = [
            p
            for p in candidates
            if all(
                _bearing_gap(bearing_deg(latitude, longitude, p.latitude, p.longitude), b) >= quarter
                for b in avoid_bearings
            )
        ]
        candidates = away or candidates
    if not candidates:
        return []
    spread = 360 / count * 0.6
    chosen: list[Discovery] = []
    for category, quota in zip(categories, _quotas(count, len(categories)), strict=False):
        _take_around(
            latitude,
            longitude,
            [p for p in candidates if p.category == category],
            quota,
            ring,
            spread,
            chosen,
            appeal_weight,
        )
    if len(chosen) < count:
        _take_around(latitude, longitude, candidates, count - len(chosen), ring, spread, chosen, appeal_weight)
    return _tour(latitude, longitude, chosen)


def _take_around(
    latitude: float,
    longitude: float,
    candidates: list[Discovery],
    count: int,
    ring: float,
    spread: float,
    chosen: list[Discovery],
    appeal_weight: float = 0.25,
) -> None:
    """Appends up to `count` places near the ring, each in a direction of its own,
    weighing what OpenStreetMap knows about a place against the detour to it."""
    taken = {poi.id for poi in chosen}
    added = 0
    for poi in sorted(
        candidates,
        key=lambda p: (
            abs(haversine_m(latitude, longitude, p.latitude, p.longitude) - ring) - appeal_weight * _appeal_m(p)
        ),
    ):
        if added == count:
            return
        if poi.id in taken:
            continue
        bearing = bearing_deg(latitude, longitude, poi.latitude, poi.longitude)
        if all(
            _bearing_gap(bearing, bearing_deg(latitude, longitude, c.latitude, c.longitude)) >= spread for c in chosen
        ):
            chosen.append(poi)
            taken.add(poi.id)
            added += 1


def _tour(latitude: float, longitude: float, stops: list[Discovery]) -> list[Discovery]:
    """Always head for the nearest stop not yet visited: a short loop instead of a zigzag."""
    remaining = list(stops)
    ordered: list[Discovery] = []
    lat, lon = latitude, longitude
    while remaining:
        nearest = min(remaining, key=lambda p: haversine_m(lat, lon, p.latitude, p.longitude))
        remaining.remove(nearest)
        ordered.append(nearest)
        lat, lon = nearest.latitude, nearest.longitude
    return ordered


def _bearing_gap(a: float, b: float) -> float:
    gap = abs(a - b) % 360
    return min(gap, 360 - gap)


def _leg_frame(
    latitude: float, longitude: float, start: Coordinate, end: Coordinate
) -> tuple[float, float, float, float]:
    """The point and the leg's end in metres east and north of the leg's start.

    Flat-earth projection around the leg's middle: over the length of a bike ride
    the error is a few metres, which a 600 m corridor does not care about.
    """
    lon_scale = math.cos(math.radians((start.latitude + end.latitude) / 2)) * 111_320.0
    px = (longitude - start.longitude) * lon_scale
    py = (latitude - start.latitude) * 110_540.0
    bx = (end.longitude - start.longitude) * lon_scale
    by = (end.latitude - start.latitude) * 110_540.0
    return px, py, bx, by


def _signed_offset(latitude: float, longitude: float, start: Coordinate, end: Coordinate) -> tuple[float, float]:
    """Metres to the left (+) or right (−) of the line through start and end, and how
    far along it the point falls (0 at the start, 1 at the end; outside either end
    it runs past 0..1). Which side a stop is on decides whether it is on the way out
    or the way back of a loop."""
    px, py, bx, by = _leg_frame(latitude, longitude, start, end)
    length_sq = bx * bx + by * by
    if length_sq == 0:
        return math.hypot(px, py), 0.0
    return (bx * py - by * px) / math.sqrt(length_sq), (px * bx + py * by) / length_sq


def _distance_to_leg(latitude: float, longitude: float, start: Coordinate, end: Coordinate) -> tuple[float, float]:
    """Metres from the point to the start→end segment, and how far along it falls (0..1)."""
    signed, along = _signed_offset(latitude, longitude, start, end)
    clamped = max(0.0, min(1.0, along))
    if clamped == along:
        return abs(signed), along
    px, py, bx, by = _leg_frame(latitude, longitude, start, end)
    return math.hypot(px - bx * clamped, py - by * clamped), clamped


def _offset_point(start: Coordinate, end: Coordinate, along: float, signed_m: float) -> tuple[float, float]:
    """(lat, lon) `along` the start→end line and `signed_m` metres to its left (+) or right (−)."""
    lon_scale = math.cos(math.radians((start.latitude + end.latitude) / 2)) * 111_320.0
    bx = (end.longitude - start.longitude) * lon_scale
    by = (end.latitude - start.latitude) * 110_540.0
    length = math.hypot(bx, by) or 1.0
    x = bx * along - by / length * signed_m
    y = by * along + bx / length * signed_m
    return start.latitude + y / 110_540.0, start.longitude + x / lon_scale


async def _pick_stops_between(
    db: AsyncSession,
    start: Coordinate,
    destination: Coordinate,
    categories: list[str],
    count: int,
    appeal_weight: float = 0.25,
    *,
    side: int | None = None,
    exclude: set[Any] | frozenset[Any] = frozenset(),
) -> list[Discovery]:
    """`count` stops strung along the way from the rider to a place.

    A ride to somewhere is not a loop, so spreading the stops around the compass
    (`_pick_stops`) would send the rider backwards. These come out of a corridor
    along the line, one per stretch of the way, in the order they are reached.
    `side` keeps them to one side of the line and `exclude` leaves some out: the
    "Other stops" card (0.9.2).
    """
    direct = haversine_m(start.latitude, start.longitude, destination.latitude, destination.longitude)
    pool = await _candidates(
        db,
        (start.latitude + destination.latitude) / 2,
        (start.longitude + destination.longitude) / 2,
        max(2500.0, direct * 0.8),
        categories,
    )
    pool = [p for p in pool if p.id not in exclude]
    if side is not None:
        pool = [p for p in pool if (_signed_offset(p.latitude, p.longitude, start, destination)[0] > 0) == (side > 0)]
    measured = [(*_distance_to_leg(poi.latitude, poi.longitude, start, destination), poi) for poi in pool]
    # A short ride has a short corridor, and three cafés within 600 m of a 1.5 km line
    # is asking a lot of one neighbourhood. Rather than answer "none", give ground:
    # a café 1 km off the way is a minute's detour, and the card says what it costs.
    along: list[tuple[float, float, Discovery]] = []
    for corridor in (max(600.0, direct * 0.2), max(1200.0, direct * 0.35), 2500.0):
        along = [(progress, offset, poi) for offset, progress, poi in measured if offset <= corridor]
        if len(along) >= count:
            break
    if not along:
        return []
    chosen: list[tuple[float, Discovery]] = []
    for category, quota in zip(categories, _quotas(count, len(categories)), strict=False):
        _take_along([c for c in along if c[2].category == category], quota, chosen, appeal_weight)
    if len(chosen) < count:
        _take_along(along, count - len(chosen), chosen, appeal_weight)
    return [poi for _, poi in sorted(chosen, key=lambda c: c[0])]


async def _pick_stops_loop(
    db: AsyncSession,
    start: Coordinate,
    destination: Coordinate,
    categories: list[str],
    count: int,
    appeal_weight: float = 0.25,
    *,
    exclude: set[Any] | frozenset[Any] = frozenset(),
    swap: bool = False,
) -> tuple[list[Discovery], list[Discovery], int]:
    """`count` stops for a ride out to a place and back another way.

    ⌈N/2⌉ go on the way out, on the side of the line with more to choose from, in
    the order they are reached; ⌊N/2⌋ on the way back, on the other side, in the
    order they are reached coming home. Strung along the line instead
    (`_pick_stops_between`), every pub sat on the way out and the way back had no
    reason to go anywhere else. Stops about 0.15× the straight distance off the line
    (400–1,500 m) are preferred, so the two halves stay apart.

    `swap` puts the way out on the other side ("Other stops", with the first card's
    stops in `exclude`). Returns (out, back, the side of the way out: +1 is left).
    """
    direct = haversine_m(start.latitude, start.longitude, destination.latitude, destination.longitude)
    pool = await _candidates(
        db,
        (start.latitude + destination.latitude) / 2,
        (start.longitude + destination.longitude) / 2,
        max(2500.0, direct * 0.8),
        categories,
    )
    ideal = shapes.stop_offset_m(direct)
    measured: list[tuple[float, float, Discovery]] = []
    for poi in pool:
        if poi.id in exclude:
            continue
        signed, along = _signed_offset(poi.latitude, poi.longitude, start, destination)
        if 0.05 <= along <= 0.95:
            measured.append((signed, along, poi))
    sides: dict[int, list[tuple[float, float, Discovery]]] = {1: [], -1: []}
    for corridor in (max(600.0, direct * 0.2), max(1200.0, direct * 0.35), 2500.0):
        sides = {
            side: [
                (along, abs(abs(signed) - ideal), poi)
                for signed, along, poi in measured
                if (signed > 0) == (side > 0) and abs(signed) <= corridor
            ]
            for side in (1, -1)
        }
        if len(sides[1]) + len(sides[-1]) >= count:
            break
    out_side = 1 if len(sides[1]) >= len(sides[-1]) else -1
    if swap:
        out_side = -out_side
    n_out, n_back = (count + 1) // 2, count // 2
    out = _take_side(sides[out_side], categories, n_out, appeal_weight)
    back = _take_side(sides[-out_side], categories, n_back, appeal_weight)
    if len(back) < n_back:
        # The far side is short: the way out carries the rest, and the way back is
        # pulled wide by an offset point instead.
        taken = {poi.id for _, poi in out}
        spare = [c for c in sides[out_side] if c[2].id not in taken]
        out += _take_side(spare, categories, n_back - len(back), appeal_weight)
    elif len(out) < n_out:
        taken = {poi.id for _, poi in back}
        spare = [c for c in sides[-out_side] if c[2].id not in taken]
        back += _take_side(spare, categories, n_out - len(out), appeal_weight)
    return (
        [poi for _, poi in sorted(out, key=lambda c: c[0])],
        [poi for _, poi in sorted(back, key=lambda c: -c[0])],
        out_side,
    )


def _take_side(
    entries: list[tuple[float, float, Discovery]], categories: list[str], count: int, appeal_weight: float
) -> list[tuple[float, Discovery]]:
    """Up to `count` of these, shared between the kinds asked for (`_quotas`)."""
    chosen: list[tuple[float, Discovery]] = []
    if count <= 0 or not entries:
        return chosen
    for category, quota in zip(categories, _quotas(count, len(categories)), strict=False):
        _take_along([c for c in entries if c[2].category == category], quota, chosen, appeal_weight)
    if len(chosen) < count:
        _take_along(entries, count - len(chosen), chosen, appeal_weight)
    return chosen


async def _anchor(db: AsyncSession, latitude: float, longitude: float) -> tuple[float, float] | None:
    """The nearest place within 400 m that sits on a street, so a point placed by
    arithmetic lands on a road and not in the river or the middle of a park."""
    for poi in await discoveries_nearby(db, latitude, longitude, shapes.OFFSET_ANCHOR_M, limit=30):
        if poi.category not in ("NATURE", "TRAIL", "VIEWPOINT"):
            return poi.latitude, poi.longitude
    return None


async def _offset_spot(
    db: AsyncSession, start: Coordinate, destination: Coordinate, side: int, factor: float
) -> tuple[float, float]:
    """The offset point for a way back: off the middle of the line, on `side`, moved
    onto a place nearby when there is one (the engine gets a 400 m search cutoff)."""
    direct = haversine_m(start.latitude, start.longitude, destination.latitude, destination.longitude)
    spot = _offset_point(start, destination, 0.5, side * shapes.offset_distance_m(direct, factor))
    return await _anchor(db, *spot) or spot


async def _return_side(db: AsyncSession, start: Coordinate, destination: Coordinate, seed: int) -> int:
    """Which side the way back goes when no stop decides it: one with a place to aim
    for, the seed's choice when both or neither have one."""
    direct = haversine_m(start.latitude, start.longitude, destination.latitude, destination.longitude)
    preferred = 1 if seed % 2 == 0 else -1
    for side in (preferred, -preferred):
        spot = _offset_point(start, destination, 0.5, side * shapes.offset_distance_m(direct, shapes.OFFSET_FACTOR))
        if await _anchor(db, *spot) is not None:
            return side
    return preferred


def _take_along(
    along: list[tuple[float, float, Discovery]],
    count: int,
    chosen: list[tuple[float, Discovery]],
    appeal_weight: float = 0.25,
) -> None:
    """Appends up to `count` of these, one per stretch of the way, each the best of
    its stretch; what is left over comes from nearest the line.

    "Best" sets the detour a stop costs against what OpenStreetMap knows about it,
    so "a nice cafe" can walk past the chain on the corner.
    """
    taken = {poi.id for _, poi in chosen}
    start = len(chosen)

    def cost(entry: tuple[float, float, Discovery]) -> float:
        return entry[1] - appeal_weight * _appeal_m(entry[2])

    for band in range(count):
        low, high = band / count, (band + 1) / count
        in_band = [c for c in along if low <= c[0] < high and c[2].id not in taken]
        if in_band:
            progress, _, poi = min(in_band, key=cost)
            taken.add(poi.id)
            chosen.append((progress, poi))
    for progress, _, poi in sorted(along, key=cost):
        if len(chosen) - start >= count:
            return
        if poi.id not in taken:
            taken.add(poi.id)
            chosen.append((progress, poi))


@dataclass
class _Plan:
    """What every card of one plan shares: who rides, from where to where, and how
    the cards are measured."""

    db: AsyncSession
    settings: Settings
    engine: RoutingEngine
    user: User
    quest: QuestInstance | None
    bike: Bike | None
    bike_type: str
    allow_gravel: bool
    allow_trails: bool
    on_foot: bool
    activity: str
    origin: Coordinate  # where the rider is
    start: Coordinate  # where the ride starts
    destination: Coordinate | None
    via: list[Coordinate]
    waypoints: list[Coordinate]
    targets: QuestTargets
    loop: bool
    target_km: float
    cfg: dict[str, Any]
    rider: RiderLimits
    known: dict[str, str]
    poi_candidates: list[Discovery]
    seed_base: int
    details: bool = True
    # Cards as shapes (0.9.2, flag `route_shapes`): loops measured for retracing,
    # new ground counted once per tile.
    shaped: bool = False

    @property
    def profile(self) -> str:
        return "foot" if self.on_foot else PROFILE_FOR_BIKE.get(self.bike_type, "hybrid")

    @property
    def speed_mps(self) -> float:
        kmh = ASSUMED_SPEED_KMH[self.activity] if self.on_foot else self.cfg["assumedSpeedKmh"].get(self.bike_type, 15)
        return kmh / 3.6


def _points_for(plan: _Plan, variant: Variant) -> list[tuple[float, float]]:
    """The points a card goes through, in order: start, quest targets, stops, the
    named places, the planner's waypoints, the finish, and home again on a loop."""
    points = [(plan.start.latitude, plan.start.longitude)]
    for lat, lon, _ in plan.targets.points:
        points.append((lat, lon))
    for stop in variant.stops:
        points.append((stop.latitude, stop.longitude))
    # In the order the rider said them, and before the finish: "the Moby Dick
    # then the tower" is a sequence, not a set.
    for point in plan.via:
        points.append((point.latitude, point.longitude))
    for wp in plan.waypoints:
        points.append((wp.latitude, wp.longitude))
    if plan.destination is not None:
        points.append((plan.destination.latitude, plan.destination.longitude))
        # "to the tower and back" — the way home is a second leg, not a U-turn.
        if plan.loop:
            points.append(points[0])
    elif plan.loop and len(points) > 1:
        points.append(points[0])
    return points


def _request_for(
    plan: _Plan, variant: Variant, index: int, points: list[tuple[float, float]], **overrides: Any
) -> EngineRequest:
    """The engine request for one card: its points, its costing, its seed."""
    prefs = variant.prefs
    distance_m = plan.target_km * 1000 * variant.distance_factor
    custom_model = (
        None if plan.on_foot else build_custom_model(prefs, plan.bike_type, plan.allow_gravel, plan.allow_trails)
    )
    round_trip = distance_m if (plan.loop and len(points) == 1) else None
    heading = None
    if round_trip and plan.targets.points:
        heading = bearing_deg(
            plan.origin.latitude,
            plan.origin.longitude,
            plan.targets.points[0][0],
            plan.targets.points[0][1],
        )
    fields: dict[str, Any] = {
        "points": points,
        "profile": plan.profile,
        "round_trip_distance_m": round_trip,
        "seed": plan.seed_base + index * 17,
        "custom_model": custom_model
        if (plan.engine.name == "synthetic" or custom_model is None)
        else strip_internal(custom_model),
        "heading": heading,
        "costing": valhalla_costing(
            prefs,
            plan.bike_type,
            plan.allow_gravel,
            plan.allow_trails,
            plan.activity,
            living_streets=plan.shaped and variant.label == ASKED_LABEL,
        ),
        "activity": plan.activity,
        "details": plan.details,
    }
    return EngineRequest(**{**fields, **overrides})


async def _route_for(plan: _Plan, request: EngineRequest, label: str) -> list[EngineRoute]:
    """The engine's answer, or nothing when it has none (the card is skipped)."""
    try:
        return await plan.engine.route(request) or []
    except RoutingUnavailable as exc:
        log.error(EVENT_ROUTE_GENERATION_FAILED, label=label, error=str(exc))
        return []


def _keep(
    plan: _Plan,
    variant: Variant,
    er: EngineRoute,
    request: EngineRequest,
    *,
    label: str | None = None,
    extra: dict[str, Any] | None = None,
    retrace: float | None = None,
) -> tuple[Route, dict[str, float]]:
    """An engine route as a card: measured, its stops attached, scored, stored."""
    label = label or variant.label
    prefs = variant.prefs
    coords = er.coordinates
    surface = surface_composition(coords, er.details.get("surface"))
    cycle = cycleway_fraction(coords, er.details.get("road_class"), er.details.get("bike_network"))
    traffic = traffic_exposure(coords, er.details.get("road_class"))
    new_fraction = _new_territory_fraction(coords, plan.known, plan.settings.h3_resolution, unique=plan.shaped)
    coverage = _coverage(coords, plan.targets)
    speed_mps = plan.speed_mps
    pois = attach_pois(
        coords,
        plan.poi_candidates,
        speed_mps=speed_mps,
        preferred_category=(prefs.poi or {}).get("category"),
        preferred_position=(prefs.poi or {}).get("preferredPosition"),
        required_ids={str(stop.id) for stop in variant.stops},
    )
    route = _route_row(
        user=plan.user,
        quest=plan.quest,
        bike_id=plan.bike.id if plan.bike else None,
        label=label,
        profile=request.profile,
        activity=plan.activity,
        er=er,
        speed_mps=speed_mps,
        pois=[p.to_dict() for p in pois],
        request={
            "preferences": prefs.to_dict(),
            "label": label,
            "targetKm": plan.target_km,
            "loop": plan.loop,
            # Surface and traffic below are defaults, not measurements.
            **({"detailsMissing": True} if not er.details else {}),
            **(extra or {}),
        },
        surface=surface,
        cycleway=cycle,
        traffic=traffic,
        new_fraction=new_fraction,
        coverage=coverage,
    )
    metrics = RouteMetrics(
        distance_m=er.distance_m,
        elevation_gain_m=route.elevation_gain_meters,
        max_gradient_percent=route.max_gradient_percent,
        surface=surface,
        cycleway_fraction=cycle,
        traffic_exposure=traffic,
        new_territory_fraction=new_fraction,
        quest_objective_coverage=coverage,
        poi_count=len(pois),
        scenic_fraction=surface.get("gravel", 0) * 0.5 + surface.get("trail", 0) * 0.5 + cycle * 0.3,
        retrace=retrace,
    )
    score, components = score_route(metrics, prefs, plan.rider, plan.target_km * 1000)
    route.score = score
    route.request = {**route.request, "scoreComponents": components}
    plan.db.add(route)
    return route, components


async def _legacy_cards(plan: _Plan, variants: list[Variant]) -> tuple[list[tuple[Route, dict[str, float]]], list[str]]:
    """One engine request per variant; a path that came back twice is one card."""
    results: list[tuple[Route, dict[str, float]]] = []
    seen_paths: dict[str, str] = {}
    same_road: list[str] = []
    for index, variant in enumerate(variants):
        points = _points_for(plan, variant)
        request = _request_for(plan, variant, index, points)
        engine_routes = await _route_for(plan, request, variant.label)
        if not engine_routes:
            continue
        er = engine_routes[0]
        polyline = encode_polyline((c[1], c[0]) for c in er.coordinates)
        if polyline in seen_paths:
            # Short A→B trips often give every label the same path; one card is
            # enough, but two cards becoming one deserves a word.
            same_road.append(f"{variant.label} and {seen_paths[polyline]} are the same road here")
            continue
        seen_paths[polyline] = variant.label
        results.append(_keep(plan, variant, er, request))
    return results, same_road


@dataclass
class _Card:
    """A route chosen for a card, before it is measured and stored."""

    label: str
    variant: Variant
    er: EngineRoute
    request: EngineRequest
    direct: bool = False
    self_overlap: float | None = None


class _Cards:
    """The cards of one plan as they are chosen: what is kept, what the engine sent
    back spare, and what to say about a card that could not be offered."""

    def __init__(self, plan: _Plan) -> None:
        self.plan = plan
        self.kept: list[_Card] = []
        # Alternates no card has used yet: a card from these costs no request.
        self.pool: list[tuple[EngineRoute, EngineRequest, Variant]] = []
        self.dropped: list[tuple[bool, str]] = []  # (was it Direct, why)

    def affordable(self, calls: int = 1) -> bool:
        """Whether `calls` more requests fit, keeping one for each card's details."""
        owed = sum(1 for card in self.kept if not card.er.details) + 1
        return budget.allows(calls + owed)

    def alike(self, card: _Card) -> str | None:
        """Why this card is not another way to ride it, or None when it is."""
        found = shapes.duplicate_of(
            card.er.coordinates,
            card.er.distance_m,
            [(str(i), k.er.coordinates, k.er.distance_m) for i, k in enumerate(self.kept)],
            direct=card.direct,
        )
        if found is None:
            return None
        other = self.kept[int(found[0])]
        if card.direct and other.variant.stops:
            return shapes.stops_add_only_note(other.er.distance_m - card.er.distance_m)
        return f"{card.label} and {other.label} are the same road here"

    def notes(self) -> list[str]:
        out: list[str] = []
        fewer = False
        for direct, why in self.dropped:
            if direct:
                out.append(why)
            elif not fewer:
                out.append(shapes.fewer_cards_note(len(self.kept)))
                fewer = True
        return out


@dataclass
class _Candidate:
    """One way to fill a card; a card's candidates are tried in order until one comes
    back different enough from the cards already kept."""

    make: Callable[[_Cards, bool], Awaitable[_Card | None]]
    free: bool = False  # from routes already fetched: costs no request


async def _fill(cards: _Cards, slots: list[list[_Candidate]]) -> None:
    """Each card from the first of its candidates that is another way to ride it.
    The first card is never refused; the rest are tried while the budget lasts."""
    for number, slot in enumerate(slots):
        rejected: list[tuple[bool, str]] = []
        for position, candidate in enumerate(slot):
            first = number == 0 and position == 0 and not cards.kept
            if not (first or candidate.free or cards.affordable()):
                continue
            card = await candidate.make(cards, first)
            if card is None:
                continue
            why = cards.alike(card)
            if why is None:
                cards.kept.append(card)
                break
            rejected.append((card.direct, why))
        else:
            if rejected:
                cards.dropped.append(rejected[0])


async def _attempt(
    plan: _Plan, request: EngineRequest, label: str
) -> tuple[list[EngineRoute], RoutingUnavailable | None]:
    try:
        return (await plan.engine.route(request)) or [], None
    except RoutingUnavailable as exc:
        log.error(EVENT_ROUTE_GENERATION_FAILED, label=label, error=str(exc)[:300])
        return [], exc


async def _shape_route(
    cards: _Cards, variant: Variant, index: int, shape: shapes.LoopShape, label: str, first: bool
) -> tuple[EngineRoute, EngineRequest, shapes.LoopShape] | None:
    """The engine's way round a loop shape, giving ground once at each failure: a
    destination at the end of a dead end needs its U-turn back (`downgraded`), and
    an offset point the engine cannot reach is left out."""
    plan = cards.plan
    tried_downgrade = tried_without_offset = False
    while True:
        if not first and not cards.affordable():
            return None
        first = False
        request = _request_for(
            plan,
            variant,
            index,
            shape.points(),
            location_types=shape.types(),
            search_cutoff_m=shape.cutoffs(),
            details=False,
        )
        routes, error = await _attempt(plan, request, label)
        if routes:
            return routes[0], request, shape
        if error is not None and error.no_path and shape.through and not tried_downgrade:
            tried_downgrade = True
            shape = shape.downgraded()
            continue
        if shape.offset is not None and not tried_without_offset:
            tried_without_offset = True
            shape = shape.without_offset()
            continue
        return None


async def _loop_card(
    cards: _Cards,
    variant: Variant,
    index: int,
    label: str,
    shape: shapes.LoopShape,
    first: bool,
    *,
    direct: bool = False,
) -> _Card | None:
    """A loop out to a destination and back another way, checked twice: that the
    offset point was reached, and that the way back is not the way out again."""
    plan = cards.plan
    got = await _shape_route(cards, variant, index, shape, label, first)
    if got is None:
        return None
    er, request, shape = got
    turn = shapes.turn_near(er.coordinates, er.leg_boundaries, shape.destination)
    if shapes.snapped_wrong(er.coordinates, turn, shape) and cards.affordable() and plan.destination is not None:
        # The offset point landed off its road (the river, a park): mirrored, or
        # nearer the line when the other side carries the way out's stops; then
        # without it (`_shape_route` drops it when the retry fails).
        side, factor = shape.offset_side, shape.offset_factor
        if shape.out_stops:
            factor *= 0.6
        else:
            side = -side
        spot = await _offset_spot(plan.db, plan.start, plan.destination, side, factor)
        retry = await _shape_route(
            cards, variant, index, replace(shape, offset=spot, offset_side=side, offset_factor=factor), label, False
        )
        if retry is not None:
            again = shapes.turn_near(retry[0].coordinates, retry[0].leg_boundaries, shape.destination)
            if not shapes.snapped_wrong(retry[0].coordinates, again, retry[2]):
                (er, request, shape), turn = retry, again
            elif cards.affordable():
                plain = await _shape_route(cards, variant, index, shape.without_offset(), label, False)
                if plain is not None:
                    er, request, shape = plain
                    turn = shapes.turn_near(er.coordinates, er.leg_boundaries, shape.destination)
    retrace = overlap.self_overlap(er.coordinates, turn)
    if retrace > shapes.SELF_OVERLAP_MAX and cards.affordable():
        # The way back found the way out anyway: ask for the way back alone, kept off
        # points along the way out, and join the two.
        out = head_of(er, turn)
        avoid = overlap.exclusion_samples(
            out.coordinates,
            avoid=[*shape.out_stops, *shape.via, *shape.back_stops],
            manoeuvres=[(i["latitude"], i["longitude"]) for i in out.instructions if i.get("latitude") is not None],
        )
        if avoid:
            points, types, cutoffs = shape.back()
            back_request = _request_for(
                plan,
                variant,
                index,
                points,
                location_types=types,
                search_cutoff_m=cutoffs,
                exclude_points=avoid,
                details=False,
            )
            routes, _ = await _attempt(plan, back_request, label)
            if routes:
                joined = join_routes(out, routes[0])
                joined_retrace = overlap.self_overlap(joined.coordinates, len(out.coordinates) - 1)
                if joined_retrace < retrace:
                    er, retrace = joined, joined_retrace
    return _Card(label, variant, er, request, direct=direct, self_overlap=retrace)


def _roles(variants: list[Variant]) -> tuple[Variant, Variant, Variant]:
    """The card that answers the request, the plain one, and the third."""
    plain = next((v for v in variants if v.label == DIRECT_LABEL), None)
    others = [v for v in variants if v is not plain] or list(variants)
    main = next((v for v in others if v.label == ASKED_LABEL), others[0])
    rest = [v for v in others if v is not main]
    third = rest[0] if rest else main
    if plain is None:
        plain = Variant(DIRECT_LABEL, main.prefs, [], 1.0)
    return main, plain, third


async def _main_loop_shape(
    db: AsyncSession,
    start: Coordinate,
    destination: Coordinate,
    via: list[Coordinate],
    out_stops: list[Discovery],
    back_stops: list[Discovery],
    out_side: int,
    seed: int,
) -> shapes.LoopShape:
    """The asked-for loop: the way out through its stops, the way back through the
    others, or pulled wide by an offset point on the far side when it has none."""
    side = -out_side if out_stops else await _return_side(db, start, destination, seed)
    shape = shapes.LoopShape(
        start=(start.latitude, start.longitude),
        destination=(destination.latitude, destination.longitude),
        out_stops=tuple((p.latitude, p.longitude) for p in out_stops),
        via=tuple((p.latitude, p.longitude) for p in via),
        back_stops=tuple((p.latitude, p.longitude) for p in back_stops),
        offset_side=side,
    )
    if not back_stops:
        shape = replace(shape, offset=await _offset_spot(db, start, destination, side, shapes.OFFSET_FACTOR))
    return shape


def _loop_destination_slots(
    plan: _Plan,
    variants: list[Variant],
    main_shape: shapes.LoopShape,
    categories: list[str],
    wanted: int,
    appeal_weight: float,
) -> list[list[_Candidate]]:
    """Three loops to the destination and back (docs/ROUTING.md, "Loops"):

    1. As asked: stops split by side, or an offset point on a way back without any.
    2. Direct: the cheapest loop, no stops, an offset point at 0.2×.
    3. Other stops on the other sides, when stops were asked for; else (or when
       those come back too alike) the long way, mirrored at 0.35×.
    """
    main, plain, third = _roles(variants)
    plain = _wider(plain)
    assert plan.destination is not None
    destination = plan.destination
    side = main_shape.offset_side
    chosen = list(main.stops)

    async def as_asked() -> tuple[shapes.LoopShape, list[Discovery]] | None:
        return main_shape, chosen

    async def cheapest() -> tuple[shapes.LoopShape, list[Discovery]] | None:
        spot = await _offset_spot(plan.db, plan.start, destination, side, shapes.DIRECT_OFFSET_FACTOR)
        return replace(
            main_shape,
            out_stops=(),
            back_stops=(),
            offset=spot,
            offset_factor=shapes.DIRECT_OFFSET_FACTOR,
            through=True,
        ), []

    async def other_stops() -> tuple[shapes.LoopShape, list[Discovery]] | None:
        out, back, out_side = await _pick_stops_loop(
            plan.db,
            plan.start,
            destination,
            categories,
            wanted,
            appeal_weight,
            exclude={p.id for p in chosen},
            swap=True,
        )
        if not out and not back:
            return None
        picked = [*out, *back]
        ids = {p.id for p in picked}
        plan.poi_candidates = [*picked, *(p for p in plan.poi_candidates if p.id not in ids)]
        shape = replace(
            main_shape,
            out_stops=tuple((p.latitude, p.longitude) for p in out),
            back_stops=tuple((p.latitude, p.longitude) for p in back),
            offset=None,
            offset_side=-out_side,
            offset_factor=shapes.OFFSET_FACTOR,
            through=True,
        )
        if not back:
            shape = replace(
                shape, offset=await _offset_spot(plan.db, plan.start, destination, -out_side, shapes.OFFSET_FACTOR)
            )
        return shape, picked

    async def long_way() -> tuple[shapes.LoopShape, list[Discovery]] | None:
        spot = await _offset_spot(plan.db, plan.start, destination, -side, shapes.LONG_OFFSET_FACTOR)
        return replace(
            main_shape,
            out_stops=(),
            back_stops=(),
            offset=spot,
            offset_side=-side,
            offset_factor=shapes.LONG_OFFSET_FACTOR,
            through=True,
        ), []

    def candidate(
        variant: Variant,
        index: int,
        label: str,
        build: Callable[[], Awaitable[tuple[shapes.LoopShape, list[Discovery]] | None]],
        *,
        direct: bool = False,
    ) -> _Candidate:
        async def make(cards: _Cards, first: bool) -> _Card | None:
            built = await build()
            if built is None:
                return None
            shape, stops = built
            return await _loop_card(cards, replace(variant, stops=stops), index, label, shape, first, direct=direct)

        return _Candidate(make)

    third_slot = [candidate(third, 2, shapes.OTHER_STOPS, other_stops)] if chosen and categories else []
    third_slot.append(candidate(third, 2, shapes.LONG_WAY, long_way))
    return [
        [candidate(main, 0, main.label, as_asked)],
        [candidate(plain, 1, plain.label, cheapest, direct=True)],
        third_slot,
    ]


# Direct's costing on Valhalla's narrow range: at most this quiet and this keen on
# cycle paths, which lifts `use_roads` from about 0.44 to 0.6.
DIRECT_TRAFFIC_AVERSION = 0.4
DIRECT_CYCLEWAY = 0.3


def _wider(variant: Variant) -> Variant:
    """Direct as the quick way, not the asked-for way again: busier roads and fewer
    cycle paths allowed than the rider's own preferences."""
    prefs = RoutePreferences(**variant.prefs.to_dict())
    prefs.trafficAversion = min(prefs.trafficAversion, DIRECT_TRAFFIC_AVERSION)
    prefs.cyclewayPreference = min(prefs.cyclewayPreference, DIRECT_CYCLEWAY)
    return replace(variant, prefs=prefs)


def _side_of(points: list[tuple[float, float]], start: Coordinate, end: Coordinate) -> int:
    """Which side of the start→end line these points mostly sit: +1 left, −1 right."""
    total = sum(_signed_offset(lat, lon, start, end)[0] for lat, lon in points)
    return 1 if total >= 0 else -1


async def _plain_card(
    cards: _Cards,
    variant: Variant,
    index: int,
    label: str,
    points: list[tuple[float, float]],
    first: bool,
    *,
    direct: bool = False,
    alternatives: int = 1,
    types: list[str] | None = None,
    cutoffs: list[float | None] | None = None,
) -> _Card | None:
    """A card through its points. Two points may ask for alternates, which go to the
    pool for a later card; a "through" point at a dead end gets its U-turn back."""
    plan = cards.plan
    request = _request_for(
        plan,
        variant,
        index,
        points,
        details=False,
        alternatives=alternatives if len(points) == 2 else 1,
        location_types=types,
        search_cutoff_m=cutoffs,
    )
    routes, error = await _attempt(plan, request, label)
    if not routes and error is not None and error.no_path and types and "through" in types and cards.affordable():
        request = downgraded(request)
        routes, _ = await _attempt(plan, request, label)
    if not routes:
        return None
    cards.pool.extend((alt, request, variant) for alt in routes[1:])
    retrace = overlap.self_overlap(routes[0].coordinates) if plan.loop else None
    return _Card(label, variant, routes[0], request, direct=direct, self_overlap=retrace)


def _plain(
    variant: Variant,
    index: int,
    label: str,
    points: list[tuple[float, float]],
    *,
    direct: bool = False,
    alternatives: int = 1,
) -> _Candidate:
    async def make(cards: _Cards, first: bool) -> _Card | None:
        return await _plain_card(cards, variant, index, label, points, first, direct=direct, alternatives=alternatives)

    return _Candidate(make)


def _pooled(label: str) -> _Candidate:
    """The alternate least like the cards already kept, from requests already made."""

    async def make(cards: _Cards, first: bool) -> _Card | None:
        if not cards.pool:
            return None

        def likeness(index: int) -> float:
            er = cards.pool[index][0]
            return max((overlap.similarity(er.coordinates, k.er.coordinates) for k in cards.kept), default=0.0)

        er, request, variant = cards.pool.pop(min(range(len(cards.pool)), key=likeness))
        retrace = overlap.self_overlap(er.coordinates) if cards.plan.loop else None
        return _Card(label, replace(variant, stops=[]), er, request, self_overlap=retrace)

    return _Candidate(make, free=True)


def _map_tap_slots(plan: _Plan, variants: list[Variant]) -> list[list[_Candidate]]:
    """A place tapped on the map, nothing typed: the quiet way and the direct way,
    each asking for the engine's alternates, and for the third card the alternate
    least like those two. Three cards from two requests."""
    assert plan.destination is not None
    plain = next((v for v in variants if v.label == DIRECT_LABEL), None)
    others = [v for v in variants if v is not plain] or list(variants)
    quiet = max(others, key=lambda v: v.prefs.trafficAversion)
    plain = _wider(plain or replace(quiet, label=DIRECT_LABEL))
    points = [(plan.start.latitude, plan.start.longitude), (plan.destination.latitude, plan.destination.longitude)]
    return [
        [_plain(quiet, 0, quiet.label, points, alternatives=3)],
        [_plain(plain, 1, DIRECT_LABEL, points, direct=True, alternatives=2)],
        [_pooled(shapes.ANOTHER_WAY)],
    ]


def _one_way_slots(
    plan: _Plan, variants: list[Variant], categories: list[str], wanted: int, appeal_weight: float
) -> list[list[_Candidate]]:
    """A ride to a place, as typed: as asked; Direct, asking for alternates; and a
    third that is another way there — through a point off the far side of the first
    card's line, else an alternate Direct's request brought back, else the stops on
    the other side of the line."""
    main, plain, third = _roles(variants)
    plain = replace(_wider(plain), stops=[])
    assert plan.destination is not None
    destination = plan.destination
    chosen = list(main.stops)

    async def corridor(cards: _Cards, first: bool) -> _Card | None:
        if cards.kept:
            coords = cards.kept[0].er.coordinates
            step = max(1, len(coords) // 60)
            side = -_side_of([(c[1], c[0]) for c in coords[::step]], plan.start, destination)
        else:
            side = 1 if plan.seed_base % 2 == 0 else -1
        spot = await _offset_spot(plan.db, plan.start, destination, side, shapes.DIRECT_OFFSET_FACTOR)
        via = [(p.latitude, p.longitude) for p in plan.via]
        points = [
            (plan.start.latitude, plan.start.longitude),
            spot,
            *via,
            (destination.latitude, destination.longitude),
        ]
        types = ["break", "through", *(["via"] * len(via)), "break"]
        cutoffs: list[float | None] = [None, shapes.OFFSET_CUTOFF_M, *([None] * (len(via) + 1))]
        return await _plain_card(
            cards, replace(third, stops=[]), 2, third.label, points, first, types=types, cutoffs=cutoffs
        )

    async def other_side(cards: _Cards, first: bool) -> _Card | None:
        side = -_side_of([(p.latitude, p.longitude) for p in chosen], plan.start, destination)
        picks = await _pick_stops_between(
            plan.db,
            plan.start,
            destination,
            categories,
            wanted,
            appeal_weight,
            side=side,
            exclude={p.id for p in chosen},
        )
        if not picks:
            return None
        ids = {p.id for p in picks}
        plan.poi_candidates = [*picks, *(p for p in plan.poi_candidates if p.id not in ids)]
        variant = replace(third, stops=picks)
        return await _plain_card(cards, variant, 2, shapes.OTHER_STOPS, _points_for(plan, variant), first)

    third_slot = [_Candidate(corridor), _pooled(shapes.ANOTHER_WAY)]
    if chosen and categories:
        third_slot.append(_Candidate(other_side))
    return [
        [_plain(main, 0, main.label, _points_for(plan, main))],
        [_plain(plain, 1, plain.label, _points_for(plan, plain), direct=True, alternatives=3)],
        third_slot,
    ]


def _loop_stops_slots(
    plan: _Plan,
    variants: list[Variant],
    categories: list[str],
    wanted: int,
    appeal_weight: float,
    max_ring_m: float | None,
) -> list[list[_Candidate]]:
    """A loop through stops: as asked; Direct through the nearer half of them (a
    round trip when that is none); and other stops, none of the first card's, turned
    half a sector — else the third costing through the same stops."""
    main, plain, third = _roles(variants)
    chosen = list(main.stops)
    start = plan.start
    nearest = sorted(chosen, key=lambda p: haversine_m(start.latitude, start.longitude, p.latitude, p.longitude))
    plain = replace(_wider(plain), stops=_tour(start.latitude, start.longitude, nearest[: len(chosen) // 2]))

    async def other_stops(cards: _Cards, first: bool) -> _Card | None:
        bearings = [bearing_deg(start.latitude, start.longitude, p.latitude, p.longitude) for p in chosen]
        picks = await _pick_stops(
            plan.db,
            start.latitude,
            start.longitude,
            categories,
            wanted,
            plan.target_km,
            max_ring_m=max_ring_m,
            appeal_weight=appeal_weight,
            exclude={p.id for p in chosen},
            avoid_bearings=bearings,
        )
        if not picks:
            return None
        ids = {p.id for p in picks}
        plan.poi_candidates = [*picks, *(p for p in plan.poi_candidates if p.id not in ids)]
        variant = replace(third, stops=picks)
        return await _plain_card(cards, variant, 2, shapes.OTHER_STOPS, _points_for(plan, variant), first)

    return [
        [_plain(main, 0, main.label, _points_for(plan, main))],
        [_plain(plain, 1, plain.label, _points_for(plan, plain), direct=True)],
        [_Candidate(other_stops), _plain(third, 2, third.label, _points_for(plan, third))],
    ]


async def _shaped_cards(
    plan: _Plan, slots: list[list[_Candidate]]
) -> tuple[list[tuple[Route, dict[str, float]]], list[_Card], list[str]]:
    """The cards from their candidates, then the surface details for the kept ones
    only: a card dropped as a duplicate costs one request, not two."""
    cards = _Cards(plan)
    await _fill(cards, slots)
    for card in cards.kept:
        if plan.details and not card.er.details and budget.allows():
            try:
                card.er = await plan.engine.details(card.er, card.request)
            except RoutingUnavailable as exc:
                log.warning("route_details_unavailable", label=card.label, error=str(exc)[:200])
    results = []
    for card, label in zip(cards.kept, shapes.unique_labels([c.label for c in cards.kept]), strict=True):
        extra = {} if card.self_overlap is None else {"selfOverlap": round(card.self_overlap, 3)}
        results.append(
            _keep(plan, card.variant, card.er, card.request, label=label, extra=extra, retrace=card.self_overlap)
        )
    return results, cards.kept, cards.notes()


async def generate(
    db: AsyncSession,
    settings: Settings,
    engine: RoutingEngine,
    llm: LLMClient,
    user: User,
    payload: RouteGenerateRequest,
    *,
    max_variants: int | None = None,
    details: bool = True,
) -> tuple[list[tuple[Route, dict[str, float]]], dict[str, Any] | None]:
    """`max_variants` is for callers that want one route and not a choice of three:
    every variant is an engine request, and a quest's own route needs only the first.

    One plan, one budget of engine requests (`budget.py`). `details=False` skips the
    surface and road-class request (the quest board's prefetch on Valhalla)."""
    with budget.plan_budget():
        return await _generate(db, settings, engine, llm, user, payload, max_variants=max_variants, details=details)


async def _generate(
    db: AsyncSession,
    settings: Settings,
    engine: RoutingEngine,
    llm: LLMClient,
    user: User,
    payload: RouteGenerateRequest,
    *,
    max_variants: int | None = None,
    details: bool = True,
) -> tuple[list[tuple[Route, dict[str, float]]], dict[str, Any] | None]:
    profile: RiderProfile = await get_rider_profile(db, user.id)
    # How the player moves: asked for, or however they usually do. On foot there is
    # no bike to consult; the pedestrian costing and shorter distances do the work.
    activity = normalise(payload.activity or profile.default_activity)
    on_foot = is_foot(activity)
    bike: Bike | None = None
    if not on_foot:
        if payload.bikeId is not None:
            bike = await db.get(Bike, payload.bikeId)
            if bike is None or bike.user_id != user.id:
                raise NotFound("That bike isn't in your list. Pick one of your bikes and try again.")
        else:
            bike = await default_bike(db, user.id)
    bike_type = bike.bike_type if bike else ("FOOT" if on_foot else "HYBRID")
    allow_gravel = bike.allow_gravel if bike else True
    allow_trails = bike.allow_trails if bike else on_foot

    quest: QuestInstance | None = None
    if payload.questId is not None:
        quest = await db.get(QuestInstance, payload.questId)
        if quest is None or quest.user_id != user.id:
            raise NotFound("We couldn't find that quest. It may have ended, so check the quest board.")
    targets = _quest_targets(quest)

    base_prefs = RoutePreferences(
        trafficAversion=1 - profile.traffic_tolerance,
        cyclewayPreference=profile.cycleway_preference,
        gravelPreference=profile.gravel_comfort if allow_gravel else 0.0,
        scenicPreference=0.6,
        hillTolerance=min(1.0, profile.max_preferred_gradient / 12),
    )
    # What this rider gets when they say nothing — the baseline the request is read
    # against, so the planner knows which preferences were a choice.
    usual_prefs = RoutePreferences(**base_prefs.to_dict())
    if payload.preferences:
        for k, v in payload.preferences.model_dump().items():
            setattr(base_prefs, k, v)
    parsed_dict: dict[str, Any] | None = None
    started = monotonic()
    if payload.request and settings.flags.get("nl_route_requests", True):
        parsed = await parse_request(payload.request, llm, base_prefs)
        base_prefs = parsed.preferences
        parsed_dict = {
            **parsed.preferences.to_dict(),
            "source": parsed.source,
            "matched": parsed.matched,
        }
    ms_parse = int((monotonic() - started) * 1000)
    shapes_on = is_enabled(settings, "route_shapes")

    # "From Aragon Tower to Westminster and back" names where the ride starts (0.9.2).
    # Resolved like the destination; it moves the start only when it is not where
    # the rider already is, and one nobody can find is said out loud.
    origin_start: Coordinate | None = None
    unresolved_origin: str | None = None
    if shapes_on and (base_prefs.origin or {}).get("query"):
        named_start = str(base_prefs.origin["query"])
        found = await geocode.resolve(
            settings, named_start, payload.origin.latitude, payload.origin.longitude, kind="point"
        )
        if found is None:
            unresolved_origin = named_start
            base_prefs.origin = None
        else:
            base_prefs.origin = {**base_prefs.origin, **found.to_dict()}
            if (
                haversine_m(payload.origin.latitude, payload.origin.longitude, found.latitude, found.longitude)
                > ORIGIN_TAKEOVER_M
            ):
                origin_start = Coordinate(latitude=found.latitude, longitude=found.longitude)
    else:
        base_prefs.origin = None
    if parsed_dict is not None:
        parsed_dict["origin"] = base_prefs.origin
        if base_prefs.origin is None:
            parsed_dict["matched"] = [m for m in parsed_dict["matched"] if not str(m).startswith("origin:")]

    # "Go to the Aragon Tower" names a finish line, not a neighbourhood, so it is
    # resolved as a point — a tower, a bridge, a pub all count — and becomes the
    # route's destination. A tap on the map (payload.destination) already is one.
    destination = payload.destination
    unresolved_destination: str | None = None
    if destination is None and (base_prefs.destination or {}).get("query"):
        wanted_place = str(base_prefs.destination["query"])
        found = await geocode.resolve(
            settings, wanted_place, payload.origin.latitude, payload.origin.longitude, kind="point"
        )
        if found is not None:
            destination = Coordinate(latitude=found.latitude, longitude=found.longitude)
            base_prefs.destination = {**base_prefs.destination, **found.to_dict()}
        else:
            unresolved_destination = wanted_place
            base_prefs.destination = None
    elif destination is not None and not (base_prefs.destination or {}).get("query"):
        base_prefs.destination = None
    if base_prefs.destination is None and parsed_dict is not None:
        parsed_dict["destination"] = None
        parsed_dict["matched"] = [m for m in parsed_dict["matched"] if not str(m).startswith("destination:")]
    elif parsed_dict is not None:
        parsed_dict["destination"] = base_prefs.destination

    # "Visit the Moby Dick pub then to Aragon Tower" names a place to pass through,
    # not a kind of place: no other pub will do, so it is a waypoint. Each is looked
    # up the way the destination is, and one the geocoder cannot place is named in
    # the notes rather than quietly dropped from the ride.
    via: list[Coordinate] = []
    unresolved_via: list[str] = []
    resolved_via: list[dict[str, Any]] = []
    for place in base_prefs.via or []:
        found = await geocode.resolve(
            settings, str(place["query"]), payload.origin.latitude, payload.origin.longitude, kind="point"
        )
        if found is None:
            unresolved_via.append(str(place["query"]))
            continue
        via.append(Coordinate(latitude=found.latitude, longitude=found.longitude))
        resolved_via.append({**place, **found.to_dict()})
    base_prefs.via = resolved_via or None
    if parsed_dict is not None:
        parsed_dict["via"] = base_prefs.via
        kept = {p["query"] for p in resolved_via}
        parsed_dict["matched"] = [
            m for m in parsed_dict["matched"] if not str(m).startswith("via:") or str(m)[4:] in kept
        ]

    # A named place ("a ride in Notting Hill") moves the ride; the rider's own position
    # still seeds the alternatives and counts new territory.
    area = None
    unresolved_place: str | None = None
    if (base_prefs.area or {}).get("query") and destination is None:
        area = await geocode.resolve(
            settings, str(base_prefs.area["query"]), payload.origin.latitude, payload.origin.longitude
        )
        if area is None and settings.geocoding_enabled:
            unresolved_place = str(base_prefs.area["query"])
    if area is None:
        # The rules parser guesses a place from whatever is left of the sentence;
        # the geocoder is the judge. A guess it threw out was never understood.
        base_prefs.area = None
        if parsed_dict is not None:
            parsed_dict["area"] = None
            parsed_dict["matched"] = [m for m in parsed_dict["matched"] if not str(m).startswith("area:")]
    start = payload.origin
    if area is not None:
        base_prefs.area = {**(base_prefs.area or {}), **area.to_dict()}
        if (
            haversine_m(payload.origin.latitude, payload.origin.longitude, area.latitude, area.longitude)
            > AREA_TAKEOVER_M
        ):
            start = Coordinate(latitude=area.latitude, longitude=area.longitude)
        # The rider may never have been there, so its places may not be imported yet.
        await osm_import.ensure_pois(settings, area.latitude, area.longitude)
        if parsed_dict is not None:
            parsed_dict["area"] = base_prefs.area
            if start is not payload.origin:
                parsed_dict["startsAt"] = area.to_dict()
    if origin_start is not None and base_prefs.origin is not None:
        start = origin_start
        if parsed_dict is not None:
            parsed_dict["startsAt"] = {key: base_prefs.origin[key] for key in ("name", "latitude", "longitude")}

    # What the rider wrote wins over the slider: the slider always has a value, while
    # typing "a 12 km loop" is a deliberate act, and a 22 km answer to it is a lie.
    target_km = (
        (base_prefs.distanceKm or {}).get("target")
        or payload.distanceTargetKm
        or (quest.recommended_distance_km if quest else None)
        or comfortable_distance_km(profile, activity)
    )
    if area is not None and payload.distanceTargetKm is None and not (base_prefs.distanceKm or {}).get("target"):
        target_km = min(target_km, NEIGHBOURHOOD_RIDE_KM * DISTANCE_SCALE.get(activity, 1.0))

    loop = (
        payload.loop
        if payload.loop is not None
        else (base_prefs.loop if base_prefs.loop is not None else destination is None)
    )
    # Cards as shapes (0.9.2): every plan but a quest's or one through the planner's
    # own waypoints (a rune's shape, a sealed quest), which keep their points.
    shaped = shapes_on and quest is None and not payload.waypoints and not targets.points
    loop_destination = shaped and destination is not None and bool(loop)
    # Riding somewhere has its own length: the way there and, if they asked to come
    # home, the way back. Scoring against the rider's usual 30 km would mark a 6 km
    # trip to the tower down for being short.
    #
    # Only when the destination came out of the sentence. Picking a place on the map
    # and then setting a distance is a rider asking for the long way round, and the
    # slider is theirs; typing "go to the tower" never touched it.
    typed_destination = payload.destination is None and destination is not None
    if typed_destination and not (base_prefs.distanceKm or {}).get("target"):
        # Through the named places, not straight there: a pub two kilometres off the
        # line makes the ride longer, and scoring it against the direct distance
        # marks the only route that does what was asked for as too long.
        legs = [start, *via, destination]
        direct_km = (
            sum(
                haversine_m(a.latitude, a.longitude, b.latitude, b.longitude)
                for a, b in zip(legs, legs[1:], strict=False)
            )
            / 1000
        )
        target_km = max(2.0, direct_km * (2.4 if loop else 1.25))

    cfg = scoring_config()
    if on_foot:
        labels = list(cfg["activityLabels"].get(activity, cfg["activityLabels"]["WALK"]))
    else:
        labels = list(cfg["bikeDefaultLabels"].get(bike_type, cfg["bikeDefaultLabels"]["OTHER"]))
    if base_prefs.gravelPreference > 0.7 and "Gravel" not in labels and allow_gravel and not on_foot:
        labels[-1] = "Gravel"
    if base_prefs.hillTolerance > 0.8 and "Challenge" not in labels:
        labels[-1] = "Challenge"
    if destination is not None and "Direct" not in labels:
        labels[0] = "Direct"

    # "with about 5 pubs" is a promise: put them on the line rather than hoping the
    # route happens to pass some.
    requested_stops: list[Discovery] = []
    wanted = int((base_prefs.poi or {}).get("count") or 0)
    categories = _stop_categories(base_prefs.poi)
    count_implied = False
    if shapes_on and categories and not wanted:
        # "Checking out some pubs" names no number, and used to get none at all: a
        # loop gets three, a ride one way two.
        wanted = 3 if loop else 2
        count_implied = True
        if parsed_dict is not None and parsed_dict.get("poi"):
            parsed_dict["poi"]["countImplied"] = True
    # "a nice cafe" is worth a detour past the nearest one; a plain "a cafe" is not.
    appeal_weight = 1.0 if (base_prefs.poi or {}).get("quality") else 0.25

    # Stops along the route come from OpenStreetMap; start importing the area if it is
    # new. A request that names stops waits for the rider's own tile, because the
    # first plan in a fresh town used to find nothing and the second, a minute later,
    # found everything — which looked like the planner ignoring the request.
    importing = monotonic()
    await osm_import.ensure_pois(settings, start.latitude, start.longitude, wait=bool(wanted and categories))
    out_stops: list[Discovery] = []
    back_stops: list[Discovery] = []
    out_side = 1
    if wanted and categories and loop_destination:
        assert destination is not None
        # Out on one side of the line and back on the other, not strung along it.
        out_stops, back_stops, out_side = await _pick_stops_loop(
            db, start, destination, categories, wanted, appeal_weight
        )
        if len(out_stops) + len(back_stops) < wanted:
            await osm_import.ensure_pois_along(
                settings,
                start.latitude,
                start.longitude,
                destination.latitude,
                destination.longitude,
                budget_s=CORRIDOR_IMPORT_BUDGET_S,
            )
            out_stops, back_stops, out_side = await _pick_stops_loop(
                db, start, destination, categories, wanted, appeal_weight
            )
        requested_stops = [*out_stops, *back_stops]
        if parsed_dict is not None:
            parsed_dict["stops"] = [
                {"name": p.name, "latitude": p.latitude, "longitude": p.longitude} for p in requested_stops
            ]
    elif wanted and categories:
        if destination is not None:
            # "Ride here, through three cafés" — a destination does not cancel the stops.
            requested_stops = await _pick_stops_between(db, start, destination, categories, wanted, appeal_weight)
            if len(requested_stops) < wanted:
                # Not enough imported along this way yet; fetch the tiles the leg
                # crosses (a 20 km ride crosses several) and look again.
                await osm_import.ensure_pois_along(
                    settings,
                    start.latitude,
                    start.longitude,
                    destination.latitude,
                    destination.longitude,
                    budget_s=CORRIDOR_IMPORT_BUDGET_S,
                )
                requested_stops = await _pick_stops_between(db, start, destination, categories, wanted, appeal_weight)
        else:
            requested_stops = await _pick_stops(
                db,
                start.latitude,
                start.longitude,
                categories,
                wanted,
                target_km,
                # A named neighbourhood keeps its ride inside it.
                max_ring_m=2500.0 if area is not None else None,
                appeal_weight=appeal_weight,
            )
        if parsed_dict is not None:
            parsed_dict["stops"] = [
                {"name": p.name, "latitude": p.latitude, "longitude": p.longitude} for p in requested_stops
            ]
    ms_import = int((monotonic() - importing) * 1000)
    seed_base = int(
        hashlib.sha256(f"{user.id}:{start.latitude:.4f}:{start.longitude:.4f}".encode()).hexdigest()[:8],
        16,
    )
    main_shape: shapes.LoopShape | None = None
    if loop_destination:
        assert destination is not None
        main_shape = await _main_loop_shape(db, start, destination, via, out_stops, back_stops, out_side, seed_base)
        if typed_destination and not (base_prefs.distanceKm or {}).get("target"):
            # The loop's own length, not 2.4× the crow's flight: out one side and
            # back the other rides about 1.2× the polygon through its points.
            target_km = max(2.0, main_shape.polygon_m() / 1000 * shapes.TARGET_DETOUR)

    # Understood at all? Then the cards are a trade-off around the request, even
    # when the ground could not give what was asked for.
    asked = bool(
        parsed_dict is not None
        and (
            parsed_dict["matched"]
            or categories
            or base_prefs.area
            or base_prefs.via
            or (base_prefs.distanceKm or {}).get("target")
            or base_prefs.loop is not None
        )
    )

    known = await known_cells(db, user.id)
    poi_candidates = await discoveries_nearby(
        db,
        start.latitude,
        start.longitude,
        max(3000.0, target_km * 1000 * 0.6),
        limit=600,
    )
    if requested_stops:
        chosen_ids = {stop.id for stop in requested_stops}
        poi_candidates = requested_stops + [p for p in poi_candidates if p.id not in chosen_ids]

    rider = RiderLimits(
        comfortable_distance_km=comfortable_distance_km(profile, activity),
        comfortable_elevation_gain=profile.comfortable_elevation_gain,
        max_preferred_gradient=profile.max_preferred_gradient,
        gravel_comfort=profile.gravel_comfort,
        technical_trail_comfort=profile.technical_trail_comfort,
        bike_allows_gravel=allow_gravel,
        bike_allows_trails=allow_trails,
    )

    plan = _Plan(
        db=db,
        settings=settings,
        engine=engine,
        user=user,
        quest=quest,
        bike=bike,
        bike_type=bike_type,
        allow_gravel=allow_gravel,
        allow_trails=allow_trails,
        on_foot=on_foot,
        activity=activity,
        origin=payload.origin,
        start=start,
        destination=destination,
        via=via,
        waypoints=list(payload.waypoints),
        targets=targets,
        loop=loop,
        target_km=target_km,
        cfg=cfg,
        rider=rider,
        known=known,
        poi_candidates=poi_candidates,
        seed_base=seed_base,
        details=details,
        shaped=shaped,
    )
    routing = monotonic()
    variants = _variants(base_prefs, usual_prefs, requested_stops, labels, cfg, asked)
    # Which shapes the cards take (docs/ROUTING.md, "Cards that differ").
    slots: list[list[_Candidate]] | None = None
    case: str | None = None
    if loop_destination and main_shape is not None:
        case, slots = "loop", _loop_destination_slots(plan, variants, main_shape, categories, wanted, appeal_weight)
    elif shaped and destination is not None:
        if asked:
            case, slots = "one_way", _one_way_slots(plan, variants, categories, wanted, appeal_weight)
        else:
            case, slots = "map_tap", _map_tap_slots(plan, variants)
    elif shaped and loop and requested_stops:
        ring = 2500.0 if area is not None else None
        case, slots = "loop_stops", _loop_stops_slots(plan, variants, categories, wanted, appeal_weight, ring)
    if slots is not None:
        results, kept, same_road = await _shaped_cards(plan, slots[:max_variants])
        if case == "loop" and kept and (kept[0].self_overlap or 0.0) > shapes.SELF_OVERLAP_MAX:
            same_road.append(shapes.RETRACE_NOTE)
    else:
        results, same_road = await _legacy_cards(plan, variants[:max_variants])
    ms_engine = int((monotonic() - routing) * 1000)
    if not results:
        raise RouteGenerationFailed("We couldn't plan a route for that. Try a different distance or starting point.")
    if parsed_dict is not None:
        parsed_dict["understood"] = _understood(base_prefs, usual_prefs, wanted, categories)
        notes = _shortfalls(base_prefs, requested_stops, wanted, [route for route, _ in results], count_implied)
        if unresolved_origin:
            notes.append(f"couldn't find '{unresolved_origin}' — starting from here instead")
        if unresolved_place:
            notes.append(f"couldn't find a place called '{unresolved_place}'")
        if unresolved_destination:
            notes.append(f"couldn't find '{unresolved_destination}' — riding from here instead")
        for name in unresolved_via:
            notes.append(f"couldn't find '{name}' — the route doesn't pass it")
        if not parsed_dict["understood"] and not parsed_dict["matched"]:
            notes.append(NO_READER if parsed_dict.get("source") == "unavailable" else CANNOT_READ)
        parsed_dict["notes"] = notes + same_road
    await db.flush()
    _keep_labels_honest(results)
    if shaped:
        # A label renamed for breaking its promise must not repeat another card's.
        for (route, _), label in zip(results, shapes.unique_labels([r.label for r, _ in results]), strict=True):
            if route.label != label:
                route.label = label
                route.request = {**(route.request or {}), "label": label}
    results.sort(key=lambda r: -r[0].score)
    if quest is not None and quest.suggested_route_id is None:
        quest.suggested_route_id = results[0][0].id
    # One line per plan, so "it didn't work" can be answered from the logs.
    log.info(
        EVENT_ROUTE_GENERATED,
        user=str(user.id),
        activity=activity,
        request=(payload.request or "")[:120] or None,
        source=parsed_dict.get("source") if parsed_dict else None,
        matched=parsed_dict.get("matched") if parsed_dict else None,
        understood=parsed_dict.get("understood") if parsed_dict else None,
        wanted=wanted,
        stops_found=len(requested_stops),
        destination=(base_prefs.destination or {}).get("name") if destination is not None else None,
        labels=[route.label for route, _ in results],
        notes=parsed_dict.get("notes") if parsed_dict else None,
        engine=results[0][0].engine,
        ms_parse=ms_parse,
        ms_import=ms_import,
        ms_engine=ms_engine,
        engine_calls=budget.used(),
        shape=case,
    )
    return results, parsed_dict


async def get_route(db: AsyncSession, user: User, route_id: uuid.UUID) -> Route:
    route = await db.get(Route, route_id)
    if route is None or route.user_id != user.id:
        raise NotFound("We couldn't find that route. Plan a new one.")
    return route


# A route is the player's while they are still about where it starts.
QUEST_ROUTE_REUSE_M = 150.0
# The board redraws a quest's route once the player has gone further than this from it.
QUEST_ROUTE_PREFETCH_M = 750.0
OPEN_QUEST_STATES = ("AVAILABLE", "ACCEPTED", "ACTIVE")
# Quests the board routes ahead of time while every request queues for the public server.
PREFETCH_ON_SHARED_ENGINE = 2


def reanchor_quest(quest: QuestInstance, origin: Coordinate) -> None:
    """The quest starts here now: its origin, its way home and its route move with the player."""
    quest.latitude, quest.longitude = origin.latitude, origin.longitude
    for o in quest.objectives:
        if o.objective_type == "RETURN_TO_START" and o.status != "COMPLETED":
            o.latitude, o.longitude = origin.latitude, origin.longitude
    quest.suggested_route_id = None


def _moved_from(quest: QuestInstance, origin: Coordinate | None, further_than_m: float) -> bool:
    if origin is None or quest.status not in OPEN_QUEST_STATES:
        return False
    return haversine_m(origin.latitude, origin.longitude, quest.latitude, quest.longitude) > further_than_m


async def quest_route(
    db: AsyncSession,
    settings: Settings,
    engine: RoutingEngine,
    llm: LLMClient,
    user: User,
    quest_id: uuid.UUID,
    origin: Coordinate | None = None,
    *,
    details: bool = True,
) -> tuple[Route, dict[str, float]]:
    """The quest's route (spec §20 "suggested route"), from where the player is.

    Generated from `origin` through the objectives still to do with the rider's
    default bike and profile, stored as `suggested_route_id`, and returned
    unchanged while the player stays about there. A player who has moved on gets
    a new one from where they stand: a route that starts three kilometres away
    is not a route to follow. Without an origin the stored one is returned as it
    is. Tweaking in the planner (POST /routes/generate with the questId) adds
    alternatives without replacing it.
    """
    quest = await db.get(QuestInstance, quest_id)
    if quest is None or quest.user_id != user.id:
        raise NotFound("We couldn't find that quest. It may have ended, so check the quest board.")
    if _moved_from(quest, origin, QUEST_ROUTE_REUSE_M):
        assert origin is not None
        reanchor_quest(quest, origin)
    must_cover_m = _must_cover_m(quest)
    if quest.suggested_route_id is not None:
        route = await db.get(Route, quest.suggested_route_id)
        # A route pinned before this rule, shorter than the quest demands, is replaced
        # while the quest is still only on offer.
        too_short = quest.status == "AVAILABLE" and route is not None and route.distance_meters < must_cover_m * 0.98
        if route is not None and not too_short:
            return route, (route.request or {}).get("scoreComponents", {})
        quest.suggested_route_id = None
    # "Ride at least 11.3 km" with a 9.5 km route could never be finished by following
    # it. Loops come back approximate, so aim a little over and try once more if short.
    target_km = max(quest.recommended_distance_km, must_cover_m / 1000 * 1.1)
    best: tuple[Route, dict[str, float]] | None = None
    for _attempt in range(3):
        payload = RouteGenerateRequest(
            origin=Coordinate(latitude=quest.latitude, longitude=quest.longitude),
            questId=quest.id,
            distanceTargetKm=min(400.0, max(1.0, target_km)),
            loop=True,
            activity=normalise(quest.activity),
        )
        quest.suggested_route_id = None
        # One way round, not a choice of three: each is a request to a shared engine,
        # and the planner is where the rider asks for alternatives.
        results, _ = await generate(db, settings, engine, llm, user, payload, max_variants=1, details=details)
        # The shortest way that still covers what the quest demands; failing that, the longest.
        enough = [r for r in results if r[0].distance_meters >= must_cover_m]
        pick = (
            min(enough, key=lambda r: r[0].distance_meters)
            if must_cover_m and enough
            else (max(results, key=lambda r: r[0].distance_meters) if must_cover_m else results[0])
        )
        if (
            best is None
            or (pick[0].distance_meters >= must_cover_m > best[0].distance_meters)
            or (best[0].distance_meters < must_cover_m and pick[0].distance_meters > best[0].distance_meters)
        ):
            best = pick
        if best[0].distance_meters >= must_cover_m:
            break
        target_km *= max(1.15, must_cover_m / max(best[0].distance_meters, 1.0) * 1.05)
    assert best is not None
    quest.suggested_route_id = best[0].id
    settle_quest_distance(quest, best[0])
    return best


def _must_cover_m(quest: QuestInstance) -> float:
    return max(
        (
            float(o.target_meters or 0)
            for o in quest.objectives
            if o.required and o.objective_type in ("COMPLETE_DISTANCE", "COMPLETE_ROUTE")
        ),
        default=0.0,
    )


def settle_quest_distance(quest: QuestInstance, route: Route) -> None:
    """The quest's headline distance becomes its fixed route's.

    The generator can only guess (twice the crow's flight and a bit), so the list
    said 10 km and the quest, once opened, said 7.7. A required distance objective
    still wins: a route shorter than what must be covered is not the whole outing.
    """
    km = max(route.distance_meters, _must_cover_m(quest)) / 1000
    quest.recommended_distance_km = round(km, 1)
    if route.distance_meters > 0:
        pace = route.estimated_duration_seconds / route.distance_meters
        quest.estimated_duration_minutes = max(5, int(round(km * 1000 * pace / 60)))


async def settle_quest_routes(
    db: AsyncSession,
    settings: Settings,
    engine: RoutingEngine,
    llm: LLMClient,
    user: User,
    quests: list[QuestInstance],
    *,
    origin: Coordinate | None = None,
    limit: int = 5,
) -> None:
    """Routes the quests in hand that have no route from about here yet, so their
    distance is real before the rider ever sees it. A quest that cannot be routed
    keeps its guess, and is routed again when it is opened.

    Bounded by the number of routes, not by a clock: a timeout that cancelled a query
    mid-flight would leave the session unusable, and the engine's own HTTP timeout
    already caps each one.

    On the public Valhalla server every request waits its turn, so the board routes
    two quests, without the surface details, and steps aside for any rider waiting
    on the planner (`budget.background`). The rest are routed when opened.
    """
    shared_engine = settings.routing_engine == "valhalla"
    if shared_engine:
        limit = min(limit, PREFETCH_ON_SHARED_ENGINE)
    pending = [
        q
        for q in quests
        if q.status in ("AVAILABLE", "ACCEPTED")
        and (q.suggested_route_id is None or _moved_from(q, origin, QUEST_ROUTE_PREFETCH_M))
    ][:limit]
    for quest in pending:
        started = monotonic()
        quest_id = quest.id
        try:
            async with db.begin_nested():
                with budget.background():
                    await quest_route(db, settings, engine, llm, user, quest_id, origin, details=not shared_engine)
        except Exception as exc:  # noqa: BLE001 - the board is more important than one route
            log.error("quest_route_prefetch_failed", quest=str(quest_id), error=str(exc)[:200])
            # The rollback expired what the attempt touched; the board is about to
            # read these rows, and an expired attribute cannot be loaded from there.
            await db.refresh(quest)
            for objective in quest.objectives:
                await db.refresh(objective)
        finally:
            log.info("quest_route_settled", quest=str(quest_id), ms=int((monotonic() - started) * 1000))


REROUTE_LABEL = "Rerouted"
# A loop with nothing left to visit is still a loop: rejoin it at these fractions of
# what was left, rather than turning the rest of the outing into a beeline home.
LOOP_KEEPERS = (1 / 3, 2 / 3)
LOOP_KEEP_MIN_M = 1500.0
REROUTE_MAX_VIA = 10


def _position_along(coords: list[list[float]], cumulative: list[float], lat: float, lon: float) -> float:
    """How far along the line its nearest point to (lat, lon) is."""
    nearest = min(range(len(coords)), key=lambda i: haversine_m(lat, lon, coords[i][1], coords[i][0]))
    return cumulative[nearest]


def _point_at(coords: list[list[float]], cumulative: list[float], distance_m: float) -> tuple[float, float]:
    index = min(bisect.bisect_left(cumulative, distance_m), len(coords) - 1)
    return coords[index][1], coords[index][0]


def _stops_ahead(route: Route, progress_m: float, visited: set[str]) -> list[dict[str, Any]]:
    return [
        poi
        for poi in route.pois or []
        if float(poi.get("routePositionMeters", 0)) > progress_m and str(poi.get("discoveryId")) not in visited
    ]


async def reroute(
    db: AsyncSession,
    engine: RoutingEngine,
    user: User,
    route_id: uuid.UUID,
    payload: RerouteRequest,
) -> Route:
    """The rest of a ride, from where the rider actually is.

    The planner draws three routes and scores them; a rider who has left the route
    needs one, now. So this is a single engine request: from them, through what the
    route still had to do — quest objectives not yet done, the stops they asked
    for and have not reached — to where it was going (home, for a loop). It reads
    nothing but the route and its quest, and it never becomes the quest's own route.
    """
    original = await get_route(db, user, route_id)
    coords = original.coordinates or []
    if len(coords) < 2:
        raise RouteGenerationFailed("This route has no path left to rejoin. Plan a new route from here.")
    quest = await db.get(QuestInstance, original.quest_id) if original.quest_id else None
    activity = normalise(original.activity)
    on_foot = is_foot(activity)
    bike = await db.get(Bike, original.bike_id) if original.bike_id else None
    bike_type = bike.bike_type if bike else ("FOOT" if on_foot else "HYBRID")
    allow_gravel = bike.allow_gravel if bike else True
    allow_trails = bike.allow_trails if bike else on_foot
    asked = (original.request or {}).get("preferences") or {}
    prefs = RoutePreferences(**{k: v for k, v in asked.items() if k in RoutePreferences.__dataclass_fields__})

    cumulative = cumulative_distances(coords)
    total = cumulative[-1]
    progress = min(payload.progressMeters, total)
    started = monotonic()

    # What is still owed, in the order the route would have reached it.
    owed: list[tuple[float, tuple[float, float]]] = []
    for lat, lon, _ in _quest_targets(quest, set(payload.completedObjectiveIds)).points:
        owed.append((_position_along(coords, cumulative, lat, lon), (lat, lon)))
    ahead = _stops_ahead(original, progress, {str(i) for i in payload.visitedStopIds})
    for poi in ahead:
        if poi.get("requested"):
            owed.append((float(poi["routePositionMeters"]), (float(poi["latitude"]), float(poi["longitude"]))))
    owed.sort(key=lambda item: item[0])
    via = [point for _, point in owed][:REROUTE_MAX_VIA]

    start_lat, start_lon = coords[0][1], coords[0][0]
    end_lat, end_lon = coords[-1][1], coords[-1][0]
    is_loop = bool((original.request or {}).get("loop")) or haversine_m(start_lat, start_lon, end_lat, end_lon) < 200
    left = total - progress
    if not via and is_loop and left > LOOP_KEEP_MIN_M:
        via = [_point_at(coords, cumulative, progress + left * fraction) for fraction in LOOP_KEEPERS]

    custom_model = None if on_foot else build_custom_model(prefs, bike_type, allow_gravel, allow_trails)
    request = EngineRequest(
        points=[(payload.origin.latitude, payload.origin.longitude), *via, (end_lat, end_lon)],
        profile=original.profile,
        custom_model=custom_model
        if (engine.name == "synthetic" or custom_model is None)
        else strip_internal(custom_model),
        costing=valhalla_costing(prefs, bike_type, allow_gravel, allow_trails, activity),
        activity=activity,
        details=False,
    )
    try:
        engine_routes = await engine.route(request)
    except RoutingUnavailable as exc:
        log.error("route_reroute_failed", route=str(original.id), error=str(exc)[:200])
        raise RouteGenerationFailed("We couldn't find a way back from here. Try again from a nearby road.") from exc
    if not engine_routes:
        raise RouteGenerationFailed("We couldn't find a way back from here. Try again from a nearby road.")
    er = engine_routes[0]

    speed_kmh = ASSUMED_SPEED_KMH[activity] if on_foot else scoring_config()["assumedSpeedKmh"].get(bike_type, 15)
    speed_mps = speed_kmh / 3.6
    new_cumulative = cumulative_distances(er.coordinates)
    pois = []
    for poi in ahead:
        position = _position_along(er.coordinates, new_cumulative, float(poi["latitude"]), float(poi["longitude"]))
        pois.append(
            {**poi, "routePositionMeters": round(position), "estimatedArrivalSeconds": int(position / speed_mps)}
        )
    pois.sort(key=lambda poi: poi["routePositionMeters"])

    route = _route_row(
        user=user,
        quest=quest,
        bike_id=original.bike_id,
        label=REROUTE_LABEL,
        profile=original.profile,
        activity=activity,
        er=er,
        speed_mps=speed_mps,
        pois=pois,
        request={**(original.request or {}), "label": REROUTE_LABEL, "reroutedFrom": str(original.id)},
        # Not measured again mid-ride (it would be a second request); the road ahead
        # is taken to be like the road behind.
        surface=original.surface,
        cycleway=original.cycleway_fraction,
        traffic=original.traffic_exposure,
        new_fraction=original.new_territory_fraction,
        coverage=original.quest_objective_coverage,
    )
    route.score = original.score
    db.add(route)
    await db.flush()
    log.info(
        "route_rerouted",
        user=str(user.id),
        route=str(original.id),
        via=len(via),
        engine=er.engine,
        ms=int((monotonic() - started) * 1000),
    )
    return route


async def package(
    db: AsyncSession, user: User, route_id: uuid.UUID, settings: Settings | None = None
) -> RoutePackageOut:
    route = await get_route(db, user, route_id)
    quest = await db.get(QuestInstance, route.quest_id) if route.quest_id else None
    if settings is not None and is_enabled(settings, "effort_combat"):
        # The route chosen to ride: one thing waits along its far half.
        from app.world_objects import service as world_objects

        character = await maybe_character(db, user.id)
        if character is not None:
            await world_objects.place_on_route(
                db,
                settings,
                user.id,
                route.id,
                list(route.coordinates or []),
                character_class=character.character_class,
                activity=route.activity,
            )
    return RoutePackageOut(
        route=route_out(route),
        quest=quest_out(quest).model_dump(mode="json") if quest else None,
        pois=route.pois,
        mapRegion={
            "minLat": route.min_lat,
            "minLon": route.min_lon,
            "maxLat": route.max_lat,
            "maxLon": route.max_lon,
        },
        generatedAt=utcnow(),
    )
