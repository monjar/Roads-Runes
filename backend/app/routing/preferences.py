"""What a rider asked for, read by Claude (spec §25, §31).

This used to be a keyword parser: word lists for every way of saying "pub", a
regex per preposition, a table of number words, and a rule that whatever was
left of the sentence might be a place. It answered "a biker ride in notting hill
with about 5 pubs" and little that was not close to it, and every phrasing a
rider actually used needed another pattern. Reading a sentence is the model's
job, so it does it.

The model returns *names*, never coordinates: `app/routing/geocode.py` resolves
them, and anything it cannot find is reported rather than ridden past — so
nothing the model invents reaches navigation (spec §20). Everything else it
returns is range-checked here, so a bad answer narrows to a plain ride rather
than a wrong one.

With no provider configured there is no parser at all, and a typed request says
so instead of quietly planning something else.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any

from app.core.llm import LLMClient

# The kinds of stop the world actually holds: `app/discoveries/osm_import.py`
# imports these, so asking for anything else finds nothing.
CATEGORIES = (
    "PUB",
    "CAFE",
    "FOOD",
    "VIEWPOINT",
    "NATURE",
    "HISTORICAL",
    "CULTURAL",
    "LANDMARK",
    "TRAIL",
)

SCALARS = (
    "trafficAversion",
    "cyclewayPreference",
    "gravelPreference",
    "scenicPreference",
    "hillTolerance",
)


@dataclass
class RoutePreferences:
    trafficAversion: float = 0.7
    cyclewayPreference: float = 0.7
    gravelPreference: float = 0.3
    scenicPreference: float = 0.6
    hillTolerance: float = 0.5
    distanceKm: dict[str, float] | None = None  # {"target": 30, "tolerance": 5}
    # {"category": "PUB", "preferredPosition": 0.75, "count": 5, "categories": [...],
    # "quality": True when they asked for a *good* one rather than any}
    poi: dict[str, Any] | None = None
    # Where the rider asked to ride: {"query": "Notting Hill"} until resolved, then
    # {"name", "latitude", "longitude"} as well (app/routing/geocode.py).
    area: dict[str, Any] | None = None
    # Somewhere to ride *to*, which is a different ride from riding *in* somewhere:
    # "to the Aragon Tower" ends there, "in Deptford" wanders around it. Same shape
    # as `area`: {"query": ...} until the geocoder answers.
    destination: dict[str, Any] | None = None
    # Named places to pass *through*, in the order the rider said them: "visit the
    # Moby Dick pub then to Aragon Tower" names one. A category stop ("2 pubs") is
    # whichever pub suits the route; this is that pub and no other, so it is a
    # waypoint rather than a preference. Same shape as `area` once resolved.
    via: list[dict[str, Any]] | None = None
    loop: bool | None = None

    def clamp(self) -> RoutePreferences:
        for name in SCALARS:
            setattr(self, name, min(1.0, max(0.0, float(getattr(self, name)))))
        return self

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class ParsedRequest:
    preferences: RoutePreferences
    #  "llm"          the model read it
    #  "unreadable"   the model was asked and gave nothing usable
    #  "unavailable"  no provider configured, so nothing read it
    source: str
    matched: list[str] = field(default_factory=list)

    @property
    def read_by_nobody(self) -> bool:
        return self.source == "unavailable"


SYSTEM = """You read one sentence from a cyclist and return what they asked for.

Places. A rider names a place in one of two ways, and they plan different rides:
- `destination` — somewhere to ride TO and finish at. "go to the Aragon Tower",
  "out to Greenwich pier", "take me to the Cutty Sark", "as far as the old
  bridge". It can be a single named thing: a tower, a bridge, a pub, a station,
  a park.
- `area` — somewhere to ride IN or AROUND. "a loop in Notting Hill", "a ride
  around Richmond Park", "somewhere in the Chilterns". The whole ride moves
  there.
- `via` — named places to ride THROUGH on the way, in the order they said them.
  "visit the Moby Dick pub then to Aragon Tower" rides through the Moby Dick and
  finishes at the tower. "past the old mill" is one. These are *named* places, so
  a name is the whole test: "2 pubs on the way" names none and belongs in
  `stops`, but "the Moby Dick" is one place and no other will do.
Use whichever the sentence means, not both for the same words. Return the name
as the rider wrote it, trimmed to just the name. NEVER return coordinates,
directions, or a description of the riding as a place: "a quiet 30 km loop"
names no place at all, and neither does "3 top cafes".

Stops. `stops.categories` is the kind of place they want on the way, best first:
PUB (pubs, bars, a pint), CAFE (cafés, coffee), FOOD (lunch, restaurants),
NATURE (parks, woods, gardens), HISTORICAL (castles, churches, monuments,
ruins), CULTURAL (museums, galleries), LANDMARK (attractions, sights),
VIEWPOINT (views, peaks, summits), TRAIL (trails). `stops.count` is how many
they asked for ("a couple" is 2, "a few" is 3). `stops.preferredPosition` is
where along the ride they want them: 0 is the start, 1 the finish, 0.5 halfway;
use 0.5 when they just said "on the way". `stops.quality` is true when they want
a *good* one ("a nice cafe", "the best pub") rather than whichever is nearest.
A place named as the destination or in `via` is not also a kind of stop: "to the
Old Church and 2 pubs" wants pubs, and "the Moby Dick pub then Aragon Tower"
wants no `stops` at all — both places are named.

Distance. `distanceKm.target` in kilometres. Convert miles (1.61 km) and time —
assume 16 km/h on a bike, so "a couple of hours" is about 32 km. "up to 40 km"
is a target of 40.

Riding preferences are 0 to 1, and null when the sentence says nothing about
them — the rider's own profile fills those in, so do not guess:
- trafficAversion: high for "quiet", "calm", "avoid traffic"; low for "fast",
  "direct".
- cyclewayPreference: high for "bike paths", "cycle lanes".
- gravelPreference: high for "gravel", "off-road", "trails"; 0 for "paved",
  "tarmac", "no gravel", "road bike".
- scenicPreference: high for "scenic", "pretty", "views"; low for "direct".
- hillTolerance: high for "hilly", "climbing", "tough"; low for "flat", "easy",
  "gentle", "nothing steep".

`loop` is true for "loop", "circular", "back home"; false for "one way" or a
ride to a destination; null when unsaid.

Read negations as decisions: "no cafes, just riding" means stops is null, not
CAFE. Return null for anything the sentence does not say."""


def _place_schema(description: str) -> dict[str, Any]:
    return {
        "description": description,
        "anyOf": [
            {
                "type": "object",
                "properties": {"query": {"type": "string", "description": "The name as the rider wrote it."}},
                "required": ["query"],
                "additionalProperties": False,
            },
            {"type": "null"},
        ],
    }


def _scalar_schema(description: str) -> dict[str, Any]:
    return {
        "description": description,
        "anyOf": [{"type": "number", "minimum": 0, "maximum": 1}, {"type": "null"}],
    }


SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "destination": _place_schema("Somewhere to ride to and finish at."),
        "area": _place_schema("Somewhere to ride in or around."),
        "via": {
            "description": "Named places to ride through on the way, in the order said.",
            "anyOf": [
                {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {"query": {"type": "string", "description": "The name as the rider wrote it."}},
                        "required": ["query"],
                        "additionalProperties": False,
                    },
                    "minItems": 1,
                    "maxItems": 5,
                },
                {"type": "null"},
            ],
        },
        "distanceKm": {
            "description": "How far they want to ride, in kilometres.",
            "anyOf": [
                {
                    "type": "object",
                    "properties": {
                        "target": {"type": "number", "minimum": 1, "maximum": 400},
                        "tolerance": {"anyOf": [{"type": "number"}, {"type": "null"}]},
                    },
                    "required": ["target", "tolerance"],
                    "additionalProperties": False,
                },
                {"type": "null"},
            ],
        },
        "stops": {
            "description": "The kind of place they want on the way.",
            "anyOf": [
                {
                    "type": "object",
                    "properties": {
                        "categories": {
                            "type": "array",
                            "items": {"type": "string", "enum": list(CATEGORIES)},
                            "minItems": 1,
                            "maxItems": 3,
                        },
                        "count": {"anyOf": [{"type": "integer", "minimum": 1, "maximum": 8}, {"type": "null"}]},
                        "preferredPosition": {
                            "anyOf": [{"type": "number", "minimum": 0, "maximum": 1}, {"type": "null"}]
                        },
                        "quality": {"type": "boolean"},
                    },
                    "required": ["categories", "count", "preferredPosition", "quality"],
                    "additionalProperties": False,
                },
                {"type": "null"},
            ],
        },
        "trafficAversion": _scalar_schema("How much they want to avoid traffic."),
        "cyclewayPreference": _scalar_schema("How much they want cycle paths."),
        "gravelPreference": _scalar_schema("How much unpaved riding they want."),
        "scenicPreference": _scalar_schema("How much they want it to be pretty."),
        "hillTolerance": _scalar_schema("How much climbing they will take."),
        "loop": {"description": "Back where they started.", "anyOf": [{"type": "boolean"}, {"type": "null"}]},
    },
    "required": ["destination", "area", "via", "distanceKm", "stops", *SCALARS, "loop"],
    "additionalProperties": False,
}


def _name(value: Any) -> dict[str, Any] | None:
    """A place name the model read back out of the sentence."""
    if not isinstance(value, dict):
        return None
    query = value.get("query")
    if not isinstance(query, str) or not query.strip():
        return None
    return {"query": query.strip()[:60]}


def _places(value: Any) -> list[dict[str, Any]] | None:
    """The named places to ride through, in order, with the repeats dropped."""
    if not isinstance(value, list):
        return None
    ordered: list[dict[str, Any]] = []
    seen: set[str] = set()
    for item in value[:5]:
        place = _name(item)
        if place and place["query"].lower() not in seen:
            seen.add(place["query"].lower())
            ordered.append(place)
    return ordered or None


def _distance(value: Any) -> dict[str, float] | None:
    if not isinstance(value, dict) or not isinstance(value.get("target"), int | float):
        return None
    target = float(value["target"])
    if not 1 <= target <= 400:
        return None
    tolerance = value.get("tolerance")
    usable = isinstance(tolerance, int | float) and not isinstance(tolerance, bool) and tolerance > 0
    return {"target": target, "tolerance": float(tolerance) if usable else max(3.0, target * 0.15)}


def _stops(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        return None
    raw = value.get("categories")
    # Deduplicated, order kept: the first is the one scoring prefers.
    ordered: list[str] = []
    for category in raw if isinstance(raw, list) else []:
        if category in CATEGORIES and category not in ordered:
            ordered.append(category)
    if not ordered:
        return None
    ordered = ordered[:3]
    position = value.get("preferredPosition")
    known = isinstance(position, int | float) and not isinstance(position, bool)
    poi: dict[str, Any] = {
        "category": ordered[0],
        "preferredPosition": min(1.0, max(0.0, float(position))) if known else 0.5,
    }
    if len(ordered) > 1:
        poi["categories"] = ordered
    count = value.get("count")
    if isinstance(count, int | float) and not isinstance(count, bool) and 1 <= count <= 8:
        poi["count"] = int(count)
    if value.get("quality") is True:
        poi["quality"] = True
    return poi


async def parse_request(text: str, llm: LLMClient, base: RoutePreferences | None = None) -> ParsedRequest:
    """Read a rider's sentence into preferences, or say honestly that nothing did."""
    prefs = RoutePreferences(**(base.to_dict() if base else {}))
    if not llm.enabled:
        return ParsedRequest(preferences=prefs.clamp(), source="unavailable")

    result = await llm.extract(SYSTEM, text, SCHEMA)
    if not isinstance(result, dict):
        return ParsedRequest(preferences=prefs.clamp(), source="unreadable")

    matched: list[str] = []
    for name in SCALARS:
        value = result.get(name)
        if isinstance(value, int | float) and not isinstance(value, bool):
            setattr(prefs, name, float(value))
            matched.append(name)

    prefs.distanceKm = _distance(result.get("distanceKm"))
    if prefs.distanceKm:
        matched.append("distance")

    prefs.poi = _stops(result.get("stops"))
    if prefs.poi:
        kinds = prefs.poi.get("categories") or [prefs.poi["category"]]
        matched.append(f"poi:{'+'.join(kinds)}")
        if prefs.poi.get("count"):
            matched.append(f"count:{prefs.poi['count']}")
        if prefs.poi.get("quality"):
            matched.append("quality")

    prefs.destination = _name(result.get("destination"))
    prefs.area = _name(result.get("area"))
    prefs.via = _places(result.get("via"))
    # The finish is not also somewhere to pass through, and neither name is the
    # region the ride sits in: a duplicate would route the rider there twice.
    if prefs.via:
        named = {p["query"].lower() for p in (prefs.destination, prefs.area) if p}
        prefs.via = [p for p in prefs.via if p["query"].lower() not in named] or None
    # The same words cannot be both; riding to somewhere wins, because it is the
    # more specific promise and the one a wrong answer ruins.
    if prefs.destination and prefs.area and prefs.destination["query"].lower() == prefs.area["query"].lower():
        prefs.area = None
    if prefs.destination:
        matched.append(f"destination:{prefs.destination['query']}")
    if prefs.area:
        matched.append(f"area:{prefs.area['query']}")
    for place in prefs.via or []:
        matched.append(f"via:{place['query']}")

    if isinstance(result.get("loop"), bool):
        prefs.loop = result["loop"]
        matched.append("loop" if prefs.loop else "one-way")
    elif prefs.destination:
        # Riding to somewhere is not riding in a circle, unless they asked for both.
        prefs.loop = False

    return ParsedRequest(preferences=prefs.clamp(), source="llm", matched=matched)
