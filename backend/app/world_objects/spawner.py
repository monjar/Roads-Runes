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

MINUTE = 60


@dataclass
class Anchor:
    discovery_id: str
    name: str
    category: str
    latitude: float
    longitude: float
    h3_index: str | None


@dataclass
class SpawnPlan:
    kind: str
    seed: str
    tier: int
    anchor: Anchor
    reward_ac: int
    payload: dict[str, Any] = field(default_factory=dict)
    bounty: bool = False


def tile_of(lat: float, lon: float) -> str:
    return f"{math.floor(lat / 0.05)}:{math.floor(lon / 0.05)}"


def day_seed(user_id: Any, day: str, tile: str, suffix: str = "") -> str:
    return hashlib.sha256(f"{user_id}|{day}|{tile}|{suffix}".encode()).hexdigest()[:40]


def _pace_text(seconds_per_km: float) -> str:
    minutes, seconds = divmod(int(round(seconds_per_km)), MINUTE)
    return f"{minutes}:{seconds:02d}/km"


def resolve_method(
    method: str, tier: int, cfg: dict[str, Any], *, character_class: str, activity: str, rng: random.Random
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
        shape = rng.choice(rules["shapes"])
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
            "hint": f"Trace a {shape.lower()} with your track, within a kilometre of it.",
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
            "hint": f"Clear {cells} new areas within {rules['withinMeters'] / 1000:.1f} km of it.",
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
    for index in indices:
        pool = [a for a in free if all(haversine_m(a.latitude, a.longitude, lat, lon) >= spacing for lat, lon in used)]
        if not pool:
            break
        weights = [1.0 + _appeal(a, kind, frontier, known) for a in pool]
        anchor = rng.choices(pool, weights=weights, k=1)[0]
        used.append((anchor.latitude, anchor.longitude))
        tier = rng.choices([1, 2, 3], weights=cfg["tierWeights"], k=1)[0]
        object_seed = f"{seed}:{kind}:{index}"
        if kind == "MONSTER":
            monster = rng.choice(cfg["monsters"])
            methods = _pick_methods(rng, cfg)
            reward = int(ac_rules["monster"][str(tier)]) * (int(ac_rules["bountyMultiplier"]) if bounty else 1)
            payload = {
                "name": monster["name"],
                "flavour": monster["flavour"],
                "anchorName": anchor.name,
                "hp": tier * 100,
                "killMethods": [
                    resolve_method(m, tier, cfg, character_class=character_class, activity=activity, rng=rng)
                    for m in methods
                ],
            }
        elif kind == "CHEST":
            reward = int(ac_rules["chest"][str(tier)])
            payload = {"name": ("Old", "Iron", "Gilded")[tier - 1] + " chest", "anchorName": anchor.name}
        else:
            collectable_set = rng.choice(cfg["collectableSets"])
            piece = rng.choice(collectable_set["pieces"])
            reward = int(ac_rules["collectable"])
            payload = {
                "name": f"{piece} ({collectable_set['name']})",
                "anchorName": anchor.name,
                "setId": collectable_set["id"],
                "piece": piece,
            }
        plans.append(SpawnPlan(kind, object_seed, tier, anchor, reward, payload, bounty))
    return plans


def _pick_methods(rng: random.Random, cfg: dict[str, Any]) -> list[str]:
    """Two ways in, one of them always beatable without a camera or a Scribe."""
    physical = ["PACE", "CLIMB", "EXPLORE"]
    first = rng.choice(physical)
    others = [m for m in cfg["killMethods"] if m != first]
    return [first, rng.choice(others)]


def _appeal(anchor: Anchor, kind: str, frontier: set[str], known: dict[str, str]) -> float:
    score = 0.0
    cell = anchor.h3_index
    if kind == "MONSTER":
        if cell in frontier:
            score += 3.0
        elif cell and cell not in known:
            score += 2.0
    if kind == "CHEST" and anchor.category in ("NATURE", "VIEWPOINT", "HISTORICAL"):
        score += 1.0
    return score
