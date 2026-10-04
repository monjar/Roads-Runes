"""Rune rides (docs/ROADMAP.md, 0.7.0): a route whose waypoints on the road network
make a rune's road form, so the shape is ridden and never improvised with a U-turn.
Loops, triangles and squares on a bike; zigzags on foot."""

from __future__ import annotations

import hashlib
import math
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.activity import is_foot, normalise
from app.core.config import Settings
from app.core.errors import Conflict, RouteGenerationFailed
from app.core.geo import destination_point
from app.core.llm import LLMClient
from app.core.schemas import Coordinate
from app.inventory import catalog as runes
from app.routing.engine import RoutingEngine
from app.routing.models import Route
from app.routing.schemas import RouteGenerateRequest
from app.users.models import User

# The size of a shape, as the length of its outline: big enough for the matcher to
# read it from a track, small enough to be one outing's detour.
OUTLINE_M = {"RIDE": 2400.0, "RUN": 1200.0, "WALK": 900.0}
BIKE_FORMS = ("LOOP", "TRIANGLE", "SQUARE")
FOOT_FORMS = ("ZIGZAG",)
BEARINGS = (0.0, 120.0, 240.0)


def shape(
    form: str, origin: tuple[float, float], bearing: float, outline_m: float
) -> tuple[list[tuple[float, float]], bool]:
    """The waypoints that make a road form, starting at `origin` and heading off on
    `bearing`; and whether the shape closes back on its start."""
    lat, lon = origin
    if form == "LOOP":
        radius = outline_m / (2 * math.pi)
        centre = destination_point(lat, lon, bearing, radius)
        back = (bearing + 180) % 360
        # Nine points round the circle (the request allows ten): fewer, and the roads
        # between them make a polygon that reads as a square.
        return [destination_point(centre[0], centre[1], back + 36 * k, radius) for k in range(1, 10)], True
    if form in ("TRIANGLE", "SQUARE"):
        sides = 3 if form == "TRIANGLE" else 4
        side = outline_m / sides
        turn = 360 / sides
        points, here, heading = [], (lat, lon), bearing
        for _ in range(sides - 1):
            here = destination_point(here[0], here[1], heading, side)
            points.append(here)
            heading = (heading + turn) % 360
        return points, True
    if form == "ZIGZAG":
        leg = outline_m / 4
        points, here = [], (lat, lon)
        for k in range(4):
            here = destination_point(here[0], here[1], (bearing + (45 if k % 2 == 0 else -45)) % 360, leg)
            points.append(here)
        return points, False
    raise ValueError(form)


def forms_for(activity: str) -> tuple[str, ...]:
    return FOOT_FORMS if is_foot(activity) else BIKE_FORMS


async def plan(
    db: AsyncSession,
    settings: Settings,
    engine: RoutingEngine,
    llm: LLMClient,
    user: User,
    origin: Coordinate,
    rune_id: str,
    activity: str | None,
    bike_id: Any = None,
) -> tuple[list[tuple[Route, dict[str, float]]], str, str]:
    """Up to three ways to cut a rune from here, each heading off a different way.
    Returns the routes, the road form and the line to show ("Cut Raido here: a 2.4 km loop.")."""
    from app.characters.service import get_rider_profile
    from app.routing import service

    form = runes.road_form(rune_id)
    if form not in runes.CUT_FORMS:
        raise Conflict("That rune is not cut with a track", code="RUNE_NOT_A_SHAPE")
    moving = normalise(activity or (await get_rider_profile(db, user.id)).default_activity)
    if form not in forms_for(moving):
        where = "on foot" if form in FOOT_FORMS else "on a bike"
        raise Conflict(f"{runes.name(rune_id)} is cut {where}", code="RUNE_NOT_FOR_ACTIVITY")
    outline = OUTLINE_M.get(moving, OUTLINE_M["RIDE"])
    seed = int(
        hashlib.sha256(
            f"{user.id}:{rune_id}:{round(origin.latitude, 3)}:{round(origin.longitude, 3)}".encode()
        ).hexdigest()[:6],
        16,
    )
    results: list[tuple[Route, dict[str, float]]] = []
    for k, base in enumerate(BEARINGS):
        bearing = (base + seed % 120) % 360
        waypoints, closed = shape(form, (origin.latitude, origin.longitude), bearing, outline)
        request = RouteGenerateRequest(
            origin=origin,
            destination=None if closed else Coordinate(latitude=waypoints[-1][0], longitude=waypoints[-1][1]),
            waypoints=[Coordinate(latitude=a, longitude=b) for a, b in (waypoints if closed else waypoints[:-1])],
            loop=closed,
            distanceTargetKm=max(1.0, outline / 1000),
            bikeId=bike_id,
            activity=moving,  # type: ignore[arg-type]
        )
        try:
            made, _ = await service.generate(db, settings, engine, llm, user, request, max_variants=1)
        except RouteGenerationFailed:
            continue
        for route, components in made:
            route.label = f"{runes.name(rune_id)} {k + 1}"[:20]
            route.request = {**(route.request or {}), "rune": rune_id, "roadForm": form}
            results.append((route, components))
    if not results:
        raise RouteGenerationFailed("No way to cut it from here")
    await db.flush()
    km = results[0][0].distance_meters / 1000
    article = {"LOOP": "a loop", "TRIANGLE": "a triangle", "SQUARE": "a square", "ZIGZAG": "a zigzag"}[form]
    return results, form, f"Cut {runes.name(rune_id)} here: {article}, about {km:.1f} km."
