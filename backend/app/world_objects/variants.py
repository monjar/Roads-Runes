"""Variants and grudges (docs/ROADMAP.md 0.7.2; config/world_objects.json
`variants` and `grudges`). Pure: a seed in, a variant or an epithet out.

* A variant: one creature in five of tiers 1 and 2 is Stubborn (more health and
  more coins), Skittish (less of both, and gone in a day) or Mossy (twice as
  likely to leave an item). The name stays plain; the client puts the variant in
  front ("Stubborn Fen Troll", `displayName`).
* A grudge: a creature that got away weakened twice at the same place comes back
  once, as "Fen Troll the Grumpy", tougher, richer, and sure to leave an item.
"""

from __future__ import annotations

import json
import random
from functools import lru_cache
from pathlib import Path
from typing import Any

CONFIG = Path(__file__).parent / "config" / "world_objects.json"
# Seeds are a String(96) column; a grudge's is "grudge:{anchor uuid}:{species id}".
SEED_WIDTH = 96


@lru_cache
def book() -> dict[str, Any]:
    data = json.loads(CONFIG.read_text())
    variants = data["variants"]
    assert {k["id"] for k in variants["kinds"]} == {"STUBBORN", "SKITTISH", "MOSSY"}
    for kind in variants["kinds"]:
        assert kind["name"] and kind["text"], kind["id"]
    grudges = data["grudges"]
    assert grudges["epithets"] and grudges["line"]
    return data


@lru_cache
def kinds() -> dict[str, dict[str, Any]]:
    return {k["id"]: k for k in book()["variants"]["kinds"]}


def pick_variant(object_seed: str, tier: int) -> str | None:
    """The variant a creature placed with this seed has, if any. Its own random
    stream, so the rest of what is placed is as it was before variants."""
    rules = book()["variants"]
    if tier not in rules["tiers"]:
        return None
    rng = random.Random(f"variant:{object_seed}")
    if rng.random() >= float(rules["chance"]):
        return None
    options = rules["kinds"]
    return str(rng.choices([k["id"] for k in options], weights=[float(k["weight"]) for k in options], k=1)[0])


def variant_out(variant_id: str | None) -> dict[str, str] | None:
    kind = kinds().get(variant_id or "")
    return {"id": kind["id"], "name": kind["name"], "text": kind["text"]} if kind else None


def display_name(payload: dict[str, Any] | None) -> str:
    """The name to show, a variant in front: "Stubborn Fen Troll". A grudge's name
    already carries its epithet."""
    payload = payload or {}
    name = str(payload.get("name") or "")
    kind = kinds().get(str(payload.get("variant") or ""))
    return f"{kind['name']} {name}" if kind and name else name


def grudge_seed(anchor_id: str, species_id: str) -> str:
    seed = f"grudge:{anchor_id}:{species_id}"
    assert len(seed) <= SEED_WIDTH, seed
    return seed


def epithet(seed: str) -> str:
    return str(random.Random(seed).choice(book()["grudges"]["epithets"]))


def grudge_out(payload: dict[str, Any] | None) -> dict[str, str] | None:
    grudge = (payload or {}).get("grudge")
    if not grudge:
        return None
    return {"epithet": str(grudge.get("epithet") or ""), "line": str(book()["grudges"]["line"])}
