"""A district's title from its places (config/titles.json). Pure.

`count_places` folds a district's places into `place_counts` (stored on the region);
`title_for` reads the first rule that applies. "pubs top" and "food top" compare
the group with every single category outside it, so a district of three pubs and
three cafés is a Tavern Quarter only when the pubs are at least as many as any
other kind of place.
"""

from __future__ import annotations

import json
from collections.abc import Iterable
from functools import lru_cache
from pathlib import Path
from typing import Any

from app.discoveries.sensitivity import is_sensitive

CONFIG = Path(__file__).parent / "config" / "titles.json"


@lru_cache
def book() -> dict[str, Any]:
    data = json.loads(CONFIG.read_text())
    groups = {k: v for k, v in data["groups"].items() if not k.startswith("_")}
    for rule in data["rules"]:
        assert rule["group"] in groups or rule["group"] == "places", f"no such group: {rule['group']}"
        assert sum(1 for k in ("share", "count", "top", "under") if k in rule) == 1, rule
        assert len(rule["title"]) <= 40, f"{rule['title']} is longer than the epithet column"
        assert rule["title"].startswith("the "), f"{rule['title']} must read after a comma"
    return {**data, "groups": groups}


def _matches(group: dict[str, Any], category: str | None, tags: dict[str, Any]) -> bool:
    if category and category in group.get("categories", []):
        return True
    for key, wanted in (group.get("tags") or {}).items():
        if key in tags and ("*" in wanted or str(tags[key]) in wanted):
            return True
    return False


def count_places(places: Iterable[tuple[str, str | None, dict[str, Any] | None]]) -> dict[str, Any]:
    """`places` as (name, category, tags). Returns {"total", "categories": {...},
    "groups": {...}}, the shape `place_counts` keeps."""
    groups = book()["groups"]
    total = 0
    categories: dict[str, int] = {}
    counted = dict.fromkeys(groups, 0)
    for name, category, tags in places:
        tags = tags or {}
        total += 1
        if category:
            categories[category] = categories.get(category, 0) + 1
        for gid, group in groups.items():
            if not _matches(group, category, tags):
                continue
            if gid == "historical" and is_sensitive(name, tags):
                continue
            counted[gid] += 1
    return {"total": total, "categories": categories, "groups": counted}


def title_for(counts: dict[str, Any] | None) -> str | None:
    """The first rule that applies, or None when none does."""
    counts = counts or {}
    total = int(counts.get("total") or 0)
    groups = counts.get("groups") or {}
    categories = counts.get("categories") or {}
    book_groups = book()["groups"]
    for rule in book()["rules"]:
        gid = rule["group"]
        if gid == "places":
            if total < int(rule["under"]):
                return str(rule["title"])
            continue
        n = int(groups.get(gid) or 0)
        if "share" in rule and total and n / total >= float(rule["share"]):
            return str(rule["title"])
        if "count" in rule and n >= int(rule["count"]):
            return str(rule["title"])
        if rule.get("top") and n:
            inside = set(book_groups[gid].get("categories") or [])
            others = [v for k, v in categories.items() if k not in inside]
            if n >= max(others, default=0):
                return str(rule["title"])
    return None


def shown_title(epithet: str | None, percent: float | None) -> str | None:
    """What the player sees after the comma: the title from 10% explored; under it
    (or before the roads are known) none, and the name reads "in the fog"."""
    if epithet is None or percent is None or percent < float(book()["fogUnderPercent"]):
        return None
    return epithet


def display_name(name: str, epithet: str | None, percent: float | None) -> str:
    """ "Rotherhithe, the Riverlands", or "Rotherhithe, in the fog"."""
    shown = shown_title(epithet, percent)
    if shown is not None:
        return f"{name}, {shown}"
    if percent is None or percent < float(book()["fogUnderPercent"]):
        return f"{name}, {book()['fog']}"
    return name
