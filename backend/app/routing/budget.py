"""How many engine requests one plan may make, and whose requests wait (0.9.2).

The hosted backend routes on the public Valhalla server, which asks for about one
request a second. A plan of three cards used to cost six requests whatever came
back; with loops, alternates and second attempts it could cost far more. So each
plan carries a budget, charged per HTTP attempt by the engine clients:

* The first card is never refused: it is asked for whatever the budget says.
* Everything optional (another card, a second attempt, a retry of the surface
  details) checks what is left first.

Nothing here talks to an engine. A request made outside any plan (a reroute, a
legend's reach test) is not counted.

`background()` marks the quest board's prefetch, so a rider waiting on the planner
goes ahead of routes nobody is looking at yet (`valhalla.Pacer`).
"""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass

# Typically five to seven for three cards; ten is about twelve seconds at the public
# server's pace, well inside the phone's 150 s.
PLAN_CALLS = 10


@dataclass
class CallBudget:
    cap: int
    used: int = 0

    @property
    def left(self) -> int:
        return max(0, self.cap - self.used)

    def allows(self, calls: int = 1) -> bool:
        return self.used + calls <= self.cap


_budget: ContextVar[CallBudget | None] = ContextVar("routing_budget", default=None)
_background: ContextVar[bool] = ContextVar("routing_background", default=False)


@contextmanager
def plan_budget(cap: int = PLAN_CALLS) -> Iterator[CallBudget]:
    """A fresh budget for the requests made inside this block."""
    budget = CallBudget(cap)
    token = _budget.set(budget)
    try:
        yield budget
    finally:
        _budget.reset(token)


def current() -> CallBudget | None:
    return _budget.get()


def charge(calls: int = 1) -> None:
    """One HTTP attempt made (a retry is another)."""
    budget = _budget.get()
    if budget is not None:
        budget.used += calls


def allows(calls: int = 1) -> bool:
    """Whether `calls` more requests fit. True outside any plan."""
    budget = _budget.get()
    return budget is None or budget.allows(calls)


def used() -> int:
    budget = _budget.get()
    return budget.used if budget is not None else 0


def left() -> int | None:
    budget = _budget.get()
    return budget.left if budget is not None else None


@contextmanager
def background() -> Iterator[None]:
    """Requests made inside this block wait for any a rider is waiting on."""
    token = _background.set(True)
    try:
        yield
    finally:
        _background.reset(token)


def in_background() -> bool:
    return _background.get()
