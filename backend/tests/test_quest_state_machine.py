import pytest

from app.core.errors import InvalidTransition
from app.quests.state_machine import assert_transition, can_transition


def test_happy_path():
    for a, b in [("AVAILABLE", "ACCEPTED"), ("ACCEPTED", "ACTIVE"), ("ACTIVE", "COMPLETED")]:
        assert can_transition(a, b)


def test_never_available_to_completed():
    assert not can_transition("AVAILABLE", "COMPLETED")
    with pytest.raises(InvalidTransition):
        assert_transition("AVAILABLE", "COMPLETED")
    assert_transition("AVAILABLE", "COMPLETED", admin_override=True)


def test_terminal_states_are_final():
    for state in ("COMPLETED", "ABANDONED", "FAILED", "EXPIRED"):
        assert not any(can_transition(state, s) for s in ("AVAILABLE", "ACCEPTED", "ACTIVE", "COMPLETED"))
