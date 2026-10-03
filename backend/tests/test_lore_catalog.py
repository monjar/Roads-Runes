"""The world's fixed content: every entry resolves, and the rules in docs/WORLD.md hold."""

from __future__ import annotations

from app.characters import catalog as classes
from app.lore import catalog


def test_the_catalogue_loads_and_checks_itself():
    assert len(catalog.runes()) == 24
    assert len(catalog.species()) == 12
    assert len(catalog.cast()) == 5
    assert catalog.codex_book()["entries"]


def test_the_runes_are_the_elder_futhark_in_order():
    names = [r["name"] for r in catalog.runes()]
    assert names[:8] == ["Fehu", "Uruz", "Thurisaz", "Ansuz", "Raido", "Kenaz", "Gebo", "Wunjo"]
    assert names[-3:] == ["Ingwaz", "Dagaz", "Othala"]


def test_the_runes_you_hold_are_the_runes_you_cut():
    """The Road Six are today's collectable set, and each has a road form."""
    road_six = {r["name"] for r in catalog.runes() if r["six"] == "ROAD"}
    from app.world_objects.service import load_config

    pieces = next(s for s in load_config()["collectableSets"] if s["id"] == "RUNES")["pieces"]
    assert road_six == set(pieces)
    assert all(r["roadForm"] for r in catalog.runes() if r["six"] == "ROAD")
    assert catalog.rune_for_form()["LOOP"] == "raido"


def test_every_creature_wants_something_a_rider_can_always_do():
    for s in catalog.species():
        assert {"RUNE", "WORD"} & set(s["wants"]), s["id"]
        if "RUNE" in s["wants"]:
            assert catalog.runes_by_id()[s["rune"]]["roadForm"] in catalog.RIDEABLE_FORMS


def test_old_names_still_find_their_creature():
    """Rows spawned before species had ids carry only a name."""
    assert catalog.species_of({"name": "Hollow Knight"}) == "hollow-sentry"
    assert catalog.species_of({"name": "the Long Cold"}) == "bog-wraith"
    assert catalog.species_of({"speciesId": "fen-troll", "name": "anything"}) == "fen-troll"
    assert catalog.species_of({"name": "Nobody"}) is None


def test_elders_are_named_by_tier():
    troll = catalog.species_by_id()["fen-troll"]
    assert catalog.name_at_tier(troll, 1) == "Fen Troll"
    assert catalog.name_at_tier(troll, 2) == "Culvert Troll"
    assert catalog.name_at_tier(troll, 3) == "Old Arch"


def test_every_trade_has_a_guild_a_saying_and_a_crest():
    for cid, c in classes.classes().items():
        assert c["guild"] and c["saying"] and c["crest"], cid


def test_every_trade_has_somebody_to_post_for_it():
    for cid in ("EXPLORER", "WIZARD", "WARRIOR", "SCRIBE", None):
        assert catalog.poster_for(cid)["name"]
    assert catalog.poster_for(None)["id"] == "ada-pym"
