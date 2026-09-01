from app.quests.generator import GenerationContext, POICandidate, generate
from app.quests.templates import all_templates, templates_for


def ctx(**overrides):
    base = dict(
        latitude=51.5,
        longitude=-0.05,
        character_class="EXPLORER",
        overall_level=3,
        class_level=3,
        comfortable_distance_km=30,
        comfortable_elevation_gain=300,
        gravel_comfort=0.6,
        bike_allows_gravel=True,
        bike_allows_trails=True,
        explored_cells=set(),
        visited_cells=set(),
        completed_template_ids=[],
        pois=[POICandidate("p1", "Greenwich Park", "NATURE", 51.477, 0.0, {"natural": "water"})],
        seed="seed",
    )
    base.update(overrides)
    return GenerationContext(**base)


def test_explorer_has_enough_templates():
    assert len([t for t in all_templates() if t["characterClass"] == "EXPLORER"]) >= 10
    assert templates_for("EXPLORER", 1) and not [t for t in templates_for("EXPLORER", 1) if t["minLevel"] > 1]


def test_generation_is_deterministic_and_distinct():
    a = generate(ctx(), 3)
    b = generate(ctx(), 3)
    assert [q.template_id for q in a] == [q.template_id for q in b]
    assert len({q.template_id for q in a}) == len(a) == 3
    for q in a:
        assert q.base_xp > 0 and q.objectives and q.difficulty in ("EASY", "MODERATE", "HARD", "EPIC")
        assert all(o.order >= 1 for o in q.objectives)


def test_poi_quests_require_matching_pois_and_bike():
    from app.quests.generator import instantiate
    from app.quests.templates import template_by_id

    assert instantiate(template_by_id()["EXPLORER_UNVISITED_PARK"], ctx(pois=[])) is None
    trail = template_by_id()["EXPLORER_TRAIL"]
    assert (
        instantiate(
            trail,
            ctx(
                pois=[POICandidate("t", "Ridge Trail", "TRAIL", 51.52, -0.05)],
                bike_allows_gravel=False,
                bike_allows_trails=False,
            ),
        )
        is None
    )
    q = instantiate(template_by_id()["EXPLORER_UNVISITED_PARK"], ctx())
    assert (
        q is not None
        and q.objectives[0].discovery_id == "p1"
        and "Greenwich Park" in q.title + q.description + q.objectives[0].title
    )


def test_difficulty_scales_with_rider_profile():
    from app.quests.generator import instantiate
    from app.quests.templates import template_by_id

    t = template_by_id()["EXPLORER_FAR_WANDER"]
    strong = instantiate(t, ctx(class_level=10, comfortable_distance_km=120))
    weak = instantiate(t, ctx(class_level=10, comfortable_distance_km=15))
    assert strong is not None and weak is not None
    order = ["EASY", "MODERATE", "HARD", "EPIC"]
    assert order.index(strong.difficulty) <= order.index(weak.difficulty)
