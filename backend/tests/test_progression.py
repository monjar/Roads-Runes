from app.progression.engine import (
    RideRewardInput,
    ability_points_between,
    apply_xp,
    compute_ride_xp,
    level_bounds,
    level_for_xp,
    load_xp_rules,
    max_level,
)


def test_levels_are_monotonic_and_config_driven():
    assert level_for_xp(0) == 1
    assert level_for_xp(249) == 1
    assert level_for_xp(250) == 2
    assert max_level() == 50
    floor, nxt = level_bounds(1)
    assert floor == 0 and nxt == 250
    assert level_bounds(50)[1] is None


def test_apply_xp_levels_up_and_grants_points():
    result = apply_xp(0, 0, 1, 1, 700)
    assert result.overall_level == 3
    assert result.class_level == 2  # 60% share = 420 class xp
    assert [lu.kind for lu in result.level_ups] == ["OVERALL", "CLASS"]
    assert result.ability_points_gained == ability_points_between(1, 2) == 1


def test_ride_xp_rewards_exploration_not_speed():
    slow_new = compute_ride_xp(
        RideRewardInput(
            "EXPLORER",
            new_cells=40,
            new_cells_explored=10,
            new_roads_meters=12000,
            distance_meters=25000,
        )
    )
    fast_repeat = compute_ride_xp(RideRewardInput("EXPLORER", new_cells=0, new_roads_meters=0, distance_meters=25000))
    assert sum(line.xp for line in slow_new) > 5 * max(1, sum(line.xp for line in fast_repeat))
    sources = {line.source for line in slow_new}
    assert "CLASS_BONUS" in sources and "NEW_AREA_EXPLORED" in sources
    assert not any("SPEED" in s for s in sources)


def test_ride_xp_is_capped():
    lines = compute_ride_xp(
        RideRewardInput(
            "EXPLORER",
            quest_completed=True,
            quest_difficulty="EPIC",
            quest_base_xp=900,
            new_cells=5000,
            new_roads_meters=300000,
            distance_meters=300000,
            elevation_gain_meters=9000,
        )
    )
    assert sum(line.xp for line in lines) <= load_xp_rules()["caps"]["perRideTotal"]


def test_a_ride_on_known_ground_is_still_worth_something():
    """Fifteen kilometres on roads already ridden, with no quest, used to earn nothing."""
    lines = compute_ride_xp(RideRewardInput(character_class="EXPLORER", distance_meters=15_000))
    assert [(line.source, line.xp) for line in lines] == [("KNOWN_GROUND", 30)]
    # New roads are not also known ground: only the rest of the ride counts here.
    mostly_new = compute_ride_xp(
        RideRewardInput(character_class="WARRIOR", distance_meters=15_000, new_roads_meters=14_500)
    )
    assert "KNOWN_GROUND" not in {line.source for line in mostly_new}
    # A kilometre on foot is more of an outing than one on a bike, and there is a ceiling.
    walk = compute_ride_xp(RideRewardInput(character_class="EXPLORER", distance_meters=5_000, activity="WALK"))
    assert [(line.source, line.xp) for line in walk] == [("KNOWN_GROUND", 50)]
    far = compute_ride_xp(RideRewardInput(character_class="WARRIOR", distance_meters=38_000))
    assert next(line.xp for line in far if line.source == "KNOWN_GROUND") == 60
    assert compute_ride_xp(RideRewardInput(character_class="EXPLORER", distance_meters=600)) == []
    # And it stays the lesser prize: a new kilometre pays ten times a known one.
    rules = load_xp_rules()
    assert rules["newRoadsPerKm"] >= 10 * rules["knownGround"]["perKm"]


def test_what_is_beaten_opened_and_found_is_worth_xp():
    lines = compute_ride_xp(
        RideRewardInput(
            character_class="WARRIOR",
            claims=[("CHEST", 2, False), ("CHEST", 1, False), ("COLLECTABLE", 1, False), ("MONSTER", 1, True)],
            sets_completed=1,
            story_arc_completed=True,
        )
    )
    by_source = {line.source: line for line in lines}
    assert by_source["CHEST_OPENED"].xp == 45 and by_source["CHEST_OPENED"].detail == {"count": 2}
    assert by_source["COLLECTABLE_FOUND"].xp == 8
    assert by_source["MONSTER_BEATEN"].xp == 75, "a bounty is worth half as much again"
    assert by_source["SET_COMPLETED"].xp == 150
    assert by_source["STORY_ARC_COMPLETED"].xp == 400
