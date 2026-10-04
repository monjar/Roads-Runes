"""The mechanical half of docs/VOICE.md, over every line a player reads."""

from __future__ import annotations

import json
from pathlib import Path

from app.inventory import deeds
from app.lore.voice import CELEBRATION_KEYS, LABELS, prose, violations
from app.quests import narrative, week

APP = Path(__file__).parent.parent / "app"
ALLOWLIST = json.loads((APP / "lore" / "config" / "voice_allowlist.json").read_text())["allow"]


def config_files() -> list[Path]:
    return sorted(p for p in APP.glob("*/config/*.json") if p.name != "voice_allowlist.json")


def allowed(file: str, text: str) -> dict | None:
    return next((a for a in ALLOWLIST if a["file"] == file and a["contains"] in text), None)


def check(path: Path, key: str, text: str) -> list[str]:
    """A line as the voice holds it: a menu label to the glossary too, a celebration may cheer."""
    label = key in LABELS.get(str(path.relative_to(APP)), set())
    return violations(text, glossary=label, celebration=key in CELEBRATION_KEYS)


def test_every_line_in_the_config_keeps_the_voice():
    broken = []
    for path in config_files():
        rel = str(path.relative_to(APP.parent))
        for where, key, text in prose(json.loads(path.read_text())):
            reasons = check(path, key, text)
            if reasons and not allowed(rel, text):
                broken.append(f"{rel} {where}: {reasons} — {text[:90]}")
    assert not broken, "\n".join(broken)


def test_the_labels_named_for_the_glossary_exist():
    """A file or key that moved would quietly stop being checked."""
    for file, keys in LABELS.items():
        found = {key for _, key, _ in prose(json.loads((APP / file).read_text()))}
        assert keys <= found, (file, keys - found)


def test_the_allowlist_only_names_lines_that_still_exist():
    """Fixing a line means taking it off the list."""
    stale = []
    for entry in ALLOWLIST:
        path = APP.parent / entry["file"]
        texts = prose(json.loads(path.read_text()))
        if not any(entry["contains"] in t and check(path, k, t) for _, k, t in texts):
            stale.append(entry)
    assert not stale, stale


def test_the_composed_paragraph_keeps_the_voice():
    for line in [*narrative.CLASS_LINES.values(), *narrative.EFFORT_LINES.values()]:
        assert not violations(line), line


def test_the_servers_own_labels_keep_the_glossary():
    lines = [n["title"] for n in week.NOTICES] + [n["unit"] for n in week.NOTICES]
    lines += [d[k] for d in deeds.DEEDS for k in ("name", "what", "unit")]
    lines += [r[k] for r in deeds.RECORDS for k in ("name", "unit")]
    for line in lines:
        assert not violations(line, glossary=True), line


def test_the_check_is_on_whole_words():
    assert not violations("Trace a loop round it.")
    assert not violations("Rivers change faster than maps do.")
    assert violations("Not a race.")
    assert violations("+60 AC")
    assert not violations("A place of no account")
    assert violations("Health 260 / 400 HP")


def test_an_exclamation_mark_is_for_a_celebration():
    assert violations("Open the chest!")
    assert not violations("Level up!", celebration=True)


def test_the_retired_words_are_held_only_where_asked():
    for old in ["No knack to choose yet.", "Pick a trade.", "Things seen off", "It got away, loosened.",
                "The reckoning", "Its hold is 400.", "Days kept: 3", "Unread ground nearby.", "Boxes pay more."]:  # fmt: skip
        assert violations(old, glossary=True), old
        assert not violations(old), f"lore and quest prose are not held to the glossary: {old}"
    for new in ["Learn skill", "Creatures defeated", "Weak to distance", "Health 260 / 400", "Wizard level 3",
                "Explore 40 new tiles this week.", "Chests pay 5% more coins, per rank."]:  # fmt: skip
        assert not violations(new, glossary=True), new
