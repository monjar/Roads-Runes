"""FIT files for Garmin (docs/GARMIN.md): what a course and an activity share.

Garmin's own SDK writes the bytes; this holds the few conversions it leaves to us.
Positions are semicircles, times are seconds since the FIT epoch, and a naive
datetime is UTC here (the SDK would read it as the server's local time).
"""

from __future__ import annotations

import re
import unicodedata
from datetime import UTC, datetime
from typing import Any

from garmin_fit_sdk import Encoder, Profile

FIT_EPOCH_S = 631065600
MEDIA_TYPE = "application/vnd.ant.fit"
# What a Garmin calls the sport, by the app's activity.
SPORT: dict[str, str] = {"RIDE": "cycling", "RUN": "running", "WALK": "walking"}
# A course point's name is read on a small screen; longer names are cut by the device.
COURSE_POINT_NAME_MAX = 16
COURSE_NAME_MAX = 40

MESG = Profile["mesg_num"]


def utc(dt: datetime) -> datetime:
    return dt.replace(tzinfo=UTC) if dt.tzinfo is None else dt.astimezone(UTC)


def fit_time(dt: datetime) -> int:
    return int(utc(dt).timestamp()) - FIT_EPOCH_S


def semicircles(degrees: float) -> int:
    return round(degrees * (2**31 / 180.0))


def short(text: str, limit: int) -> str:
    """At most `limit` characters, cut at a word when that keeps most of it:
    "Rotherhithe Street" is "Rotherhithe" on a small screen, not "Rotherhithe Stre"."""
    text = " ".join(text.split())
    if len(text) <= limit:
        return text
    cut = text[: limit + 1].rsplit(" ", 1)[0]
    return cut if len(cut) >= limit // 2 else text[:limit].strip()


def file_id(kind: str, created: datetime) -> dict[str, Any]:
    """`kind` is "course" or "activity". The manufacturer is FIT's own `development`:
    the file says it was written by an app, not a Garmin."""
    return {
        "mesg_num": MESG["FILE_ID"],
        "type": kind,
        "manufacturer": "development",
        "product": 0,
        "time_created": fit_time(created),
    }


def encode(mesgs: list[dict[str, Any]]) -> bytes:
    encoder = Encoder()
    for mesg in mesgs:
        encoder.write_mesg(mesg)
    return bytes(encoder.close())


def filename(name: str, extension: str) -> str:
    """A name a share sheet and a file system both take: ASCII, no quotes or slashes."""
    plain = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
    safe = re.sub(r"[^A-Za-z0-9 ._&'-]+", " ", plain)
    safe = " ".join(safe.split()).strip(" .") or "Roads and Runes"
    return f"{safe[:60]}.{extension}"
