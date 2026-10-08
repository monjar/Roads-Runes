"""A planned route as a course for a Garmin (docs/GARMIN.md, plan step 1).

The rider shares the file to the Garmin Connect app, which syncs it to their Edge
or watch. A course carries the line with its heights, the turns as course points
named for the street, and the places the phone already shows on the route: stops
asked for and quest objectives not yet done. A hidden objective's place stays out,
as it does on the phone, and a sealed quest's route is not sent at all while the
quest is open: its way is the secret.
"""

from __future__ import annotations

from bisect import bisect_left
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any
from xml.sax.saxutils import escape

from sqlalchemy.ext.asyncio import AsyncSession

from app.core import fit
from app.core.activity import ASSUMED_SPEED_KMH, normalise, noun
from app.core.errors import Conflict
from app.core.geo import haversine_m
from app.core.security import utcnow
from app.quests.models import QuestInstance
from app.quests.schemas import ObjectiveOut
from app.quests.service import objective_out, quest_extra
from app.routing.models import Route
from app.routing.service import ASKED_LABEL
from app.users.models import User

OPEN_QUEST_STATES = ("AVAILABLE", "ACCEPTED", "ACTIVE")
# A turn the device announces, by the planner's sign. CONTINUE is left out: it is
# a street changing its name, and a Garmin would chime for every one.
TURN_POINT: dict[str, str] = {
    "LEFT": "left",
    "RIGHT": "right",
    "SLIGHT_LEFT": "slight_left",
    "SHARP_LEFT": "sharp_left",
    "SLIGHT_RIGHT": "slight_right",
    "SHARP_RIGHT": "sharp_right",
    "U_TURN": "u_turn",
    "ROUNDABOUT": "generic",  # FIT has no roundabout
}
TURN_WORD: dict[str, str] = {
    "LEFT": "Left",
    "RIGHT": "Right",
    "SLIGHT_LEFT": "Bear left",
    "SHARP_LEFT": "Sharp left",
    "SLIGHT_RIGHT": "Bear right",
    "SHARP_RIGHT": "Sharp right",
    "U_TURN": "U-turn",
    "ROUNDABOUT": "Roundabout",
}
STOP_POINT: dict[str, str] = {"PUB": "food", "CAFE": "food", "FOOD": "food", "VIEWPOINT": "overlook"}
# An objective further than this from the line is not on the way; it is not a course point.
OBJECTIVE_ON_ROUTE_M = 300.0


@dataclass(frozen=True)
class CoursePoint:
    index: int  # into the route's coordinates
    kind: str  # FIT course_point type
    name: str
    turn: bool = False


@dataclass(frozen=True)
class Course:
    route: Route
    name: str
    objectives: list[ObjectiveOut]


async def course(db: AsyncSession, user: User, route: Route) -> Course:
    """The route as a course, or 409 `ROUTE_SEALED` for an open sealed quest's way."""
    quest = await db.get(QuestInstance, route.quest_id) if route.quest_id else None
    if quest is not None and quest_extra(quest).get("sealed") and quest.status in OPEN_QUEST_STATES:
        raise Conflict(
            "A sealed quest keeps its way secret until you ride it, so it can't go to a Garmin.",
            code="ROUTE_SEALED",
        )
    objectives = [objective_out(o) for o in quest.objectives] if quest is not None else []
    return Course(route=route, name=course_name(route, quest), objectives=objectives)


def course_name(route: Route, quest: QuestInstance | None) -> str:
    """The quest's title, else the kind of route and the day it was planned:
    "Scenic ride 8 Oct". A Garmin lists courses by name, and a week of loops
    called "Scenic ride" would be one name seven times."""
    if quest is not None:
        return quest.title
    kind = f"Your {noun(route.activity)}" if route.label == ASKED_LABEL else f"{route.label} {noun(route.activity)}"
    day = fit.utc(route.created_at) if route.created_at else utcnow()
    return f"{kind} {day.day} {day:%b}"


def _along(coords: list[list[float]]) -> list[float]:
    """Metres along the line at each coordinate."""
    out = [0.0]
    for a, b in zip(coords, coords[1:], strict=False):
        out.append(out[-1] + haversine_m(a[1], a[0], b[1], b[0]))
    return out


def _nearest(coords: list[list[float]], lat: float, lon: float) -> tuple[int, float]:
    best = min(range(len(coords)), key=lambda i: haversine_m(lat, lon, coords[i][1], coords[i][0]))
    return best, haversine_m(lat, lon, coords[best][1], coords[best][0])


def course_points(c: Course, along: list[float]) -> list[CoursePoint]:
    coords = c.route.coordinates
    last = len(coords) - 1
    points: list[CoursePoint] = []
    for i in c.route.instructions or []:
        kind = TURN_POINT.get(str(i.get("sign")))
        index = int(i.get("coordinateIndex", -1))
        if kind is None or not 0 < index < last:
            continue
        street = str(i.get("streetName") or "").strip()
        name = fit.short(street or TURN_WORD[str(i["sign"])], fit.COURSE_POINT_NAME_MAX)
        points.append(CoursePoint(index, kind, name, turn=True))
    for poi in c.route.pois or []:
        if poi.get("routePositionMeters") is not None:
            index = min(bisect_left(along, float(poi["routePositionMeters"])), last)
        elif poi.get("latitude") is not None and poi.get("longitude") is not None:
            index = _nearest(coords, float(poi["latitude"]), float(poi["longitude"]))[0]
        else:
            continue
        kind = STOP_POINT.get(str(poi.get("category") or "").upper(), "generic")
        points.append(CoursePoint(index, kind, fit.short(str(poi.get("name") or "Stop"), fit.COURSE_POINT_NAME_MAX)))
    for o in c.objectives:
        if o.latitude is None or o.longitude is None or o.status == "COMPLETED":
            continue
        index, off = _nearest(coords, o.latitude, o.longitude)
        if off <= OBJECTIVE_ON_ROUTE_M:
            points.append(CoursePoint(index, "checkpoint", fit.short(o.title, fit.COURSE_POINT_NAME_MAX)))
    return sorted(points, key=lambda p: p.index)


def to_fit_course(c: Course, created: datetime | None = None) -> bytes:
    """A FIT course file: file_id, course, lap, timer start, records, course points,
    timer stop. Times are paced by the route's own estimate; a course only needs
    them in order."""
    route = c.route
    coords = route.coordinates
    along = _along(coords)
    start = fit.utc(created or utcnow()).replace(microsecond=0)
    if route.distance_meters > 0 and route.estimated_duration_seconds > 0:
        speed = route.distance_meters / route.estimated_duration_seconds
    else:
        speed = ASSUMED_SPEED_KMH[normalise(route.activity)] / 3.6
    times = [start + timedelta(seconds=d / speed) for d in along]

    def at(i: int) -> dict[str, Any]:
        return {
            "timestamp": fit.fit_time(times[i]),
            "position_lat": fit.semicircles(coords[i][1]),
            "position_long": fit.semicircles(coords[i][0]),
            "distance": along[i],
        }

    records: list[dict[str, Any]] = []
    for i, point in enumerate(coords):
        record = {"mesg_num": fit.MESG["RECORD"], **at(i)}
        if len(point) > 2 and point[2] is not None and -500 <= point[2] <= 9000:
            record["altitude"] = point[2]
        records.append(record)
    elapsed = (times[-1] - times[0]).total_seconds()
    sport = fit.SPORT[normalise(route.activity)]
    first, last = coords[0], coords[-1]
    return fit.encode(
        [
            fit.file_id("course", start),
            {"mesg_num": fit.MESG["COURSE"], "name": fit.short(c.name, fit.COURSE_NAME_MAX), "sport": sport},
            {
                "mesg_num": fit.MESG["LAP"],
                "timestamp": fit.fit_time(times[-1]),
                "start_time": fit.fit_time(times[0]),
                "start_position_lat": fit.semicircles(first[1]),
                "start_position_long": fit.semicircles(first[0]),
                "end_position_lat": fit.semicircles(last[1]),
                "end_position_long": fit.semicircles(last[0]),
                "total_elapsed_time": elapsed,
                "total_timer_time": elapsed,
                "total_distance": along[-1],
                "total_ascent": round(route.elevation_gain_meters or 0),
                "total_descent": round(route.elevation_loss_meters or 0),
            },
            {
                "mesg_num": fit.MESG["EVENT"],
                "timestamp": fit.fit_time(times[0]),
                "event": "timer",
                "event_type": "start",
            },
            *records,
            *(
                {
                    "mesg_num": fit.MESG["COURSE_POINT"],
                    "message_index": n,
                    **at(p.index),
                    "type": p.kind,
                    "name": p.name,
                }
                for n, p in enumerate(course_points(c, along))
            ),
            {
                "mesg_num": fit.MESG["EVENT"],
                "timestamp": fit.fit_time(times[-1]),
                "event": "timer",
                "event_type": "stop_disable_all",
            },
        ]
    )


def to_gpx_course(c: Course) -> str:
    """The same course as GPX for apps that take only that: the line as a track and
    the places as waypoints. GPX has no turns."""
    coords = c.route.coordinates
    title = escape(c.name)
    parts = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<gpx version="1.1" creator="Roads &amp; Runes" xmlns="http://www.topografix.com/GPX/1/1">',
        f"<metadata><name>{title}</name></metadata>",
    ]
    for p in course_points(c, _along(coords)):
        if p.turn:
            continue
        lon, lat = coords[p.index][0], coords[p.index][1]
        parts.append(
            f'<wpt lat="{lat:.6f}" lon="{lon:.6f}"><name>{escape(p.name)}</name><type>{escape(p.kind)}</type></wpt>'
        )
    parts.append(f"<trk><name>{title}</name><type>{fit.SPORT[normalise(c.route.activity)]}</type><trkseg>")
    for point in coords:
        ele = f"<ele>{point[2]:.1f}</ele>" if len(point) > 2 and point[2] is not None else ""
        parts.append(f'<trkpt lat="{point[1]:.6f}" lon="{point[0]:.6f}">{ele}</trkpt>')
    parts.append("</trkseg></trk></gpx>")
    return "\n".join(parts)
