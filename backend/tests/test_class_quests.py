"""Wizard puzzles, Warrior effort and Scribe records: the class quest mechanics."""

from __future__ import annotations

import uuid

from app.quests import generator
from app.quests.generator import GenerationContext, POICandidate
from app.quests.models import QuestObjective
from app.quests.service import objective_out
from app.quests.templates import all_templates, templates_for
from app.rides.processing import evaluate_objectives

CATEGORIES = ("VIEWPOINT", "HISTORICAL", "CULTURAL", "NATURE", "CAFE", "LANDMARK", "PUB", "CYCLING")


def context(character_class: str, class_level: int = 5) -> GenerationContext:
    """A rider in a place with plenty of everything, so any template can be rolled."""
    pois = []
    for i, category in enumerate(CATEGORIES * 3):
        pois.append(
            POICandidate(
                str(uuid.uuid4()),
                f"{category.title()} {i}",
                category,
                51.50 + 0.01 * (i % 9),
                -0.10 + 0.01 * (i % 7),
                {"tourism": "viewpoint", "water": "river"} if i % 2 else {"historic": "castle"},
                None,
            )
        )
    return GenerationContext(
        latitude=51.49,
        longitude=-0.06,
        character_class=character_class,
        overall_level=class_level,
        class_level=class_level,
        comfortable_distance_km=30,
        comfortable_elevation_gain=400,
        gravel_comfort=0.5,
        bike_allows_gravel=True,
        bike_allows_trails=True,
        explored_cells=set(),
        visited_cells=set(),
        completed_template_ids=[],
        pois=pois,
        unlocked_templates=set(),
        resolution=9,
        seed="test:2026-09-12",
        requested_distance_km=None,
        poi_visibility_bonus=0.0,
    )


def test_every_class_has_quests_and_every_template_renders():
    for character_class in ("EXPLORER", "WIZARD", "WARRIOR", "SCRIBE"):
        templates = templates_for(character_class, class_level=5)
        assert len(templates) >= 5, f"{character_class} has only {len(templates)} templates"
        ctx = context(character_class)
        for template in templates:
            quest = generator.instantiate(template, ctx, salt=3)
            if quest is None:
                continue  # needs geography this rider does not have; acceptable
            texts = [quest.title, quest.description] + [o.title for o in quest.objectives]
            assert not any("{" in t for t in texts), f"{template['id']} left a placeholder in {texts}"


def test_warrior_quests_ask_for_pace_and_time():
    ctx = context("WARRIOR")
    tempo = generator.instantiate(next(t for t in all_templates() if t["id"] == "WARRIOR_STEADY_TEMPO"), ctx, salt=1)
    speed = next(o for o in tempo.objectives if o.objective_type == "SUSTAIN_SPEED")
    assert 15 <= speed.progress_target <= 30
    assert speed.extra["minDistanceMeters"] > 0  # a fast two kilometres does not count

    hour = generator.instantiate(next(t for t in all_templates() if t["id"] == "WARRIOR_HOUR_OF_IRON"), ctx, salt=1)
    duration = next(o for o in hour.objectives if o.objective_type == "RIDE_DURATION")
    assert duration.progress_target >= 30


def test_wizard_puzzle_keeps_its_place_secret_until_it_is_done():
    ctx = context("WIZARD")
    quest = generator.instantiate(next(t for t in all_templates() if t["id"] == "WIZARD_RIDDLE_VIEWPOINT"), ctx, salt=1)
    hidden = quest.objectives[0]
    assert hidden.extra.get("hidden") is True
    assert hidden.latitude is not None  # the server still knows, so the route leads there
    # Nothing else in the quest may give the place away.
    assert all(o.extra.get("hidden") for o in quest.objectives if o.discovery_id)

    row = QuestObjective(
        objective_type=hidden.objective_type,
        title=hidden.title,
        latitude=hidden.latitude,
        longitude=hidden.longitude,
        radius_meters=hidden.radius_meters,
        required=True,
        order=1,
        status="PENDING",
        completion_rule="AUTOMATIC",
        provisional=False,
        extra=hidden.extra,
        progress_current=0.0,
        progress_target=1.0,
    )
    row.id = uuid.uuid4()
    assert objective_out(row).latitude is None
    row.status = "COMPLETED"
    assert objective_out(row).latitude == hidden.latitude


def test_scribe_quests_ask_for_a_photograph_and_a_note():
    ctx = context("SCRIBE")
    kinds = set()
    for template in templates_for("SCRIBE", class_level=5):
        quest = generator.instantiate(template, ctx, salt=2)
        if quest is not None:
            kinds |= {o.objective_type for o in quest.objectives}
    assert {"PHOTO_LOCATION", "WRITE_NOTE"} <= kinds


def _objective(objective_type: str, target: float, extra: dict | None = None) -> QuestObjective:
    o = QuestObjective(
        objective_type=objective_type,
        title=objective_type,
        required=True,
        order=1,
        status="PENDING",
        completion_rule="AUTOMATIC",
        provisional=False,
        extra=extra or {},
        progress_current=0.0,
        progress_target=target,
    )
    o.id = uuid.uuid4()
    return o


class FakeQuest:
    def __init__(self, objectives):
        self.objectives = objectives


def test_pace_and_time_are_judged_over_the_whole_ride():
    speed = _objective("SUSTAIN_SPEED", 20.0, {"minDistanceMeters": 10_000})
    minutes = _objective("RIDE_DURATION", 60.0)
    quest = FakeQuest([speed, minutes])

    # 24 km in an hour: fast enough and long enough.
    evaluate_objectives(
        quest, [], distance_m=24_000, duration_s=3600, elevation_gain_m=0, new_roads_m=0,
        new_cells=set(), resolution=9, client_events=[],
    )  # fmt: skip
    assert speed.status == "COMPLETED"
    assert minutes.status == "COMPLETED"

    # Same pace, but a short spin: the distance floor keeps it honest.
    short = _objective("SUSTAIN_SPEED", 20.0, {"minDistanceMeters": 10_000})
    evaluate_objectives(
        FakeQuest([short]), [], distance_m=4_000, duration_s=600, elevation_gain_m=0, new_roads_m=0,
        new_cells=set(), resolution=9, client_events=[],
    )  # fmt: skip
    assert short.status != "COMPLETED"
    assert short.progress_current == 20.0 or short.progress_current > 0


def test_the_ley_line_is_a_line():
    """Three points on one bearing, nearest first, and a ride the length of going
    out along them and back. Picked one random bearing at a time they made a
    triangle across the city: 51.6 km for a quest whose title promised a line."""
    from app.core.geo import bearing_deg, haversine_m
    from app.quests.templates import template_by_id

    for seed in range(6):
        ctx = context("WIZARD")
        ctx.seed = f"ley:{seed}"
        quest = generator.instantiate(template_by_id()["WIZARD_LEY_LINE"], ctx)
        assert quest is not None, seed
        points = [(c["latitude"], c["longitude"]) for c in quest.objectives[0].extra["cells"]]
        assert len(points) == 3
        bearings = [bearing_deg(ctx.latitude, ctx.longitude, lat, lon) for lat, lon in points]
        for bearing in bearings[1:]:
            off = (bearing - bearings[0] + 180) % 360 - 180
            assert abs(off) <= 6, f"seed {seed}: bearings {bearings}"
        distances = [haversine_m(ctx.latitude, ctx.longitude, lat, lon) for lat, lon in points]
        assert distances == sorted(distances), distances
        # The range is scaled to the rider (30 km is a comfortable day here), so the far point can pass 11 km.
        assert 3_000 <= distances[0] and distances[-1] <= 15_000, distances
        # Out along the line and back, with room for roads: not a lap of the city.
        assert quest.recommended_distance_km <= distances[-1] / 1000 * 2.3, quest.recommended_distance_km
