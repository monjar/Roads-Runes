"""Which district a tile is in, worked out on the fly (pure).

A cell belongs to the nearest district node within 4 km of its centre, looked for
among the districts of its own 0.1° tile and the eight round it (a 4 km circle
never reaches further than that). Nothing about the shape of a district is
stored: its tiles are the cells whose nearest node it is. Answers are cached per
cell in memory, keyed by the districts that were in reach, so a district imported
later is never missed.
"""

from __future__ import annotations

import math
from collections.abc import Iterable, Sequence
from dataclasses import dataclass

import h3

from app.core.geo import haversine_m
from app.exploration.cells import cell_center, cell_for

CATCHMENT_M = 4000.0
TILES_PER_DEGREE = 10
# A cell cache that outgrows this is started again; a district's cells are a few hundred.
CACHE_LIMIT = 250_000


@dataclass(frozen=True)
class Node:
    """A district as the geometry needs it."""

    id: str
    latitude: float
    longitude: float
    osm_id: str = ""


def tile_of(latitude: float, longitude: float) -> str:
    """The importer's tile without its version: "514:-1"."""
    return f"{math.floor(latitude * TILES_PER_DEGREE)}:{math.floor(longitude * TILES_PER_DEGREE)}"


def tiles_near(latitude: float, longitude: float) -> list[str]:
    """The tile under a point and the eight round it."""
    row, col = math.floor(latitude * TILES_PER_DEGREE), math.floor(longitude * TILES_PER_DEGREE)
    return [f"{row + dr}:{col + dc}" for dr in (-1, 0, 1) for dc in (-1, 0, 1)]


def nearest(latitude: float, longitude: float, nodes: Iterable[Node], within_m: float = CATCHMENT_M) -> Node | None:
    """The nearest node within reach; ties go to the lower OSM id, so it never flickers."""
    best: tuple[float, str, Node] | None = None
    # A cheap box first: a degree of latitude is 111 km everywhere, of longitude less.
    lon_m = 111_320 * max(0.01, math.cos(math.radians(latitude)))
    for node in nodes:
        if (
            abs(node.latitude - latitude) * 111_000 > within_m
            or abs(node.longitude - longitude) * lon_m > within_m * 1.01
        ):
            continue
        d = haversine_m(latitude, longitude, node.latitude, node.longitude)
        if d > within_m:
            continue
        key = (d, node.osm_id or node.id, node)
        if best is None or key[:2] < best[:2]:
            best = key
    return best[2] if best else None


_cache: dict[str, tuple[int, str | None]] = {}


def clear_cache() -> None:
    _cache.clear()


def _signature(nodes: Sequence[Node]) -> int:
    return hash(tuple(sorted(n.id for n in nodes)))


class Assigner:
    """Assigns cells to districts from the districts loaded by tile. Build one with
    every district in the tiles round the cells in question (`tiles_near` of each)."""

    def __init__(self, nodes: Iterable[Node]) -> None:
        self.by_tile: dict[str, list[Node]] = {}
        for node in nodes:
            self.by_tile.setdefault(tile_of(node.latitude, node.longitude), []).append(node)
        self._near: dict[str, tuple[int, list[Node]]] = {}

    def _reach(self, tile: str) -> tuple[int, list[Node]]:
        if tile not in self._near:
            row, col = (int(x) for x in tile.split(":"))
            nodes = [
                n for dr in (-1, 0, 1) for dc in (-1, 0, 1) for n in self.by_tile.get(f"{row + dr}:{col + dc}", [])
            ]
            self._near[tile] = (_signature(nodes), nodes)
        return self._near[tile]

    def region_of(self, cell: str) -> str | None:
        """The id of the district a cell is in, or None."""
        lat, lon = cell_center(cell)
        signature, nodes = self._reach(tile_of(lat, lon))
        hit = _cache.get(cell)
        if hit is not None and hit[0] == signature:
            return hit[1]
        found = nearest(lat, lon, nodes)
        if len(_cache) > CACHE_LIMIT:
            _cache.clear()
        _cache[cell] = (signature, found.id if found else None)
        return found.id if found else None

    def group(self, cells: Iterable[str]) -> dict[str, set[str]]:
        """Cells by the district they are in; cells in none are left out."""
        out: dict[str, set[str]] = {}
        for cell in cells:
            region = self.region_of(cell)
            if region is not None:
                out.setdefault(region, set()).add(cell)
        return out

    def catchment(self, node: Node, resolution: int) -> set[str]:
        """Every cell of a district: those within 4 km of its node whose nearest it is."""
        centre = cell_for(node.latitude, node.longitude, resolution)
        edge = h3.average_hexagon_edge_length(resolution, unit="m")
        k = int(CATCHMENT_M / (edge * 1.5)) + 2
        return {c for c in h3.grid_disk(centre, k) if self.region_of(c) == node.id}


def edge_cells(cells: set[str]) -> set[str]:
    """The cells of a set with a neighbour outside it: its edge."""
    return {c for c in cells if any(n not in cells for n in h3.grid_disk(c, 1) if n != c)}


def bbox(cells: Iterable[str]) -> tuple[float, float, float, float] | None:
    """(south, west, north, east) round the cells' corners."""
    lats: list[float] = []
    lons: list[float] = []
    for cell in cells:
        for lat, lon in h3.cell_to_boundary(cell):
            lats.append(lat)
            lons.append(lon)
    if not lats:
        return None
    return (min(lats), min(lons), max(lats), max(lons))


def touched_share(trace_cells: set[str], edge: set[str]) -> float:
    """How much of a district's edge a trace touched: an edge cell counts when the
    trace passed it or a neighbour of it."""
    if not edge:
        return 0.0
    near = {n for c in trace_cells for n in h3.grid_disk(c, 1)}
    return sum(1 for c in edge if c in near) / len(edge)


LOOP_CLOSE_M = 500.0


def is_closed_loop(coords: Sequence[tuple[float, float]], distance_m: float) -> bool:
    """A journey that ends within 500 m of where it began, and went somewhere."""
    if len(coords) < 3 or distance_m < 2000:
        return False
    (lat1, lon1), (lat2, lon2) = coords[0], coords[-1]
    return haversine_m(lat1, lon1, lat2, lon2) <= LOOP_CLOSE_M


def way_cells_along(ways: Iterable[Sequence[tuple[float, float]]], resolution: int, every_m: float = 50.0) -> set[str]:
    """The cells a set of ways passes through, sampling every `every_m` along each."""
    out: set[str] = set()
    for way in ways:
        points = list(way)
        for i, (lat, lon) in enumerate(points):
            out.add(cell_for(lat, lon, resolution))
            if i + 1 >= len(points):
                continue
            nlat, nlon = points[i + 1]
            steps = int(haversine_m(lat, lon, nlat, nlon) // every_m)
            for s in range(1, steps + 1):
                f = s / (steps + 1)
                out.add(cell_for(lat + (nlat - lat) * f, lon + (nlon - lon) * f, resolution))
    return out
