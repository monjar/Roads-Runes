"""Route generation orchestration (spec §25–32)."""

from __future__ import annotations

import hashlib
import uuid
from dataclasses import dataclass
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from app.characters.models import Bike, RiderProfile
from app.characters.service import default_bike, get_rider_profile
from app.core.config import Settings
from app.core.errors import NotFound, RouteGenerationFailed
from app.core.geo import encode_polyline
from app.core.llm import LLMClient
from app.core.logging import EVENT_ROUTE_GENERATION_FAILED, get_logger
from app.core.security import utcnow
from app.discoveries.service import nearby as discoveries_nearby
from app.exploration.cells import cell_for
from app.exploration.service import known_cells
from app.quests.models import QuestInstance
from app.quests.service import quest_out
from app.routing.analysis import (
    analyse_elevation,
    bounding_box,
    cycleway_fraction,
    elevation_samples_from_coordinates,
    surface_composition,
    traffic_exposure,
)
from app.routing.custom_models import build_custom_model, strip_internal
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

    target_km = (
        payload.distanceTargetKm
        or (base_prefs.distanceKm or {}).get("target")
        or (quest.recommended_distance_km if quest else None)
        or profile.comfortable_distance_km
    )
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

    known = await known_cells(db, user.id)
    poi_candidates = await discoveries_nearby(
        db,
        payload.origin.latitude,
        payload.origin.longitude,
        max(3000.0, target_km * 1000 * 0.6),
        limit=600,
    )
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
        hashlib.sha256(f"{user.id}:{payload.origin.latitude:.4f}:{payload.origin.longitude:.4f}".encode()).hexdigest()[
            :8
        ],
        16,
    )

    results: list[tuple[Route, dict[str, float]]] = []
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
        points = [(payload.origin.latitude, payload.origin.longitude)]
        for lat, lon, _ in targets.points:
            points.append((lat, lon))
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
            encoded_polyline=encode_polyline((c[1], c[0]) for c in coords),
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
