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

# Why a quest in this state cannot do what was asked, and what to do instead.
REFUSALS = {
    "AVAILABLE": "This quest is still on the quest board. Accept it first.",
    "ACCEPTED": "This quest hasn't started yet. Start it on your next journey.",
    "ACTIVE": "This quest is already under way. Finish it on your journey.",
    "COMPLETED": "This quest is already done. Pick a new one from the quest board.",
    "ABANDONED": "You gave up this quest. Pick a new one from the quest board.",
    "FAILED": "This quest is over. Pick a new one from the quest board.",
    "EXPIRED": "This quest ran out of time. Pick a new one from the quest board.",
}


def can_transition(current: str, new: str) -> bool:
    return new in TRANSITIONS.get(current, set())


def assert_transition(current: str, new: str, *, admin_override: bool = False) -> None:
    if admin_override and new in QUEST_STATES:
        return
    if not can_transition(current, new):
        raise InvalidTransition(
            REFUSALS.get(current, "This quest can't do that now. Check the quest board."),
            details={"from": current, "to": new},
        )
