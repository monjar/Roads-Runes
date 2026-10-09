"""GPX / TCX / FIT export of a journey (spec §39, §93; FIT for Garmin, docs/GARMIN.md).

Every format carries the fixes processing keeps (`service.kept_points`), and says
what the journey was: a run is not exported as a ride.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any
from xml.sax.saxutils import escape

from app.core import fit
from app.core.activity import normalise, verb
from app.core.geo import haversine_m
from app.rides.models import Ride
from app.rides.validation import CleanPoint

GPX_TYPE: dict[str, str] = {"RIDE": "cycling", "RUN": "running", "WALK": "walking"}
# TCX knows only these three sports.
TCX_SPORT: dict[str, str] = {"RIDE": "Biking", "RUN": "Running", "WALK": "Other"}


def _iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def name(ride: Ride) -> str:
    """The journey's title, else what it was and when: "Ride 8 Oct 2026"."""
    if ride.title:
        return ride.title
    day = ride.local_date or ride.started_at.date()
    return f"{verb(ride.activity)} {day.day} {day:%b %Y}"


def to_gpx(ride: Ride, points: list[CleanPoint]) -> str:
    title = escape(name(ride))
    parts = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<gpx version="1.1" creator="Roads &amp; Runes" xmlns="http://www.topografix.com/GPX/1/1" '
        'xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">',
        f"<metadata><name>{title}</name><time>{_iso(ride.started_at)}</time></metadata>",
        f"<trk><name>{title}</name><type>{GPX_TYPE[normalise(ride.activity)]}</type><trkseg>",
    ]
    for p in points:
        ext = (
            f"<extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>{p.heart_rate}</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>"
            if p.heart_rate
            else ""
        )
        ele = f"<ele>{p.altitude:.1f}</ele>" if p.altitude is not None else ""
        parts.append(
            f'<trkpt lat="{p.latitude:.6f}" lon="{p.longitude:.6f}">{ele}<time>{_iso(p.timestamp)}</time>{ext}</trkpt>'
        )
    parts.append("</trkseg></trk></gpx>")
    return "\n".join(parts)


def to_tcx(ride: Ride, points: list[CleanPoint]) -> str:
    parts = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">',
        f'<Activities><Activity Sport="{TCX_SPORT[normalise(ride.activity)]}">',
        f"<Id>{_iso(ride.started_at)}</Id>",
        f'<Lap StartTime="{_iso(ride.started_at)}"><TotalTimeSeconds>{ride.duration_seconds}</TotalTimeSeconds>'
        f"<DistanceMeters>{ride.distance_meters:.1f}</DistanceMeters><Calories>{int(ride.active_calories or 0)}</Calories>"
        "<Intensity>Active</Intensity><TriggerMethod>Manual</TriggerMethod><Track>",
    ]
    for p in points:
        hr = f"<HeartRateBpm><Value>{p.heart_rate}</Value></HeartRateBpm>" if p.heart_rate else ""
        alt = f"<AltitudeMeters>{p.altitude:.1f}</AltitudeMeters>" if p.altitude is not None else ""
        parts.append(
            f"<Trackpoint><Time>{_iso(p.timestamp)}</Time><Position><LatitudeDegrees>{p.latitude:.6f}</LatitudeDegrees>"
            f"<LongitudeDegrees>{p.longitude:.6f}</LongitudeDegrees></Position>{alt}{hr}</Trackpoint>"
        )
    parts.append("</Track></Lap></Activity></Activities></TrainingCenterDatabase>")
    return "\n".join(parts)


def _record(p: CleanPoint, distance_m: float) -> dict[str, Any]:
    record: dict[str, Any] = {
        "mesg_num": fit.MESG["RECORD"],
        "timestamp": fit.fit_time(p.timestamp),
        "position_lat": fit.semicircles(p.latitude),
        "position_long": fit.semicircles(p.longitude),
        "distance": distance_m,
    }
    # Only what fits the field: a broken altimeter or a negative "no speed" is left out.
    if p.altitude is not None and -500 <= p.altitude <= 9000:
        record["altitude"] = p.altitude
    if p.speed is not None and 0 <= p.speed <= 60:
        record["speed"] = p.speed
    if p.heart_rate and 0 < p.heart_rate < 255:
        record["heart_rate"] = int(p.heart_rate)
    return record


def to_fit(ride: Ride, points: list[CleanPoint]) -> bytes:
    """A FIT activity file (one session, one lap) a rider can import into Garmin
    Connect by hand: Garmin lets no other app add it for them. `points` is not empty."""
    start, end = points[0], points[-1]
    records: list[dict[str, Any]] = []
    travelled = 0.0
    for prev, p in zip([None, *points[:-1]], points, strict=True):
        if prev is not None:
            travelled += haversine_m(prev.latitude, prev.longitude, p.latitude, p.longitude)
        records.append(_record(p, travelled))
    elapsed = max(0.0, (end.timestamp - start.timestamp).total_seconds())
    timer = float(ride.duration_seconds or elapsed)
    heart = [p.heart_rate for p in points if p.heart_rate]
    totals: dict[str, Any] = {
        "timestamp": fit.fit_time(end.timestamp),
        "start_time": fit.fit_time(start.timestamp),
        "start_position_lat": fit.semicircles(start.latitude),
        "start_position_long": fit.semicircles(start.longitude),
        "end_position_lat": fit.semicircles(end.latitude),
        "end_position_long": fit.semicircles(end.longitude),
        "total_elapsed_time": elapsed,
        "total_timer_time": timer,
        "total_distance": ride.distance_meters or travelled,
        "total_ascent": round(ride.elevation_gain_meters or 0),
        "sport": fit.SPORT[normalise(ride.activity)],
    }
    if ride.average_speed_mps:
        totals["avg_speed"] = min(ride.average_speed_mps, 60.0)
    if ride.max_speed_mps:
        totals["max_speed"] = min(ride.max_speed_mps, 60.0)
    if heart:
        totals["avg_heart_rate"] = round(sum(heart) / len(heart))
        totals["max_heart_rate"] = max(heart)
    if ride.active_calories:
        totals["total_calories"] = round(ride.active_calories)
    return fit.encode(
        [
            fit.file_id("activity", start.timestamp),
            {
                "mesg_num": fit.MESG["EVENT"],
                "timestamp": fit.fit_time(start.timestamp),
                "event": "timer",
                "event_type": "start",
            },
            *records,
            {
                "mesg_num": fit.MESG["EVENT"],
                "timestamp": fit.fit_time(end.timestamp),
                "event": "timer",
                "event_type": "stop_all",
            },
            {
                "mesg_num": fit.MESG["LAP"],
                "message_index": 0,
                "event": "lap",
                "event_type": "stop",
                "lap_trigger": "session_end",
                **totals,
            },
            {
                "mesg_num": fit.MESG["SESSION"],
                "message_index": 0,
                "event": "session",
                "event_type": "stop",
                "trigger": "activity_end",
                "first_lap_index": 0,
                "num_laps": 1,
                **totals,
            },
            {
                "mesg_num": fit.MESG["ACTIVITY"],
                "timestamp": fit.fit_time(end.timestamp),
                "total_timer_time": timer,
                "num_sessions": 1,
                "type": "manual",
                "event": "activity",
                "event_type": "stop",
            },
        ]
    )
