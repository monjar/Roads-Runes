"""Where things appear, and what they are. Pure: a seed and the places nearby in, plans out.

The same seed always gives the same plans, so two `/world` calls in one day
agree, and `IntegrityError` on `(user_id, seed)` is the tie-breaker between
concurrent callers rather than a double spawn.
"""

from __future__ import annotations

import hashlib
import math
import random
from dataclasses import dataclass, field
from typing import Any

from app.core.activity import ACTIVITIES, normalise
from app.core.geo import haversine_m
from app.lore.catalog import flavour_at_tier, name_at_tier, runes_by_id
from app.world_objects.variants import kinds as variant_kinds
from app.world_objects.variants import pick_variant

MINUTE = 60
# A place not passed in this many days is somewhere things settle.
STALE_DAYS = 30


@dataclass
class Anchor:
    discovery_id: str
    name: str
    category: str
    latitude: float
    longitude: float
    h3_index: str | None
    # What OpenStreetMap says the place is: water, a park, a ruin. A creature is
    # chosen to suit it.
    tags: dict[str, Any] = field(default_factory=dict)
    # Days since the player last passed through this place's cell, if they ever have.
    unpassed_days: int | None = None


@dataclass
class SpawnPlan:
    kind: str
    seed: str
    tier: int
    anchor: Anchor
    reward_ac: int
    payload: dict[str, Any] = field(default_factory=dict)
    bounty: bool = False
    # How long it stays, when not the usual (a Skittish creature leaves after a day).
    life_days: float | None = None


def tile_of(lat: float, lon: float) -> str:
    return f"{math.floor(lat / 0.05)}:{math.floor(lon / 0.05)}"


def day_seed(user_id: Any, day: str, tile: str, suffix: str = "") -> str:
    return hashlib.sha256(f"{user_id}|{day}|{tile}|{suffix}".encode()).hexdigest()[:40]


def _pace_text(seconds_per_km: float) -> str:
    minutes, seconds = divmod(int(round(seconds_per_km)), MINUTE)
    return f"{minutes}:{seconds:02d}/km"


def resolve_method(
    method: str,
    tier: int,
    cfg: dict[str, Any],
    *,
    character_class: str,
    activity: str,
    rng: random.Random,
    shape: str | None = None,
) -> dict[str, Any]:
    """One way to beat a monster with the numbers already worked out for this player."""
    rules = cfg["killMethods"][method]
    t = str(tier)
    activity = normalise(activity)
    if method == "PACE":
        ease = float(rules.get("classEase", {}).get(character_class, 1.0))
        paces = {a: int(round(float(rules["paceSecPerKm"][a][t]) * ease)) for a in ACTIVITIES}
        window = int(rules["windowMeters"][t])
        return {
            "method": "PACE",
            "params": {
                "windowMeters": window,
                "paceSecPerKm": paces,
                "searchRadiusMeters": rules["searchRadiusMeters"],
            },
            "hint": f"Cover {window} m at {_pace_text(paces[activity])} or faster within a kilometre of it.",
        }
    if method == "RUNE":
        # Its own rune's shape where it has one, so both ways of judging agree.
        shape = shape if shape in rules["shapes"] else rng.choice(rules["shapes"])
        threshold = float(rules.get("classThreshold", {}).get(character_class, rules["scoreThreshold"]))
        return {
            "method": "RUNE",
            "params": {
                "shape": shape,
                "scoreThreshold": threshold,
                "searchRadiusMeters": rules["searchRadiusMeters"],
                "minLengthMeters": rules["minLengthMeters"],
                "maxLengthMeters": rules["maxLengthMeters"],
            },
            "hint": f"Ride a {shape.lower()} shape within 1 km of it.",
        }
    if method == "CLIMB":
        ease = float(rules.get("classEase", {}).get(character_class, 1.0))
        gain = int(round(float(rules["gainMeters"][t]) * ease))
        return {
            "method": "CLIMB",
            "params": {"gainMeters": gain, "withinMeters": rules["withinMeters"]},
            "hint": f"Climb {gain} m within {rules['withinMeters'] // 1000} km of it.",
        }
    if method == "LORE":
        requires = list(rules.get("classRequires", {}).get(character_class, rules["requires"]))
        what = " and ".join({"photo": "a photo", "note": "a note"}[r] for r in requires)
        return {
            "method": "LORE",
            "params": {"requires": requires, "radiusMeters": rules["radiusMeters"]},
            "hint": f"Stop within {rules['radiusMeters']} m and leave {what}.",
        }
    if method == "EXPLORE":
        ease = int(rules.get("classEase", {}).get(character_class, 0))
        cells = max(1, int(rules["cells"][t]) + ease)
        return {
            "method": "EXPLORE",
            "params": {"cells": cells, "withinMeters": rules["withinMeters"]},
            "hint": f"Explore {cells} new tile{'s' if cells != 1 else ''} within {rules['withinMeters'] / 1000:g} km of it.",
        }
    raise ValueError(method)


def plan_spawns(
    *,
    seed: str,
    kind: str,
    indices: list[int],
    anchors: list[Anchor],
    taken_anchor_ids: set[str],
    occupied: list[tuple[float, float]],
    cfg: dict[str, Any],
    ac_rules: dict[str, Any],
    frontier: set[str],
    known: dict[str, str],
    character_class: str,
    activity: str,
    bounty: bool = False,
    centre: tuple[float, float] | None = None,
    runes: dict[str, Any] | None = None,
    variants: bool = True,
) -> list[SpawnPlan]:
    """One new object of `kind` per index, each at a real place nobody is using yet.

    Indices are the day's slots for this kind; a claimed or expired object keeps
    its slot, so its replacement takes the next one.
    """
    rng = random.Random(f"{seed}:{kind}")
    spacing = float(cfg["minSpacingMeters"])
    free = [
        a
        for a in anchors
        if a.discovery_id not in taken_anchor_ids
        and all(haversine_m(a.latitude, a.longitude, lat, lon) >= spacing for lat, lon in occupied)
    ]
    plans: list[SpawnPlan] = []
    used: list[tuple[float, float]] = []
    rings = list(cfg.get("rings") or ["anywhere"])
    for position, index in enumerate(indices):
        pool = [a for a in free if all(haversine_m(a.latitude, a.longitude, lat, lon) >= spacing for lat, lon in used)]
        if not pool:
            break
        # A weighting was not enough: in a city most places are a mile off, so most
        # spawns were too. Each slot belongs to a ring, and widens only if it is empty.
        pool = _in_ring(pool, rings[position % len(rings)], centre, cfg, _ring_scale(kind, activity, cfg))
        weights = [1.0 + _appeal(a, kind, frontier, known) + _nearness(a, centre, cfg) for a in pool]
        anchor = rng.choices(pool, weights=weights, k=1)[0]
        used.append((anchor.latitude, anchor.longitude))
        tier = rng.choices([1, 2, 3], weights=cfg["tierWeights"], k=1)[0]
        object_seed = f"{seed}:{kind}:{index}"
        if kind == "MONSTER":
            # The place first, then what would live there: a Tide Serpent at a pub
            # was a random draw, and the codex now says where each keeps.
            monster = pick_species(rng, anchor, cfg["monsters"])
            form = species_road_form(monster)
            methods = _pick_methods(rng, cfg)
            reward = int(ac_rules["monster"][str(tier)]) * (int(ac_rules["bountyMultiplier"]) if bounty else 1)
            hold = int(cfg.get("combat", {}).get("holdByTier", {}).get(str(tier), tier * 100))
            payload = {
                # Tier 1 is the thing itself; tiers 2 and 3 are its elders, by name.
                "name": name_at_tier(monster, tier) if monster.get("elders") else monster["name"],
                "flavour": flavour_at_tier(monster, tier) if monster.get("elders") else monster["flavour"],
                "speciesId": monster.get("id"),
                "anchorName": anchor.name,
                "hp": hold,
                # Effort is damage (fight.py): what it wants, what it shrugs at, its rune's shape.
                "species": {
                    "wants": list(monster.get("wants", [])),
                    "minds": list(monster.get("minds", [])),
                    "roadForm": form,
                },
                # The old pass/fail check, kept so a phone from before effort_combat (and
                # the server with the flag off) has something true to judge by. Never PACE.
                "killMethods": [
                    resolve_method(
                        m, tier, cfg, character_class=character_class, activity=activity, rng=rng, shape=form
                    )
                    for m in methods
                ],
            }
            if anchor.unpassed_days is not None:
                payload["unpassedDays"] = anchor.unpassed_days
            # A variant (0.7.2): never a bounty or a story's elder.
            variant = pick_variant(object_seed, tier) if variants and not bounty else None
            if variant is not None:
                spec = variant_kinds()[variant]
                payload["variant"] = variant
                payload["hp"] = payload["holdMax"] = int(round(hold * float(spec.get("healthScale", 1.0))))
                reward = int(round(reward * float(spec.get("coinScale", 1.0))))
                plans.append(
                    SpawnPlan(kind, object_seed, tier, anchor, reward, payload, bounty, life_days=spec.get("lifeDays"))
                )
                continue
        elif kind == "CHEST":
            reward = int(ac_rules["chest"][str(tier)])
            payload = {"name": ("Old", "Iron", "Gilded")[tier - 1] + " chest", "anchorName": anchor.name}
        else:
            collectable_set, piece = _pick_piece(rng, anchor, cfg, runes)
            reward = int(ac_rules["collectable"])
            payload = {
                "name": f"{piece} ({collectable_set['name']})",
                "anchorName": anchor.name,
                "setId": collectable_set["id"],
                "piece": piece,
            }
        plans.append(SpawnPlan(kind, object_seed, tier, anchor, reward, payload, bounty))
    return plans


RUNE_SETS = ("RUNES", "GROUND")


def _pick_piece(
    rng: random.Random, anchor: Anchor, cfg: dict[str, Any], runes: dict[str, Any] | None
) -> tuple[dict[str, Any], str]:
    """Which piece a place holds (0.7.0). The Ground Six only on their own kind of
    ground; rune stones a little likelier with Arcane Sight; and after enough
    stones of runes already held, one the player does not hold, if there is one."""
    from app.inventory import catalog as rune_book
    from app.lore.catalog import rune_by_name, runes_by_id

    runes = runes or {}
    ground_here = {runes_by_id()[r]["name"] for r in rune_book.ground_runes_at(anchor.category, anchor.tags)}
    options: list[tuple[dict[str, Any], list[str]]] = []
    for collectable_set in cfg["collectableSets"]:
        pieces = list(collectable_set["pieces"])
        if collectable_set.get("onGround"):
            pieces = [p for p in pieces if p in ground_here]
        if pieces:
            options.append((collectable_set, pieces))
    weights = [(1.0 + float(runes.get("arcaneSight", 0.0))) if s["id"] in RUNE_SETS else 1.0 for s, _ in options]
    collectable_set, pieces = rng.choices(options, weights=weights, k=1)[0]
    if collectable_set["id"] in RUNE_SETS and runes.get("pity"):
        held = set(runes.get("held") or ())
        unheld = [p for p in pieces if (rune_by_name(p) or {}).get("id") not in held]
        if unheld:
            pieces = unheld
    return collectable_set, rng.choice(pieces)


# Speed is never asked for (docs/PRODUCT_SPEC.md): PACE is no longer dealt.
RETIRED_METHODS = {"PACE"}


def _pick_methods(rng: random.Random, cfg: dict[str, Any]) -> list[str]:
    """Two ways in, one of them always beatable without a camera or a Scribe."""
    physical = ["CLIMB", "EXPLORE"]
    first = rng.choice(physical)
    others = [m for m in cfg["killMethods"] if m != first and m not in RETIRED_METHODS]
    return [first, rng.choice(others)]


def _tag_matches(habitat_tags: dict[str, list[str]], tags: dict[str, Any]) -> bool:
    for key, values in habitat_tags.items():
        if key in tags and ("*" in values or str(tags[key]) in values):
            return True
    return False


def species_weight(species: dict[str, Any], anchor: Anchor) -> float:
    """How well a creature suits a place: its tags, then its kind of place, then anywhere."""
    habitat = species.get("habitat") or {}
    if _tag_matches(habitat.get("tags") or {}, anchor.tags or {}):
        return 6.0
    if anchor.category in (habitat.get("categories") or []):
        return 3.0
    # The odd one turns up lost, about one time in four.
    return 0.2


def pick_species(rng: random.Random, anchor: Anchor, monsters: list[dict[str, Any]]) -> dict[str, Any]:
    return rng.choices(monsters, weights=[species_weight(m, anchor) for m in monsters], k=1)[0]


def species_road_form(species: dict[str, Any]) -> str | None:
    rune = runes_by_id().get(species.get("rune") or "")
    return rune.get("roadForm") if rune else None


def _ring_scale(kind: str, activity: str, cfg: dict[str, Any]) -> float:
    """A creature's rings widen with how far the player goes: a ride passes more
    ground than a walk, and a monster on the doorstep is met by every outing."""
    if kind != "MONSTER":
        return 1.0
    return float(cfg.get("monsterRingScale", {}).get(normalise(activity), 1.0))


def _in_ring(
    pool: list[Anchor], ring: str, centre: tuple[float, float] | None, cfg: dict[str, Any], scale: float = 1.0
) -> list[Anchor]:
    """The places within this slot's ring; the next ring out if there are none."""
    if centre is None or ring == "anywhere":
        return pool
    limits = [float(cfg.get("nearMeters", 700)) * scale, float(cfg.get("walkableMeters", 1800)) * scale]
    for limit in limits if ring == "near" else limits[1:]:
        inside = [a for a in pool if haversine_m(centre[0], centre[1], a.latitude, a.longitude) <= limit]
        if inside:
            return inside
    return pool


def _nearness(anchor: Anchor, centre: tuple[float, float] | None, cfg: dict[str, Any]) -> float:
    """A pull towards the player: most of what spawns should be a walk away, not a day trip."""
    if centre is None:
        return 0.0
    distance = haversine_m(centre[0], centre[1], anchor.latitude, anchor.longitude)
    if distance <= float(cfg.get("nearMeters", 1200)):
        return 4.0
    if distance <= float(cfg.get("walkableMeters", 2500)):
        return 2.0
    return 0.0


def _appeal(anchor: Anchor, kind: str, frontier: set[str], known: dict[str, str]) -> float:
    score = 0.0
    cell = anchor.h3_index
    if kind == "MONSTER":
        if cell in frontier:
            score += 3.0
        elif cell and cell not in known:
            score += 2.0
        # Things settle where nobody is paying attention: ground the player once
        # read and has not passed in a month.
        if anchor.unpassed_days is not None and anchor.unpassed_days >= STALE_DAYS:
            score += 2.0
    if kind == "CHEST" and anchor.category in ("NATURE", "VIEWPOINT", "HISTORICAL"):
        score += 1.0
    return score
