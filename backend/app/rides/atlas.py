"""The Atlas (0.9.0): every journey of a year on one map, a calendar of the days with
a journey, and the year in numbers and firsts. Read from what is already kept."""

from __future__ import annotations

import uuid
from datetime import UTC, date, datetime
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.geo import encode_polyline
from app.rides.models import Ride, RidePoint, RideRoute

MAX_TRACES = 1000
MAX_POINTS = 200
COUNTED = ("PROCESSED", "FLAGGED")


def _perpendicular(p: tuple[float, float], a: tuple[float, float], b: tuple[float, float]) -> float:
    """How far p is from the line a-b, in degrees (good enough to choose points by)."""
    (x, y), (x1, y1), (x2, y2) = p, a, b
    dx, dy = x2 - x1, y2 - y1
    if dx == 0 and dy == 0:
        return ((x - x1) ** 2 + (y - y1) ** 2) ** 0.5
    return abs(dy * x - dx * y + x2 * y1 - y2 * x1) / (dx * dx + dy * dy) ** 0.5


def _rdp(points: list[tuple[float, float]], epsilon: float) -> list[tuple[float, float]]:
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        start, end = stack.pop()
        best, index = 0.0, -1
        for i in range(start + 1, end):
            d = _perpendicular(points[i], points[start], points[end])
            if d > best:
                best, index = d, i
        if index >= 0 and best > epsilon:
            keep[index] = True
            stack += [(start, index), (index, end)]
    return [p for p, k in zip(points, keep, strict=True) if k]


def simplify(points: list[tuple[float, float]], max_points: int = MAX_POINTS) -> list[tuple[float, float]]:
    """A track with at most `max_points` points that keeps its shape (Douglas-Peucker,
    loosened until it fits; every nth point if it never does)."""
    if len(points) <= max_points:
        return list(points)
    epsilon = 1e-5
    for _ in range(24):
        out = _rdp(points, epsilon)
        if len(out) <= max_points:
            return out
        epsilon *= 2
    step = len(points) / (max_points - 1)
    return [points[int(i * step)] for i in range(max_points - 1)] + [points[-1]]


def _day(ride: Ride) -> date:
    return ride.local_date or ride.started_at.date()


async def atlas(db: AsyncSession, user_id: uuid.UUID, year: int) -> dict[str, Any]:
    from app.districts.models import UserRegion
    from app.inventory.models import RuneCut, RuneHolding
    from app.legends.models import DEFEATED, OldOne
    from app.progression.models import RewardEvent
    from app.world_objects.models import WorldObject

    start = datetime(year, 1, 1, tzinfo=UTC)
    end = datetime(year + 1, 1, 1, tzinfo=UTC)
    rides = list(
        (
            await db.execute(
                select(Ride)
                .where(
                    Ride.user_id == user_id, Ride.status.in_(COUNTED), Ride.started_at >= start, Ride.started_at < end
                )
                .order_by(Ride.started_at)
            )
        ).scalars()
    )
    # The traces: the newest thousand, in order.
    shown = rides[-MAX_TRACES:]
    routes = {}
    ids = [r.id for r in shown]
    for i in range(0, len(ids), 500):
        for route in (await db.execute(select(RideRoute).where(RideRoute.ride_id.in_(ids[i : i + 500])))).scalars():
            routes[route.ride_id] = route
    traces = []
    for ride in shown:
        route = routes.get(ride.id)
        coords = [(float(c[1]), float(c[0])) for c in (route.coordinates if route else None) or []]
        if len(coords) < 2:
            continue
        traces.append(
            {
                "rideId": str(ride.id),
                "activity": ride.activity,
                "date": _day(ride).isoformat(),
                "polyline": encode_polyline(simplify(coords)),
            }
        )
    days: dict[date, dict[str, Any]] = {}
    for ride in rides:
        entry = days.setdefault(_day(ride), {"date": _day(ride).isoformat(), "journeys": 0, "distanceMeters": 0.0})
        entry["journeys"] += 1
        entry["distanceMeters"] = round(entry["distanceMeters"] + float(ride.distance_meters or 0), 1)

    def in_year(column: Any) -> Any:
        return (column >= start) & (column < end)

    creatures = int(
        await db.scalar(
            select(func.count(WorldObject.id)).where(
                WorldObject.user_id == user_id,
                WorldObject.kind == "MONSTER",
                WorldObject.status == "CLAIMED",
                in_year(WorldObject.claimed_at),
            )
        )
        or 0
    )
    legends = int(
        await db.scalar(
            select(func.count(OldOne.id)).where(
                OldOne.user_id == user_id, OldOne.status == DEFEATED, in_year(OldOne.defeated_at)
            )
        )
        or 0
    )
    cuts = int(
        await db.scalar(select(func.count(RuneCut.id)).where(RuneCut.user_id == user_id, in_year(RuneCut.cut_at))) or 0
    )
    yours = int(
        await db.scalar(
            select(func.count(UserRegion.id)).where(UserRegion.user_id == user_id, in_year(UserRegion.yours_since))
        )
        or 0
    )
    deeds = [
        str((e.payload or {}).get("title"))
        for e in (
            await db.execute(
                select(RewardEvent)
                .where(
                    RewardEvent.user_id == user_id, RewardEvent.reward_type == "TITLE", in_year(RewardEvent.created_at)
                )
                .order_by(RewardEvent.created_at)
            )
        ).scalars()
        if str((e.payload or {}).get("slug") or "").startswith("deed-") and (e.payload or {}).get("title")
    ]

    firsts: list[dict[str, Any]] = []

    def first(kind: str, when: datetime | date | None, text: str) -> None:
        if when is None:
            return
        day = when.date() if isinstance(when, datetime) else when
        if day.year == year:
            firsts.append({"kind": kind, "date": day.isoformat(), "text": text})

    creature = (
        await db.execute(
            select(WorldObject)
            .where(WorldObject.user_id == user_id, WorldObject.kind == "MONSTER", WorldObject.status == "CLAIMED")
            .order_by(WorldObject.claimed_at)
            .limit(1)
        )
    ).scalar_one_or_none()
    if creature is not None:
        first("FIRST_CREATURE", creature.claimed_at, f"First creature defeated: {creature.payload.get('name')}.")
    legend = (
        await db.execute(
            select(OldOne)
            .where(OldOne.user_id == user_id, OldOne.status == DEFEATED)
            .order_by(OldOne.defeated_at)
            .limit(1)
        )
    ).scalar_one_or_none()
    if legend is not None:
        first("FIRST_LEGEND", legend.defeated_at, f"First legend defeated: {legend.name}.")
    rune = (
        await db.execute(
            select(RuneHolding).where(RuneHolding.user_id == user_id).order_by(RuneHolding.first_found_at).limit(1)
        )
    ).scalar_one_or_none()
    if rune is not None:
        from app.inventory.catalog import name as rune_name

        first("FIRST_RUNE", rune.first_found_at, f"First rune: {rune_name(rune.rune_id)}.")
    if rides:
        longest = max(rides, key=lambda r: float(r.distance_meters or 0))
        if longest.distance_meters:
            first("LONGEST_JOURNEY", _day(longest), f"Longest journey: {longest.distance_meters / 1000:.1f} km.")
    highest = (
        await db.execute(
            select(RidePoint.altitude_meters, Ride.started_at, Ride.local_date)
            .join(Ride, Ride.id == RidePoint.ride_id)
            .where(
                Ride.user_id == user_id,
                Ride.status == "PROCESSED",
                Ride.started_at >= start,
                Ride.started_at < end,
                RidePoint.altitude_meters.is_not(None),
            )
            .order_by(RidePoint.altitude_meters.desc())
            .limit(1)
        )
    ).first()
    if highest is not None:
        first("HIGHEST_POINT", highest.local_date or highest.started_at, f"Highest point: {round(highest[0])} m.")
    from app.districts.models import Region

    complete = (
        await db.execute(
            select(Region.name, UserRegion.completed_at)
            .join(UserRegion, UserRegion.region_id == Region.id)
            .where(UserRegion.user_id == user_id, UserRegion.completed_at.is_not(None))
            .order_by(UserRegion.completed_at)
            .limit(1)
        )
    ).first()
    if complete is not None:
        first("FIRST_DISTRICT_COMPLETE", complete.completed_at, f"First district complete: {complete.name}!")
    firsts.sort(key=lambda f: f["date"])
    return {
        "traces": traces,
        "days": [days[d] for d in sorted(days)],
        "year": {
            "year": year,
            "journeys": len(rides),
            "distanceMeters": round(sum(float(r.distance_meters or 0) for r in rides), 1),
            "newTiles": sum(int((r.processing_result or {}).get("newCells") or 0) for r in rides),
            "creaturesDefeated": creatures,
            "legendsDefeated": legends,
            "runesCut": cuts,
            "districtsYours": yours,
            "deedsReached": deeds,
            "firsts": firsts,
        },
    }
