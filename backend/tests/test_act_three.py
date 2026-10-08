"""Act III, "What Holds the Ground" (0.8.0): four chapters after Act II, and the two
objectives they bring, LAIR_VISIT and WOUND_BOSS."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

from app.lore.voice import violations
from app.quests import story
from app.quests.generator import WorldObjectCandidate, instantiate
from app.quests.models import QuestInstance, QuestObjective
from app.quests.templates import OBJECTIVE_TYPES, template_by_id
from app.rides.processing import evaluate_objectives
from app.rides.validation import CleanPoint
from tests.test_quest_generation import ctx

NOW = datetime.now(UTC)
LAIR = WorldObjectCandidate("lair-1", "LAIR", "The lair at Burgess Park", "Burgess Park", 51.48, -0.08)
LEGEND = WorldObjectCandidate("legend-1", "LEGEND", "The Fog Dragon", None, 51.51, -0.06)
TROLL = WorldObjectCandidate("troll", "MONSTER", "Fen Troll", "The Pond", 51.501, -0.05)
BOUNTY = WorldObjectCandidate("bounty", "MONSTER", "Grey Stag", "The Hill", 51.505, -0.04, bounty=True)


def test_act_three_is_four_chapters_after_act_two():
    arcs = [a for a in story.load_arcs() if a.get("act") == 3]
    assert [a["slug"] for a in arcs] == ["habits", "the-lair", "the-one-that-stayed", "double-pay"]
    assert [a["chapter"] for a in arcs] == [1, 2, 3, 4]
    assert arcs[0]["after"] == "the-cut-of-dagaz" and all(a["track"] == "MAIN" for a in arcs)
    assert len(arcs[0]["quests"]) == 2
    assert [q["templateId"] for a in arcs[1:] for q in a["quests"]] == [
        "ANY_LAIR_VISIT",
        "ANY_WOUND_BOSS",
        "ANY_DOUBLE_PAY",
    ]
    assert story.acts()[2] == {**story.acts()[2], "id": 3, "title": "What Holds the Ground"}
    assert arcs[-1]["reward"]["title"] == "Holds the Ground"
    for arc in arcs:
        for text in [arc["title"], arc["description"], *(q["completion"] for q in arc["quests"])]:
            assert not violations(text, celebration=True), text
        for step in arc["quests"]:
            assert len(step["slug"]) <= 64 and len(step["templateId"]) <= 64
    assert {"LAIR_VISIT", "WOUND_BOSS"} <= set(OBJECTIVE_TYPES)


def test_the_lair_step_points_at_the_lair_or_waits_for_one():
    template = template_by_id()["ANY_LAIR_VISIT"]
    assert instantiate(template, ctx(world_objects=[TROLL])) is None
    quest = instantiate(template, ctx(world_objects=[TROLL, LAIR]))
    objective = quest.objectives[0]
    assert objective.objective_type == "LAIR_VISIT" and objective.target_count == 5
    assert objective.extra["objectId"] == "lair-1" and (objective.latitude, objective.longitude) == (51.48, -0.08)
    assert objective.title == "Visit 5 of the 7 tiles of the lair at Burgess Park"


def test_the_legend_step_needs_a_legend_awake():
    template = template_by_id()["ANY_WOUND_BOSS"]
    assert instantiate(template, ctx()) is None
    quest = instantiate(template, ctx(legend=LEGEND))
    objective = quest.objectives[0]
    assert objective.objective_type == "WOUND_BOSS" and objective.progress_target == 300
    assert objective.title == "Do 300 damage to The Fog Dragon on one journey"
    assert objective.extra["legendId"] == "legend-1"


def test_double_pay_is_only_ever_the_bounty():
    template = template_by_id()["ANY_DOUBLE_PAY"]
    assert instantiate(template, ctx(world_objects=[TROLL])) is None
    for salt in range(5):
        quest = instantiate(template, ctx(world_objects=[TROLL, BOUNTY]), salt=salt)
        assert quest.objectives[0].extra["objectId"] == "bounty"


def objective(kind: str, target: float) -> QuestObjective:
    return QuestObjective(
        id=uuid.uuid4(), quest_id=uuid.uuid4(), objective_type=kind, title=kind, required=True, order=1,
        status="PENDING", progress_current=0, progress_target=target, provisional=False, completion_rule="AUTO",
        extra={},
    )  # fmt: skip


def judge(o: QuestObjective, **outcome) -> bool:
    quest = QuestInstance(id=uuid.uuid4(), objectives=[o])
    points = [CleanPoint(51.5, -0.05, NOW), CleanPoint(51.501, -0.05, NOW)]
    done = evaluate_objectives(
        quest, points, distance_m=0, duration_s=0, elevation_gain_m=0, new_roads_m=0, new_cells=set(), resolution=9,
        client_events=[], **outcome,
    )  # fmt: skip
    return o in done


def test_a_lair_visit_is_done_when_its_great_chest_opens():
    o = objective("LAIR_VISIT", 5)
    assert not judge(o) and o.progress_current == 0
    assert not judge(o, lair={"visited": 3, "need": 5, "done": False}) and o.progress_current == 3
    assert judge(o, lair={"visited": 5, "need": 5, "done": True}) and o.status == "COMPLETED"


def test_wounding_the_legend_counts_one_journey_at_a_time():
    o = objective("WOUND_BOSS", 300)
    assert not judge(o, legend={"damage": 120}) and o.progress_current == 120
    assert not judge(o, legend=None)
    assert judge(o, legend={"damage": 300}) and o.status == "COMPLETED"
