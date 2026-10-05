"""Effort is damage (app/world_objects/fight.py): the rules in docs/ROADMAP.md, Appendix C."""

from __future__ import annotations

import math

from app.characters.sheet import CharacterSheet
from app.core.geo import destination_point, haversine_m
from app.exploration.cells import cell_for
from app.world_objects import fight
from app.world_objects.fight import FightPoint, Foe, RuneHit
from app.world_objects.service import load_config

CFG = load_config()["combat"]
HOME = (51.4900, -0.0400)


def line(
    start, bearing: float, meters: float, spacing: float, alt0: float = 10.0, climb: float = 0.0
) -> list[FightPoint]:
    """Fixes every `spacing` metres along a bearing, rising `climb` metres in all."""
    steps = max(1, int(meters / spacing))
    out = []
    for k in range(steps + 1):
        lat, lon = destination_point(start[0], start[1], bearing, k * spacing)
        out.append(FightPoint(lat, lon, alt0 + climb * k / steps))
    return out


def loop(centre, radius: float, spacing: float, laps: int = 1) -> list[FightPoint]:
    circumference = 2 * math.pi * radius
    steps = max(8, int(circumference / spacing))
    out = []
    for _lap in range(laps):
        for k in range(steps):
            lat, lon = destination_point(centre[0], centre[1], 360 * k / steps, radius)
            out.append(FightPoint(lat, lon, 10.0))
    return out


def foe(wants=("ROAD", "WORD"), minds=("CLIMB",), hold=100.0, at=HOME, road_form=None, **kw) -> Foe:
    return Foe(
        at[0],
        at[1],
        hold_max=hold,
        hold_before=kw.pop("before", hold),
        wants=wants,
        minds=minds,
        road_form=road_form,
        **kw,
    )


def run(points, f, activity="RIDE", pct=None, **kw):
    return fight.resolve(points, f, activity=activity, damage_pct=pct or {}, cfg=CFG, **kw)


def test_a_thing_never_reached_is_untouched():
    far = (51.5200, -0.0400)
    report = run(line(far, 90, 2000, 10), foe())
    assert report.outcome == "NOT_NEAR"
    assert report.hold_after == 100


def test_how_fast_the_fixes_came_does_not_matter():
    """There is no clock in the fight. The same path, sampled at the spacings the
    battery modes produce, does the same damage."""
    start = destination_point(HOME[0], HOME[1], 270, 900)
    f = foe(wants=("ROAD", "WORD"), hold=400)
    dense = run(line(start, 90, 1800, 4), f)
    sparse = run(line(start, 90, 1800, 22), f)
    assert dense.outcome == sparse.outcome == "LOOSENED"
    assert abs(dense.damage["ROAD"] - sparse.damage["ROAD"]) / dense.damage["ROAD"] < 0.1


def test_laps_pay_nothing_more():
    """Ground covered twice on one outing pays once."""
    f = foe(wants=("ROAD", "WORD"), hold=1000)
    once = run(loop(HOME, 110, 8, laps=1), f)
    five = run(loop(HOME, 110, 8, laps=5), f)
    assert five.damage["ROAD"] < once.damage["ROAD"] * 1.25


def test_hill_repeats_are_one_climb():
    start = destination_point(HOME[0], HOME[1], 180, 300)
    up = line(start, 0, 300, 10, alt0=10, climb=30)
    down = list(reversed(up))
    f = foe(wants=("CLIMB", "RUNE"), minds=("WORD",), hold=1000, road_form="TRIANGLE")
    once = run(up, f)
    thrice = run(up + down + up + down + up, f)
    assert once.damage["CLIMB"] > 0
    assert abs(thrice.damage["CLIMB"] - once.damage["CLIMB"]) < 1e-6


def test_effort_it_does_not_want_loosens_it_but_never_sees_it_off():
    """A thing goes when it gets what it wants: new ground and height loosen a
    creature that does not want them, down to one, and stop there."""
    start = destination_point(HOME[0], HOME[1], 180, 400)
    climbing = line(start, 0, 800, 10, climb=80)
    f = foe(wants=("GROUND", "WORD"), minds=("ROAD",), hold=50)
    report = run(climbing, f)
    assert report.damage["CLIMB"] > 0
    assert report.outcome == "LOOSENED" and report.hold_after == 1
    wanted = run(climbing, foe(wants=("CLIMB", "WORD"), minds=("ROAD",), hold=50))
    assert wanted.outcome == "SEEN_OFF" and wanted.finisher == "CLIMB"


def test_the_road_alone_never_finishes_a_thing_that_does_not_want_it():
    start = destination_point(HOME[0], HOME[1], 270, 950)
    f = foe(wants=("GROUND", "WORD"), minds=("CLIMB",), hold=8)
    report = run(line(start, 90, 1900, 10), f)
    assert report.outcome == "LOOSENED"
    assert report.hold_after == 1
    wanted = run(line(start, 90, 1900, 10), foe(wants=("ROAD", "WORD"), hold=8))
    assert wanted.outcome == "SEEN_OFF"
    assert wanted.finisher == "ROAD"


def test_its_own_rune_lands_and_any_other_shape_does_nothing():
    f = foe(wants=("ROAD", "RUNE"), minds=("WORD",), hold=220, road_form="LOOP")
    pts = loop(HOME, 120, 10)
    landed = run(pts, f, rune_hit=RuneHit("LOOP", len(pts) - 1))
    other = run(pts, f, rune_hit=RuneHit("SQUARE", len(pts) - 1))
    assert landed.rune_landed and landed.damage["RUNE"] == CFG["rates"]["RUNE"] * CFG["wants"]
    assert not other.rune_landed and "RUNE" not in other.damage
    # Once a day: a second outing the same day cuts nothing more.
    again = run(pts, Foe(**{**f.__dict__, "rune_today": True}), rune_hit=RuneHit("LOOP", len(pts) - 1))
    assert not again.rune_landed


def test_the_word_lands_only_near_it():
    pts = line(destination_point(HOME[0], HOME[1], 270, 500), 90, 1000, 10)
    near = min(range(len(pts)), key=lambda i: haversine_m(HOME[0], HOME[1], pts[i].latitude, pts[i].longitude))
    f = foe(wants=("GROUND", "WORD"), hold=100)
    written = run(pts, f, word_indices=[near])
    far = run(pts, f, word_indices=[0])
    assert written.word_landed and written.damage["WORD"] == CFG["rates"]["WORD"] * CFG["wants"]
    assert not far.word_landed


def test_what_the_outing_did_before_counts_as_an_opening_blow():
    """A long way in before meeting it lands at contact, at most half its hold."""
    long_way = line(destination_point(HOME[0], HOME[1], 270, 9000), 90, 7000, 20, climb=60)
    then_past = line(long_way[-1].__dict__ and (long_way[-1].latitude, long_way[-1].longitude), 90, 2500, 20)
    f = foe(wants=("ROAD", "WORD"), hold=220)
    with_carry = run(long_way + then_past, f)
    without = fight.resolve(long_way + then_past, f, activity="RIDE", damage_pct={}, cfg={**CFG, "carriedFraction": 0})
    assert with_carry.damage.get("CARRIED", 0) > 0
    assert with_carry.damage["CARRIED"] <= CFG["carriedCap"] * 220 + 1e-6
    assert with_carry.taken > without.taken


def test_new_ground_inside_its_ground_counts():
    pts = line(destination_point(HOME[0], HOME[1], 270, 900), 90, 1800, 10)
    entered = []
    seen = set()
    for i, p in enumerate(pts):
        cell = cell_for(p.latitude, p.longitude, 9)
        if cell not in seen:
            seen.add(cell)
            entered.append(i)
    f = foe(wants=("GROUND", "WORD"), hold=1000)
    report = run(pts, f, new_cell_indices=entered)
    assert report.units["GROUND"] >= 3
    assert report.damage["GROUND"] == report.units["GROUND"] * CFG["rates"]["GROUND"] * CFG["wants"]


def test_wanting_beats_neutral_beats_not_minding_for_every_kind_and_activity():
    for kind in fight.KINDS:
        for activity in ("RIDE", "RUN", "WALK"):
            wants = fight.per_unit(kind, foe(wants=(kind,), minds=()), activity, {}, CFG)
            neutral = fight.per_unit(kind, foe(wants=(), minds=()), activity, {}, CFG)
            minds = fight.per_unit(kind, foe(wants=(), minds=(kind,)), activity, {}, CFG)
            assert wants > neutral > minds, (kind, activity)
            # A build bonus still changes things against something that wants it.
            boosted = fight.per_unit(kind, foe(wants=(kind,), minds=()), activity, {kind: 0.1}, CFG)
            assert boosted > wants, (kind, activity)


def test_an_untrusted_fix_does_nothing():
    pts = [
        FightPoint(p.latitude, p.longitude, p.altitude, ok=False)
        for p in line(destination_point(HOME[0], HOME[1], 270, 900), 90, 1800, 10)
    ]
    report = run(pts, foe())
    assert report.outcome == "NOT_NEAR"


def test_a_thing_left_standing_says_what_would_have_done_it():
    start = destination_point(HOME[0], HOME[1], 180, 400)
    f = foe(wants=("CLIMB", "RUNE"), minds=("WORD",), hold=400, road_form="TRIANGLE")
    report = run(line(start, 0, 400, 10, climb=30), f)
    assert report.outcome == "LOOSENED"
    assert report.would_have_done is not None


def test_the_shared_fixtures_are_current():
    """The phone's port is held to tests/fixtures/fight_tracks.json; it must say
    what the server says now. Regenerate with scripts/gen_fight_fixtures.py."""
    import json
    from pathlib import Path

    stored = json.loads((Path(__file__).parent / "fixtures" / "fight_tracks.json").read_text())
    assert {k: v for k, v in CFG.items() if not k.startswith("_")} == stored["combat"], "combat constants changed"
    for case in stored["cases"]:
        f = case["foe"]
        pts = [FightPoint(lat, lon, alt, ok) for lat, lon, alt, ok, _ in case["points"]]
        foe = Foe(
            f["latitude"], f["longitude"], f["hold"], f.get("holdBefore", f["hold"]), tuple(f["wants"]),
            tuple(f["minds"]), f["roadForm"],
        )  # fmt: skip
        hit = RuneHit(*case["runeHit"]) if case["runeHit"] else None
        # 0.7.2: a case may carry the sheet's rules (the Unrung Bell, the Atlas); 0.8.0 the
        # Hard Six's (Nauthiz, Uruz), Thurisaz against an elder, and a legend's phase.
        rules = case.get("rules") or {}
        cfg = CharacterSheet(rules=rules).fight_cfg(CFG)
        pct = dict(case["pct"])
        if case.get("elder") and rules.get("ELDER_CARRIED_SCALE"):
            cfg = {**cfg, "carriedFraction": cfg["carriedFraction"] * rules["ELDER_CARRIED_SCALE"]}
        if case.get("legend"):
            assert case["elder"] is True
            radius = case.get("legendWordRadiusMeters", 0)
            cfg = {**cfg, "wordRadiusMeters": max(cfg["wordRadiusMeters"], radius)}
            for kind, more in (case.get("vsLegendsPct") or {}).items():
                pct[kind] = pct.get(kind, 0.0) + more
        report = fight.resolve(
            pts, foe, activity=case["activity"], damage_pct=pct, cfg=cfg,
            new_cell_indices=case["newCellIndices"], rune_hit=hit, word_indices=case["wordIndices"],
        )  # fmt: skip
        assert report.outcome == case["expect"]["outcome"], case["name"]
        assert abs(report.hold_after - case["expect"]["holdAfter"]) < 0.01, case["name"]
        assert report.finisher == case["expect"]["finisher"], case["name"]
        for kind, amount in case["expect"]["damage"].items():
            assert abs(report.damage.get(kind, 0.0) - amount) < 0.01, (case["name"], kind)
    assert {"FINISH_UNDER", "GROUND_CELL_SCALE", "ENGAGE_M", "CLIMB_SHARED_M", "ELDER_CARRIED_SCALE"} <= {
        r for c in stored["cases"] for r in c.get("rules", {})
    }
    assert any(c.get("legend") and c.get("vsLegendsPct") for c in stored["cases"])
