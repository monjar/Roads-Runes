"""H3 cell logic (pure). Server-side authority for VISITED/EXPLORED states."""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field

import h3

from app.core.geo import haversine_m

CELL_STATES = ("UNSEEN", "DISCOVERED", "VISITED", "EXPLORED")
STATE_RANK = {s: i for i, s in enumerate(CELL_STATES)}


def cell_for(latitude: float, longitude: float, resolution: int) -> str:
    return h3.latlng_to_cell(latitude, longitude, resolution)


def cell_center(h3_index: str) -> tuple[float, float]:
    lat, lon = h3.cell_to_latlng(h3_index)
    return lat, lon


def cell_boundary(h3_index: str) -> list[tuple[float, float]]:
    return [(lat, lon) for lat, lon in h3.cell_to_boundary(h3_index)]


def is_valid_cell(h3_index: str, resolution: int | None = None) -> bool:
    try:
        if not h3.is_valid_cell(h3_index):
            return False
        return resolution is None or h3.get_resolution(h3_index) == resolution
    except (TypeError, ValueError):
        return False


def disk(h3_index: str, k: int) -> list[str]:
    return list(h3.grid_disk(h3_index, k))


def cells_in_radius(latitude: float, longitude: float, radius_m: float, resolution: int) -> list[str]:
    """All cells whose centre is within radius of a point."""
    centre = cell_for(latitude, longitude, resolution)
    edge = h3.average_hexagon_edge_length(resolution, unit="m")
    k = int(radius_m / (edge * 1.5)) + 1
    return [c for c in h3.grid_disk(centre, k) if haversine_m(latitude, longitude, *cell_center(c)) <= radius_m]


def cell_area_m2(resolution: int) -> float:
    return h3.average_hexagon_area(resolution, unit="m^2")


@dataclass
class TraversedCell:
    h3_index: str
    distance_inside_m: float = 0.0
    entries: int = 0
    first_seq: int = 0


@dataclass
class TraversalResult:
    cells: dict[str, TraversedCell] = field(default_factory=dict)

    @property
    def ordered(self) -> list[TraversedCell]:
        return sorted(self.cells.values(), key=lambda c: c.first_seq)


def traverse(points: Sequence[tuple[float, float]], resolution: int) -> TraversalResult:
    """Map a GPS trace to cells with distance ridden inside each cell.

    Segment distance is attributed to the cell of the segment's start point;
    at resolution 9 (~174 m edge) with fixes every few seconds this is accurate
    enough for state decisions. Gaps between non-adjacent cells are bridged
    with `h3.grid_path_cells` so a brief GPS outage does not leave holes.
    """
    result = TraversalResult()
    previous_cell: str | None = None
    for seq, (lat, lon) in enumerate(points):
        cell = cell_for(lat, lon, resolution)
        if previous_cell is not None and cell != previous_cell and not h3.are_neighbor_cells(previous_cell, cell):
            try:
                for bridged in h3.grid_path_cells(previous_cell, cell)[1:-1]:
                    result.cells.setdefault(bridged, TraversedCell(bridged, first_seq=seq)).entries += 1
            except Exception:  # noqa: BLE001 - pentagon distortion etc.; skip bridging
                pass
        entry = result.cells.setdefault(cell, TraversedCell(cell, first_seq=seq))
        if cell != previous_cell:
            entry.entries += 1
        if seq + 1 < len(points):
            nlat, nlon = points[seq + 1]
            entry.distance_inside_m += haversine_m(lat, lon, nlat, nlon)
        previous_cell = cell
    return result


def state_for(distance_inside_m: float, explored_threshold_m: float) -> str:
    return "EXPLORED" if distance_inside_m >= explored_threshold_m else "VISITED"


def merge_state(current: str | None, new: str) -> str:
    if current is None:
        return new
    return new if STATE_RANK[new] > STATE_RANK[current] else current


def reconcile_client_cells(
    server_cells: Iterable[str], client_cells: Iterable[str], resolution: int
) -> tuple[set[str], list[str]]:
    """Accept client-reported cells only if they are supported by the GPS trace
    (the cell itself or a neighbour was traversed). Returns (accepted, rejected)."""
    server = set(server_cells)
    support = set(server)
    for c in server:
        support.update(h3.grid_disk(c, 1))
    accepted: set[str] = set()
    rejected: list[str] = []
    for c in client_cells:
        if not is_valid_cell(c, resolution):
            rejected.append(c)
        elif c in support:
            accepted.add(c)
        else:
            rejected.append(c)
    return accepted | server, rejected


def frontier_cells(explored: set[str], resolution: int, around: str, k: int) -> list[str]:
    """Unexplored cells adjacent to explored ones within k rings of `around`."""
    out: list[str] = []
    for c in h3.grid_disk(around, k):
        if c in explored:
            continue
        if any(n in explored for n in h3.grid_disk(c, 1) if n != c):
            out.append(c)
    return out
