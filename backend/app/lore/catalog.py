"""The world's fixed content: runes, the cast, codex pages, and the creatures' lore.

Pure: JSON in, checked dictionaries out. Every loader asserts on bad content at
first use, so a broken entry fails the test suite rather than a player's screen.
The creatures are read from `world_objects/config/world_objects.json`, where
their numbers live, so a creature's lore and its mechanics are one entry.
"""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Any

CONFIG_DIR = Path(__file__).parent / "config"
WORLD_OBJECTS = Path(__file__).parent.parent / "world_objects" / "config" / "world_objects.json"

KINDS = ("ROAD", "GROUND", "CLIMB", "RUNE", "WORD")
SIXES = ("ROAD", "GROUND", "TRADE", "HARD")
ROAD_FORMS = ("LOOP", "TRIANGLE", "SQUARE", "ZIGZAG", "NOTE", "STOP")
# The shapes a rider can be asked to cut on a bike; zigzags are for feet.
RIDEABLE_FORMS = ("LOOP", "TRIANGLE", "SQUARE")
FAMILIES = ("WATER", "GREEN", "STONE", "STREET")
SIGIL_BODIES = ("shade", "hulk", "beast", "wyrm", "armour", "wisp", "bird")
SIGIL_FEATURES = ("antlers", "horns", "crown", "hood", "hook", "visor", "ember", "wings", "moss", "fins")
SIGIL_MARKS = ("water", "reeds", "bridge", "wall", "lamp", "ash", "mist", "tree")
CHAPTERS = ("WORLD", "CREATURES", "RUNES", "PEOPLE", "PLACES")
# Height is only asked of a thing that lives where there is height to be had.
RELIEF_CATEGORIES = ("VIEWPOINT",)


def _load(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text())


# --- runes -------------------------------------------------------------------


@lru_cache(maxsize=1)
def rune_book() -> dict[str, Any]:
    book = _load(CONFIG_DIR / "runes.json")
    runes = book["runes"]
    assert len(runes) == 24, "the Elder Futhark has 24 runes"
    assert sorted(r["order"] for r in runes) == list(range(1, 25)), "futhark order must run 1..24"
    assert len({r["id"] for r in runes}) == 24, "rune ids must be unique"
    for six in SIXES:
        assert sum(1 for r in runes if r["six"] == six) == 6, f"{six} must hold six runes"
        assert six in book["sixes"], f"{six} needs a name"
    forms = [r["roadForm"] for r in runes if r.get("roadForm")]
    assert all(f in ROAD_FORMS for f in forms), "unknown road form"
    assert len(forms) == len(set(forms)), "a road form belongs to one rune"
    for r in runes:
        assert r["gloss"].strip() and "!" not in r["gloss"], f"{r['id']} needs a plain gloss"
    return book


def runes() -> list[dict[str, Any]]:
    return sorted(rune_book()["runes"], key=lambda r: r["order"])


@lru_cache(maxsize=1)
def runes_by_id() -> dict[str, dict[str, Any]]:
    return {r["id"]: r for r in rune_book()["runes"]}


@lru_cache(maxsize=1)
def rune_for_form() -> dict[str, str]:
    """LOOP -> raido: the rune a traced shape is."""
    return {r["roadForm"]: r["id"] for r in rune_book()["runes"] if r.get("roadForm")}


def rune_by_name(name: str) -> dict[str, Any] | None:
    lowered = name.strip().lower()
    return next((r for r in rune_book()["runes"] if r["name"].lower() == lowered), None)


# --- cast --------------------------------------------------------------------


@lru_cache(maxsize=1)
def cast() -> list[dict[str, Any]]:
    people = _load(CONFIG_DIR / "cast.json")["cast"]
    assert len({p["id"] for p in people}) == len(people), "cast ids must be unique"
    for p in people:
        assert p["lines"], f"{p['id']} needs lines"
        assert p["posts"] in ("ANY", "BOUNTY", "EXPLORER", "WIZARD", "WARRIOR", "SCRIBE")
    ids = {p["id"] for p in people}
    assert all(p["pageBy"] in ids for p in people), "a page is written by somebody in the cast"
    return people


@lru_cache(maxsize=1)
def cast_by_id() -> dict[str, dict[str, Any]]:
    return {p["id"]: p for p in cast()}


def poster_for(character_class: str | None) -> dict[str, Any]:
    """Who posts a notice for this trade; anyone's notices are Ada Pym's."""
    wanted = (character_class or "ANY").upper()
    return next((p for p in cast() if p["posts"] == wanted), cast_by_id()["ada-pym"])


# --- codex pages -------------------------------------------------------------


@lru_cache(maxsize=1)
def codex_book() -> dict[str, Any]:
    book = _load(CONFIG_DIR / "codex.json")
    assert [c["id"] for c in book["chapters"]] == list(CHAPTERS)
    ids = [e["id"] for e in book["entries"]]
    assert len(ids) == len(set(ids)), "codex ids must be unique"
    people = cast_by_id()
    for e in book["entries"]:
        assert e["chapter"] in CHAPTERS, f"{e['id']}: unknown chapter"
        assert e["by"] in people, f"{e['id']}: written by somebody not in the cast"
        if e["id"] != "the-old-roads":
            sentences = sum(part.count(". ") + 1 for part in e["body"])
            assert sentences <= 3, f"{e['id']}: at most three sentences a page"
    return book


# --- creatures ---------------------------------------------------------------


@lru_cache(maxsize=1)
def species() -> list[dict[str, Any]]:
    """Every creature, with its lore and the numbers that make it a fight."""
    all_species = _load(WORLD_OBJECTS)["monsters"]
    ids = [s["id"] for s in all_species]
    assert len(ids) == len(set(ids)), "species ids must be unique"
    known_runes = runes_by_id()
    for s in all_species:
        sid = s["id"]
        assert s["family"] in FAMILIES, f"{sid}: unknown family"
        assert len(s["wants"]) == 2 and all(k in KINDS for k in s["wants"]), f"{sid}: wants two kinds"
        assert len(s["minds"]) == 1 and s["minds"][0] in KINDS, f"{sid}: does not mind one kind"
        assert not set(s["wants"]) & set(s["minds"]), f"{sid}: cannot want what it does not mind"
        # The two kinds a rider can do anywhere: cut a rune, write the word.
        assert {"RUNE", "WORD"} & set(s["wants"]), f"{sid}: must want a rune or the word"
        if "CLIMB" in s["wants"]:
            assert set(s["habitat"]["categories"]) & set(RELIEF_CATEGORIES), f"{sid}: wants height on flat ground"
        terrain = {"GROUND", "CLIMB"}
        if s["minds"] == ["ROAD"]:
            assert not set(s["wants"]) <= terrain, f"{sid}: shrugs off the road with only terrain to want"
        if "RUNE" in s["wants"]:
            rune = known_runes.get(s.get("rune") or "")
            assert rune is not None, f"{sid}: wants a rune but names none"
            assert rune["roadForm"] in RIDEABLE_FORMS, f"{sid}: its rune must be one a bike can cut"
        else:
            assert s.get("rune") is None, f"{sid}: names a rune it does not want"
        assert [e["tier"] for e in s["elders"]] == [2, 3], f"{sid}: elders at tiers 2 and 3"
        sigil = s["sigil"]
        assert sigil["body"] in SIGIL_BODIES, f"{sid}: unknown sigil body"
        assert sigil["feature"] in SIGIL_FEATURES, f"{sid}: unknown sigil feature"
        assert sigil["mark"] in SIGIL_MARKS, f"{sid}: unknown sigil mark"
        for field in ("flavour", "hint", "leaves", "page"):
            assert str(s.get(field) or "").strip(), f"{sid}: needs a {field}"
    return all_species


@lru_cache(maxsize=1)
def species_by_id() -> dict[str, dict[str, Any]]:
    return {s["id"]: s for s in species()}


@lru_cache(maxsize=1)
def species_alias() -> dict[str, str]:
    """Every name a creature has gone by, lower-cased, to its species id: its own
    name, its elders' names and any former name. Rows spawned before species had
    ids carry only a name, and still belong to somebody."""
    out: dict[str, str] = {}
    for s in species():
        names = [s["name"], *(e["name"] for e in s["elders"]), *s.get("formerly", [])]
        for name in names:
            out[name.lower()] = s["id"]
    return out


def species_of(payload: dict[str, Any] | None) -> str | None:
    payload = payload or {}
    if payload.get("speciesId") in species_by_id():
        return str(payload["speciesId"])
    return species_alias().get(str(payload.get("name") or "").lower())


def name_at_tier(species_entry: dict[str, Any], tier: int) -> str:
    """Tier 1 is the thing itself; tiers 2 and 3 are its elders, by name."""
    for elder in species_entry.get("elders", []):
        if elder["tier"] == tier:
            return str(elder["name"])
    return str(species_entry["name"])


def flavour_at_tier(species_entry: dict[str, Any], tier: int) -> str:
    for elder in species_entry.get("elders", []):
        if elder["tier"] == tier:
            return str(elder["flavour"])
    return str(species_entry["flavour"])
