"""Outings and the fights the server makes of them, for both ports of fight.py.

    .venv/bin/python scripts/gen_fight_fixtures.py [--no-ios]

Writes tests/fixtures/fight_tracks.json and (unless --no-ios) a copy into the iOS
Core test resources, so the phone's FightResolver is held to the server's
verdicts (within one point of hold). tests/test_fight.py checks the file is
current.

A case may carry `rules` (0.7.2), the sheet's rules for that fight
({"FINISH_UNDER": 0.1}, {"GROUND_CELL_SCALE": 1.25}); the fight is folded over
the combat constants as `CharacterSheet.fight_cfg` changes them, the same way
the phone's sheet does. A case without `rules` uses the constants as they are.

0.8.0 adds the Hard Six's fold rules and the legend (see RULES_0_8 below, which
is written into the file as `_rules`):

* `rules.ENGAGE_M` (Nauthiz): engageMeters = max(engageMeters, v).
* `rules.CLIMB_SHARED_M` (Uruz): climbSharedMeters = v. A climb band gained at a
  fix within v m of the foe counts as a full CLIMB blow: one gained before
  contact lands at the contact index (after the opening blow), one gained after
  contact counts even when the fix is outside its ground.
* `rules.ELDER_CARRIED_SCALE` (Thurisaz), with `elder: true` (an elder, a bounty
  or a legend): carriedFraction × v, after CARRIED_SCALE; carriedCap unchanged.
* A legend case (`legend` set; `elder` is true too): the foe is the current
  phase (hold = phase health, holdBefore = what is left of it, wants = weakTo,
  minds = resists, roadForm = the phase's own rune's shape or null);
  wordRadiusMeters = max(wordRadiusMeters, legendWordRadiusMeters); the damage
  percentages are `pct` plus `vsLegendsPct`, kind by kind, before the clamp.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

from app.characters.sheet import CharacterSheet
from app.core.geo import destination_point
from app.exploration.cells import cell_for
from app.legends.catalog import phase_spec
from app.legends.models import OldOne
from app.legends.service import foe_for
from app.world_objects import fight
from app.world_objects.service import load_config

HERE = Path(__file__).resolve().parent.parent
OUT = HERE / "tests" / "fixtures" / "fight_tracks.json"
IOS = HERE.parent / "ios/Packages/RoadsAndRunesCore/Tests/RoadsAndRunesCoreTests/Resources/fight_tracks.json"
HOME = (51.4906, -0.0316)
RULES_0_8 = [
    "ENGAGE_M: engageMeters = max(engageMeters, v).",
    "CLIMB_SHARED_M: a climb band gained at a fix within v m of the foe is a full CLIMB blow; "
    "before contact it lands at the contact index (after the opening blow), after contact it counts "
    "even outside the foe's ground.",
    "ELDER_CARRIED_SCALE: when `elder` is true (an elder, a bounty or a legend), carriedFraction x v "
    "after CARRIED_SCALE; carriedCap unchanged.",
    "legend: the foe is the current phase: hold = phase health (foe.hold), holdBefore = what is left "
    "(foe.holdBefore, default hold), wants = weakTo, minds = resists, roadForm = the phase rune's shape. "
    "elder is true; wordRadiusMeters = max(wordRadiusMeters, legendWordRadiusMeters); damage pct = pct + "
    "vsLegendsPct by kind, before the sheet clamp.",
]


def line(start, bearing, meters, spacing, alt0=10.0, climb=0.0, bad_every=0):
    steps = max(1, int(meters / spacing))
    pts = []
    for k in range(steps + 1):
        lat, lon = destination_point(start[0], start[1], bearing, k * spacing)
        ok = not (bad_every and k % bad_every == 0)
        pts.append(fight.FightPoint(round(lat, 7), round(lon, 7), round(alt0 + climb * k / steps, 2), ok))
    return pts


def loop(centre, radius, spacing, laps=1):
    steps = max(8, int(2 * math.pi * radius / spacing))
    pts = []
    for _ in range(laps):
        for k in range(steps):
            lat, lon = destination_point(centre[0], centre[1], 360 * k / steps, radius)
            pts.append(fight.FightPoint(round(lat, 7), round(lon, 7), 10.0))
    return pts


def new_cells(points):
    seen, out = set(), []
    for i, p in enumerate(points):
        cell = cell_for(p.latitude, p.longitude, 9)
        if cell not in seen:
            seen.add(cell)
            out.append(i)
    return out


def cases():
    west = destination_point(HOME[0], HOME[1], 270, 950)
    south = destination_point(HOME[0], HOME[1], 180, 500)
    straight = line(west, 90, 1900, 10)
    climb = line(south, 0, 900, 10, climb=60)
    laps = loop(HOME, 120, 9, laps=3)
    noisy = line(west, 90, 1900, 10, bad_every=4)
    middle = min(range(len(straight)), key=lambda i: abs(straight[i].longitude - HOME[1]))
    return [
        ("passing by, wants the road", straight, ("ROAD", "WORD"), ("CLIMB",), None, 220, "RIDE", {}, [], None, []),
        ("passing by, does not want it", straight, ("GROUND", "WORD"), ("ROAD",), None, 100, "RIDE", {}, [], None, []),
        (
            "new ground on foot",
            straight,
            ("GROUND", "WORD"),
            ("CLIMB",),
            None,
            100,
            "WALK",
            {},
            new_cells(straight),
            None,
            [],
        ),
        (
            "a climb it wants",
            climb,
            ("CLIMB", "RUNE"),
            ("WORD",),
            "TRIANGLE",
            220,
            "RIDE",
            {"CLIMB": 0.3},
            [],
            None,
            [],
        ),
        ("laps round it", laps, ("ROAD", "WORD"), ("CLIMB",), None, 400, "RIDE", {}, [], None, []),
        ("its own rune", laps, ("ROAD", "RUNE"), ("WORD",), "LOOP", 220, "RIDE", {}, [], ("LOOP", len(laps) - 1), []),
        (
            "a word beside it",
            straight,
            ("GROUND", "WORD"),
            ("ROAD",),
            None,
            100,
            "RUN",
            {"WORD": 0.3},
            [],
            None,
            [middle],
        ),
        ("untrusted fixes", noisy, ("ROAD", "WORD"), ("CLIMB",), None, 220, "RIDE", {}, [], None, []),
    ]


def gear_cases():
    """0.7.2: the two numbers gear changes in the fold, with the rules that change them."""
    west = destination_point(HOME[0], HOME[1], 270, 950)
    south = destination_point(HOME[0], HOME[1], 180, 500)
    straight = line(west, 90, 1900, 10)
    climb = line(south, 0, 900, 10, climb=60)
    laps = loop(HOME, 120, 9, laps=3)
    bell = {"FINISH_UNDER": 0.1}
    atlas = {"GROUND_CELL_SCALE": 1.25}
    rune = ("LOOP", len(laps) - 1)
    return [
        ("the bell finishes what the rune left", laps, ("ROAD", "RUNE"), ("WORD",), "LOOP", 220, "RIDE", {}, [],
         rune, [], bell),
        ("the bell leaves a healthy one standing", climb, ("CLIMB", "RUNE"), ("WORD",), "TRIANGLE", 220, "RIDE",
         {"CLIMB": 0.3}, [], None, [], bell),
        ("new ground counts more with the atlas", straight, ("GROUND", "WORD"), ("CLIMB",), None, 400, "WALK", {},
         new_cells(straight), None, [], atlas),
        ("the atlas and the bell together", straight, ("GROUND", "WORD"), ("CLIMB",), None, 330, "WALK", {},
         new_cells(straight), None, [], {**bell, **atlas}),
    ]  # fmt: skip


def hard_six_cases():
    """0.8.0: Nauthiz, Uruz and Thurisaz in the fold, each with and without."""
    beside = destination_point(*destination_point(HOME[0], HOME[1], 0, 220), 270, 950)
    wide = line(beside, 90, 1900, 10)
    approach = line(destination_point(HOME[0], HOME[1], 180, 900), 0, 900, 10, climb=60)
    climb = line(destination_point(HOME[0], HOME[1], 180, 500), 0, 900, 10, climb=60)
    thurisaz = {"ELDER_CARRIED_SCALE": 2.0}
    return [
        ("220 m away is not met", wide, ("ROAD", "WORD"), ("CLIMB",), None, 220, "RIDE", {}, [], None, [], {}, {}),
        ("Nauthiz meets it from 250 m", wide, ("ROAD", "WORD"), ("CLIMB",), None, 220, "RIDE", {}, [], None, [],
         {"ENGAGE_M": 250}, {}),
        ("a climb on the way in is only the opening blow", approach, ("CLIMB", "RUNE"), ("WORD",), "TRIANGLE", 220,
         "RIDE", {}, [], None, [], {}, {}),
        ("Uruz counts the climb within 500 m in full", approach, ("CLIMB", "RUNE"), ("WORD",), "TRIANGLE", 220,
         "RIDE", {}, [], None, [], {"CLIMB_SHARED_M": 500}, {}),
        ("Thurisaz does nothing against a tier-1", climb, ("CLIMB", "RUNE"), ("WORD",), "TRIANGLE", 400, "RIDE",
         {}, [], None, [], thurisaz, {"elder": False}),
        ("Thurisaz doubles the opening blow on an elder", climb, ("CLIMB", "RUNE"), ("WORD",), "TRIANGLE", 400,
         "RIDE", {}, [], None, [], thurisaz, {"elder": True}),
    ]  # fmt: skip


def legend_cases():
    """0.8.0: a legend's phase is a foe like any other, with the capstones' percentages."""
    west = destination_point(HOME[0], HOME[1], 270, 950)
    straight = line(west, 90, 1900, 10)
    dragon = OldOne(species_id="fog-dragon", phase=1, phase_hold_max=500, latitude=HOME[0], longitude=HOME[1])
    king = OldOne(species_id="hill-king", phase=2, phase_hold_max=500, latitude=HOME[0], longitude=HOME[1])
    climb = line(destination_point(HOME[0], HOME[1], 180, 500), 0, 900, 10, climb=60)
    return [
        ("the Fog Dragon's first phase, with Fog Breaker", straight, dragon, 420, "WALK", {}, new_cells(straight),
         None, [], {"ELDER_CARRIED_SCALE": 1.5}, {"vsLegendsPct": {"GROUND": 0.25}}),
        ("the Hill King's second phase, with Giant Slayer", climb, king, 500, "RIDE", {"CLIMB": 0.3}, [],
         None, [], {}, {"vsLegendsPct": {"CLIMB": 0.2, "ROAD": 0.2}}),
    ]  # fmt: skip


def main() -> None:
    cfg = load_config()["combat"]
    out = {
        "_comment": __doc__.strip().splitlines()[0],
        "_rules": RULES_0_8,
        "combat": {k: v for k, v in cfg.items() if not k.startswith("_")},
        "cases": [],
    }
    legends = [
        (
            name,
            pts,
            None,
            None,
            None,
            None,
            activity,
            pct,
            cells,
            rune,
            words,
            rules,
            {**extra, "row": row, "left": left},
        )
        for name, pts, row, left, activity, pct, cells, rune, words, rules, extra in legend_cases()
    ]
    for name, pts, wants, minds, form, hold, activity, pct, cells, rune, words, *more in [
        *cases(),
        *gear_cases(),
        *hard_six_cases(),
        *legends,
    ]:
        rules = more[0] if more else {}
        extra = dict(more[1]) if len(more) > 1 else {}
        sheet = CharacterSheet(rules=rules, vs_legends_pct=dict(extra.get("vsLegendsPct") or {}))
        case_cfg = sheet.fight_cfg(cfg)
        damage_pct = dict(pct)
        legend = None
        hold_before = hold
        if "row" in extra:
            row, left = extra.pop("row"), extra.pop("left")
            foe = foe_for(row, left)
            wants, minds, form, hold, hold_before = foe.wants, foe.minds, foe.road_form, int(foe.hold_max), left
            case_cfg = sheet.legend_cfg(case_cfg)
            for kind, more_pct in sheet.vs_legends_pct.items():
                damage_pct[kind] = damage_pct.get(kind, 0.0) + more_pct
            phase = phase_spec(row.species_id, row.phase)
            legend = {
                "speciesId": row.species_id,
                "phase": row.phase,
                "weakTo": list(phase["weakTo"]),
                "resists": list(phase["resists"]),
                "rune": phase.get("rune"),
                "healthMax": hold,
                "healthLeft": left,
            }
            extra["elder"] = True
        else:
            foe = fight.Foe(HOME[0], HOME[1], hold, hold, wants, minds, form)
            case_cfg = sheet.foe_cfg(case_cfg, elder=bool(extra.get("elder")))
        hit = fight.RuneHit(*rune) if rune else None
        report = fight.resolve(
            pts,
            foe,
            activity=activity,
            damage_pct=damage_pct,
            cfg=case_cfg,
            new_cell_indices=cells,
            rune_hit=hit,
            word_indices=words,
        )
        out["cases"].append(
            {
                "name": name,
                "points": [
                    [
                        p.latitude,
                        p.longitude,
                        p.altitude,
                        p.ok,
                        cell_for(p.latitude, p.longitude, cfg["roadCellResolution"]),
                    ]
                    for p in pts
                ],
                "foe": {
                    "latitude": HOME[0],
                    "longitude": HOME[1],
                    "hold": hold,
                    **({"holdBefore": hold_before} if hold_before != hold else {}),
                    "wants": list(wants),
                    "minds": list(minds),
                    "roadForm": form,
                },
                "activity": activity,
                "pct": pct,
                "newCellIndices": cells,
                "runeHit": list(rune) if rune else None,
                "wordIndices": words,
                **({"rules": rules} if rules else {}),
                **({"elder": bool(extra["elder"])} if "elder" in extra else {}),
                **({"legend": legend} if legend else {}),
                **({"vsLegendsPct": extra["vsLegendsPct"]} if extra.get("vsLegendsPct") else {}),
                **(
                    {"legendWordRadiusMeters": extra["legendWordRadiusMeters"]}
                    if extra.get("legendWordRadiusMeters")
                    else {}
                ),
                "expect": {
                    "outcome": report.outcome,
                    "holdAfter": report.hold_after,
                    "damage": {k: round(v, 3) for k, v in report.damage.items()},
                    "finisher": report.finisher,
                },
            }
        )
    text = json.dumps(out, indent=1) + "\n"
    OUT.write_text(text)
    if "--no-ios" in sys.argv:
        print(f"{len(out['cases'])} cases → {OUT}")
        return
    IOS.write_text(text)
    print(f"{len(out['cases'])} cases → {OUT} and {IOS}")


if __name__ == "__main__":
    main()
