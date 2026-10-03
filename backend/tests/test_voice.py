"""The mechanical half of the voice sheet (docs/WORLD.md), over every line a player reads."""

from __future__ import annotations

import json
from pathlib import Path

from app.lore.voice import prose, violations
from app.quests import narrative

APP = Path(__file__).parent.parent / "app"
ALLOWLIST = json.loads((APP / "lore" / "config" / "voice_allowlist.json").read_text())["allow"]


def config_files() -> list[Path]:
    return sorted(p for p in APP.glob("*/config/*.json") if p.name != "voice_allowlist.json")


def allowed(file: str, text: str) -> dict | None:
    return next((a for a in ALLOWLIST if a["file"] == file and a["contains"] in text), None)


def test_every_line_in_the_config_keeps_the_voice():
    broken = []
    for path in config_files():
        rel = str(path.relative_to(APP.parent))
        for where, text in prose(json.loads(path.read_text())):
            reasons = violations(text)
            if reasons and not allowed(rel, text):
                broken.append(f"{rel} {where}: {reasons} — {text[:90]}")
    assert not broken, "\n".join(broken)


def test_the_allowlist_only_names_lines_that_still_exist():
    """Fixing a line means taking it off the list."""
    stale = []
    for entry in ALLOWLIST:
        texts = [t for _, t in prose(json.loads((APP.parent / entry["file"]).read_text()))]
        if not any(entry["contains"] in t and violations(t) for t in texts):
            stale.append(entry)
    assert not stale, stale


def test_the_composed_paragraph_keeps_the_voice():
    for line in [*narrative.CLASS_LINES.values(), *narrative.EFFORT_LINES.values()]:
        assert not violations(line), line


def test_the_check_is_on_whole_words():
    assert not violations("Trace a loop round it.")
    assert not violations("Rivers change faster than maps do.")
    assert violations("Not a race.")
    assert violations("+60 AC")
    assert not violations("A place of no account")
    assert violations("Nice one!")
