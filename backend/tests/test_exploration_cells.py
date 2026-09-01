from app.exploration.cells import (
    cell_for,
    cells_in_radius,
    merge_state,
    reconcile_client_cells,
    state_for,
    traverse,
)


def _line(n=30, step=0.0015):
    return [(51.5 + i * step, -0.1) for i in range(n)]


def test_traverse_attributes_distance_to_cells():
    result = traverse(_line(), 9)
    assert len(result.cells) > 3
    assert abs(sum(c.distance_inside_m for c in result.cells.values()) - 29 * 0.0015 * 111_195) < 200


def test_bridges_gaps_in_trace():
    pts = [(51.5, -0.1), (51.52, -0.1)]  # ~2.2 km jump
    result = traverse(pts, 9)
    assert len(result.cells) >= 6


def test_state_rules():
    assert state_for(100, 400) == "VISITED"
    assert state_for(400, 400) == "EXPLORED"
    assert merge_state("EXPLORED", "VISITED") == "EXPLORED"
    assert merge_state("DISCOVERED", "VISITED") == "VISITED"
    assert merge_state(None, "DISCOVERED") == "DISCOVERED"


def test_client_cells_need_gps_support():
    trace = {cell_for(lat, lon, 9) for lat, lon in _line()}
    far = cell_for(52.0, 0.5, 9)
    near = next(iter(trace))
    accepted, rejected = reconcile_client_cells(trace, [near, far, "notacell"], 9)
    assert near in accepted and far not in accepted
    assert set(rejected) == {far, "notacell"}


def test_cells_in_radius():
    cells = cells_in_radius(51.5, -0.1, 800, 9)
    assert 15 <= len(cells) <= 40
