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
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

from app.characters.sheet import CharacterSheet
from app.core.geo import destination_point
from app.exploration.cells import cell_for
from app.world_objects import fight
from app.world_objects.service import load_config

HERE = Path(__file__).resolve().parent.parent
OUT = HERE / "tests" / "fixtures" / "fight_tracks.json"
IOS = HERE.parent / "ios/Packages/RoadsAndRunesCore/Tests/RoadsAndRunesCoreTests/Resources/fight_tracks.json"
HOME = (51.4906, -0.0316)


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


def main() -> None:
    cfg = load_config()["combat"]
    out = {
        "_comment": __doc__.strip().splitlines()[0],
        "combat": {k: v for k, v in cfg.items() if not k.startswith("_")},
        "cases": [],
    }
    for name, pts, wants, minds, form, hold, activity, pct, cells, rune, words, *more in [
        *cases(),
        *gear_cases(),
    ]:
        rules = more[0] if more else {}
        foe = fight.Foe(HOME[0], HOME[1], hold, hold, wants, minds, form)
        hit = fight.RuneHit(*rune) if rune else None
        report = fight.resolve(
            pts,
            foe,
            activity=activity,
            damage_pct=pct,
            cfg=CharacterSheet(rules=rules).fight_cfg(cfg),
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
                    "wants": wants,
                    "minds": minds,
                    "roadForm": form,
                },
                "activity": activity,
                "pct": pct,
                "newCellIndices": cells,
                "runeHit": list(rune) if rune else None,
                "wordIndices": words,
                **({"rules": rules} if rules else {}),
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
