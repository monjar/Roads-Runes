"""The mechanical half of docs/VOICE.md.

Only what a machine can judge without being wrong. Everything that needs taste
("a joke at the wrong place", "the same turn on every screen") stays with a
reader. Matching is on whole words, so "trace" is not "race".

Three kinds of rule:

* BANNED holds on every line a player reads: config (lore and quests included),
  the server's own lines, and anything a model writes, which is replaced by the
  composed line when it trips one.
* An exclamation mark is for a celebration (a level, a creature defeated, a
  quest done) and nowhere else, so it is refused unless the line is one.
* RETIRED is the old lexicon's jargon, the glossary's "Not" column. It is held
  only where `glossary=True` asks: the labels a player reads in a menu (LABELS)
  and the server's own composed lines. Lore, quest and Codex prose are the
  author's to rewrite, and are not held to it until then.
"""

from __future__ import annotations

import re
from typing import Any

# (pattern, why). Case-insensitive unless the pattern sets otherwise.
BANNED: list[tuple[str, str]] = [
    (r"(?-i:\bAC\b)", "coins are coins, never AC"),
    (r"\bactive coins?\b", "coins are coins"),
    (r"\bpence\b|\bpenny\b", "coins are coins, not pence"),
    (r"(?-i:\bHP\b)|\bhit points\b", "a creature has health, never HP"),
    (r"\bloot\b|\bbuffs?\b|\bspawns?\b|\bspawned\b|\bmobs?\b", "no surface jargon"),
    (r"\bsprint\w*|\bracing\b|\brace\b|\bpersonal best\b", "never praise speed; nothing is a race"),
    (r"\bthe settled\b", "a thing has settled; there is no 'the settled'"),
    (
        r"\bthou\b|\bhark\b|\bbehold\b|\brealms?\b|\bdestiny\b|\bheroe?s?\b|\bchosen one\b|\btraveller\b",
        "no archaic diction",
    ),
    (r"\bslay\w*|\bslain\b|\bblood\w*", "no gore"),
    (r"\bgreat job\b|\bamazing\b|\bawesome\b", "no cheerleading"),
    (r"[\U0001F300-\U0001FAFF\u2600-\u27BF]", "no emoji"),
]

EXCLAMATION: tuple[str, str] = (r"!", "an exclamation mark is for a celebration only")

# The words docs/VOICE.md retired, each with the one that replaced it.
RETIRED: list[tuple[str, str]] = [
    (r"\bknacks?\b", "a skill, not a knack"),
    (r"\bability points?\b", "a skill point, not an ability point"),
    (r"\btrades?\b", "a class, not a trade"),
    (r"\bthe reckoning\b", "Journey's end, not the reckoning"),
    (r"\bloosen\w*", "weakened, not loosened"),
    (r"\b(?:seen|sees|see|saw) off\b", "defeated, not seen off"),
    (r"\bits hold\b", "health, not its hold"),
    (r"\bdays kept\b", "a streak, not days kept"),
    (r"\b(?:un)?read ground\b|\bground (?:you had not |not yet )?read\b", "explored or unexplored, not read ground"),
    (r"\bpatch(?:es)?\b", "tiles, not patches"),
    (r"\boutings?\b", "a ride, run, walk or journey, not an outing"),
    (r"\bboxe?s?\b", "a chest, not a box"),
]

_COMPILED = [(re.compile(p, re.IGNORECASE), why) for p, why in BANNED]
_EXCLAMATION = (re.compile(EXCLAMATION[0]), EXCLAMATION[1])
_RETIRED = [(re.compile(p, re.IGNORECASE), why) for p, why in RETIRED]

# The keys whose values a player reads. Ids, slugs, flags, numbers and comments
# are not prose and are never checked.
PROSE_KEYS = {
    "title",
    "description",
    "flavour",
    "tagline",
    "completion",
    "hint",
    "saying",
    "lines",
    "line",
    "body",
    "page",
    "gloss",
    "lends",
    "leaves",
    "story",
    "hook",
    "how",
    "name",
    "titles",
    "role",
    "text",
}

# Lines that celebrate (a quest done): the one place an exclamation mark belongs.
CELEBRATION_KEYS = {"completion"}

# The menu labels held to the glossary as well, by config file (relative to
# app/) and key. Lore, quest and Codex files are not here on purpose.
LABELS: dict[str, set[str]] = {
    "characters/config/classes.json": {"name", "tagline", "description"},
    "characters/config/abilities.json": {"name", "description"},
    "progression/config/titles.json": {"name", "how"},
    "inventory/config/runes.json": {"text"},
    "inventory/config/gear.json": {"name", "text"},
}


def violations(text: str, *, glossary: bool = False, celebration: bool = False) -> list[str]:
    """Why a line breaks the voice, one reason per broken rule; empty if it does not.

    `glossary` also holds it to the retired words (a menu label, or a line the
    server composes); `celebration` lets it end in an exclamation mark."""
    rules = list(_COMPILED)
    if not celebration:
        rules.append(_EXCLAMATION)
    if glossary:
        rules += _RETIRED
    found = []
    for pattern, why in rules:
        match = pattern.search(text or "")
        if match:
            found.append(f"{why}: {match.group(0)!r}")
    return found


def prose(value: Any, key: str | None = None, path: str = "") -> list[tuple[str, str, str]]:
    """Every player-facing string in a JSON document: where it sits, its key, and the text."""
    out: list[tuple[str, str, str]] = []
    if isinstance(value, dict):
        for k, v in value.items():
            if str(k).startswith("_"):
                continue
            out += prose(v, k, f"{path}.{k}" if path else str(k))
    elif isinstance(value, list):
        for i, v in enumerate(value):
            out += prose(v, key, f"{path}[{i}]")
    elif isinstance(value, str) and key in PROSE_KEYS:
        out.append((path, key, value))
    return out
