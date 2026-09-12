"""Score how well a ride request is understood, with and without a model.

Usage: python scripts/eval_requests.py [model ...]      (default: the two candidates)

The rules parser (`app/routing/preferences.py`) is a floor under whatever the
model says, so what is scored here is the merged result the planner actually
uses. Two sets: things riders write plainly, and things they write the way
people actually talk — implicit intent, negation, another language.

The key comes from ANTHROPIC_API_KEY or secrets/claude.txt (gitignored). On
2026-09-12, on 26 checks of the hard set: rules 17, Haiku 4.5 26 (median 1.5 s),
Sonnet 5 26 (median 1.7 s) — hence Haiku as the default in app/core/config.py.
"""

from __future__ import annotations

import asyncio
import os
import statistics
import sys
import time
from collections.abc import Callable
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.core.llm import AnthropicLLM, NullLLM  # noqa: E402
from app.routing.preferences import RoutePreferences, parse_request  # noqa: E402

Check = Callable[[RoutePreferences], bool]

CANDIDATES = ("claude-haiku-4-5-20251001", "claude-sonnet-5")


def category(p: RoutePreferences) -> str | None:
    return (p.poi or {}).get("category")


def count(p: RoutePreferences) -> int | None:
    return (p.poi or {}).get("count")


def position(p: RoutePreferences) -> float | None:
    return (p.poi or {}).get("preferredPosition")


def area(p: RoutePreferences) -> str:
    return ((p.area or {}).get("query") or "").lower()


def target_km(p: RoutePreferences) -> float | None:
    return (p.distanceKm or {}).get("target")


PLAIN: list[tuple[str, dict[str, Check]]] = [
    (
        "A gravel heavy ride with 1 nice cafe stop",
        {
            "café": lambda p: category(p) == "CAFE",
            "one of them": lambda p: count(p) == 1,
            "gravel": lambda p: p.gravelPreference >= 0.7,
            "no place named": lambda p: not area(p),
        },
    ),
    (
        "a biker ride in notting hill with about 5 pubs",
        {
            "the place": lambda p: "notting hill" in area(p),
            "pubs": lambda p: category(p) == "PUB",
            "five": lambda p: count(p) == 5,
        },
    ),
    ("Richmond bike ride", {"the place": lambda p: "richmond" in area(p)}),
    (
        "I want the ride to be through 3 top cafes or cultural",
        {
            "a kind of stop": lambda p: category(p) in {"CAFE", "CULTURAL"},
            "three": lambda p: count(p) == 3,
            "no place named": lambda p: not area(p),
        },
    ),
    (
        "something flat and quiet, nothing too far",
        {"flat": lambda p: p.hillTolerance <= 0.3, "quiet": lambda p: p.trafficAversion >= 0.8},
    ),
    (
        "30 miles with a pub halfway",
        {
            "miles": lambda p: bool(target_km(p)) and 44 <= target_km(p) <= 52,
            "pub": lambda p: category(p) == "PUB",
            "halfway": lambda p: 0.35 <= (position(p) or 0) <= 0.65,
        },
    ),
    (
        "a couple of hours of hills, no gravel",
        {
            "hours as distance": lambda p: bool(target_km(p)) and 24 <= target_km(p) <= 45,
            "hilly": lambda p: p.hillTolerance >= 0.7,
            "paved": lambda p: p.gravelPreference <= 0.2,
        },
    ),
    (
        "scenic loop around richmond park with a coffee stop",
        {
            "the place": lambda p: "richmond" in area(p),
            "coffee": lambda p: category(p) == "CAFE",
            "a loop": lambda p: p.loop is True,
        },
    ),
    (
        "fast and direct, no stops please",
        {"not scenic": lambda p: p.scenicPreference <= 0.35, "no stops": lambda p: p.poi is None},
    ),
    (
        "easy ride with the kids to a museum",
        {"museum": lambda p: category(p) == "CULTURAL", "gentle": lambda p: p.hillTolerance <= 0.3},
    ),
]

AS_PEOPLE_TALK: list[tuple[str, dict[str, Check]]] = [
    (
        "I've got about an hour before sunset, keep it close to home and mostly off tarmac",
        {
            "an hour of riding": lambda p: bool(target_km(p)) and 12 <= target_km(p) <= 20,
            "off tarmac": lambda p: p.gravelPreference >= 0.5,
        },
    ),
    (
        "take the tourists to see something old, nothing too far",
        {"something old": lambda p: category(p) in {"HISTORICAL", "CULTURAL", "LANDMARK"}},
    ),
    (
        "quiero un paseo tranquilo de 20 km con un café",
        {
            "20 km": lambda p: target_km(p) == 20,
            "un café": lambda p: category(p) == "CAFE",
            "tranquilo": lambda p: p.trafficAversion >= 0.7,
        },
    ),
    (
        "avoid the main roads, I'm on 25mm tyres",
        {"quiet": lambda p: p.trafficAversion >= 0.8, "road tyres": lambda p: p.gravelPreference <= 0.3},
    ),
    (
        "a loop that isn't hilly with two stops for coffee and cake",
        {
            "coffee": lambda p: category(p) == "CAFE",
            "two": lambda p: count(p) == 2,
            "not hilly": lambda p: p.hillTolerance <= 0.35,
            "loop": lambda p: p.loop is True,
        },
    ),
    ("somewhere I can watch the sunset over the city", {"a viewpoint": lambda p: category(p) == "VIEWPOINT"}),
    ("im knackered, short and flat", {"flat": lambda p: p.hillTolerance <= 0.3}),
    (
        "ride out to hampstead heath and back, grab lunch on the way",
        {"the place": lambda p: "hampstead" in area(p), "lunch": lambda p: category(p) in {"FOOD", "CAFE"}},
    ),
    (
        "45 min spin, no cafes, just riding",
        {
            "45 minutes": lambda p: bool(target_km(p)) and 9 <= target_km(p) <= 14,
            "no stops": lambda p: p.poi is None,
        },
    ),
    ("chuck in a castle or two", {"castles": lambda p: category(p) == "HISTORICAL", "two": lambda p: count(p) == 2}),
    (
        "the long way round to greenwich, stop at a nice bakery",
        {"the place": lambda p: "greenwich" in area(p), "a bakery": lambda p: category(p) in {"CAFE", "FOOD"}},
    ),
    (
        "6 miles, dead flat, and a pub at the end",
        {
            "miles": lambda p: bool(target_km(p)) and 9 <= target_km(p) <= 11,
            "pub": lambda p: category(p) == "PUB",
            "at the end": lambda p: (position(p) or 0) >= 0.7,
            "flat": lambda p: p.hillTolerance <= 0.3,
        },
    ),
]


def api_key() -> str:
    key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if key:
        return key
    path = Path(__file__).resolve().parents[2] / "secrets" / "claude.txt"
    raw = path.read_text().strip() if path.exists() else ""
    # The file has been pasted into twice before now; either copy will do.
    parts = [part for part in raw.split("sk-ant-") if part]
    return f"sk-ant-{parts[0]}" if parts else ""


async def score(name: str, llm, cases: list[tuple[str, dict[str, Check]]]) -> None:
    total = hits = 0
    latencies: list[float] = []
    misses: list[str] = []
    for text, checks in cases:
        started = time.perf_counter()
        prefs = (await parse_request(text, llm)).preferences
        latencies.append((time.perf_counter() - started) * 1000)
        for label, check in checks.items():
            total += 1
            try:
                ok = bool(check(prefs))
            except Exception:  # noqa: BLE001 - a broken check is a failed check
                ok = False
            hits += ok
            if not ok:
                misses.append(f"{text[:44]!r}: {label}")
    print(f"  {name:<28} {hits:>2}/{total}   median {statistics.median(latencies):>6.0f} ms")
    for miss in misses:
        print(f"      missed {miss}")


async def main() -> None:
    models = sys.argv[1:] or list(CANDIDATES)
    key = api_key()
    if not key:
        print("No ANTHROPIC_API_KEY and no secrets/claude.txt; scoring the rules parser only.")
        models = []
    for title, cases in (("plainly written", PLAIN), ("as people talk", AS_PEOPLE_TALK)):
        print(f"\n{title}")
        await score("rules only", NullLLM(), cases)
        for model in models:
            await score(model, AnthropicLLM(key, model), cases)


if __name__ == "__main__":
    asyncio.run(main())
