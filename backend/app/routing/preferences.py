"""Route preference model and natural-language parsing (spec §25, §31)."""

from __future__ import annotations

import re
from dataclasses import asdict, dataclass, field
from typing import Any

from app.core.llm import LLMClient

POI_WORDS = {
    "pub": "PUB",
    "beer": "PUB",
    "cafe": "CAFE",
    "café": "CAFE",
    "coffee": "CAFE",
    "food": "FOOD",
    "lunch": "FOOD",
    "restaurant": "FOOD",
    "view": "VIEWPOINT",
    "viewpoint": "VIEWPOINT",
    "park": "NATURE",
    "forest": "NATURE",
    "wood": "NATURE",
    "castle": "HISTORICAL",
    "church": "HISTORICAL",
    "landmark": "LANDMARK",
    "trail": "TRAIL",
}


@dataclass
class RoutePreferences:
    trafficAversion: float = 0.7
    cyclewayPreference: float = 0.7
    gravelPreference: float = 0.3
    scenicPreference: float = 0.6
    hillTolerance: float = 0.5
    distanceKm: dict[str, float] | None = None  # {"target": 30, "tolerance": 5}
    poi: dict[str, Any] | None = None  # {"category": "PUB", "preferredPosition": 0.75, "count": 5}
    # Where the rider asked to ride: {"query": "Notting Hill"} until resolved, then
    # {"name", "latitude", "longitude"} as well (app/routing/geocode.py).
    area: dict[str, Any] | None = None
    loop: bool | None = None

    def clamp(self) -> RoutePreferences:
        for name in (
            "trafficAversion",
            "cyclewayPreference",
            "gravelPreference",
            "scenicPreference",
            "hillTolerance",
        ):
            setattr(self, name, min(1.0, max(0.0, float(getattr(self, name)))))
        return self

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class ParsedRequest:
    preferences: RoutePreferences
    source: str  # "llm" | "rules"
    matched: list[str] = field(default_factory=list)


COUNT_WORDS = {"a couple": 2, "a couple of": 2, "a few": 3, "some": 3, "several": 4}
# "in Notting Hill with 5 pubs" -> "notting hill". The phrase is a guess; the geocoder
# decides whether it is a place, so this can afford to be generous.
AREA_PATTERN = re.compile(
    r"\b(?:in|around|near|through|via|round)\s+(?!the\s+(?:morning|afternoon|evening))"
    r"([a-z0-9'\u2019\-\. ]{3,40}?)"
    r"(?=\s+(?:with|and|for|that|about|including|taking|via|through)\b|[,.;]|$)"
)
NOT_A_PLACE = re.compile(r"^\s*(?:\d|an? |the )?\s*(?:hour|hr|min|km|mile|k\b|loop|circle|ride|bit|while)")


# Everything a request can say that is about the riding, not about a place. What is
# left after removing these is a candidate name — "richmond bike ride" -> "richmond".
RIDE_WORDS = {
    "a",
    "an",
    "the",
    "my",
    "me",
    "some",
    "any",
    "about",
    "around",
    "roughly",
    "with",
    "and",
    "for",
    "of",
    "to",
    "please",
    "want",
    "give",
    "plan",
    "find",
    "take",
    "go",
    "ride",
    "rides",
    "riding",
    "bike",
    "biker",
    "bicycle",
    "cycle",
    "cycling",
    "route",
    "loop",
    "circular",
    "tour",
    "trip",
    "spin",
    "today",
    "tomorrow",
    "morning",
    "afternoon",
    "evening",
    "quiet",
    "calm",
    "peaceful",
    "scenic",
    "pretty",
    "beautiful",
    "nice",
    "easy",
    "gentle",
    "flat",
    "hilly",
    "hills",
    "climb",
    "climbing",
    "hard",
    "tough",
    "challenging",
    "fast",
    "quick",
    "direct",
    "short",
    "long",
    "gravel",
    "paved",
    "tarmac",
    "road",
    "off-road",
    "unpaved",
    "trails",
    "new",
    "km",
    "kms",
    "kilometres",
    "kilometers",
    "miles",
    "mile",
    "hour",
    "hours",
    "hrs",
    "min",
    "mins",
    "minutes",
    "stops",
    "stop",
    "way",
    "one-way",
    "back",
    "home",
    "near",
    "nearby",
    "somewhere",
    "place",
    "places",
    "views",
    # Quantities and vagueness: "a couple of cafes", "something hilly".
    "couple",
    "few",
    "several",
    "lots",
    "plenty",
    "something",
    "anything",
    "everything",
    "nothing",
    "thing",
    "things",
    "bit",
    "kind",
    "sort",
    "type",
    "recommend",
    "suggest",
    "show",
    "make",
    "need",
    "like",
    "good",
    "great",
    "best",
    "better",
    "fun",
    "lovely",
    "interesting",
    "safe",
    "family",
    "kids",
    "weekend",
    "week",
    "day",
    "night",
    "weather",
}


def _area_phrase(lowered: str) -> str | None:
    for match in AREA_PATTERN.finditer(lowered):
        phrase = match.group(1).strip(" .,")
        if len(phrase) < 3 or NOT_A_PLACE.match(phrase):
            continue
        return phrase
    # No preposition ("richmond bike ride"): whatever is left once the riding words,
    # the numbers and the kinds of stop are gone is a candidate name. The geocoder is
    # what decides whether it is really a place.
    leftover = [
        word
        for word in re.findall(r"[a-z0-9'\u2019\-]+", lowered)
        if word not in RIDE_WORDS and word not in POI_WORDS and word.rstrip("s") not in POI_WORDS and not word.isdigit()
    ]
    if 1 <= len(leftover) <= 3 and all(len(w) > 2 for w in leftover):
        return " ".join(leftover)
    return None


def _poi_count(lowered: str, word: str) -> int | None:
    pattern = rf"\b(\d{{1,2}}|{'|'.join(COUNT_WORDS)})\s+(?:\w+\s+){{0,2}}?{re.escape(word)}s?\b"
    match = re.search(pattern, lowered)
    if not match:
        return None
    found = match.group(1)
    count = int(found) if found.isdigit() else COUNT_WORDS.get(found, 2)
    return max(1, min(8, count))  # more than a handful stops being a bike ride


def parse_rules(text: str, base: RoutePreferences | None = None) -> ParsedRequest:
    """Deterministic keyword parser used as fallback and as a sanity bound for LLM output."""
    prefs = RoutePreferences(**(base.to_dict() if base else {}))
    lowered = text.lower()
    matched: list[str] = []

    m = re.search(r"(\d{1,3})\s*(km|kilomet)", lowered)
    if m:
        prefs.distanceKm = {
            "target": float(m.group(1)),
            "tolerance": max(3.0, float(m.group(1)) * 0.15),
        }
        matched.append("distance")
    m = re.search(r"(\d{1,3})\s*(mi|miles?)\b", lowered)
    if m and not prefs.distanceKm:
        km = float(m.group(1)) * 1.609
        prefs.distanceKm = {"target": round(km, 1), "tolerance": max(3.0, km * 0.15)}
        matched.append("distance")
    m = re.search(r"(\d(?:\.\d)?)\s*(hours?|hrs?|h)\b", lowered)
    if m and not prefs.distanceKm:
        km = float(m.group(1)) * 16
        prefs.distanceKm = {"target": round(km, 1), "tolerance": max(4.0, km * 0.2)}
        matched.append("duration")

    if any(w in lowered for w in ("quiet", "no traffic", "avoid traffic", "calm", "peaceful")):
        prefs.trafficAversion = 0.95
        matched.append("quiet")
    if any(w in lowered for w in ("fast", "direct", "quick", "shortest")):
        prefs.trafficAversion = min(prefs.trafficAversion, 0.5)
        prefs.scenicPreference = 0.2
        matched.append("direct")
    if "gravel" in lowered or "off-road" in lowered or "off road" in lowered or "unpaved" in lowered:
        prefs.gravelPreference = 0.6 if "some" in lowered or "bit" in lowered else 0.9
        matched.append("gravel")
    if any(w in lowered for w in ("no gravel", "paved", "tarmac", "road bike")):
        prefs.gravelPreference = 0.0
        matched.append("paved")
    if any(w in lowered for w in ("flat", "easy", "no hills", "gentle")):
        prefs.hillTolerance = 0.15
        matched.append("flat")
    if any(w in lowered for w in ("hilly", "climb", "hills", "hard", "tough")):
        prefs.hillTolerance = 0.9
        matched.append("hilly")
    if any(w in lowered for w in ("scenic", "pretty", "beautiful", "views", "nature")):
        prefs.scenicPreference = 0.95
        matched.append("scenic")
    if "loop" in lowered or "circular" in lowered or "back home" in lowered:
        prefs.loop = True
        matched.append("loop")
    if "one way" in lowered or "one-way" in lowered:
        prefs.loop = False
        matched.append("one-way")

    for word, category in POI_WORDS.items():
        if re.search(rf"\b{re.escape(word)}s?\b", lowered):
            position = 0.5
            if any(w in lowered for w in ("end", "towards the end", "finish", "near the end", "last")):
                position = 0.8
            elif any(w in lowered for w in ("start", "beginning", "first")):
                position = 0.2
            elif any(w in lowered for w in ("halfway", "middle", "midway")):
                position = 0.5
            prefs.poi = {"category": category, "preferredPosition": position}
            matched.append(f"poi:{category}")
            count = _poi_count(lowered, word)
            if count:
                prefs.poi["count"] = count
                matched.append(f"count:{count}")
            break

    phrase = _area_phrase(lowered)
    if phrase:
        prefs.area = {"query": phrase}
        matched.append(f"area:{phrase}")
    return ParsedRequest(preferences=prefs.clamp(), source="rules", matched=matched)


LLM_SYSTEM = (
    "Convert a cyclist's free-text route request into structured preferences. "
    "Output only fields you are confident about. Preference values are floats 0..1. "
    "`area` is the place the rider named to ride in, as written, never coordinates. "
    "`poi.count` is how many such stops they asked for."
)
LLM_SCHEMA = (
    '{"distanceKm": {"target": number, "tolerance": number} | null, "trafficAversion": number, '
    '"cyclewayPreference": number, "gravelPreference": number, "scenicPreference": number, '
    '"hillTolerance": number, "poi": {"category": "PUB|CAFE|FOOD|VIEWPOINT|NATURE|HISTORICAL|LANDMARK|TRAIL", '
    '"preferredPosition": number, "count": number | null} | null, "area": {"query": string} | null, "loop": boolean | null}'
)


async def parse_request(text: str, llm: LLMClient, base: RoutePreferences | None = None) -> ParsedRequest:
    rules = parse_rules(text, base)
    if not llm.enabled:
        return rules
    result = await llm.complete_json(LLM_SYSTEM, text, LLM_SCHEMA)
    if not result:
        return rules
    prefs = RoutePreferences(**(base.to_dict() if base else {}))
    for name in (
        "trafficAversion",
        "cyclewayPreference",
        "gravelPreference",
        "scenicPreference",
        "hillTolerance",
    ):
        if isinstance(result.get(name), int | float):
            setattr(prefs, name, float(result[name]))
    dist = result.get("distanceKm")
    if isinstance(dist, dict) and isinstance(dist.get("target"), int | float) and 1 <= dist["target"] <= 400:
        prefs.distanceKm = {
            "target": float(dist["target"]),
            "tolerance": float(dist.get("tolerance") or max(3.0, dist["target"] * 0.15)),
        }
    elif rules.preferences.distanceKm:
        prefs.distanceKm = rules.preferences.distanceKm
    poi = result.get("poi")
    if isinstance(poi, dict) and poi.get("category") in {
        "PUB",
        "CAFE",
        "FOOD",
        "VIEWPOINT",
        "NATURE",
        "HISTORICAL",
        "LANDMARK",
        "TRAIL",
    }:
        prefs.poi = {
            "category": poi["category"],
            "preferredPosition": min(1.0, max(0.0, float(poi.get("preferredPosition", 0.5)))),
        }
        count = poi.get("count")
        if isinstance(count, int | float) and 1 <= count <= 8:
            prefs.poi["count"] = int(count)
        elif (rules.preferences.poi or {}).get("count"):
            prefs.poi["count"] = rules.preferences.poi["count"]
    elif rules.preferences.poi:
        prefs.poi = rules.preferences.poi
    area = result.get("area")
    if isinstance(area, dict) and isinstance(area.get("query"), str) and area["query"].strip():
        prefs.area = {"query": area["query"].strip()[:60]}
    elif rules.preferences.area:
        prefs.area = rules.preferences.area
    if isinstance(result.get("loop"), bool):
        prefs.loop = result["loop"]
    elif rules.preferences.loop is not None:
        prefs.loop = rules.preferences.loop
    return ParsedRequest(preferences=prefs.clamp(), source="llm", matched=rules.matched)
