"""The mechanical half of the voice sheet in docs/WORLD.md.

Only what a machine can judge without being wrong: exclamation marks, surface
jargon, the words the lexicon forbids, archaic and gory diction. Everything
that needs taste ("a joke at the wrong place", "the same turn on every screen")
stays with a reader. Matching is on whole words, so "trace" is not "race".

Used by the voice test over every config file, and at run time on anything a
model writes, so a model's line that trips it is replaced by the composed one.
"""

from __future__ import annotations

import re
from typing import Any

# (pattern, why). Case-insensitive unless the pattern sets otherwise.
BANNED: list[tuple[str, str]] = [
    (r"!", "no exclamation marks"),
    (r"(?-i:\bAC\b)", "coins are coins, never AC"),
    (r"\bactive coins?\b", "coins are coins"),
    (r"\bpence\b|\bpenny\b", "coins are coins, not pence"),
    (r"(?-i:\bHP\b)|\bhit points\b", "a thing has hold, not HP"),
    (r"\bloot\b|\bbuffs?\b|\bspawns?\b|\bspawned\b|\bmobs?\b", "no surface jargon"),
    (r"\bsprint\w*|\bracing\b|\brace\b|\bpersonal best\b", "nothing is a race"),
    (r"\bthe settled\b", "a thing has settled; there is no 'the settled'"),
    (r"\bweakness(es)?\b|\bresistances?\b", "a thing wants, or does not mind"),
    (
        r"\bthou\b|\bhark\b|\bbehold\b|\brealms?\b|\bdestiny\b|\bheroe?s?\b|\bchosen one\b|\btraveller\b",
        "no archaic diction",
    ),
    (r"\bslay\w*|\bslain\b|\bblood\w*", "no gore"),
    (r"\bgreat job\b|\bamazing\b|\bawesome\b", "no cheerleading"),
    (r"[\U0001F300-\U0001FAFF\u2600-\u27BF]", "no emoji"),
]

_COMPILED = [(re.compile(p, re.IGNORECASE), why) for p, why in BANNED]

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
}


def violations(text: str) -> list[str]:
    """Why a line breaks the voice, one reason per broken rule; empty if it does not."""
    found = []
    for pattern, why in _COMPILED:
        match = pattern.search(text or "")
        if match:
            found.append(f"{why}: {match.group(0)!r}")
    return found


def prose(value: Any, key: str | None = None, path: str = "") -> list[tuple[str, str]]:
    """Every player-facing string in a JSON document, with where it sits."""
    out: list[tuple[str, str]] = []
    if isinstance(value, dict):
        for k, v in value.items():
            if str(k).startswith("_"):
                continue
            out += prose(v, k, f"{path}.{k}" if path else str(k))
    elif isinstance(value, list):
        for i, v in enumerate(value):
            out += prose(v, key, f"{path}[{i}]")
    elif isinstance(value, str) and key in PROSE_KEYS:
        out.append((path, value))
    return out
