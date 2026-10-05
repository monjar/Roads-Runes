"""Looks (0.9.0): route ink, marker frames and crest frames (config/cosmetics.json).
Pure. They are kept as `inventory_items` with prefixed ids (no table of their own);
the free ones everyone has, and each deed tier reached gives a crest frame."""

from __future__ import annotations

import json
import random
from functools import lru_cache
from pathlib import Path
from typing import Any

CONFIG = Path(__file__).parent / "config" / "cosmetics.json"
KINDS = {"ink": "INK", "marker": "MARKER_FRAME", "crest": "CREST_FRAME"}
# PUT /inventory/look's fields, by kind.
LOOK_FIELDS = {"INK": "ink", "MARKER_FRAME": "markerFrame", "CREST_FRAME": "crestFrame"}
PREFIXES = tuple(f"{p}:" for p in KINDS)


@lru_cache
def book() -> dict[str, Any]:
    data = json.loads(CONFIG.read_text())
    ids = [i["id"] for i in data["items"]]
    assert len(ids) == len(set(ids)), "cosmetic ids must be unique"
    for item in data["items"]:
        prefix = item["id"].split(":")[0]
        assert KINDS.get(prefix) == item["kind"], f"{item['id']} has the wrong prefix for {item['kind']}"
        assert len(item["id"]) <= 40, f"{item['id']} fits inventory_items.item_id"
        assert item["price"] == 0 or 200 <= item["price"] <= 400, f"{item['id']}: the stall sells looks for 200-400"
        assert item["kind"] != "INK" or item.get("color"), f"{item['id']}: an ink needs a colour"
    for field, default in data["defaults"].items():
        assert field in LOOK_FIELDS.values() and default in ids, field
    assert sum(1 for i in data["items"] if i["kind"] == "INK") == 6, "six inks"
    assert sum(1 for i in data["items"] if i["kind"] == "MARKER_FRAME") == 4, "four marker frames"
    assert sum(1 for i in data["items"] if i["kind"] == "CREST_FRAME" and i["price"]) == 3, "three crest frames to buy"
    return data


@lru_cache
def by_id() -> dict[str, dict[str, Any]]:
    return {i["id"]: i for i in book()["items"]}


def is_cosmetic(item_id: str | None) -> bool:
    return bool(item_id) and str(item_id).startswith(PREFIXES)


def kind_of(item_id: str) -> str | None:
    return KINDS.get(str(item_id).split(":")[0]) if ":" in str(item_id) else None


def defaults() -> dict[str, str]:
    return dict(book()["defaults"])


def free() -> list[str]:
    return [i["id"] for i in book()["items"] if not i["price"]]


def for_sale() -> list[dict[str, Any]]:
    return [i for i in book()["items"] if i["price"]]


def deed_frame_id(deed_id: str, tier: int) -> str:
    from app.inventory.deeds import frame_id

    return f"crest:{frame_id(deed_id, tier)}"


def deed_frame(item_id: str) -> dict[str, Any] | None:
    """A crest frame a deed gave ("crest:legs-2"), named for the deed title it came with."""
    from app.inventory.deeds import DEEDS

    if not str(item_id).startswith("crest:"):
        return None
    rest = str(item_id).removeprefix("crest:")
    deed_id, _, tier = rest.rpartition("-")
    deed = next((d for d in DEEDS if d["id"].lower() == deed_id), None)
    if deed is None or not tier.isdigit() or not 1 <= int(tier) <= len(deed["titles"]):
        return None
    return {
        "id": item_id,
        "kind": "CREST_FRAME",
        "name": deed["titles"][int(tier) - 1],
        "text": f"Earned with the {deed['name']} deed.",
        "price": 0,
    }


def entry(item_id: str) -> dict[str, Any] | None:
    return by_id().get(item_id) or deed_frame(item_id)


def stall_offer(user_id: str, week: str, owned: set[str]) -> dict[str, Any] | None:
    """The stall's fifth offer for the week: one look not owned, seeded by player and
    week (in the same order all week, so it stays put once bought)."""
    pool = sorted(for_sale(), key=lambda i: i["id"])
    random.Random(f"stall-look:{user_id}:{week}").shuffle(pool)
    choice = next((i for i in pool if i["id"] not in owned), None)
    if choice is None:
        return None
    short = week.split("-W")[-1]
    return {
        "id": f"w{short}-4",
        "kind": "COSMETIC",
        "itemId": choice["id"],
        "cosmeticKind": choice["kind"],
        "price": int(choice["price"]),
    }
