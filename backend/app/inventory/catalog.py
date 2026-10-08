"""The runes as a build (config/runes.json): which can be held, what each does when
inscribed, at which rank, and where the Ground Six are found. Pure."""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Any

from app.lore import catalog as lore

CONFIG = Path(__file__).parent / "config" / "runes.json"
MAX_RANK = 3
# The forms a track can cut; Ansuz (a note) and Wunjo (a stop) are not shapes.
CUT_FORMS = ("LOOP", "ZIGZAG", "TRIANGLE", "SQUARE")


@lru_cache
def book() -> dict[str, Any]:
    data = json.loads(CONFIG.read_text())
    known = lore.runes_by_id()
    rules = set()
    for rune in data["runes"]:
        assert rune["id"] in known, f"no such rune: {rune['id']}"
        assert len(rune["values"]) == MAX_RANK + 1, f"{rune['id']} needs a value per rank and one woken"
        assert rune["rule"] not in rules, f"two runes share {rune['rule']}"
        rules.add(rune["rule"])
        if rune["six"] == "GROUND":
            assert rune.get("ground"), f"{rune['id']} is a Ground rune with no ground"
        # The Hard Six are taken, never picked up: no ground, and no stone on the map;
        # the Trade Six are given (0.9.0), never picked up either.
        assert rune["six"] not in ("HARD", "TRADE") or not rune.get("ground"), f"{rune['id']} is given, with ground"
        assert rune["six"] == known[rune["id"]]["six"], f"{rune['id']} is in another six in the lore"
    return data


@lru_cache
def by_id() -> dict[str, dict[str, Any]]:
    return {r["id"]: r for r in book()["runes"]}


def holdable(rune_id: str) -> bool:
    return rune_id in by_id()


def slots_for_level(level: int) -> int:
    return sum(1 for at in book()["slotsAtLevel"] if level >= at)


def rank_cost(to_rank: int) -> dict[str, int] | None:
    return book()["rankCost"].get(str(to_rank))


def value(rune_id: str, rank: int) -> float:
    """The rule's number at a rank; rank 4 is rank III woken."""
    values = by_id()[rune_id]["values"]
    return float(values[max(1, min(len(values), rank)) - 1])


def rule_text(rune_id: str, rank: int) -> str:
    v = value(rune_id, rank)
    km = v / 1000
    n = int(v)
    # {first} reads "first" for one and "first 3" for more, so rank I is not "the first 1".
    first = "first" if n == 1 else f"first {n}"
    return by_id()[rune_id]["text"].format(
        v=f"{v:g}", km=f"{km:g}", n=n, s="" if n == 1 else "s", min=f"{v / 60:g}", first=first, pct=f"{v * 100:g}"
    )


def rules_for(inscribed: dict[str, int]) -> dict[str, float]:
    """The rules a set of inscribed runes make, by rule id: {"CARRIED_SCALE": 2.0}."""
    out: dict[str, float] = {}
    for rune_id, rank in inscribed.items():
        entry = by_id().get(rune_id)
        if entry is not None:
            out[entry["rule"]] = value(rune_id, rank)
    return out


def road_form(rune_id: str) -> str | None:
    return (lore.runes_by_id().get(rune_id) or {}).get("roadForm")


def rune_for_form(form: str) -> str | None:
    return lore.rune_for_form().get(form)


def _matches(ground: dict[str, Any], category: str | None, tags: dict[str, Any]) -> bool:
    if category and category in (ground.get("categories") or []):
        return True
    for key, wanted in (ground.get("tags") or {}).items():
        if key in tags and ("*" in wanted or str(tags[key]) in wanted):
            return True
    return False


def ground_runes_at(category: str | None, tags: dict[str, Any] | None) -> list[str]:
    """The Ground Six whose own kind of ground this place is."""
    return [r["id"] for r in book()["runes"] if r["six"] == "GROUND" and _matches(r["ground"], category, tags or {})]


def hard_six() -> list[str]:
    return [r["id"] for r in book()["runes"] if r["six"] == "HARD"]


def trade_six() -> list[str]:
    return [r["id"] for r in book()["runes"] if r["six"] == "TRADE"]


def road_six() -> list[str]:
    return [r["id"] for r in book()["runes"] if r["six"] == "ROAD"]


def name(rune_id: str) -> str:
    return str((lore.runes_by_id().get(rune_id) or {}).get("name") or rune_id.capitalize())
