"""Deterministic quest generation (spec §20–21).

Stage 1 (this module) is purely geographic and rule based:
  inputs  -> location, class, levels, rider profile, bike, explored cells,
             completed templates, nearby POIs, unlocked templates, seed
  outputs -> `GeneratedQuest` objects with concrete objectives

Stage 2 (narrative.py) may replace titles/descriptions with LLM text but
never touches objectives or coordinates.

Safety: candidate destinations are POIs flagged `cycling_accessible` and
H3 cell centres; cell-centre objectives use a generous radius so the rider
never has to reach an exact point that might be off the road network.
"""

from __future__ import annotations

import hashlib
import random
from dataclasses import dataclass, field
from typing import Any

import h3

from app.core.activity import ASSUMED_SPEED_KMH, DISTANCE_SCALE, noun, verb
from app.core.geo import destination_point, haversine_m
from app.core.logging import get_logger
from app.economy.rules import quest_ac
from app.exploration.cells import cell_center, cell_for, frontier_cells
from app.quests.templates import ANY_CLASS, DIFFICULTIES, template_by_id, templates_for

REGION_RADIUS_M = 250.0  # radius around a cell centre that counts as "entered"


log = get_logger(__name__)


@dataclass
class POICandidate:
    id: str
    name: str
    category: str
    latitude: float
    longitude: float
    tags: dict[str, Any] = field(default_factory=dict)
    h3_index: str | None = None


@dataclass
class WorldObjectCandidate:
    """A chest, piece or monster already placed in this player's world (world_objects)."""

    id: str
    kind: str
    name: str
    anchor_name: str | None
    latitude: float
    longitude: float


@dataclass
class GenerationContext:
    latitude: float
    longitude: float
    character_class: str
    overall_level: int
    class_level: int
    comfortable_distance_km: float
    comfortable_elevation_gain: float
    gravel_comfort: float
    bike_allows_gravel: bool
    bike_allows_trails: bool
    explored_cells: set[str]
    visited_cells: set[str]
    completed_template_ids: list[str]
    pois: list[POICandidate]
    unlocked_templates: set[str] = field(default_factory=set)
    resolution: int = 9
    seed: str | None = None
    requested_distance_km: float | None = None
    poi_visibility_bonus: float = 0.0
    activity: str = "RIDE"  # RIDE | RUN | WALK (core/activity.py)
    world_objects: list[WorldObjectCandidate] = field(default_factory=list)


@dataclass
class GeneratedObjective:
    objective_type: str
    title: str
    required: bool
    order: int
    latitude: float | None = None
    longitude: float | None = None
    radius_meters: float | None = None
    target_meters: float | None = None
    target_cells: list[str] | None = None
    target_elevation_meters: float | None = None
    target_count: int | None = None
    # Targets that are neither a distance nor a count: km/h to hold, minutes to ride.
    target_value: float | None = None
    discovery_id: str | None = None
    extra: dict[str, Any] = field(default_factory=dict)

    @property
    def progress_target(self) -> float:
        if self.target_value:
            return float(self.target_value)
        if self.target_count:
            return float(self.target_count)
        if self.target_meters:
            return float(self.target_meters)
        if self.target_elevation_meters:
            return float(self.target_elevation_meters)
        return 1.0


@dataclass
class GeneratedQuest:
    template_id: str
    quest_type: str
    character_class: str
    title: str
    description: str
    difficulty: str
    recommended_distance_km: float
    estimated_duration_minutes: int
    base_xp: int
    objectives: list[GeneratedObjective]
    narrative: dict[str, Any]
    seed: str
    latitude: float
    longitude: float
    rewards: dict[str, Any]
    variables: dict[str, Any]
    activity: str = "RIDE"


def _rng(ctx: GenerationContext, template_id: str, salt: int) -> random.Random:
    base = ctx.seed or f"{round(ctx.latitude, 3)}:{round(ctx.longitude, 3)}"
    digest = hashlib.sha256(f"{base}|{template_id}|{salt}".encode()).hexdigest()
    return random.Random(int(digest[:16], 16))


def _scale_range(rng: random.Random, rng_range: list[float], scale: float) -> float:
    lo, hi = rng_range
    value = rng.uniform(lo, hi) * scale
    return round(max(lo * 0.6, value), 1)


def _distance_scale(ctx: GenerationContext) -> float:
    # The comfortable distance is already the activity's own (run or walk), so it
    # is measured against that activity's idea of a middling outing, not a ride's.
    base = ctx.requested_distance_km or ctx.comfortable_distance_km
    middling = 25.0 * DISTANCE_SCALE.get(ctx.activity, 1.0)
    return max(0.5, min(2.0, base / middling))


# Rules that are distances: written for bikes, scaled for feet.
DISTANCE_RULES = ("distanceKm", "newTerritoryKm", "regionDistanceKm", "poiDistanceKm")


def _rules_for(rules: dict[str, Any], activity: str) -> dict[str, Any]:
    """A template's rules for this activity.

    A rule may be one value (written for bikes; feet get distances scaled) or a
    dict keyed by activity, for numbers that do not scale, like a tempo.
    """
    scale = DISTANCE_SCALE.get(activity, 1.0)
    out: dict[str, Any] = {}
    for key, value in rules.items():
        if isinstance(value, dict) and any(k in value for k in DISTANCE_SCALE):
            value = value.get(activity, value.get("RIDE"))
            if value is None:
                continue
        elif key in DISTANCE_RULES and scale != 1.0:
            value = [v * scale for v in value] if isinstance(value, list) else value * scale
        out[key] = value
    return out


def _unexplored_cell_at(
    ctx: GenerationContext, rng: random.Random, distance_km_range: list[float], exclude: set[str]
) -> str | None:
    """Pick an unexplored cell roughly `distance` away in a random bearing."""
    for _ in range(24):
        distance_m = rng.uniform(*distance_km_range) * 1000
        bearing = rng.uniform(0, 360)
        lat, lon = destination_point(ctx.latitude, ctx.longitude, bearing, distance_m)
        cell = cell_for(lat, lon, ctx.resolution)
        if cell in ctx.visited_cells or cell in ctx.explored_cells or cell in exclude:
            continue
        return cell
    return None


def _frontier_cell(ctx: GenerationContext, rng: random.Random, exclude: set[str], max_km: float) -> str | None:
    origin = cell_for(ctx.latitude, ctx.longitude, ctx.resolution)
    edge_m = h3.average_hexagon_edge_length(ctx.resolution, unit="m")
    k = max(2, int(max_km * 1000 / (edge_m * 1.7)))
    known = ctx.explored_cells | ctx.visited_cells
    candidates = [c for c in frontier_cells(known, ctx.resolution, origin, k) if c not in exclude]
    if not candidates:
        return _unexplored_cell_at(ctx, rng, [1.5, max_km], exclude)
    rng.shuffle(candidates)
    return candidates[0]


def _poi_candidates(ctx: GenerationContext, rules: dict[str, Any]) -> list[POICandidate]:
    default_reach = DISTANCE_SCALE.get(ctx.activity, 1.0)
    lo, hi = rules.get("poiDistanceKm", [3 * default_reach, 15 * default_reach])
    lo_m, hi_m = lo * 1000, hi * 1000 * (1 + ctx.poi_visibility_bonus)
    category = rules.get("poiCategory")
    tag_any = rules.get("poiTagAny")
    out = []
    for poi in ctx.pois:
        if category and poi.category != category:
            continue
        if tag_any and not any(t in " ".join(str(v) for v in poi.tags.values()).lower() for t in tag_any):
            continue
        d = haversine_m(ctx.latitude, ctx.longitude, poi.latitude, poi.longitude)
        if not lo_m <= d <= hi_m:
            continue
        if rules.get("requireUnexplored"):
            cell = poi.h3_index or cell_for(poi.latitude, poi.longitude, ctx.resolution)
            if cell in ctx.explored_cells:
                continue
        out.append(poi)
    return out


def _fact_for(poi: POICandidate) -> str:
    """One line about a place, from its OpenStreetMap tags. Wizard and Scribe
    quests read it out; it is never invented."""
    tags = poi.tags or {}
    for key in ("historic", "tourism", "leisure", "natural", "amenity", "shop"):
        value = tags.get(key)
        if value:
            return f"The map files it as {str(value).replace('_', ' ')}."
    return "The map says almost nothing about it."


def _difficulty(distance_km: float, ctx: GenerationContext, elevation_m: float = 0.0) -> str:
    ratio = distance_km / max(ctx.comfortable_distance_km, 5)
    if elevation_m > ctx.comfortable_elevation_gain * 1.5:
        ratio += 0.5
    if ratio < 0.7:
        return "EASY"
    if ratio < 1.15:
        return "MODERATE"
    if ratio < 1.7:
        return "HARD"
    return "EPIC"


def _base_xp(difficulty: str, template: dict[str, Any]) -> int:
    from app.progression.engine import load_xp_rules

    return int(load_xp_rules()["questBase"][difficulty] * (1 + 0.05 * (template.get("weight", 1) - 1)))


def instantiate(template: dict[str, Any], ctx: GenerationContext, salt: int = 0) -> GeneratedQuest | None:
    rng = _rng(ctx, template["id"], salt)
    rules = _rules_for(template.get("objectiveRules", {}), ctx.activity)
    scale = _distance_scale(ctx)
    variables: dict[str, Any] = {}
    used_cells: set[str] = set()
    objectives: list[GeneratedObjective] = []
    farthest_m = 0.0

    variables["activityVerb"] = verb(ctx.activity)
    variables["activityNoun"] = noun(ctx.activity)
    if "distanceKm" in rules:
        variables["distanceKm"] = _scale_range(rng, rules["distanceKm"], scale)
    if "newTerritoryKm" in rules:
        variables["newTerritoryKm"] = _scale_range(rng, rules["newTerritoryKm"], scale)
    if "elevationMeters" in rules:
        variables["elevationMeters"] = int(
            _scale_range(rng, rules["elevationMeters"], max(0.6, ctx.comfortable_elevation_gain / 300))
        )
    if "durationMinutes" in rules:
        variables["durationMinutes"] = int(_scale_range(rng, rules["durationMinutes"], scale))
    if "speedKmh" in rules:
        # Pace is personal, not a function of how far the rider usually goes.
        variables["speedKmh"] = round(_scale_range(rng, rules["speedKmh"], 1.0), 1)

    poi: POICandidate | None = None
    if "poiCategory" in rules:
        if rules.get("requiresGravel") and not (ctx.bike_allows_gravel or ctx.bike_allows_trails):
            return None
        candidates = _poi_candidates(ctx, rules)
        if not candidates:
            return None
        poi = rng.choice(candidates)
        variables["poiName"] = poi.name
        variables["poiFact"] = _fact_for(poi)
        farthest_m = haversine_m(ctx.latitude, ctx.longitude, poi.latitude, poi.longitude)

    region_cells: list[str] = []
    if "regionCount" in rules:
        count = int(rules["regionCount"])
        dist_range = rules.get(
            "regionDistanceKm", [3 * DISTANCE_SCALE.get(ctx.activity, 1.0), 12 * DISTANCE_SCALE.get(ctx.activity, 1.0)]
        )
        dist_range = [dist_range[0] * scale, dist_range[1] * scale]
        for _ in range(count):
            cell = (
                _frontier_cell(ctx, rng, used_cells, dist_range[1])
                if rules.get("frontier")
                else _unexplored_cell_at(ctx, rng, dist_range, used_cells)
            )
            if cell is None:
                break
            used_cells.add(cell)
            region_cells.append(cell)
            lat, lon = cell_center(cell)
            farthest_m = max(farthest_m, haversine_m(ctx.latitude, ctx.longitude, lat, lon))
        if len(region_cells) < count:
            return None

    # A quest about the world points at something already in it: the nearest few, one at random.
    target_object: WorldObjectCandidate | None = None
    if "worldObject" in rules:
        kind = str(rules["worldObject"].get("kind", "MONSTER"))
        pool = sorted(
            (o for o in ctx.world_objects if o.kind == kind),
            key=lambda o: haversine_m(ctx.latitude, ctx.longitude, o.latitude, o.longitude),
        )
        if not pool:
            return None
        target_object = rng.choice(pool[:3])
        variables["objectName"] = target_object.name
        variables["objectPlace"] = target_object.anchor_name or "somewhere near"
        farthest_m = max(
            farthest_m, haversine_m(ctx.latitude, ctx.longitude, target_object.latitude, target_object.longitude)
        )

    explored_region_cells: list[str] = []
    order = 0
    for spec in template["objectives"]:
        order += 1
        otype = spec["type"]
        title = spec["title"].format(**{k: v for k, v in variables.items()}) if variables else spec["title"]
        obj = GeneratedObjective(objective_type=otype, title=title, required=spec.get("required", True), order=order)

        if otype == "VISIT_POI" and poi is not None:
            obj.latitude, obj.longitude = poi.latitude, poi.longitude
            obj.radius_meters = float(spec.get("radiusMeters", 60))
            obj.discovery_id = poi.id
            obj.extra = {"poiName": poi.name, "category": poi.category}
        elif otype == "VISIT_REGION":
            cell = region_cells[0] if region_cells else None
            if cell is None:
                return None
            lat, lon = cell_center(cell)
            obj.latitude, obj.longitude, obj.radius_meters = lat, lon, REGION_RADIUS_M
            obj.target_cells = [cell]
        elif otype == "VISIT_MULTIPLE_LOCATIONS":
            if spec.get("explored"):
                known = list(ctx.explored_cells or ctx.visited_cells)
                if len(known) < spec.get("count", 2):
                    return None
                rng.shuffle(known)
                explored_region_cells = known[: spec.get("count", 2)]
                cells = explored_region_cells
            else:
                cells = region_cells
            obj.target_cells = cells
            obj.target_count = len(cells)
            lat, lon = cell_center(cells[0])
            obj.latitude, obj.longitude, obj.radius_meters = lat, lon, REGION_RADIUS_M
            obj.extra = {
                "cells": [{"h3": c, "latitude": cell_center(c)[0], "longitude": cell_center(c)[1]} for c in cells]
            }
        elif otype == "EXPLORE_NEW_ROADS":
            km = variables.get("newTerritoryKm") or 2.0
            obj.target_meters = km * 1000
        elif otype == "EXPLORE_DISTANCE":
            fraction = rules.get("newTerritoryFraction", 0.5)
            obj.target_meters = variables.get("distanceKm", 15) * 1000 * fraction
            obj.extra = {"fraction": fraction}
        elif otype == "COMPLETE_DISTANCE":
            obj.target_meters = variables.get("distanceKm", 15) * 1000
        elif otype == "REACH_ELEVATION":
            obj.target_elevation_meters = float(
                variables.get("elevationMeters") or max(150, ctx.comfortable_elevation_gain * 0.6)
            )
        elif otype == "RETURN_TO_START":
            obj.latitude, obj.longitude = ctx.latitude, ctx.longitude
            obj.radius_meters = float(spec.get("radiusMeters", 300))
        elif otype in ("PHOTO_LOCATION", "WRITE_NOTE"):
            if poi is not None:
                obj.latitude, obj.longitude, obj.radius_meters = poi.latitude, poi.longitude, 120.0
                obj.discovery_id = poi.id
            obj.extra = {"safety": "Stop safely before completing this objective."}
        elif otype == "COMPLETE_CLIMB":
            obj.target_elevation_meters = float(variables.get("elevationMeters", 300))
        elif otype == "RIDE_DURATION":
            obj.target_value = float(variables.get("durationMinutes", 60))
        elif otype == "SUSTAIN_SPEED":
            obj.target_value = float(variables.get("speedKmh", 20))
            # A fast two kilometres is not a tempo ride.
            obj.extra = {"minDistanceMeters": float(variables.get("distanceKm", 10)) * 1000 * 0.8}
        elif otype in ("SLAY_MONSTER", "OPEN_CHEST", "COLLECT"):
            wanted = int(rules.get("worldObject", {}).get("count", 1))
            obj.target_count = 1 if otype == "SLAY_MONSTER" else wanted
            if target_object is not None:
                obj.latitude, obj.longitude = target_object.latitude, target_object.longitude
                obj.radius_meters = 150.0 if otype == "SLAY_MONSTER" else 60.0
                obj.extra = {
                    "kind": target_object.kind,
                    "objectName": target_object.name,
                    **({"objectId": target_object.id} if otype != "COLLECT" else {}),
                }
        if spec.get("hidden"):
            # A puzzle: the app is told there is a target, never where it is,
            # until the ride is processed (`objective_out`).
            obj.extra = {**obj.extra, "hidden": True}
        objectives.append(obj)

    # A puzzle hides the whole place: a photo or note objective on the same POI
    # would otherwise pin on the map exactly what the riddle withholds.
    if poi is not None and any(o.extra.get("hidden") for o in objectives):
        for o in objectives:
            if o.discovery_id == poi.id:
                o.extra = {**o.extra, "hidden": True}

    distance_km = variables.get("distanceKm")
    if distance_km is None:
        distance_km = round(max(8.0, (farthest_m * 2.2) / 1000), 1)
    difficulty = _difficulty(distance_km, ctx, float(variables.get("elevationMeters", 0)))
    base_xp = _base_xp(difficulty, template)
    speed_kmh = ASSUMED_SPEED_KMH.get(ctx.activity, 15.0)
    duration = int(distance_km / speed_kmh * 60 + 10)
    narrative = rng.choice(template["narrative"])
    title = narrative["title"].format(**variables)
    description = narrative["description"].format(**variables)
    return GeneratedQuest(
        template_id=template["id"],
        quest_type=template["questType"],
        character_class=template["characterClass"],
        title=title,
        description=description,
        difficulty=difficulty,
        recommended_distance_km=float(distance_km),
        estimated_duration_minutes=duration,
        base_xp=base_xp,
        objectives=objectives,
        narrative={"hook": description, "completion": None, "source": "template"},
        seed=f"{template['id']}:{salt}",
        latitude=ctx.latitude,
        longitude=ctx.longitude,
        rewards={"xp": base_xp, "ac": quest_ac(difficulty), "items": [], "titles": []},
        variables=variables,
        activity=ctx.activity,
    )


def _same_targets(a: GeneratedQuest, b: GeneratedQuest) -> bool:
    ta = [(o.latitude, o.longitude, o.target_cells) for o in a.objectives]
    tb = [(o.latitude, o.longitude, o.target_cells) for o in b.objectives]
    return ta == tb


def _try_instantiate(template: dict[str, Any], ctx: GenerationContext, salt: int) -> GeneratedQuest | None:
    """One malformed template must not cost the rider every quest."""
    try:
        return instantiate(template, ctx, salt=salt)
    except Exception as exc:  # noqa: BLE001
        log.warning("quest_template_failed", template=template["id"], error=str(exc)[:200])
        return None


def generate(
    ctx: GenerationContext,
    count: int = 3,
    exclude_template_ids: set[str] | None = None,
    *,
    only_any: bool = False,
) -> list[GeneratedQuest]:
    """Produce up to `count` distinct quests, preferring templates the user has
    completed least recently and weighting by template weight.

    One of them is for anyone whenever such a template can be made here: a class
    shapes the quests, it does not own the whole board. `only_any` asks for the
    open quests alone (topping up a list that has none).
    """
    exclude = set(exclude_template_ids or ())
    candidates = [
        t
        for t in templates_for(ctx.character_class, ctx.class_level, ctx.unlocked_templates, activity=ctx.activity)
        if t["id"] not in exclude and (not only_any or t["characterClass"] == ANY_CLASS)
    ]
    if not candidates:
        return []
    recent = ctx.completed_template_ids[-6:]
    weights = [max(0.2, t.get("weight", 1) * (0.4 if t["id"] in recent else 1.0)) for t in candidates]
    rng = _rng(ctx, "selection", 0)
    generated: list[GeneratedQuest] = []
    attempts = 0
    pool = list(zip(candidates, weights, strict=True))
    while pool and len(generated) < count and attempts < 40:
        attempts += 1
        template = rng.choices([p[0] for p in pool], weights=[p[1] for p in pool], k=1)[0]
        quest = _try_instantiate(template, ctx, attempts)
        pool = [p for p in pool if p[0]["id"] != template["id"]]
        if quest is not None:
            generated.append(quest)
    # Second pass: sparse POI data can leave us short; re-roll region-based
    # templates with new salts so the player still gets `count` distinct quests.
    salt = 100
    while len(generated) < count and salt < 140:
        salt += 1
        template = rng.choice(candidates)
        quest = _try_instantiate(template, ctx, salt)
        if quest is None:
            continue
        if any(
            q.template_id == quest.template_id and q.title == quest.title and _same_targets(q, quest) for q in generated
        ):
            continue
        generated.append(quest)
    # One for anyone, if the class picks crowded it out and one can be made here.
    open_templates = [t for t in candidates if t["characterClass"] == ANY_CLASS]
    if open_templates and generated and not any(q.character_class == ANY_CLASS for q in generated):
        for salt in range(200, 220):
            quest = _try_instantiate(rng.choice(open_templates), ctx, salt)
            if quest is None:
                continue
            if len(generated) >= count:
                # The lightest class pick makes room; the list stays `count` long.
                lightest = min(
                    range(len(generated)),
                    key=lambda i: template_by_id()[generated[i].template_id].get("weight", 1),
                )
                generated.pop(lightest)
            generated.append(quest)
            break
    assert DIFFICULTIES
    return generated
