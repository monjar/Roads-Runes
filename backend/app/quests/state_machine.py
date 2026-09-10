"""Quest instance state machine (spec §19)."""

from __future__ import annotations

from app.core.errors import InvalidTransition

QUEST_STATES = ("AVAILABLE", "ACCEPTED", "ACTIVE", "COMPLETED", "ABANDONED", "FAILED", "EXPIRED")

TRANSITIONS: dict[str, set[str]] = {
    "AVAILABLE": {"ACCEPTED", "EXPIRED"},
    "ACCEPTED": {"ACTIVE", "ABANDONED", "EXPIRED"},
    "ACTIVE": {"COMPLETED", "ABANDONED", "FAILED"},
    "COMPLETED": set(),
    "ABANDONED": set(),
    "FAILED": set(),
    "EXPIRED": set(),
}

TERMINAL_STATES = {"COMPLETED", "ABANDONED", "FAILED", "EXPIRED"}


def can_transition(current: str, new: str) -> bool:
    return new in TRANSITIONS.get(current, set())


def assert_transition(current: str, new: str, *, admin_override: bool = False) -> None:
    if admin_override and new in QUEST_STATES:
        return
    if not can_transition(current, new):
        raise InvalidTransition(f"Quest cannot move from {current} to {new}", details={"from": current, "to": new})
