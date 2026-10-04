"""Effort is damage: a fight decided over an outing, from the trace alone.

Pure: points, a creature and the rules in, a report out. No clock is read. A
point carries a position, an altitude and whether it can be trusted; nothing
here knows how fast it was reached, so going faster can only ever lose effect
(a fix over the speed cap, or after a jump, is not trusted).

Five kinds of effort take hold off a thing (docs/ROADMAP.md, Appendix C):

* ROAD: metres made good inside its ground, counted on stride anchors so a
  standing GPS wobble adds nothing. Ground covered twice on one outing pays
  once (it is counted by small cells), so laps pay nothing more, and the total
  is capped at about one out-and-back.
* GROUND: new cells first entered inside its ground.
* CLIMB: new height inside its ground. Height already climbed on this outing
  pays nothing, so riding the same hill again is one climb, not three.
* RUNE: the creature's own road form, cut nearby. Once a day per creature.
* WORD: a note of a few words written within reach of it. Once a day.

Everything done on the outing before contact lands as one opening blow (the
carried blow), at a fraction of its local worth and never more than a third of
a thing's hold, so a long or hilly outing matters to something met on the way
home.

A thing goes when it gets what it wants. Effort it does not want (the road,
new ground, height, the opening blow) can loosen it down to its last point of
hold, but only a kind it wants, or a deliberate act (a rune, the word), sees
it off. Passing by never finishes anything by chance.
"""

from __future__ import annotations

import math
from collections.abc import Sequence
from dataclasses import dataclass, field
from typing import Any

from app.core.geo import haversine_m
from app.exploration.cells import cell_for

KINDS = ("ROAD", "GROUND", "CLIMB", "RUNE", "WORD")
CARRIED = "CARRIED"
FOOT = ("RUN", "WALK")


@dataclass(frozen=True)
class FightPoint:
    latitude: float
    longitude: float
    altitude: float | None
    # Accurate enough, not after a jump, not over the activity's speed cap.
    ok: bool = True


@dataclass(frozen=True)
class Foe:
    latitude: float
    longitude: float
    hold_max: float
    hold_before: float
    wants: tuple[str, ...]
    minds: tuple[str, ...] = ()
    # The shape its rune comes out as on a road (LOOP, TRIANGLE, SQUARE, ZIGZAG).
    road_form: str | None = None
    # Already given a rune, or a word, today: each lands once a day.
    rune_today: bool = False
    word_today: bool = False


@dataclass(frozen=True)
class RuneHit:
    shape: str
    index: int


@dataclass
class Blow:
    kind: str
    index: int
    units: float
    amount: float = 0.0


@dataclass
class FightReport:
    # SEEN_OFF, LOOSENED (hold taken, not finished), UNTOUCHED (met, nothing
    # landed) or NOT_NEAR (never came within reach).
    outcome: str
    hold_max: float
    hold_before: float
    hold_after: float
    damage: dict[str, float] = field(default_factory=dict)
    units: dict[str, float] = field(default_factory=dict)
    finisher: str | None = None
    blows: list[Blow] = field(default_factory=list)
    contact_index: int | None = None
    rune_landed: bool = False
    word_landed: bool = False
    # For a thing left standing: the cheapest wanted effort that would have done it.
    would_have_done: dict[str, Any] | None = None

    @property
    def taken(self) -> float:
        return self.hold_before - self.hold_after

    def to_dict(self) -> dict[str, Any]:
        return {
            "outcome": self.outcome,
            "holdMax": round(self.hold_max),
            "holdBefore": round(self.hold_before),
            "holdAfter": round(self.hold_after),
            "damage": {k: round(v) for k, v in self.damage.items() if round(v) > 0},
            "units": {k: round(v, 1) for k, v in self.units.items() if v > 0},
            "finisher": self.finisher,
            "runeLanded": self.rune_landed,
            "wordLanded": self.word_landed,
            "wouldHaveDone": self.would_have_done,
        }


DELIBERATE = ("RUNE", "WORD")


def finishes(kind: str, foe: Foe) -> bool:
    """Whether a blow of this kind may see a thing off: one it wants, or a deliberate act."""
    return kind in DELIBERATE or kind in foe.wants


def affinity(kind: str, foe: Foe, cfg: dict[str, Any]) -> float:
    if kind in foe.wants:
        return float(cfg["wants"])
    if kind in foe.minds:
        return float(cfg["minds"])
    return 1.0


def foot_scale(kind: str, activity: str, cfg: dict[str, Any]) -> float:
    if activity.upper() in FOOT:
        return float(cfg["footScale"].get(kind, 1.0))
    return 1.0


def sheet_multiplier(kind: str, damage_pct: dict[str, float], cfg: dict[str, Any]) -> float:
    low, high = cfg["sheetClamp"]
    return min(float(high), max(float(low), 1.0 + float(damage_pct.get(kind, 0.0))))


def per_unit(kind: str, foe: Foe, activity: str, damage_pct: dict[str, float], cfg: dict[str, Any]) -> float:
    """Hold one unit of this effort takes off this thing: a metre, a cell, a rune, a word."""
    rate = float(cfg["rates"][kind])
    return rate * foot_scale(kind, activity, cfg) * affinity(kind, foe, cfg) * sheet_multiplier(kind, damage_pct, cfg)


def resolve(
    points: Sequence[FightPoint],
    foe: Foe,
    *,
    activity: str,
    damage_pct: dict[str, float],
    cfg: dict[str, Any],
    new_cell_indices: Sequence[int] = (),
    rune_hit: RuneHit | None = None,
    word_indices: Sequence[int] = (),
) -> FightReport:
    """What one outing did to one thing."""
    report = FightReport(
        outcome="NOT_NEAR", hold_max=foe.hold_max, hold_before=foe.hold_before, hold_after=foe.hold_before
    )
    if not points or foe.hold_before <= 0:
        return report
    engage = float(cfg["engageMeters"])
    ground = float(cfg["groundMeters"])
    break_off = float(cfg["breakOffMeters"])
    distances = [haversine_m(foe.latitude, foe.longitude, p.latitude, p.longitude) for p in points]
    contact = next((i for i, (p, d) in enumerate(zip(points, distances, strict=True)) if p.ok and d <= engage), None)
    if contact is None:
        return report
    report.contact_index = contact

    # Inside its ground: from coming within `groundMeters` until passing `breakOffMeters`.
    inside: list[bool] = []
    within = False
    for d in distances:
        if not within and d <= ground:
            within = True
        elif within and d > break_off:
            within = False
        inside.append(within)

    stride = float(cfg["strideMeters"])
    max_jump = float(cfg["maxJumpMeters"])
    band_m = float(cfg["climbBandMeters"])
    road_cap = float(cfg["roadCapMeters"])
    road_resolution = int(cfg.get("roadCellResolution", 11))

    blows: list[Blow] = []
    before = {"ROAD": 0.0, "GROUND": 0.0, "CLIMB": 0.0}
    new_cells = set(new_cell_indices)

    # One pass for the road and the climb: anchors for the road, bands for height.
    anchor: FightPoint | None = None
    road_counted = 0.0
    # Cells left behind on this outing. Riding on inside the cell you are in is
    # new road; coming back into one you left is ground covered twice.
    road_cells: set[str] = set()
    road_cell: str | None = None
    road_fresh = True
    climbed_bands: set[int] = set()
    last_band: int | None = None
    for i, p in enumerate(points):
        if i in new_cells:
            if i < contact:
                before["GROUND"] += 1
            elif inside[i]:
                blows.append(Blow("GROUND", i, 1.0))
        if not p.ok:
            anchor = None
            continue
        if anchor is None:
            anchor = p
        else:
            step = haversine_m(anchor.latitude, anchor.longitude, p.latitude, p.longitude)
            if step > max_jump:
                anchor = p
            elif step >= stride:
                cell = cell_for(p.latitude, p.longitude, road_resolution)
                if cell != road_cell:
                    road_fresh = cell not in road_cells
                    road_cells.add(cell)
                    road_cell = cell
                fresh = road_fresh
                if fresh and i < contact:
                    before["ROAD"] += step
                elif fresh and inside[i] and road_counted < road_cap:
                    take = min(step, road_cap - road_counted)
                    road_counted += take
                    blows.append(Blow("ROAD", i, take))
                anchor = p
        if p.altitude is not None:
            band = math.floor(p.altitude / band_m)
            if last_band is not None and band > last_band:
                for b in range(last_band + 1, band + 1):
                    if b in climbed_bands:
                        continue
                    climbed_bands.add(b)
                    if i < contact:
                        before["CLIMB"] += band_m
                    elif inside[i]:
                        blows.append(Blow("CLIMB", i, band_m))
            last_band = band

    if rune_hit is not None and foe.road_form and not foe.rune_today and rune_hit.shape == foe.road_form:
        blows.append(Blow("RUNE", max(rune_hit.index, contact), 1.0))
    if not foe.word_today:
        radius = float(cfg["wordRadiusMeters"])
        near = [i for i in word_indices if 0 <= i < len(points) and distances[i] <= radius]
        if near:
            blows.append(Blow("WORD", max(min(near), contact), 1.0))

    # The opening blow: what the outing did before it met this thing.
    fraction = float(cfg.get("carriedFraction", 0.0))
    if fraction > 0:
        carried = fraction * sum(
            units * per_unit(kind, foe, activity, damage_pct, cfg) for kind, units in before.items()
        )
        carried = min(carried, float(cfg["carriedCap"]) * foe.hold_max)
        if carried > 0:
            blows.append(Blow(CARRIED, contact, 1.0, amount=carried))

    # Ordered as they happened; the opening blow first at contact.
    blows.sort(key=lambda b: (b.index, 0 if b.kind == CARRIED else 1))
    hold = foe.hold_before
    for blow in blows:
        if blow.kind != CARRIED:
            blow.amount = blow.units * per_unit(blow.kind, foe, activity, damage_pct, cfg)
            report.units[blow.kind] = report.units.get(blow.kind, 0.0) + blow.units
        if blow.amount <= 0:
            continue
        if hold - blow.amount <= 0 and not finishes(blow.kind, foe):
            # It loosens; it does not finish a thing that does not want it.
            blow.amount = max(0.0, hold - 1.0)
            hold = min(hold, 1.0)
        else:
            hold -= blow.amount
        report.damage[blow.kind] = report.damage.get(blow.kind, 0.0) + blow.amount
        report.blows.append(blow)
        if blow.kind == "RUNE":
            report.rune_landed = True
        if blow.kind == "WORD":
            report.word_landed = True
        if hold <= 0:
            report.finisher = blow.kind
            break

    if hold <= 0:
        report.outcome = "SEEN_OFF"
        report.hold_after = 0.0
        return report
    # A thing left standing keeps at least one: nobody is told "0 left".
    report.hold_after = max(1.0, round(hold))
    report.outcome = "LOOSENED" if report.taken >= 1 else "UNTOUCHED"
    report.would_have_done = _would_have_done(report.hold_after, foe, activity, damage_pct, cfg)
    return report


def _would_have_done(
    left: float, foe: Foe, activity: str, damage_pct: dict[str, float], cfg: dict[str, Any]
) -> dict[str, Any] | None:
    """The cheapest wanted effort that would have finished it: "13 m more height"."""
    options = []
    for kind, unit in (("CLIMB", "m"), ("GROUND", "cells"), ("ROAD", "m")):
        if kind not in foe.wants:
            continue
        need = left / per_unit(kind, foe, activity, damage_pct, cfg)
        if kind == "GROUND":
            need = math.ceil(need)
        elif kind == "CLIMB":
            need = math.ceil(need)
        else:
            need = int(math.ceil(need / 50.0) * 50)
        options.append({"kind": kind, "units": need, "unit": unit})
    for kind in ("RUNE", "WORD"):
        if kind in foe.wants and per_unit(kind, foe, activity, damage_pct, cfg) >= left:
            options.append({"kind": kind, "units": 1, "unit": "one"})
    if not options:
        return None
    # A single deliberate act beats any amount of anything; then the smallest ask.
    options.sort(key=lambda o: (o["unit"] != "one", o["units"] if o["unit"] != "m" else o["units"] / 100))
    return options[0]
