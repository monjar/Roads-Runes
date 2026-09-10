"""GPX / TCX export (spec §39, §93)."""

from __future__ import annotations

from datetime import datetime
from xml.sax.saxutils import escape

from app.rides.models import Ride, RidePoint


def _iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def to_gpx(ride: Ride, points: list[RidePoint]) -> str:
    name = escape(ride.title or "Roads & Runes ride")
    parts = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<gpx version="1.1" creator="Roads & Runes" xmlns="http://www.topografix.com/GPX/1/1" '
        'xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">',
        f"<metadata><name>{name}</name><time>{_iso(ride.started_at)}</time></metadata>",
        f"<trk><name>{name}</name><type>cycling</type><trkseg>",
    ]
    for p in points:
        ext = (
            f"<extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>{p.heart_rate_bpm}</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>"
            if p.heart_rate_bpm
            else ""
        )
        ele = f"<ele>{p.altitude_meters:.1f}</ele>" if p.altitude_meters is not None else ""
        parts.append(
            f'<trkpt lat="{p.latitude:.6f}" lon="{p.longitude:.6f}">{ele}<time>{_iso(p.timestamp)}</time>{ext}</trkpt>'
        )
    parts.append("</trkseg></trk></gpx>")
    return "\n".join(parts)


def to_tcx(ride: Ride, points: list[RidePoint]) -> str:
    parts = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">',
        '<Activities><Activity Sport="Biking">',
        f"<Id>{_iso(ride.started_at)}</Id>",
        f'<Lap StartTime="{_iso(ride.started_at)}"><TotalTimeSeconds>{ride.duration_seconds}</TotalTimeSeconds>'
        f"<DistanceMeters>{ride.distance_meters:.1f}</DistanceMeters><Calories>{int(ride.active_calories or 0)}</Calories>"
        "<Intensity>Active</Intensity><TriggerMethod>Manual</TriggerMethod><Track>",
    ]
    for p in points:
        hr = f"<HeartRateBpm><Value>{p.heart_rate_bpm}</Value></HeartRateBpm>" if p.heart_rate_bpm else ""
        alt = f"<AltitudeMeters>{p.altitude_meters:.1f}</AltitudeMeters>" if p.altitude_meters is not None else ""
        parts.append(
            f"<Trackpoint><Time>{_iso(p.timestamp)}</Time><Position><LatitudeDegrees>{p.latitude:.6f}</LatitudeDegrees>"
            f"<LongitudeDegrees>{p.longitude:.6f}</LongitudeDegrees></Position>{alt}{hr}</Trackpoint>"
        )
    parts.append("</Track></Lap></Activity></Activities></TrainingCenterDatabase>")
    return "\n".join(parts)
