"""Plan a ride's cards as shapes, not only as costings (0.9.2). Pure; no I/O.

Riding 0.9.1 showed two faults with one cause. Every card went through the same
points with a different costing, and on Valhalla the costings barely differ, so
the three cards were the same road. And "to Westminster and back" was one request
`[O, D, O]` with nothing to stop the way back retracing the way out.

So a card is now a shape:

* A loop to a destination goes out on one side of the line and back on the
  other: stops split by side, no U-turn at the destination (`break_through`), and
  on a way back with no stops an offset point to pull it wide (`LoopShape`).
* Cards that come back too alike are dropped, honestly, rather than shown twice
  (`duplicate_of`): the planner shows fewer cards and says why.
* A quest's loop and a sealed quest's are the same shape (2026-10-19): the objective
  furthest from the start is where it turns, the others go out on one side and
  home on the other (`back_via`), and the way back is pulled wide enough for the
  quest's distance (`offset_factor_for`). Before, a quest went `[O, T, O]` and
  rode the same road both ways.

`service.py` places the points and asks the engine; this module holds the shapes,
the thresholds and the tests applied to what comes back.
"""

from __future__ import annotations

import math
from collections.abc import Sequence
from dataclasses import dataclass, replace

from app.core.geo import haversine_m
from app.routing import overlap

LatLon = tuple[float, float]

# How much of a loop's way back may ride its way out before a second try at it.
# 0.40 let a loop whose whole length was more than half one road ridden twice
# through untried (2026-10-19): a quarter of the way home already reads as a line.
SELF_OVERLAP_MAX = 0.25
# How much of a loop through stops may ride along itself (`overlap.ridden_twice`),
# both times counted, before its way home is asked for again.
RIDDEN_TWICE_MAX = 0.40
# A card this like one already kept is not another way to ride it.
SIMILAR = 0.75
# Direct stays as the yardstick unless it is the same road and about the same length.
DIRECT_SAME = 0.90
DIRECT_LENGTH_SAME = 0.05
# A card that has the rider push the bike this much further than the cards already
# kept (a foot tunnel, a lift, steps) is not another way to ride it.
PUSH_ALLOWANCE_M = 150.0

# The offset point on a way back with no stops: off the middle of the line by this
# share of the straight distance, within these bounds, moved onto a place nearby.
OFFSET_FACTOR = 0.30
DIRECT_OFFSET_FACTOR = 0.20
LONG_OFFSET_FACTOR = 0.35
OFFSET_MIN_M = 600.0
OFFSET_MAX_M = 4000.0
OFFSET_ANCHOR_M = 400.0
OFFSET_CUTOFF_M = 400.0
# Two cards' offset points closer than this are the same point.
ANCHOR_APART_M = 150.0
# An offset point this close to the way out pulls the way back onto it: the second
# try at the way back goes without it.
OFFSET_ON_WAY_OUT_M = 300.0
# An offset point the road missed: the way back passes further from it than this,
# or rides further than this many times the straight line through it.
SNAP_OFF_LINE_M = 120.0
SNAP_DETOUR = 1.6
# A loop rides about this much further than the polygon through its points.
TARGET_DETOUR = 1.2
# Stops on a loop sit about this far off the line, within these bounds.
STOP_OFFSET_FACTOR = 0.15
STOP_OFFSET_MIN_M = 400.0
STOP_OFFSET_MAX_M = 1500.0

# The ways a quest can be ridden (`quest_ways.py`): planned one each, from the
# quest's origin, and the rider picks one on the quest's page.
WAY_LOOP = "LOOP"
WAY_ONE_WAY = "ONE_WAY"
WAY_QUIET = "QUIET"
WAY_NEW_GROUND = "NEW_GROUND"
WAY_LONG = "LONG_WAY"
WAYS = (WAY_LOOP, WAY_ONE_WAY, WAY_QUIET, WAY_NEW_GROUND, WAY_LONG)
# The long way is about this much longer than the quest asks, and pulled at least
# this far off the line, on the other side from the loop.
LONG_WAY_SCALE = 1.5
LONG_WAY_MIN_FACTOR = 0.5
# New ground looks at offset points this far off the line on both sides.
NEW_GROUND_FACTORS = (OFFSET_FACTOR, 0.5)

# Labels for cards that are a different shape rather than a different costing.
ANOTHER_WAY = "Another way"
LONG_WAY = "The long way"
OTHER_STOPS = "Other stops"
SPARE_LABELS = (ANOTHER_WAY, LONG_WAY, OTHER_STOPS)


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def offset_distance_m(direct_m: float, factor: float) -> float:
    return clamp(direct_m * factor, OFFSET_MIN_M, OFFSET_MAX_M)


def offset_factor_for(direct_m: float, target_m: float) -> float:
    """The offset factor that makes a loop out to a point `direct_m` away and home
    through an offset point about `target_m` long, never under `OFFSET_FACTOR`.

    The polygon O→D→R→O, with R off the middle of the line by h, is
    d + 2·√((d/2)² + h²); the road rides about `TARGET_DETOUR` times that.
    """
    if direct_m <= 0:
        return OFFSET_FACTOR
    half_back = (target_m / TARGET_DETOUR - direct_m) / 2
    if half_back <= direct_m / 2:
        return OFFSET_FACTOR
    return max(OFFSET_FACTOR, math.sqrt(half_back**2 - (direct_m / 2) ** 2) / direct_m)


def stop_offset_m(direct_m: float) -> float:
    return clamp(direct_m * STOP_OFFSET_FACTOR, STOP_OFFSET_MIN_M, STOP_OFFSET_MAX_M)


@dataclass(frozen=True)
class LoopShape:
    """Out to a destination and back another way.

    `[O(break), out-stops(via), named places(via), D(break_through),
    R(through)?, back-stops(via), back-places(via), O(break)]`. `break_through`
    forbids the U-turn at D; R, the offset point, is only on a way back with no
    stops or places of its own. `through=False` is the same shape with turning back
    allowed again, for a destination at the end of a dead end.

    `via` and `back_via` are places the ride must pass whatever the card (a
    quest's objectives); stops are the card's own and another card may swap them.
    """

    start: LatLon
    destination: LatLon
    out_stops: tuple[LatLon, ...] = ()
    via: tuple[LatLon, ...] = ()
    back_stops: tuple[LatLon, ...] = ()
    back_via: tuple[LatLon, ...] = ()
    offset: LatLon | None = None
    offset_side: int = 1  # +1 left of O→D, −1 right
    offset_factor: float = OFFSET_FACTOR
    through: bool = True

    def points(self) -> list[LatLon]:
        return [
            self.start,
            *self.out_stops,
            *self.via,
            self.destination,
            *([self.offset] if self.offset else []),
            *self.back_stops,
            *self.back_via,
            self.start,
        ]

    def types(self) -> list[str]:
        turn, through = ("break_through", "through") if self.through else ("break", "via")
        return [
            "break",
            *(["via"] * (len(self.out_stops) + len(self.via))),
            turn,
            *([through] if self.offset else []),
            *(["via"] * (len(self.back_stops) + len(self.back_via))),
            "break",
        ]

    def cutoffs(self) -> list[float | None]:
        cut: list[float | None] = [None] * (2 + len(self.out_stops) + len(self.via))
        if self.offset:
            cut.append(OFFSET_CUTOFF_M)
        return [*cut, *([None] * (len(self.back_stops) + len(self.back_via) + 1))]

    def turn(self) -> int:
        """Where the destination is in `points()`."""
        return 1 + len(self.out_stops) + len(self.via)

    def back(self) -> tuple[list[LatLon], list[str], list[float | None]]:
        """The way back on its own, from the destination: points, types, cutoffs."""
        points, types, cutoffs = self.points(), self.types(), self.cutoffs()
        turn = self.turn()
        return points[turn:], ["break", *types[turn + 1 :]], [None, *cutoffs[turn + 1 :]]

    def without_offset(self) -> LoopShape:
        return replace(self, offset=None)

    def downgraded(self) -> LoopShape:
        return replace(self, through=False)

    def polygon_m(self) -> float:
        points = self.points()
        return sum(haversine_m(a[0], a[1], b[0], b[1]) for a, b in zip(points, points[1:], strict=False))


def path_length_m(coords: Sequence[Sequence[float]]) -> float:
    return sum(
        haversine_m(float(a[1]), float(a[0]), float(b[1]), float(b[0]))
        for a, b in zip(coords, coords[1:], strict=False)
    )


def turn_near(coords: Sequence[Sequence[float]], boundaries: Sequence[int], destination: LatLon) -> int:
    """The coordinate where the loop turns: the leg boundary nearest the destination,
    or the coordinate nearest it when the engine gave no legs."""
    candidates = [b for b in boundaries if 0 < b < len(coords) - 1] or range(1, max(2, len(coords) - 1))
    return min(
        candidates, key=lambda i: haversine_m(destination[0], destination[1], float(coords[i][1]), float(coords[i][0]))
    )


def snapped_wrong(coords: Sequence[Sequence[float]], turn: int, shape: LoopShape) -> bool:
    """The road missed the offset point: it landed across a river or in a park and
    the engine took it somewhere else, or reaching it took a long way round."""
    if shape.offset is None or turn >= len(coords) - 1:
        return False
    back = coords[turn:]
    lat, lon = shape.offset
    nearest = min(haversine_m(lat, lon, float(c[1]), float(c[0])) for c in back)
    if nearest > SNAP_OFF_LINE_M:
        return True
    if shape.back_stops:
        return False  # the way back runs on through its stops; only the reach is checked
    straight = haversine_m(*shape.destination, lat, lon) + haversine_m(lat, lon, *shape.start)
    return path_length_m(back) > SNAP_DETOUR * straight


def duplicate_of(
    coords: Sequence[Sequence[float]],
    distance_m: float,
    kept: Sequence[tuple[str, Sequence[Sequence[float]], float]],
    *,
    direct: bool = False,
) -> tuple[str, float] | None:
    """The kept card this one repeats, and how alike they are, or None.

    `kept` is (label, coordinates, distance). A card at `SIMILAR` or more to one
    already kept is the same ride. Direct is the planner's yardstick, so it goes
    only when it is the same road (`DIRECT_SAME`) and within 5% of the length.
    """
    for label, other, other_m in kept:
        alike = overlap.similarity(coords, other)
        if direct:
            longer = max(distance_m, other_m, 1.0)
            if alike >= DIRECT_SAME and abs(distance_m - other_m) / longer < DIRECT_LENGTH_SAME:
                return label, alike
        elif alike >= SIMILAR:
            return label, alike
    return None


def unique_labels(labels: list[str]) -> list[str]:
    """Each card's label once: a repeat takes the next spare shape label."""
    out: list[str] = []
    for label in labels:
        if label in out:
            label = next((spare for spare in SPARE_LABELS if spare not in out and spare not in labels), label)
        out.append(label)
    return out


NUMBER_WORDS = {1: "one", 2: "two", 3: "three"}


def fewer_cards_note(count: int) -> str:
    """Said when a card was dropped for being the same ride as another."""
    return "only one way here" if count == 1 else f"only {NUMBER_WORDS.get(count, str(count))} different ways here"


def stops_add_only_note(extra_m: float) -> str:
    extra = max(0, int(round(extra_m, -2)))
    return "the stops are on the direct way" if extra < 100 else f"the stops add only {extra} m"


RETRACE_NOTE = "the way back shares some roads with the way out"
