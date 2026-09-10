"""POI corridor search along a route (spec §32). The candidate list comes
from PostGIS (`ST_DWithin` on a buffered linestring in production, bbox in
tests); the per-candidate route position / detour maths is in-memory."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from app.core.geo import haversine_m


@dataclass
class POIOnRoute:
    discovery_id: str
    name: str
    category: str
    latitude: float
    longitude: float
    route_position_m: float
    detour_m: float
    detour_s: int
    eta_s: int
    relevance: float

    def to_dict(self) -> dict[str, Any]:
        return {
            "discoveryId": self.discovery_id,
            "name": self.name,
            "category": self.category,
            "latitude": self.latitude,
            "longitude": self.longitude,
            "routePositionMeters": round(self.route_position_m),
            "detourMeters": round(self.detour_m),
            "detourSeconds": self.detour_s,
            "estimatedArrivalSeconds": self.eta_s,
            "relevance": round(self.relevance, 2),
        }


def cumulative_distances(coords: list[list[float]]) -> list[float]:
    out = [0.0]
    for a, b in zip(coords, coords[1:], strict=False):
        out.append(out[-1] + haversine_m(a[1], a[0], b[1], b[0]))
    return out


def attach_pois(
    coords: list[list[float]],
    candidates: list[Any],
    *,
    corridor_m: float = 400.0,
    speed_mps: float = 4.5,
    preferred_category: str | None = None,
    preferred_position: float | None = None,
    max_pois: int = 8,
    stride: int = 3,
) -> list[POIOnRoute]:
    """`candidates` need .id .name .category .latitude .longitude attributes."""
    if len(coords) < 2:
        return []
    cumulative = cumulative_distances(coords)
    total = cumulative[-1] or 1.0
    results: list[POIOnRoute] = []
    for poi in candidates:
        best_d, best_i = float("inf"), 0
        for i in range(0, len(coords), stride):
            d = haversine_m(poi.latitude, poi.longitude, coords[i][1], coords[i][0])
            if d < best_d:
                best_d, best_i = d, i
        if best_d > corridor_m:
            continue
        position = cumulative[best_i]
        detour = best_d * 2
        relevance = 0.5
        if preferred_category and poi.category == preferred_category:
            relevance += 0.4
            if preferred_position is not None:
                relevance += 0.3 * (1 - abs(position / total - preferred_position))
        relevance -= best_d / corridor_m * 0.2
        results.append(
            POIOnRoute(
                discovery_id=str(poi.id),
                name=poi.name,
                category=poi.category,
                latitude=poi.latitude,
                longitude=poi.longitude,
                route_position_m=position,
                detour_m=detour,
                detour_s=int(detour / speed_mps),
                eta_s=int(position / speed_mps),
                relevance=max(0.0, min(1.0, relevance)),
            )
        )
    results.sort(key=lambda p: (-p.relevance, p.route_position_m))
    return results[:max_pois]
