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
