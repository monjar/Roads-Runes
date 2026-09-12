"""Route generation orchestration (spec §25–32)."""

from __future__ import annotations

import hashlib
import math
import uuid
from dataclasses import dataclass
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from app.characters.models import Bike, RiderProfile
from app.characters.service import default_bike, get_rider_profile
from app.core.config import Settings
from app.core.errors import NotFound, RouteGenerationFailed
from app.core.geo import bearing_deg, encode_polyline, haversine_m
from app.core.llm import LLMClient
from app.core.logging import EVENT_ROUTE_GENERATION_FAILED, get_logger
from app.core.schemas import Coordinate
from app.core.security import utcnow
from app.discoveries import osm_import
from app.discoveries.models import Discovery
from app.discoveries.service import nearby as discoveries_nearby
from app.exploration.cells import cell_for
from app.exploration.service import known_cells
from app.quests.models import QuestInstance
from app.quests.service import quest_out
from app.routing import geocode
from app.routing.analysis import (
    analyse_elevation,
    bounding_box,
    cycleway_fraction,
    elevation_samples_from_coordinates,
    surface_composition,
    traffic_exposure,
)
from app.routing.custom_models import build_custom_model, strip_internal, valhalla_costing
from app.routing.engine import PROFILE_FOR_BIKE, EngineRequest, RoutingEngine, RoutingUnavailable
from app.routing.models import Route
from app.routing.pois import attach_pois
from app.routing.preferences import RoutePreferences, parse_request
from app.routing.schemas import (
    InstructionOut,
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


def _quest_targets(quest: QuestInstance | None) -> QuestTargets:
    if quest is None:
        return QuestTargets([], False)
    points = []
    rts = False
    for o in quest.objectives:
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


def _new_territory_fraction(coords: list[list[float]], known: dict[str, str], resolution: int) -> float:
    if len(coords) < 2:
        return 0.0
    cells = [cell_for(c[1], c[0], resolution) for c in coords]
    unknown = sum(1 for c in cells if known.get(c) not in ("VISITED", "EXPLORED"))
    return round(unknown / len(cells), 3)


def route_out(route: Route, components: dict[str, float] | None = None) -> RouteOptionOut:
    return RouteOptionOut(
        id=route.id,
        label=route.label,
        engine=route.engine,
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


AREA_TAKEOVER_M = 2000.0
NEIGHBOURHOOD_RIDE_KM = 14.0


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
) -> list[Discovery]:
    """`count` places around a centre, spread around the compass.

    Picking the nearest few would send the rider up and down the same street; one
    per sector of the circle gives a loop that actually goes somewhere. When the
    rider named a neighbourhood, `max_ring_m` keeps the stops inside it — five pubs
    "in Notting Hill" must not be spread across half of London.
    """
    ring = max(400.0, target_km * 1000 / (2 * math.pi) * 0.8)
    if max_ring_m is not None:
        ring = min(ring, max_ring_m)
    candidates = await _candidates(db, latitude, longitude, ring * 2.5, categories)
    if not candidates:
        return []
    spread = 360 / count * 0.6
    chosen: list[Discovery] = []
    for category, quota in zip(categories, _quotas(count, len(categories)), strict=False):
        _take_around(
            latitude, longitude, [p for p in candidates if p.category == category], quota, ring, spread, chosen
        )
    if len(chosen) < count:
        _take_around(latitude, longitude, candidates, count - len(chosen), ring, spread, chosen)
    return _tour(latitude, longitude, chosen)


def _take_around(
    latitude: float,
    longitude: float,
    candidates: list[Discovery],
    count: int,
    ring: float,
    spread: float,
    chosen: list[Discovery],
) -> None:
    """Appends up to `count` places near the ring, each in a direction of its own."""
    taken = {poi.id for poi in chosen}
    added = 0
    for poi in sorted(candidates, key=lambda p: abs(haversine_m(latitude, longitude, p.latitude, p.longitude) - ring)):
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


def _distance_to_leg(latitude: float, longitude: float, start: Coordinate, end: Coordinate) -> tuple[float, float]:
    """Metres from the point to the start→end line, and how far along it falls (0..1).

    Flat-earth projection around the leg's middle: over the length of a bike ride
    the error is a few metres, which a 600 m corridor does not care about.
    """
    lon_scale = math.cos(math.radians((start.latitude + end.latitude) / 2)) * 111_320.0
    px = (longitude - start.longitude) * lon_scale
    py = (latitude - start.latitude) * 110_540.0
    bx = (end.longitude - start.longitude) * lon_scale
    by = (end.latitude - start.latitude) * 110_540.0
    length_sq = bx * bx + by * by
    if length_sq == 0:
        return math.hypot(px, py), 0.0
    along = max(0.0, min(1.0, (px * bx + py * by) / length_sq))
    return math.hypot(px - bx * along, py - by * along), along


async def _pick_stops_between(
    db: AsyncSession,
    start: Coordinate,
    destination: Coordinate,
    categories: list[str],
    count: int,
) -> list[Discovery]:
    """`count` stops strung along the way from the rider to a place.

    A ride to somewhere is not a loop, so spreading the stops around the compass
    (`_pick_stops`) would send the rider backwards. These come out of a corridor
    along the line, one per stretch of the way, in the order they are reached.
    """
    direct = haversine_m(start.latitude, start.longitude, destination.latitude, destination.longitude)
    corridor = max(600.0, direct * 0.2)
    pool = await _candidates(
        db,
        (start.latitude + destination.latitude) / 2,
        (start.longitude + destination.longitude) / 2,
        max(1500.0, direct * 0.7),
        categories,
    )
    along = []
    for poi in pool:
        offset, progress = _distance_to_leg(poi.latitude, poi.longitude, start, destination)
        if offset <= corridor:
            along.append((progress, offset, poi))
    if not along:
        return []
    chosen: list[tuple[float, Discovery]] = []
    for category, quota in zip(categories, _quotas(count, len(categories)), strict=False):
        _take_along([c for c in along if c[2].category == category], quota, chosen)
    if len(chosen) < count:
        _take_along(along, count - len(chosen), chosen)
    return [poi for _, poi in sorted(chosen, key=lambda c: c[0])]


def _take_along(along: list[tuple[float, float, Discovery]], count: int, chosen: list[tuple[float, Discovery]]) -> None:
    """Appends up to `count` of these, one per stretch of the way, each the closest
    to the line in its stretch; what is left over comes from nearest the line."""
    taken = {poi.id for _, poi in chosen}
    start = len(chosen)
    for band in range(count):
        low, high = band / count, (band + 1) / count
        in_band = [c for c in along if low <= c[0] < high and c[2].id not in taken]
        if in_band:
            progress, _, poi = min(in_band, key=lambda c: c[1])
            taken.add(poi.id)
            chosen.append((progress, poi))
    for progress, _, poi in sorted(along, key=lambda c: c[1]):
        if len(chosen) - start >= count:
            return
        if poi.id not in taken:
            taken.add(poi.id)
            chosen.append((progress, poi))


async def generate(
    db: AsyncSession,
    settings: Settings,
    engine: RoutingEngine,
    llm: LLMClient,
    user: User,
    payload: RouteGenerateRequest,
) -> tuple[list[tuple[Route, dict[str, float]]], dict[str, Any] | None]:
    profile: RiderProfile = await get_rider_profile(db, user.id)
    bike: Bike | None = None
    if payload.bikeId is not None:
        bike = await db.get(Bike, payload.bikeId)
        if bike is None or bike.user_id != user.id:
            raise NotFound("Bike not found")
    else:
        bike = await default_bike(db, user.id)
    bike_type = bike.bike_type if bike else "HYBRID"
    allow_gravel = bike.allow_gravel if bike else True
    allow_trails = bike.allow_trails if bike else False

    quest: QuestInstance | None = None
    if payload.questId is not None:
        quest = await db.get(QuestInstance, payload.questId)
        if quest is None or quest.user_id != user.id:
            raise NotFound("Quest not found")
    targets = _quest_targets(quest)

    base_prefs = RoutePreferences(
        trafficAversion=1 - profile.traffic_tolerance,
        cyclewayPreference=profile.cycleway_preference,
        gravelPreference=profile.gravel_comfort if allow_gravel else 0.0,
        scenicPreference=0.6,
        hillTolerance=min(1.0, profile.max_preferred_gradient / 12),
    )
    if payload.preferences:
        for k, v in payload.preferences.model_dump().items():
            setattr(base_prefs, k, v)
    parsed_dict: dict[str, Any] | None = None
    if payload.request and settings.flags.get("nl_route_requests", True):
        parsed = await parse_request(payload.request, llm, base_prefs)
        base_prefs = parsed.preferences
        parsed_dict = {
            **parsed.preferences.to_dict(),
            "source": parsed.source,
            "matched": parsed.matched,
        }

    # A named place ("a ride in Notting Hill") moves the ride; the rider's own position
    # still seeds the alternatives and counts new territory.
    area = None
    if (base_prefs.area or {}).get("query") and payload.destination is None:
        area = await geocode.resolve(
            settings, str(base_prefs.area["query"]), payload.origin.latitude, payload.origin.longitude
        )
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

    # What the rider wrote wins over the slider: the slider always has a value, while
    # typing "a 12 km loop" is a deliberate act, and a 22 km answer to it is a lie.
    target_km = (
        (base_prefs.distanceKm or {}).get("target")
        or payload.distanceTargetKm
        or (quest.recommended_distance_km if quest else None)
        or profile.comfortable_distance_km
    )
    if area is not None and payload.distanceTargetKm is None and not (base_prefs.distanceKm or {}).get("target"):
        target_km = min(target_km, NEIGHBOURHOOD_RIDE_KM)

    loop = (
        payload.loop
        if payload.loop is not None
        else (base_prefs.loop if base_prefs.loop is not None else payload.destination is None)
    )

    cfg = scoring_config()
    labels = list(cfg["bikeDefaultLabels"].get(bike_type, cfg["bikeDefaultLabels"]["OTHER"]))
    if base_prefs.gravelPreference > 0.7 and "Gravel" not in labels and allow_gravel:
        labels[-1] = "Gravel"
    if base_prefs.hillTolerance > 0.8 and "Challenge" not in labels:
        labels[-1] = "Challenge"
    if payload.destination is not None and "Direct" not in labels:
        labels[0] = "Direct"

    # Stops along the route come from OpenStreetMap; start importing the area if it is new.
    await osm_import.ensure_pois(settings, start.latitude, start.longitude, wait=False)

    # "with about 5 pubs" is a promise: put them on the line rather than hoping the
    # route happens to pass some.
    requested_stops: list[Discovery] = []
    wanted = int((base_prefs.poi or {}).get("count") or 0)
    categories = _stop_categories(base_prefs.poi)
    if wanted and categories:
        if payload.destination is not None:
            # "Ride here, through three cafés" — a destination does not cancel the stops.
            requested_stops = await _pick_stops_between(db, start, payload.destination, categories, wanted)
            if not requested_stops:
                # Nothing imported along this way yet; fetch its middle and look again.
                await osm_import.ensure_pois(
                    settings,
                    (start.latitude + payload.destination.latitude) / 2,
                    (start.longitude + payload.destination.longitude) / 2,
                )
                requested_stops = await _pick_stops_between(db, start, payload.destination, categories, wanted)
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
            )
        if parsed_dict is not None:
            parsed_dict["stops"] = [
                {"name": p.name, "latitude": p.latitude, "longitude": p.longitude} for p in requested_stops
            ]

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
        comfortable_distance_km=profile.comfortable_distance_km,
        comfortable_elevation_gain=profile.comfortable_elevation_gain,
        max_preferred_gradient=profile.max_preferred_gradient,
        gravel_comfort=profile.gravel_comfort,
        technical_trail_comfort=profile.technical_trail_comfort,
        bike_allows_gravel=allow_gravel,
        bike_allows_trails=allow_trails,
    )
    seed_base = int(
        hashlib.sha256(f"{user.id}:{start.latitude:.4f}:{start.longitude:.4f}".encode()).hexdigest()[:8],
        16,
    )

    results: list[tuple[Route, dict[str, float]]] = []
    seen_paths: set[str] = set()
    for index, label in enumerate(labels):
        overlay = cfg["labels"][label]
        prefs = RoutePreferences(
            **{
                **base_prefs.to_dict(),
                **{k: v for k, v in overlay.items() if k in RoutePreferences.__dataclass_fields__},
            }
        ).clamp()
        prefs.distanceKm = base_prefs.distanceKm
        prefs.poi = base_prefs.poi
        distance_m = target_km * 1000 * overlay.get("distanceFactor", 1.0)
        custom_model = build_custom_model(prefs, bike_type, allow_gravel, allow_trails)
        points = [(start.latitude, start.longitude)]
        for lat, lon, _ in targets.points:
            points.append((lat, lon))
        for stop in requested_stops:
            points.append((stop.latitude, stop.longitude))
        for wp in payload.waypoints:
            points.append((wp.latitude, wp.longitude))
        if payload.destination is not None:
            points.append((payload.destination.latitude, payload.destination.longitude))
        elif loop and len(points) > 1:
            points.append(points[0])
        round_trip = distance_m if (loop and len(points) == 1) else None
        heading = None
        if round_trip and targets.points:
            from app.core.geo import bearing_deg

            heading = bearing_deg(
                payload.origin.latitude,
                payload.origin.longitude,
                targets.points[0][0],
                targets.points[0][1],
            )
        request = EngineRequest(
            points=points,
            profile=PROFILE_FOR_BIKE.get(bike_type, "hybrid"),
            round_trip_distance_m=round_trip,
            seed=seed_base + index * 17,
            custom_model=custom_model if engine.name == "synthetic" else strip_internal(custom_model),
            heading=heading,
            costing=valhalla_costing(prefs, bike_type, allow_gravel, allow_trails),
        )
        try:
            engine_routes = await engine.route(request)
        except RoutingUnavailable as exc:
            log.error(EVENT_ROUTE_GENERATION_FAILED, label=label, error=str(exc))
            continue
        if not engine_routes:
            continue
        er = engine_routes[0]
        coords = er.coordinates
        polyline = encode_polyline((c[1], c[0]) for c in coords)
        if polyline in seen_paths:
            # Short A→B trips often give every label the same path; one card is enough.
            continue
        seen_paths.add(polyline)
        samples = elevation_samples_from_coordinates(coords)
        elev = analyse_elevation(samples)
        surface = surface_composition(coords, er.details.get("surface"))
        cycle = cycleway_fraction(coords, er.details.get("road_class"), er.details.get("bike_network"))
        traffic = traffic_exposure(coords, er.details.get("road_class"))
        new_fraction = _new_territory_fraction(coords, known, settings.h3_resolution)
        coverage = _coverage(coords, targets)
        speed_mps = cfg["assumedSpeedKmh"].get(bike_type, 15) / 3.6
        pois = attach_pois(
            coords,
            poi_candidates,
            speed_mps=speed_mps,
            preferred_category=(prefs.poi or {}).get("category"),
            preferred_position=(prefs.poi or {}).get("preferredPosition"),
            required_ids={str(stop.id) for stop in requested_stops},
        )
        metrics = RouteMetrics(
            distance_m=er.distance_m,
            elevation_gain_m=elev.total_ascent,
            max_gradient_percent=elev.max_gradient_percent,
            surface=surface,
            cycleway_fraction=cycle,
            traffic_exposure=traffic,
            new_territory_fraction=new_fraction,
            quest_objective_coverage=coverage,
            poi_count=len(pois),
            scenic_fraction=surface.get("gravel", 0) * 0.5 + surface.get("trail", 0) * 0.5 + cycle * 0.3,
        )
        score, components = score_route(metrics, prefs, rider, target_km * 1000)
        min_lat, min_lon, max_lat, max_lon = bounding_box(coords)
        route = Route(
            user_id=user.id,
            quest_id=quest.id if quest else None,
            bike_id=bike.id if bike else None,
            label=label,
            profile=request.profile,
            engine=er.engine,
            distance_meters=round(er.distance_m, 1),
            estimated_duration_seconds=int(er.distance_m / speed_mps),
            elevation_gain_meters=elev.total_ascent,
            elevation_loss_meters=elev.total_descent,
            highest_point_meters=elev.highest_point,
            max_gradient_percent=elev.max_gradient_percent,
            average_climb_gradient_percent=elev.average_climb_gradient_percent,
            longest_climb=elev.longest_climb.to_dict() if elev.longest_climb else None,
            surface=surface,
            cycleway_fraction=cycle,
            traffic_exposure=traffic,
            new_territory_fraction=new_fraction,
            quest_objective_coverage=coverage,
            score=score,
            coordinates=[[round(c[0], 6), round(c[1], 6), round(c[2], 1)] for c in coords],
            encoded_polyline=polyline,
            instructions=er.instructions,
            elevation_samples=samples,
            climbs=[c.to_dict() for c in elev.climbs],
            pois=[p.to_dict() for p in pois],
            request={
                "preferences": prefs.to_dict(),
                "label": label,
                "scoreComponents": components,
                "targetKm": target_km,
                "loop": loop,
            },
            min_lat=min_lat,
            min_lon=min_lon,
            max_lat=max_lat,
            max_lon=max_lon,
        )
        db.add(route)
        results.append((route, components))
    if not results:
        raise RouteGenerationFailed("No route could be generated for this request")
    await db.flush()
    results.sort(key=lambda r: -r[0].score)
    if quest is not None and quest.suggested_route_id is None:
        quest.suggested_route_id = results[0][0].id
    return results, parsed_dict


async def get_route(db: AsyncSession, user: User, route_id: uuid.UUID) -> Route:
    route = await db.get(Route, route_id)
    if route is None or route.user_id != user.id:
        raise NotFound("Route not found")
    return route


async def quest_route(
    db: AsyncSession,
    settings: Settings,
    engine: RoutingEngine,
    llm: LLMClient,
    user: User,
    quest_id: uuid.UUID,
) -> tuple[Route, dict[str, float]]:
    """The quest's fixed route (spec §20 "suggested route").

    Generated once from the quest origin through its objectives with the rider's
    default bike and profile, stored as `suggested_route_id`, and returned
    unchanged from then on. Tweaking in the planner (POST /routes/generate with
    the questId) adds alternatives without replacing it.
    """
    quest = await db.get(QuestInstance, quest_id)
    if quest is None or quest.user_id != user.id:
        raise NotFound("Quest not found")
    if quest.suggested_route_id is not None:
        route = await db.get(Route, quest.suggested_route_id)
        if route is not None:
            return route, (route.request or {}).get("scoreComponents", {})
        quest.suggested_route_id = None
    payload = RouteGenerateRequest(
        origin=Coordinate(latitude=quest.latitude, longitude=quest.longitude),
        questId=quest.id,
        distanceTargetKm=quest.recommended_distance_km,
        loop=True,
    )
    results, _ = await generate(db, settings, engine, llm, user, payload)
    return results[0]


async def package(db: AsyncSession, user: User, route_id: uuid.UUID) -> RoutePackageOut:
    route = await get_route(db, user, route_id)
    quest = await db.get(QuestInstance, route.quest_id) if route.quest_id else None
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
