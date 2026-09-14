"""Route preference model and natural-language parsing (spec §25, §31)."""

from __future__ import annotations

import re
from dataclasses import asdict, dataclass, field
from typing import Any

from app.core.llm import LLMClient

# Words a rider uses for a kind of stop. The categories must be ones
# `app/discoveries/osm_import.py:category_for` actually produces, or the stop
# search finds nothing: CAFE, PUB, NATURE, HISTORICAL, CULTURAL, LANDMARK,
# VIEWPOINT, CYCLING. FOOD and TRAIL are understood but never imported, so they
# read as a request the route can only honour incidentally.
POI_WORDS = {
    "pub": "PUB",
    "beer": "PUB",
    "pint": "PUB",
    "bar": "PUB",
    "cafe": "CAFE",
    "café": "CAFE",
    "coffee": "CAFE",
    "food": "FOOD",
    "lunch": "FOOD",
    "restaurant": "FOOD",
    "view": "VIEWPOINT",
    "viewpoint": "VIEWPOINT",
    "peak": "VIEWPOINT",
    "summit": "VIEWPOINT",
    "park": "NATURE",
    "forest": "NATURE",
    "wood": "NATURE",
    "garden": "NATURE",
    "nature": "NATURE",
    "castle": "HISTORICAL",
    "church": "HISTORICAL",
    "monument": "HISTORICAL",
    "historic": "HISTORICAL",
    "historical": "HISTORICAL",
    "ruin": "HISTORICAL",
    "museum": "CULTURAL",
    "gallery": "CULTURAL",
    "art": "CULTURAL",
    "cultural": "CULTURAL",
    "culture": "CULTURAL",
    "landmark": "LANDMARK",
    "attraction": "LANDMARK",
    "sight": "LANDMARK",
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


# Asking for a good one, not just any one.
QUALITY_WORDS = (
    "nice",
    "best",
    "good",
    "great",
    "top",
    "proper",
    "decent",
    "lovely",
    "favourite",
    "favorite",
    "independent",
    "special",
    "famous",
)

COUNT_WORDS = {
    "a couple": 2,
    "a couple of": 2,
    "a": 1,
    "an": 1,
    "a few": 3,
    "some": 3,
    "several": 4,
    "one": 1,
    "two": 2,
    "three": 3,
    "four": 4,
    "five": 5,
    "six": 6,
    "seven": 7,
    "eight": 8,
    "nine": 9,
    "ten": 10,
}
# "in Notting Hill with 5 pubs" -> "notting hill". The phrase is a guess; the geocoder
# decides whether it is a place, so this can afford to be generous.
AREA_PATTERN = re.compile(
    r"\b(?:in|around|near|through|via|round)\s+(?!the\s+(?:morning|afternoon|evening))"
    r"([a-z0-9'\u2019\-\. ]{3,40}?)"
    r"(?=\s+(?:with|and|for|that|about|including|taking|via|through)\b|[,.;]|$)"
)
NOT_A_PLACE = re.compile(r"^\s*(?:\d|an? |the )?\s*(?:hour|hr|min|km|mile|k\b|loop|circle|ride|bit|while)")

# "go to the Aragon Tower", "out to Greenwich", "as far as the pier". A ride *to*
# somewhere, which `in|around|near` never covered: those put the rider inside a
# neighbourhood, this one gives them a finish line.
DESTINATION_PATTERN = re.compile(
    r"\b(?:as far as|all the way to|up to|out to|over to|down to|ending at|ending in|"
    r"finishing at|finish at|end at|end up at|towards|toward|to)\s+"
    r"([a-z0-9'\u2019\-\. ]{3,40}?)"
    r"(?=\s+(?:with|and|for|that|about|including|taking|via|through|then|plus|on the way|"
    r"and back|before|after)\b|[,.;]|$)"
)


def _destination_phrase(lowered: str) -> tuple[str, int, int] | None:
    """The place a rider said they want to end up at, and where they said it.

    "to" is the most overloaded word in a ride request — "I want to go", "close to
    home", "up to 40 km" — so the same test the area guess uses applies here: a
    phrase made only of riding words names nothing, and the geocoder is the judge
    of what is left.
    """
    for match in DESTINATION_PATTERN.finditer(lowered):
        phrase = _trim_lead(match.group(1).strip(" .,"))
        if len(phrase) < 3 or NOT_A_PLACE.match(phrase) or not _names_a_place(phrase):
            continue
        return phrase, match.start(1), match.end(1)
    return None


def _trim_lead(phrase: str) -> str:
    """Drop the run-up and keep the name.

    "I want to go to the Aragon Tower" matches at the first `to`, so the phrase
    arrives as "go to the aragon tower". Everything before the first word that
    could be part of a name is run-up — and a phrase that is *all* run-up ("go for
    a 20km ride") trims down to nothing, which is the right answer.
    """
    words = phrase.split()
    while words and (
        words[0] in RIDE_WORDS
        or words[0].rstrip("s") in RIDE_WORDS
        or words[0] in COUNT_WORDS
        or words[0] in {"to", "the", "a", "an"}
        or words[0][:1].isdigit()
    ):
        words.pop(0)
    return " ".join(words)


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
    "i",
    "we",
    "us",
    "our",
    "on",
    "at",
    "out",
    "up",
    "over",
    "off",
    "just",
    "get",
    "getting",
    "head",
    "heading",
    "end",
    "ending",
    "finish",
    "finishing",
    "start",
    "starting",
    "there",
    "here",
    "towards",
    "toward",
    "as",
    "far",
    "all",
    "going",
    "goes",
    "gone",
    "let",
    "lets",
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
    # How a rider qualifies the stops they want: "3 top cafes", "the best pubs".
    "top",
    "favourite",
    "favorite",
    "popular",
    "local",
    "famous",
    "cool",
    "must",
    "see",
    "including",
    "include",
    "includes",
    "visit",
    "visiting",
    "pass",
    "passing",
    "stopping",
    "then",
    "plus",
    "or",
    "also",
    "maybe",
    "either",
    # Prepositions AREA_PATTERN uses; on their own they name nothing.
    "through",
    "via",
    "along",
    "across",
    "past",
    "between",
    # How much of a thing: "gravel heavy", "mostly quiet", "loads of climbing".
    "heavy",
    "mostly",
    "mainly",
    "packed",
    "full",
    "loads",
    "lot",
    "little",
}


def _names_a_place(phrase: str) -> bool:
    """ "richmond park" is a place; "3 top cafes or cultural" is a shopping list.

    `through`/`via` introduce both ("a ride through Richmond", "a ride through 3
    cafes"), so a phrase that counts things, or says nothing but what kind of
    stop is wanted, is not handed to the geocoder.
    """
    words = re.findall(r"[a-z0-9'\u2019\-]+", phrase)
    if not words or any(word[:1].isdigit() for word in words):
        return False
    return not all(
        word in RIDE_WORDS
        or word.rstrip("s") in RIDE_WORDS
        or word in POI_WORDS
        or word.rstrip("s") in POI_WORDS
        or word in COUNT_WORDS
        for word in words
    )


def _area_phrase(lowered: str) -> str | None:
    for match in AREA_PATTERN.finditer(lowered):
        phrase = match.group(1).strip(" .,")
        if len(phrase) < 3 or NOT_A_PLACE.match(phrase) or not _names_a_place(phrase):
            continue
        return phrase
    # No preposition ("richmond bike ride"): whatever is left once the riding words,
    # the numbers and the kinds of stop are gone is a candidate name. The geocoder is
    # what decides whether it is really a place.
    leftover = [
        word
        for word in re.findall(r"[a-z0-9'\u2019\-]+", lowered)
        if word not in RIDE_WORDS
        # "quiet roads" is not a ride in Roads Wood: the plural of a riding word is one too.
        and word.rstrip("s") not in RIDE_WORDS
        and word not in POI_WORDS
        and word.rstrip("s") not in POI_WORDS
        and word not in COUNT_WORDS
        and not word[:1].isdigit()
    ]
    if 1 <= len(leftover) <= 3 and all(len(w) > 2 for w in leftover):
        return " ".join(leftover)
    return None


HOURS_PATTERN = re.compile(
    r"\b(\d+(?:\.\d)?|an|a|one|two|three|four|five|six|a couple of|a couple|a few)\s*"
    r"(?:hours?|hrs?|h)\b(\s+and\s+a\s+half)?"
)
HOUR_WORDS = {"an": 1.0, "a": 1.0, "one": 1.0, "two": 2.0, "three": 3.0, "four": 4.0, "five": 5.0, "six": 6.0}
HOUR_WORDS.update({"a couple of": 2.0, "a couple": 2.0, "a few": 3.0})


def _hours(lowered: str) -> float | None:
    """ "an hour and a half", "a couple of hours", "90 minutes" — riders say time as
    often as distance, and only ever gave us a number before."""
    match = HOURS_PATTERN.search(lowered)
    if match:
        word = match.group(1)
        hours = float(word) if word.replace(".", "", 1).isdigit() else HOUR_WORDS.get(word)
        if hours:
            return hours + (0.5 if match.group(2) else 0.0)
    minutes = re.search(r"\b(\d{2,3})\s*(?:minutes|mins|min)\b", lowered)
    return int(minutes.group(1)) / 60 if minutes else None


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
    hours = _hours(lowered)
    if hours and not prefs.distanceKm:
        km = hours * 16
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
    # "nothing steep" and "no big hills" are about hills, and mean the opposite of
    # "hilly": look for the refusal first and let it stand.
    gentle = any(
        w in lowered
        for w in ("flat", "easy", "gentle", "no hills", "nothing steep", "not steep", "nothing hilly", "not hilly")
    )
    if gentle:
        prefs.hillTolerance = 0.15
        matched.append("flat")
    elif any(w in lowered for w in ("hilly", "climb", "hills", "hard", "tough", "steep")):
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

    # A destination is read first, and hidden from the area guess: "to the Aragon
    # Tower" must not also read as "a ride around Aragon Tower", which would move
    # the start instead of setting a finish.
    destination = _destination_phrase(lowered)
    for_area = lowered
    if destination:
        _, start_at, end_at = destination
        for_area = lowered[:start_at] + " " * (end_at - start_at) + lowered[end_at:]
    phrase = _area_phrase(for_area)

    # "3 cafes or somewhere cultural" asks for two kinds of stop. They are kept in
    # the order the rider wrote them: the first is the one scoring prefers, and any
    # of them can fill the count.
    asked = sorted(
        (match.start(), word, category)
        for word, category in POI_WORDS.items()
        if (match := re.search(rf"\b{re.escape(word)}s?\b", lowered))
    )
    # "a loop around richmond park with a coffee stop" wants coffee; the park is part
    # of where, not what. A word inside the place name is not a kind of stop.
    named = " ".join(filter(None, [phrase, destination[0] if destination else None]))
    if named:
        elsewhere = [entry for entry in asked if entry[1] not in named]
        asked = elsewhere or asked
    if asked:
        position = 0.5
        if any(w in lowered for w in ("end", "towards the end", "finish", "near the end", "last")):
            position = 0.8
        elif any(w in lowered for w in ("start", "beginning", "first")):
            position = 0.2
        elif any(w in lowered for w in ("halfway", "middle", "midway")):
            position = 0.5
        categories: list[str] = []
        for _, _, category in asked:
            if category not in categories:
                categories.append(category)
        categories = categories[:3]
        prefs.poi = {"category": categories[0], "preferredPosition": position}
        if len(categories) > 1:
            prefs.poi["categories"] = categories
        # "a nice cafe", "the best pub": worth a detour past the nearest one.
        if any(w in lowered for w in QUALITY_WORDS):
            prefs.poi["quality"] = True
            matched.append("quality")
        matched.append(f"poi:{'+'.join(categories)}")
        for _, word, _ in asked:
            count = _poi_count(lowered, word)
            if count:
                prefs.poi["count"] = count
                matched.append(f"count:{count}")
                break

    if phrase:
        prefs.area = {"query": phrase}
        matched.append(f"area:{phrase}")
    if destination:
        prefs.destination = {"query": destination[0]}
        matched.append(f"destination:{destination[0]}")
        # Riding to somewhere is not riding in a circle, unless they asked for both.
        if prefs.loop is None:
            prefs.loop = False
    return ParsedRequest(preferences=prefs.clamp(), source="rules", matched=matched)


LLM_SYSTEM = (
    "Convert a cyclist's free-text route request into structured preferences. "
    "Output only fields you are confident about. Preference values are floats 0..1. "
    "`area` is a place the rider named to ride *in* — a town, a neighbourhood, a park "
    '("a loop in Notting Hill") — as written, never coordinates and never a '
    "description of the riding or of the stops. `destination` is a place they want to "
    'ride *to* and finish at ("go to the Aragon Tower", "out to Greenwich pier"), '
    "which can be a single named thing: a tower, a bridge, a pub, a station. Use one "
    "or the other, not both for the same words. "
    "`poi` is the kind of stop they want on the way: cafés and coffee are CAFE, pubs and "
    "bars PUB, restaurants and lunch FOOD, museums, galleries and anything cultural "
    "CULTURAL, parks, woods and gardens NATURE, castles, churches and monuments "
    "HISTORICAL, attractions and sights LANDMARK, viewpoints, peaks and summits "
    "VIEWPOINT, trails TRAIL. `poi.count` is how many of them they asked for, and "
    "`poi.preferredPosition` where along the ride they want it (0 start, 1 finish). "
    "`distanceKm.target` may come from a time they gave: assume 16 km per hour. "
    '`poi.quality` is true when they want a *good* one — "a nice cafe", "the best pub" '
    "— rather than whichever is nearest."
)
LLM_SCHEMA = (
    '{"distanceKm": {"target": number, "tolerance": number} | null, "trafficAversion": number, '
    '"cyclewayPreference": number, "gravelPreference": number, "scenicPreference": number, '
    '"hillTolerance": number, "poi": {"category": "PUB|CAFE|FOOD|VIEWPOINT|NATURE|HISTORICAL|CULTURAL|LANDMARK|TRAIL", '
    '"preferredPosition": number, "count": number | null, "quality": boolean} | null, '
    '"area": {"query": string} | null, "destination": {"query": string} | null, '
    '"loop": boolean | null}'
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
        # A model that has no opinion sends `"preferredPosition": null`, and float(None)
        # would take the whole request down with it.
        position = poi.get("preferredPosition")
        prefs.poi = {
            "category": poi["category"],
            "preferredPosition": min(1.0, max(0.0, float(position))) if isinstance(position, int | float) else 0.5,
        }
        count = poi.get("count")
        if isinstance(count, int | float) and 1 <= count <= 8:
            prefs.poi["count"] = int(count)
        elif (rules.preferences.poi or {}).get("count"):
            prefs.poi["count"] = rules.preferences.poi["count"]
        if poi.get("quality") is True or (rules.preferences.poi or {}).get("quality"):
            prefs.poi["quality"] = True
        # The schema has room for one category; the rules parser sees "cafes or
        # museums", so keep its list when it agrees about the main one.
        also = (rules.preferences.poi or {}).get("categories") or []
        if prefs.poi["category"] in also:
            prefs.poi["categories"] = list(also)
    elif "poi" in result and poi is None:
        # "no cafes, just riding": the model read the sentence, while the rules parser
        # only saw the word "cafes". An explicit null is a decision, not a gap.
        prefs.poi = None
    elif rules.preferences.poi:
        prefs.poi = rules.preferences.poi
    area = result.get("area")
    if isinstance(area, dict) and isinstance(area.get("query"), str) and area["query"].strip():
        prefs.area = {"query": area["query"].strip()[:60]}
    elif rules.preferences.area:
        prefs.area = rules.preferences.area
    destination = result.get("destination")
    if isinstance(destination, dict) and isinstance(destination.get("query"), str) and destination["query"].strip():
        prefs.destination = {"query": destination["query"].strip()[:60]}
    elif "destination" in result and destination is None:
        # An explicit null is the model reading "no particular destination"; the
        # rules parser only saw the word "to".
        prefs.destination = None
    elif rules.preferences.destination:
        prefs.destination = rules.preferences.destination
    # The same words cannot be both; riding to somewhere wins, because it is the
    # more specific promise and the one a wrong answer ruins.
    if prefs.destination and prefs.area and prefs.destination.get("query") == prefs.area.get("query"):
        prefs.area = None
    if isinstance(result.get("loop"), bool):
        prefs.loop = result["loop"]
    elif rules.preferences.loop is not None:
        prefs.loop = rules.preferences.loop
    elif prefs.destination:
        prefs.loop = False
    matched = [m for m in rules.matched if not str(m).startswith("destination:")]
    if prefs.destination:
        matched.append(f"destination:{prefs.destination['query']}")
    return ParsedRequest(preferences=prefs.clamp(), source="llm", matched=matched)
