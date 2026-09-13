"""Routing engine clients.

`GraphHopperClient` talks to a GraphHopper instance configured from
`routing/config.yml` (custom bike profiles, LM, elevation, details) and
knows only the extract it imported; `ValhallaClient` (valhalla.py) routes
anywhere, and `RegionalRouter` picks between them per request.
`SyntheticRouter` is a deterministic fallback used in tests and when no
engine is reachable; it produces geometrically plausible loops so the rest
of the pipeline (analysis, scoring, packages) can be exercised. Synthetic
routes are flagged `engine="synthetic"` and must never be presented as
navigable in production.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any, Protocol

import httpx

from app.core.config import Settings
from app.core.geo import destination_point, haversine_m
from app.core.logging import EVENT_ROUTE_GENERATION_FAILED, get_logger

log = get_logger(__name__)

PROFILE_FOR_BIKE = {
    "ROAD": "road",
    "GRAVEL": "gravel",
    "MOUNTAIN": "mountain",
    "HYBRID": "hybrid",
    "FOLDING": "hybrid",
    "OTHER": "hybrid",
}

SIGN_MAP = {
    -98: "U_TURN",
    -8: "U_TURN",
    -7: "CONTINUE",
    -6: "ROUNDABOUT",
    -3: "SHARP_LEFT",
    -2: "LEFT",
    -1: "SLIGHT_LEFT",
    0: "CONTINUE",
    1: "SLIGHT_RIGHT",
    2: "RIGHT",
    3: "SHARP_RIGHT",
    4: "FINISH",
    5: "WAYPOINT",
    6: "ROUNDABOUT",
    8: "U_TURN",
}


@dataclass
class EngineRequest:
    points: list[tuple[float, float]]  # [(lat, lon)] origin first; destination last unless round trip
    profile: str
    round_trip_distance_m: float | None = None
    seed: int = 0
    custom_model: dict[str, Any] | None = None
    alternatives: int = 1
    heading: float | None = None
    costing: dict[str, Any] | None = None  # Valhalla costing options for the same preferences
    activity: str = "RIDE"  # RIDE | RUN | WALK; on foot the costing is pedestrian


@dataclass
class EngineRoute:
    coordinates: list[list[float]]  # [[lon, lat, ele]]
    distance_m: float
    duration_s: int
    instructions: list[dict[str, Any]]
    details: dict[str, list[list[Any]]] = field(default_factory=dict)
    engine: str = "graphhopper"


class RoutingEngine(Protocol):
    name: str

    async def route(self, request: EngineRequest) -> list[EngineRoute]: ...

    async def healthy(self) -> bool: ...


class GraphHopperClient:
    name = "graphhopper"

    def __init__(self, base_url: str, timeout: float = 20.0) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    async def healthy(self) -> bool:
        try:
            async with httpx.AsyncClient(timeout=3.0) as client:
                r = await client.get(f"{self.base_url}/health")
                return r.status_code == 200
        except httpx.HTTPError:
            return False

    async def bbox(self) -> tuple[float, float, float, float] | None:
        """The loaded graph's extent as (min_lon, min_lat, max_lon, max_lat)."""
        try:
            async with httpx.AsyncClient(timeout=3.0) as client:
                r = await client.get(f"{self.base_url}/info")
            box = r.json().get("bbox") if r.status_code == 200 else None
        except (httpx.HTTPError, ValueError):
            return None
        if not box or len(box) != 4:
            return None
        min_lon, min_lat, max_lon, max_lat = (float(v) for v in box)
        return min_lon, min_lat, max_lon, max_lat

    async def route(self, request: EngineRequest) -> list[EngineRoute]:
        body: dict[str, Any] = {
            "profile": request.profile,
            "points": [[lon, lat] for lat, lon in request.points],
            "elevation": True,
            "points_encoded": False,
            "instructions": True,
            "locale": "en",
            "details": [
                "surface",
                "road_class",
                "road_environment",
                "bike_network",
                "average_slope",
            ],
            "ch.disable": True,
        }
        if request.custom_model:
            body["custom_model"] = request.custom_model
        if request.round_trip_distance_m:
            body["algorithm"] = "round_trip"
            body["round_trip.distance"] = int(request.round_trip_distance_m)
            body["round_trip.seed"] = request.seed
            if request.heading is not None:
                body["heading"] = request.heading
        elif request.alternatives > 1:
            body["algorithm"] = "alternative_route"
            body["alternative_route.max_paths"] = request.alternatives
            body["alternative_route.max_weight_factor"] = 1.6
            body["alternative_route.max_share_factor"] = 0.7
        try:
            async with httpx.AsyncClient(timeout=self.timeout) as client:
                response = await client.post(f"{self.base_url}/route", json=body)
        except httpx.HTTPError as exc:
            log.error(EVENT_ROUTE_GENERATION_FAILED, engine="graphhopper", error=str(exc))
            raise RoutingUnavailable(str(exc)) from exc
        if response.status_code != 200:
            log.error(
                EVENT_ROUTE_GENERATION_FAILED,
                engine="graphhopper",
                status=response.status_code,
                body=response.text[:500],
            )
            raise RoutingUnavailable(f"GraphHopper returned {response.status_code}")
        payload = response.json()
        routes: list[EngineRoute] = []
        for path in payload.get("paths", []):
            coords = [
                [float(c[0]), float(c[1]), float(c[2]) if len(c) > 2 else 0.0] for c in path["points"]["coordinates"]
            ]
            instructions = []
            for idx, ins in enumerate(path.get("instructions", [])):
                interval = ins.get("interval", [0, 0])
                ci = int(interval[0])
                lon, lat = coords[ci][0], coords[ci][1]
                instructions.append(
                    {
                        "index": idx,
                        "text": ins.get("text", ""),
                        "streetName": ins.get("street_name", ""),
                        "sign": SIGN_MAP.get(int(ins.get("sign", 0)), "CONTINUE"),
                        "distanceMeters": round(float(ins.get("distance", 0.0)), 1),
                        "durationSeconds": int(ins.get("time", 0) / 1000),
                        "coordinateIndex": ci,
                        "latitude": lat,
                        "longitude": lon,
                    }
                )
            routes.append(
                EngineRoute(
                    coordinates=coords,
                    distance_m=float(path["distance"]),
                    duration_s=int(path["time"] / 1000),
                    instructions=instructions,
                    details=path.get("details", {}),
                )
            )
        return routes


class RoutingUnavailable(Exception):
    pass


class SyntheticRouter:
    """Deterministic geometric router for tests/dev without GraphHopper."""

    name = "synthetic"

    async def healthy(self) -> bool:
        return True

    async def route(self, request: EngineRequest) -> list[EngineRoute]:
        lat0, lon0 = request.points[0]
        seed = request.seed
        if request.round_trip_distance_m:
            coords = self._loop(lat0, lon0, request.round_trip_distance_m, seed, request.heading)
        else:
            coords = self._chain(request.points, seed)
        distance = sum(haversine_m(a[1], a[0], b[1], b[0]) for a, b in zip(coords, coords[1:], strict=False))
        speed_mps = 4.5
        n = len(coords)
        instructions = [
            {
                "index": 0,
                "text": "Head out",
                "streetName": "Start",
                "sign": "CONTINUE",
                "distanceMeters": round(distance / 4, 1),
                "durationSeconds": int(distance / 4 / speed_mps),
                "coordinateIndex": 0,
                "latitude": coords[0][1],
                "longitude": coords[0][0],
            },
            {
                "index": 1,
                "text": "Turn right",
                "streetName": "Ridge Lane",
                "sign": "RIGHT",
                "distanceMeters": round(distance / 4, 1),
                "durationSeconds": int(distance / 4 / speed_mps),
                "coordinateIndex": n // 4,
                "latitude": coords[n // 4][1],
                "longitude": coords[n // 4][0],
            },
            {
                "index": 2,
                "text": "Turn left",
                "streetName": "Mill Road",
                "sign": "LEFT",
                "distanceMeters": round(distance / 4, 1),
                "durationSeconds": int(distance / 4 / speed_mps),
                "coordinateIndex": n // 2,
                "latitude": coords[n // 2][1],
                "longitude": coords[n // 2][0],
            },
            {
                "index": 3,
                "text": "Continue",
                "streetName": "River Path",
                "sign": "CONTINUE",
                "distanceMeters": round(distance / 4, 1),
                "durationSeconds": int(distance / 4 / speed_mps),
                "coordinateIndex": 3 * n // 4,
                "latitude": coords[3 * n // 4][1],
                "longitude": coords[3 * n // 4][0],
            },
            {
                "index": 4,
                "text": "Arrive",
                "streetName": "",
                "sign": "FINISH",
                "distanceMeters": 0.0,
                "durationSeconds": 0,
                "coordinateIndex": n - 1,
                "latitude": coords[-1][1],
                "longitude": coords[-1][0],
            },
        ]
        surface = "gravel" if (request.custom_model or {}).get("_gravel", 0) > 0.5 else "asphalt"
        details = {
            "surface": [[0, n // 2, "asphalt"], [n // 2, n - 1, surface]],
            "road_class": [
                [0, n // 3, "residential"],
                [n // 3, 2 * n // 3, "cycleway"],
                [2 * n // 3, n - 1, "tertiary"],
            ],
            "bike_network": [[0, n - 1, "missing"]],
        }
        return [
            EngineRoute(
                coords,
                distance,
                int(distance / speed_mps),
                instructions,
                details,
                engine="synthetic",
            )
        ]

    @staticmethod
    def _loop(lat0: float, lon0: float, distance_m: float, seed: int, heading: float | None) -> list[list[float]]:
        radius = distance_m / (2 * math.pi) * 0.82
        base_bearing = heading if heading is not None else (seed * 47) % 360
        centre_lat, centre_lon = destination_point(lat0, lon0, base_bearing, radius)
        coords: list[list[float]] = []
        steps = 120
        for i in range(steps + 1):
            angle = (base_bearing + 180 + 360 * i / steps) % 360
            wobble = 1 + 0.08 * math.sin(i * 0.7 + seed)
            lat, lon = destination_point(centre_lat, centre_lon, angle, radius * wobble)
            ele = 20 + 40 * math.sin(2 * math.pi * i / steps + seed) + 15 * math.sin(6 * math.pi * i / steps)
            coords.append([lon, lat, round(ele, 1)])
        coords[0] = [lon0, lat0, coords[0][2]]
        coords[-1] = [lon0, lat0, coords[-1][2]]
        return coords

    @staticmethod
    def _chain(points: list[tuple[float, float]], seed: int) -> list[list[float]]:
        coords: list[list[float]] = []
        for (lat1, lon1), (lat2, lon2) in zip(points, points[1:], strict=False):
            steps = 40
            for i in range(steps):
                t = i / steps
                # Size and side of the bend both follow the seed, so each label's alternative
                # is a different path (seeds 17 apart would otherwise share one).
                bulge = 0.0008 * (1 + (seed % 5) * 0.5) * math.sin(math.pi * t) * (1 if seed % 2 == 0 else -1)
                lat = lat1 + (lat2 - lat1) * t + bulge
                lon = lon1 + (lon2 - lon1) * t + bulge
                # The seed is a large hash; only a few metres of it may reach the elevation.
                ele = 15 + 25 * math.sin(math.pi * t) + seed % 11
                coords.append([lon, lat, round(ele, 1)])
        last = points[-1]
        coords.append([last[1], last[0], 15.0])
        return coords


class RegionalRouter:
    """GraphHopper where its graph covers the ride, another engine everywhere else.

    GraphHopper carries the project's custom bike models but only knows the
    extract it imported; the fallback (Valhalla) covers the world. A ride goes
    to GraphHopper only when every point, and for a loop the circle it may
    sweep, lies inside the graph; if GraphHopper fails anyway the fallback answers.
    """

    name = "regional"

    def __init__(self, local: RoutingEngine, bbox: tuple[float, float, float, float], fallback: RoutingEngine) -> None:
        self.local = local
        self.bbox = bbox  # (min_lon, min_lat, max_lon, max_lat)
        self.fallback = fallback

    async def healthy(self) -> bool:
        return await self.local.healthy() or await self.fallback.healthy()

    def covers(self, request: EngineRequest) -> bool:
        if request.activity != "RIDE":
            return False  # the local graph carries bike profiles only; feet go to the fallback
        min_lon, min_lat, max_lon, max_lat = self.bbox
        reach_m = (request.round_trip_distance_m or 0.0) / math.pi
        for lat, lon in request.points:
            dlat = reach_m / 111_320
            dlon = reach_m / (111_320 * max(0.2, math.cos(math.radians(lat))))
            if not (min_lat + dlat <= lat <= max_lat - dlat and min_lon + dlon <= lon <= max_lon - dlon):
                return False
        return True

    async def route(self, request: EngineRequest) -> list[EngineRoute]:
        if self.covers(request):
            try:
                return await self.local.route(request)
            except RoutingUnavailable as exc:
                log.warning("local_routing_failed_using_fallback", engine=self.local.name, error=str(exc)[:300])
        return await self.fallback.route(request)


async def build_engine(settings: Settings) -> RoutingEngine:
    """The engine for ROUTING_ENGINE (routing/README.md).

    auto: GraphHopper inside its graph and Valhalla elsewhere; Valhalla alone
    when GraphHopper is down; the synthetic router only when neither answers
    (development; production refuses to start on it).
    """
    from app.routing.valhalla import ValhallaClient  # valhalla.py imports this module

    mode = settings.routing_engine
    if mode == "synthetic":
        return SyntheticRouter()
    gh = GraphHopperClient(settings.graphhopper_url, settings.graphhopper_timeout_seconds)
    valhalla = ValhallaClient(settings.valhalla_url, settings.valhalla_timeout_seconds, settings.valhalla_api_key)
    if mode in ("auto", "graphhopper") and await gh.healthy():
        bbox = await gh.bbox() if mode == "auto" else None
        return RegionalRouter(gh, bbox, valhalla) if bbox else gh
    if mode in ("auto", "valhalla") and await valhalla.healthy():
        return valhalla
    log.warning(
        "routing_unreachable_using_synthetic",
        mode=mode,
        graphhopper=settings.graphhopper_url,
        valhalla=settings.valhalla_url,
    )
    return SyntheticRouter()
