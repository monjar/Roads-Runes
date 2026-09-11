"""Valhalla routing client: bicycle routes anywhere in the world.

GraphHopper, with the project's custom bike models, routes inside the extract
it imported (routing/); Valhalla covers the rest of the world (see
RegionalRouter in engine.py). The public FOSSGIS server needs no key and suits
development under its fair-use policy; production points VALHALLA_URL at a
self-hosted Valhalla built from planet tiles.

Valhalla has no round-trip algorithm, so a loop is routed through three
waypoints on a circle and rescaled once toward the target distance. Surface,
road class and cycle-network details come from a `trace_attributes` call over
the same shape, translated into GraphHopper's detail format so analysis and
scoring stay engine-agnostic.
"""

from __future__ import annotations

import bisect
import math
from typing import Any

import httpx

from app.core.geo import decode_polyline, destination_point, encode_polyline, haversine_m
from app.core.logging import EVENT_ROUTE_GENERATION_FAILED, get_logger
from app.routing.engine import EngineRequest, EngineRoute, RoutingUnavailable

log = get_logger(__name__)

USER_AGENT = "RoadsAndRunes-backend/0.1"
ELEVATION_INTERVAL_M = 30.0
# Roads wander: a loop through points on a circle rides about this much further than the circle.
LOOP_DETOUR = 1.25
LOOP_TOLERANCE = 0.15

BICYCLE_TYPE_FOR_PROFILE = {"road": "Road", "gravel": "Cross", "mountain": "Mountain", "hybrid": "Hybrid"}

# Valhalla maneuver types mapped to the instruction signs the apps know (GraphHopper's
# vocabulary); everything else (start, continue, becomes, stay straight, merges,
# roundabout exits) reads as CONTINUE.
MANEUVER_SIGN = {
    4: "FINISH",
    5: "FINISH",
    6: "FINISH",
    9: "SLIGHT_RIGHT",
    10: "RIGHT",
    11: "SHARP_RIGHT",
    12: "U_TURN",
    13: "U_TURN",
    14: "SHARP_LEFT",
    15: "LEFT",
    16: "SLIGHT_LEFT",
    18: "SLIGHT_RIGHT",
    19: "SLIGHT_LEFT",
    20: "SLIGHT_RIGHT",
    21: "SLIGHT_LEFT",
    23: "SLIGHT_RIGHT",
    24: "SLIGHT_LEFT",
    26: "ROUNDABOUT",
    37: "SLIGHT_RIGHT",
    38: "SLIGHT_LEFT",
}

# Valhalla surface classes mapped to OSM surface values the analysis buckets understand.
SURFACE = {
    "paved_smooth": "asphalt",
    "paved": "paved",
    "paved_rough": "sett",
    "compacted": "compacted",
    "gravel": "gravel",
    "dirt": "dirt",
    "path": "ground",
    "impassable": "ground",
}
PATH_USES = frozenset(
    {"footway", "path", "pedestrian", "sidewalk", "steps", "bridleway", "mountain_bike", "pedestrian_crossing"}
)
SERVICE_USES = frozenset({"service_road", "driveway", "alley", "parking_aisle", "drive_through", "emergency_access"})
BIKE_NETWORK = ((1, "national"), (2, "regional"), (4, "local"), (8, "other"))
DETAIL_ATTRIBUTES = [
    "edge.begin_shape_index",
    "edge.end_shape_index",
    "edge.surface",
    "edge.road_class",
    "edge.use",
    "edge.cycle_lane",
    "edge.bicycle_network",
    "edge.length",
]


def road_class(edge: dict[str, Any]) -> str:
    """GraphHopper-style road class for an edge; separated cycle tracks count as cycleways."""
    use = edge.get("use")
    if use == "cycleway" or edge.get("cycle_lane") == "separated":
        return "cycleway"
    if use in PATH_USES:
        return "path"
    if use == "track":
        return "track"
    if use == "living_street":
        return "living_street"
    road = edge.get("road_class") or "road"
    if use in SERVICE_USES or road == "service_other":
        return "service"
    return str(road)


def bike_network(mask: int | None) -> str:
    for bit, name in BIKE_NETWORK:
        if (mask or 0) & bit:
            return name
    return "missing"


def edge_details(edges: list[dict[str, Any]], points: list[tuple[float, float]]) -> dict[str, list[list[Any]]]:
    """trace_attributes edges as GraphHopper `details`: [[fromIndex, toIndex, value], ...].

    Edges are laid onto the route's own points by distance travelled, not by
    shape index: when the exact walk fails (loops that turn back on themselves
    do) the trace is map-matched and has a shape of its own.
    """
    if len(points) < 2 or not edges:
        return {}
    along = [0.0]
    for (lat1, lon1), (lat2, lon2) in zip(points, points[1:], strict=False):
        along.append(along[-1] + haversine_m(lat1, lon1, lat2, lon2))
    matched = sum(float(e.get("length", 0.0)) for e in edges) * 1000
    scale = along[-1] / matched if matched > 0 else 1.0
    out: dict[str, list[list[Any]]] = {"surface": [], "road_class": [], "bike_network": []}
    start, travelled = 0, 0.0
    for edge in edges:
        travelled += float(edge.get("length", 0.0)) * 1000 * scale
        end = _nearest_index(along, travelled)
        if end <= start:  # shorter than one segment of the drawn route
            continue
        values = {
            "surface": SURFACE.get(str(edge.get("surface")), "missing"),
            "road_class": road_class(edge),
            "bike_network": bike_network(edge.get("bicycle_network")),
        }
        for key, value in values.items():
            series = out[key]
            if series and series[-1][2] == value:
                series[-1][1] = end
            else:
                series.append([start, end, value])
        start = end
    for series in out.values():
        if series:
            series[-1][1] = len(points) - 1
    return {k: v for k, v in out.items() if v}


def _nearest_index(along: list[float], distance: float) -> int:
    i = bisect.bisect_left(along, distance)
    if i <= 0:
        return 0
    if i >= len(along):
        return len(along) - 1
    return i if along[i] - distance < distance - along[i - 1] else i - 1


def loop_waypoints(
    lat: float, lon: float, radius_m: float, seed: int, heading: float | None = None
) -> list[tuple[float, float]]:
    """Three points on a circle through the origin; the seed picks its side and direction."""
    bearing = heading if heading is not None else (seed * 47) % 360
    centre_lat, centre_lon = destination_point(lat, lon, bearing, radius_m)
    back = (bearing + 180) % 360  # from the centre toward the origin
    turn = 1 if seed % 2 == 0 else -1
    points = []
    for k in (1, 2, 3):
        jitter = (seed >> (3 * k)) % 21 - 10
        points.append(destination_point(centre_lat, centre_lon, (back + turn * (90 * k + jitter)) % 360, radius_m))
    return points


def with_elevation(points: list[tuple[float, float]], elevation: list[Any], interval: float) -> list[list[float]]:
    """[[lon, lat, ele]] with the elevation sampled every `interval` metres interpolated onto each point."""
    samples: list[float] = []
    carry = next((float(e) for e in elevation if _valid_height(e)), 0.0)
    for e in elevation:
        if _valid_height(e):
            carry = float(e)
        samples.append(carry)
    coords: list[list[float]] = []
    travelled = 0.0
    for i, (lat, lon) in enumerate(points):
        if i:
            travelled += haversine_m(points[i - 1][0], points[i - 1][1], lat, lon)
        if not samples:
            ele = 0.0
        else:
            pos = travelled / interval
            j = int(pos)
            ele = samples[-1] if j >= len(samples) - 1 else samples[j] + (samples[j + 1] - samples[j]) * (pos - j)
        coords.append([lon, lat, round(ele, 1)])
    return coords


def _valid_height(value: Any) -> bool:
    return value is not None and float(value) > -500  # Valhalla marks missing data with -32768


class ValhallaClient:
    name = "valhalla"

    def __init__(
        self,
        base_url: str,
        timeout: float = 30.0,
        api_key: str = "",
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.api_key = api_key
        self.transport = transport

    def _params(self) -> dict[str, str] | None:
        return {"api_key": self.api_key} if self.api_key else None

    def _client(self, timeout: float | None = None) -> httpx.AsyncClient:
        return httpx.AsyncClient(
            timeout=timeout or self.timeout, headers={"User-Agent": USER_AGENT}, transport=self.transport
        )

    async def healthy(self) -> bool:
        try:
            async with self._client(5.0) as client:
                response = await client.get(f"{self.base_url}/status", params=self._params())
        except httpx.HTTPError:
            return False
        return response.status_code == 200

    async def route(self, request: EngineRequest) -> list[EngineRoute]:
        costing = request.costing or {"bicycle_type": BICYCLE_TYPE_FOR_PROFILE.get(request.profile, "Hybrid")}
        async with self._client() as client:
            try:
                if request.round_trip_distance_m:
                    trips = [await self._loop(client, request, costing)]
                else:
                    alternates = request.alternatives - 1 if len(request.points) == 2 else 0
                    trips = await self._trips(client, request.points, costing, alternates)
            except RoutingUnavailable as exc:
                log.error(EVENT_ROUTE_GENERATION_FAILED, engine="valhalla", error=str(exc)[:300])
                raise
            return [await self._build(client, trip, costing) for trip in trips]

    async def _loop(self, client: httpx.AsyncClient, request: EngineRequest, costing: dict[str, Any]) -> dict[str, Any]:
        lat, lon = request.points[0]
        target = float(request.round_trip_distance_m or 0.0)
        radius = target / (2 * math.pi) / LOOP_DETOUR
        best: dict[str, Any] | None = None
        for _ in range(2):
            waypoints = loop_waypoints(lat, lon, radius, request.seed, request.heading)
            trip = (await self._trips(client, [(lat, lon), *waypoints, (lat, lon)], costing, 0))[0]
            length = _length_m(trip)
            if best is None or abs(length - target) < abs(_length_m(best) - target):
                best = trip
            if abs(length - target) <= target * LOOP_TOLERANCE:
                break
            radius *= target / max(length, 1.0)
        assert best is not None
        return best

    async def _trips(
        self,
        client: httpx.AsyncClient,
        points: list[tuple[float, float]],
        costing: dict[str, Any],
        alternates: int,
    ) -> list[dict[str, Any]]:
        last = len(points) - 1
        body: dict[str, Any] = {
            # Intermediate points are "via": no leg boundary, but a U-turn is allowed there,
            # which an out-and-back to an objective needs.
            "locations": [
                {"lat": lat, "lon": lon, "type": "break" if i in (0, last) else "via"}
                for i, (lat, lon) in enumerate(points)
            ],
            "costing": "bicycle",
            "costing_options": {"bicycle": costing},
            "elevation_interval": ELEVATION_INTERVAL_M,
            "directions_options": {"units": "kilometers", "language": "en-US"},
        }
        if alternates > 0:
            body["alternates"] = alternates
        payload = await self._post(client, "route", body)
        return [payload["trip"], *(alt["trip"] for alt in payload.get("alternates", []) if "trip" in alt)]

    async def _build(self, client: httpx.AsyncClient, trip: dict[str, Any], costing: dict[str, Any]) -> EngineRoute:
        points: list[tuple[float, float]] = []
        elevation: list[Any] = []
        instructions: list[dict[str, Any]] = []
        interval = ELEVATION_INTERVAL_M
        legs = trip.get("legs", [])
        for leg_index, leg in enumerate(legs):
            leg_points = decode_polyline(leg["shape"], precision=6)
            offset = len(points) - 1 if points else 0
            points.extend(leg_points[1:] if points else leg_points)  # legs share their joining point
            interval = float(leg.get("elevation_interval") or interval)
            elevation.extend(leg.get("elevation") or [])
            for maneuver in leg.get("maneuvers", []):
                sign = MANEUVER_SIGN.get(int(maneuver.get("type", 0)), "CONTINUE")
                if sign == "FINISH" and leg_index < len(legs) - 1:
                    sign = "WAYPOINT"
                index = min(offset + int(maneuver.get("begin_shape_index", 0)), len(points) - 1)
                lat, lon = points[index]
                instructions.append(
                    {
                        "index": len(instructions),
                        "text": str(maneuver.get("instruction", "")).rstrip("."),
                        "streetName": (maneuver.get("street_names") or [""])[0],
                        "sign": sign,
                        "distanceMeters": round(float(maneuver.get("length", 0.0)) * 1000, 1),
                        "durationSeconds": int(maneuver.get("time", 0)),
                        "coordinateIndex": index,
                        "latitude": lat,
                        "longitude": lon,
                    }
                )
        summary = trip.get("summary", {})
        return EngineRoute(
            coordinates=with_elevation(points, elevation, interval),
            distance_m=round(_length_m(trip), 1),
            duration_s=int(summary.get("time", 0)),
            instructions=instructions,
            details=await self._details(client, points, costing),
            engine="valhalla",
        )

    async def _details(
        self, client: httpx.AsyncClient, points: list[tuple[float, float]], costing: dict[str, Any]
    ) -> dict[str, list[list[Any]]]:
        if len(points) < 2:
            return {}
        body = {
            "encoded_polyline": encode_polyline(points, precision=6),
            # Exact walk when it can; map matching when it cannot (loops that double back).
            "shape_match": "walk_or_snap",
            "costing": "bicycle",
            "costing_options": {"bicycle": costing},
            "filters": {"attributes": DETAIL_ATTRIBUTES, "action": "include"},
        }
        try:
            payload = await self._post(client, "trace_attributes", body)
        except RoutingUnavailable as exc:
            # The route stands without them; analysis falls back to "unknown" surfaces.
            log.warning("valhalla_details_unavailable", error=str(exc)[:300])
            return {}
        return edge_details(payload.get("edges", []), points)

    async def _post(self, client: httpx.AsyncClient, action: str, body: dict[str, Any]) -> dict[str, Any]:
        try:
            response = await client.post(f"{self.base_url}/{action}", json=body, params=self._params())
        except httpx.HTTPError as exc:
            raise RoutingUnavailable(f"Valhalla {action}: {exc}") from exc
        if response.status_code != 200:
            raise RoutingUnavailable(f"Valhalla {action} returned {response.status_code}: {response.text[:200]}")
        return response.json()


def _length_m(trip: dict[str, Any]) -> float:
    return float(trip.get("summary", {}).get("length", 0.0)) * 1000
