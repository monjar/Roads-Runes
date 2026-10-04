"""The titles a character can wear (config/titles.json). Pure; the only writer
of a character's titles is `progression.service.award_title`.

Level titles are degrees of being known, from Passer-by to Known to the Roads.
Finishing an arc gives its own. A title is worn as soon as it is earned, until
the player chooses one; after that, earning another only adds it to the list.
"""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Any

CONFIG = Path(__file__).parent / "config" / "titles.json"


@lru_cache
def catalogue() -> list[dict[str, Any]]:
    data = json.loads(CONFIG.read_text())
    titles = data["titles"]
    slugs = [t["slug"] for t in titles]
    assert len(slugs) == len(set(slugs)), "duplicate title slug"
    names = [t["name"] for t in titles]
    assert len(names) == len(set(names)), "two titles share a name"
    for t in titles:
        assert t["source"] in ("LEVEL", "ARC", "DEED", "CAST"), t["slug"]
        assert t.get("how"), f"{t['slug']} does not say how it is earned"
    return titles


@lru_cache
def by_slug() -> dict[str, dict[str, Any]]:
    return {t["slug"]: t for t in catalogue()}


@lru_cache
def renamed() -> dict[str, str]:
    """The seven old level titles, and what each is called now."""
    return dict(json.loads(CONFIG.read_text())["renamed"])


def level_titles() -> list[dict[str, Any]]:
    return sorted((t for t in catalogue() if t["source"] == "LEVEL"), key=lambda t: t["level"])


def level_title(level: int) -> dict[str, Any] | None:
    """The level title this level has reached."""
    best = None
    for t in level_titles():
        if level >= t["level"]:
            best = t
    return best


def level_titles_between(old_level: int, new_level: int) -> list[dict[str, Any]]:
    """Level titles reached by going from one level to another, lowest first."""
    return [t for t in level_titles() if old_level < t["level"] <= new_level]


def arc_title(arc_slug: str) -> dict[str, Any] | None:
    return next((t for t in catalogue() if t["source"] == "ARC" and t.get("arc") == arc_slug), None)
