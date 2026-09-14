"""Synthetic GPS tracks that trace runes (and some that do not), for both ports of the matcher.

    .venv/bin/python scripts/gen_rune_fixtures.py

Writes tests/fixtures/rune_tracks.json; the iOS Core tests read a copy of the same
file, so the Swift port is held to the same verdicts.
"""

from __future__ import annotations

import cmath
import json
import math
import random
from pathlib import Path

from app.world_objects.claims import CLOSED, _vertices

CENTRE = (51.4906, -0.0316)
OUT = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "rune_tracks.json"


def to_latlon(xy: complex) -> list[float]:
    lat = CENTRE[0] + xy.imag / 111_320
    lon = CENTRE[1] + xy.real / (111_320 * math.cos(math.radians(CENTRE[0])))
    return [round(lat, 6), round(lon, 6)]


def polyline(
    shape: str,
    scale_m: float,
    rotation_deg: float,
    mirror: bool,
    noise_m: float,
    rng: random.Random,
    offset=(150.0, 80.0),
    step_m: float = 15.0,
) -> list[complex]:
    vertices = list(_vertices(shape))
    if CLOSED[shape]:
        vertices.append(vertices[0])
    rotation = cmath.rect(1, math.radians(rotation_deg))
    out: list[complex] = []
    for a, b in zip(vertices, vertices[1:], strict=False):
        steps = max(3, int(abs(b - a) * scale_m / step_m))
        for k in range(steps):
            out.append(a + (b - a) * k / steps)
    out.append(vertices[-1])
    placed = []
    for p in out:
        q = p.conjugate() if mirror else p
        q = q * rotation * scale_m + complex(*offset)
        placed.append(q + complex(rng.gauss(0, noise_m), rng.gauss(0, noise_m)))
    return placed


def approach(xy: list[complex], rng: random.Random, from_m: float = 2200.0) -> list[complex]:
    """The rider comes in from far off, traces the rune, and leaves the other way."""
    first, last = xy[0], xy[-1]
    lead = [first + complex(-from_m + k * 40, 30 * math.sin(k / 3)) for k in range(int(from_m / 40))]
    tail = [last + complex(k * 40, 20 * math.cos(k / 4)) for k in range(1, 40)]
    return [p + complex(rng.gauss(0, 6), rng.gauss(0, 6)) for p in lead] + xy + tail


def main() -> None:
    rng = random.Random(7)
    cases = []
    for shape in ("TRIANGLE", "SQUARE", "STAR", "LOOP", "ZIGZAG"):
        cases.append(
            {
                "name": f"{shape.lower()}-plain",
                "expected": shape,
                "track": [to_latlon(p) for p in polyline(shape, 250 if shape == "STAR" else 400, 0, False, 4, rng)],
            }
        )
        cases.append(
            {
                "name": f"{shape.lower()}-turned-mirrored",
                "expected": shape,
                "track": [to_latlon(p) for p in polyline(shape, 260, 137, True, 4, rng, offset=(-300.0, 400.0))],
            }
        )
    cases.append(
        {
            "name": "triangle-with-approach",
            "expected": "TRIANGLE",
            "track": [to_latlon(p) for p in approach(polyline("TRIANGLE", 350, 40, False, 4, rng), rng)],
        }
    )
    cases.append(
        {
            "name": "square-is-not-a-triangle",
            "expected": "SQUARE",
            "track": [to_latlon(p) for p in polyline("SQUARE", 300, 20, False, 6, rng)],
        }
    )
    line = [complex(-400 + k * 15, 100 + rng.gauss(0, 6)) for k in range(60)]
    cases.append({"name": "straight-line", "expected": None, "track": [to_latlon(p) for p in line]})
    walk = [complex(0, 0)]
    heading = 0.0
    for _ in range(120):
        heading += rng.uniform(-35, 35)
        walk.append(walk[-1] + cmath.rect(15, math.radians(heading)))
    cases.append({"name": "random-walk", "expected": None, "track": [to_latlon(p) for p in walk]})
    OUT.write_text(json.dumps({"centre": list(CENTRE), "cases": cases}, indent=1) + "\n")
    print(f"wrote {len(cases)} cases to {OUT}")


if __name__ == "__main__":
    main()
