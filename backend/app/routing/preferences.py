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
    poi: dict[str, Any] | None = None  # {"category": "PUB", "preferredPosition": 0.75}
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
            break
    return ParsedRequest(preferences=prefs.clamp(), source="rules", matched=matched)


LLM_SYSTEM = (
    "Convert a cyclist's free-text route request into structured preferences. "
    "Output only fields you are confident about. Preference values are floats 0..1. "
    "Never output coordinates or place names as destinations."
)
LLM_SCHEMA = (
    '{"distanceKm": {"target": number, "tolerance": number} | null, "trafficAversion": number, '
    '"cyclewayPreference": number, "gravelPreference": number, "scenicPreference": number, '
    '"hillTolerance": number, "poi": {"category": "PUB|CAFE|FOOD|VIEWPOINT|NATURE|HISTORICAL|LANDMARK|TRAIL", '
    '"preferredPosition": number} | null, "loop": boolean | null}'
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
    elif rules.preferences.poi:
        prefs.poi = rules.preferences.poi
    if isinstance(result.get("loop"), bool):
        prefs.loop = result["loop"]
    elif rules.preferences.loop is not None:
        prefs.loop = rules.preferences.loop
    return ParsedRequest(preferences=prefs.clamp(), source="llm", matched=rules.matched)
