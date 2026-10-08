"""Places nothing in the game should be placed at, joked about or asked of.

Memorials, graves, places of worship, hospitals and anything marked private
(docs/WORLD.md, "Real places"). Read from the tags OpenStreetMap gives a place,
with the name as a fallback: a cemetery filed as a nature reserve still says
"Cemetery" on it. Pure, and used wherever the game picks a real place: the
spawner's anchors (every kind of world object), quest targets, place lore.
"""

from __future__ import annotations

import re
from typing import Any

SENSITIVE_TAGS: dict[str, set[str] | None] = {
    # None means any value.
    "historic": {"memorial", "monument", "wayside_cross", "wayside_shrine", "tomb", "grave", "cemetery"},
    "amenity": {"place_of_worship", "grave_yard", "crematorium", "hospital", "hospice", "funeral_hall", "mortuary"},
    "landuse": {"cemetery", "religious"},
    "building": {"church", "chapel", "mosque", "synagogue", "temple", "cathedral", "shrine", "religious", "hospital"},
    "healthcare": {"hospital", "hospice"},
    "memorial": None,
    "religion": None,
    "cemetery": None,
    "access": {"private", "no"},
}

_NAME = re.compile(
    r"\b(cemetery|graveyard|churchyard|crematorium|memorial|cenotaph|war grave|church|chapel|cathedral|minster|"
    r"mosque|masjid|synagogue|temple|gurdwara|mandir|shrine|hospice|hospital|mortuary|burial)\b",
    re.IGNORECASE,
)


def is_sensitive(name: str | None, tags: dict[str, Any] | None) -> bool:
    tags = tags or {}
    for key, values in SENSITIVE_TAGS.items():
        if key in tags and (values is None or str(tags[key]).lower() in values):
            return True
    return bool(name and _NAME.search(name))
