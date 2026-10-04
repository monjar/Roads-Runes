"""Run outings through the fight model and print whether the numbers hold up.

Usage:
  python scripts/replay_fights.py --synthetic            # outings made up over real places
  python scripts/replay_fights.py --gpx a.gpx b.gpx       # outings you exported from the Journal
  python scripts/replay_fights.py --rides [--subject rider-1]   # stored rides, read-only

Creatures are placed the way the spawner places them (by habitat, at real
places from the database near each outing's start), then each outing is fought
with `app/world_objects/fight.py` and the constants in world_objects.json.
Nothing is written. It prints, per outing, how much of its effort landed on
anything, what was seen off, and how many of those needed no deliberate act;
then the pass marks from docs/ROADMAP.md (Ground truth 5):

* a 25 km outing does more than a 5 km one;
* at least a third of an outing's effort lands on something;
* at most one outing in five sees something off by accident.
"""

from __future__ import annotations

import argparse
import asyncio
import math
import random
import xml.etree.ElementTree as ET
from dataclasses import dataclass

from sqlalchemy import select

import app.db.models  # noqa: F401  # register every mapper before the first query
from app.core.geo import destination_point, haversine_m
from app.db.session import get_session_factory
from app.discoveries.sensitivity import is_sensitive
from app.discoveries.service import nearby
from app.exploration.cells import cell_for
from app.lore import catalog
from app.rides.models import Ride, RidePoint
from app.users.models import User
from app.world_objects import fight
from app.world_objects.service import load_config
from app.world_objects.spawner import Anchor, pick_species, species_road_form

VERBOSE = False


@dataclass
class Outing:
    name: str
    activity: str
    points: list[fight.FightPoint]


def made_good(points: list[fight.FightPoint]) -> float:
    return sum(
        haversine_m(a.latitude, a.longitude, b.latitude, b.longitude) for a, b in zip(points, points[1:], strict=False)
    )


def climbed(points: list[fight.FightPoint]) -> float:
    gain, anchor = 0.0, None
    for p in points:
        if p.altitude is None:
            continue
        if anchor is None or p.altitude < anchor - 3:
            anchor = p.altitude
        elif p.altitude >= anchor + 3:
            gain += p.altitude - anchor
            anchor = p.altitude
    return gain


# --- outings -------------------------------------------------------------------


def synthetic(home: tuple[float, float]) -> list[Outing]:
    """A commute, a walk, a flat ride and a hilly one, wandering like real streets do."""

    def wander(name, activity, km, seed, climb_m=0.0, spacing=10.0):
        rng = random.Random(seed)
        pts, here, bearing, alt = [], home, rng.uniform(0, 360), 10.0
        steps = int(km * 1000 / spacing)
        for k in range(steps):
            if k < steps // 2:
                # Out: wander, turning now and then like streets do.
                if k % 40 == 0:
                    bearing += rng.choice([-90, 0, 0, 90])
            else:
                # Home: head back, with a little wiggle.
                from app.core.geo import bearing_deg

                bearing = bearing_deg(here[0], here[1], home[0], home[1]) + rng.uniform(-25, 25)
                if haversine_m(here[0], here[1], home[0], home[1]) < spacing * 2:
                    break
            here = destination_point(here[0], here[1], bearing, spacing)
            if climb_m:
                alt = 10 + climb_m / 4 * (1 + math.sin(k / steps * 8 * math.pi))
            pts.append(fight.FightPoint(here[0], here[1], alt))
        return Outing(name, activity, pts)

    return [
        wander("commute 5 km", "RIDE", 5, 1),
        wander("walk 6 km", "WALK", 6, 2),
        wander("flat ride 25 km", "RIDE", 25, 3),
        wander("hilly ride 40 km", "RIDE", 40, 4, climb_m=620),
        wander("run 8 km", "RUN", 8, 5),
    ]


def from_gpx(paths: list[str]) -> list[Outing]:
    out = []
    for path in paths:
        tree = ET.parse(path)
        pts = []
        for el in tree.iter():
            if el.tag.endswith("trkpt"):
                ele = next((c.text for c in el if c.tag.endswith("ele")), None)
                pts.append(fight.FightPoint(float(el.get("lat")), float(el.get("lon")), float(ele) if ele else None))
        out.append(Outing(path.rsplit("/", 1)[-1], "RIDE", pts))
    return out


async def from_rides(subject: str | None) -> list[Outing]:
    async with get_session_factory()() as db:
        stmt = select(Ride).where(Ride.status.in_(["PROCESSED", "FLAGGED"])).order_by(Ride.started_at)
        if subject:
            user = await db.scalar(select(User).where(User.apple_subject.in_([f"dev:{subject}", subject])))
            stmt = stmt.where(Ride.user_id == user.id)
        out = []
        for ride in (await db.execute(stmt)).scalars():
            rows = (
                await db.execute(select(RidePoint).where(RidePoint.ride_id == ride.id).order_by(RidePoint.sequence))
            ).scalars()
            pts = [
                fight.FightPoint(
                    p.latitude, p.longitude, p.altitude_meters, ok=(p.horizontal_accuracy_meters or 0) <= 30
                )
                for p in rows
            ]
            if len(pts) > 10:
                out.append(
                    Outing(f"{ride.started_at:%Y-%m-%d} {ride.distance_meters / 1000:.1f} km", ride.activity, pts)
                )
        return out


# --- fighting ------------------------------------------------------------------


async def creatures_for(outing: Outing, seed: int) -> list[tuple[dict, Anchor, int]]:
    """Five creatures round the start, placed as the spawner would."""
    cfg = load_config()
    start = outing.points[0]
    async with get_session_factory()() as db:
        places = [
            d
            for d in await nearby(db, start.latitude, start.longitude, 6000, limit=900)
            if not is_sensitive(d.name, d.tags)
        ]
    rng = random.Random(seed)
    scale = cfg.get("monsterRingScale", {}).get(outing.activity, 1.0)
    rings = [700 * scale, 1800 * scale, 700 * scale, 6000, 1800 * scale]
    out = []
    for ring in rings:
        pool = [d for d in places if haversine_m(start.latitude, start.longitude, d.latitude, d.longitude) <= ring]
        if not pool:
            continue
        d = rng.choice(pool)
        anchor = Anchor(str(d.id), d.name, d.category, d.latitude, d.longitude, d.h3_index, tags=dict(d.tags or {}))
        species = pick_species(rng, anchor, cfg["monsters"])
        tier = rng.choices([1, 2, 3], weights=cfg["tierWeights"], k=1)[0]
        out.append((species, anchor, tier))
    return out


async def replay(outings: list[Outing], home: tuple[float, float], known_radius_m: float) -> None:
    cfg = load_config()["combat"]
    summary = []
    # An established player has read the ground round home; outings run in order
    # and each one's new ground is known to the next.
    import h3

    known: set[str] = set(h3.grid_disk(cell_for(home[0], home[1], 9), max(0, int(known_radius_m / 350))))
    print(f"Ground already read round home: {len(known)} cells ({known_radius_m:.0f} m)")
    print(f"{'outing':<22} {'km':>5} {'climb':>6} {'landed':>7} {'met':>4} {'off':>4} {'by chance':>9} {'taken':>6}")
    for n, outing in enumerate(outings):
        pts = outing.points
        entered = []
        for i, p in enumerate(pts):
            cell = cell_for(p.latitude, p.longitude, 9)
            if cell not in known:
                known.add(cell)
                entered.append(i)
        met = off = accidental = 0
        taken = 0.0
        landed_road = 0.0
        for species, anchor, tier in await creatures_for(outing, n):
            hold = float(cfg["holdByTier"][str(tier)])
            foe = fight.Foe(
                anchor.latitude,
                anchor.longitude,
                hold,
                hold,
                tuple(species["wants"]),
                tuple(species["minds"]),
                species_road_form(species),
            )
            report = fight.resolve(pts, foe, activity=outing.activity, damage_pct={}, cfg=cfg, new_cell_indices=entered)
            if report.outcome == "NOT_NEAR":
                continue
            if VERBOSE:
                print(
                    f"    {species['name']} t{tier} wants {'+'.join(species['wants'])}: {report.outcome} "
                    f"{ {k: round(v) for k, v in report.damage.items()} } finisher {report.finisher}"
                )
            met += 1
            taken += report.taken
            landed_road += report.units.get("ROAD", 0.0)
            if report.outcome == "SEEN_OFF":
                off += 1
                # No rune, no word: nothing was done on purpose.
                if not (report.rune_landed or report.word_landed):
                    accidental += 1
        km = made_good(pts) / 1000
        share = min(1.0, landed_road / max(1.0, km * 1000))
        summary.append((outing, km, share, off, accidental, taken))
        print(
            f"{outing.name[:22]:<22} {km:5.1f} {climbed(pts):6.0f} {share:7.0%} {met:4d} {off:4d} {accidental:9d} {taken:6.0f}"
        )

    print()
    by_name = {o.name: t for o, _, _, _, _, t in summary}
    if "flat ride 25 km" in by_name and "commute 5 km" in by_name:
        verdict = by_name["flat ride 25 km"] > by_name["commute 5 km"]
        print(f"25 km does more than 5 km: {'yes' if verdict else 'NO'}")
    landed = sum(1 for _, _, share, _, _, _ in summary if share >= 1 / 3)
    print(f"Outings where a third of the road landed on something: {landed} of {len(summary)}")
    chance = sum(1 for *_, acc, _ in summary if acc)
    print(f"Outings that saw something off by chance: {chance} of {len(summary)} (pass: at most one in five)")
    if len(summary) < 10:
        print("Fewer than ten outings: the numbers stay provisional.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--synthetic", action="store_true")
    parser.add_argument("--gpx", nargs="*")
    parser.add_argument("--rides", action="store_true")
    parser.add_argument("--subject")
    parser.add_argument("--home", default="51.4906,-0.0316")
    parser.add_argument("--known", type=float, default=1500, help="metres round home already read")
    parser.add_argument("-v", "--verbose", action="store_true", help="every fight, blow by blow")
    args = parser.parse_args()
    home = tuple(float(x) for x in args.home.split(","))
    global VERBOSE
    VERBOSE = args.verbose
    if args.gpx:
        outings = from_gpx(args.gpx)
    elif args.rides:
        outings = asyncio.run(from_rides(args.subject))
    else:
        outings = synthetic(home)
    asyncio.run(replay(outings, home, args.known))
    _ = catalog


if __name__ == "__main__":
    main()
