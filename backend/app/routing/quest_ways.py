"""The ways a quest can be ridden (2026-10-19).

A quest had one route, a loop, and "Adjust route" in the planner asked for a loop
again. Now the quest's page offers its ways, each planned once from the quest's
origin and kept while the rider stays about there:

* **Loop** — the quest's own route (`service.quest_route`), out and home another way.
* **One way** — through the objectives, nearest first, ending at the furthest. Not
  when coming home is required, nor when the quest has nowhere to end.
* **Quiet roads** — the loop on the quietest costing.
* **New ground** — the loop bent towards cells the rider has never been.
* **The long way** — a wider loop, about 1.5× the quest's distance, on the other side.

A way that comes back as the same road as one already offered is left out and said
so (`shapes.duplicate_of`); so is one shorter than the distance the quest demands.
The rider picks one (`choose`) and it becomes the quest's route: the board's
distance, the Watch's "Start quest" and the planner all follow it. The long way
and new ground carry a small bonus, paid only when the journey did what the way
promised (`bonus_earned`).
"""

from __future__ import annotations

import json
import uuid
from functools import lru_cache
from pathlib import Path
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.core.errors import Conflict, NotFound, RouteGenerationFailed
from app.core.geo import haversine_m
from app.core.llm import LLMClient
from app.core.logging import get_logger
from app.core.schemas import Coordinate
from app.quests.models import QuestInstance
from app.quests.sealed import TEMPLATE_ID as SEALED
from app.rides.models import Ride
from app.routing import budget, shapes
from app.routing import service as routing
from app.routing.engine import RoutingEngine, RoutingUnavailable
from app.routing.models import Route
from app.routing.schemas import RouteGenerateRequest
from app.users.models import User

log = get_logger(__name__)

# Engine requests one way may make: the first is never refused, then a retry or two
# and its details. Four ways on the public server is then at most about 20 s.
WAY_CALLS = 5
# Ways planned from further than this from the quest's origin are another place's.
REUSE_M = 150.0
# One way rides about this much further than the straight lines through its points.
ONE_WAY_DETOUR = 1.25
# New ground is offered only when the loop leaves this much to find, and only when
# it finds more than the loop by this share of its length.
NEW_GROUND_LOOP_MAX = 0.9
NEW_GROUND_GAIN = 0.05
ALL_NEW = "New ground would add nothing: the loop is all new to you already"
OPEN = ("AVAILABLE", "ACCEPTED", "ACTIVE")


@lru_cache(maxsize=1)
def config() -> dict[str, Any]:
    return json.loads((Path(__file__).parents[1] / "quests" / "config" / "ways.json").read_text())


def way_of(route: Route | None) -> str | None:
    return (route.request or {}).get("questWay") if route is not None else None


def _name(kind: str) -> str:
    return config()["names"][kind]


def _bonus(kind: str) -> dict[str, Any] | None:
    found = config()["bonus"].get(kind)
    return {"xp": found["xp"], "ac": found["ac"], "condition": found["condition"]} if found else None


def _summary(kind: str, quest: QuestInstance) -> str:
    words = config()["summaries"]
    targets = routing._quest_targets(quest).points
    if kind == shapes.WAY_LOOP and not targets:
        return words["LOOP_ROUND"]
    if kind == shapes.WAY_ONE_WAY:
        place = _last_place(quest)
        return words["ONE_WAY"].format(place=place) if place else words["ONE_WAY_PLAIN"]
    return words[kind]


def _last_place(quest: QuestInstance) -> str | None:
    """The name of the objective one way ends at, when it has one and it is not hidden."""
    here = (quest.latitude, quest.longitude)
    placed = [
        o
        for o in quest.objectives
        if o.latitude is not None and o.status != "COMPLETED" and o.objective_type != "RETURN_TO_START"
    ]
    if not placed:
        return None
    last = max(placed, key=lambda o: haversine_m(*here, o.latitude, o.longitude))
    extra = last.extra or {}
    if extra.get("hidden"):
        return None
    return extra.get("poiName") or extra.get("objectName")


def _from_here(route: Route, quest: QuestInstance) -> bool:
    origin = (route.request or {}).get("wayFrom")
    return bool(origin) and haversine_m(origin[0], origin[1], quest.latitude, quest.longitude) <= REUSE_M


def _tag(route: Route, kind: str, quest: QuestInstance) -> None:
    route.label = _name(kind)
    route.request = {**(route.request or {}), "questWay": kind, "wayFrom": [quest.latitude, quest.longitude]}


async def _stored(db: AsyncSession, quest: QuestInstance) -> dict[str, Route]:
    """The ways already planned from where the quest is now, newest of each kind."""
    rows = (
        await db.execute(select(Route).where(Route.quest_id == quest.id).order_by(Route.created_at.desc()).limit(60))
    ).scalars()
    found: dict[str, Route] = {}
    for route in rows:
        kind = way_of(route)
        if kind in shapes.WAYS and kind not in found and _from_here(route, quest):
            found[kind] = route
    return found


def _not_offered(kind: str, quest: QuestInstance) -> str | None:
    """Why a quest has no such way, said to the rider; None when it has."""
    targets = routing._quest_targets(quest)
    if kind != shapes.WAY_ONE_WAY:
        return None
    if any(o.objective_type == "RETURN_TO_START" and o.required for o in quest.objectives):
        return "No one way here: this quest asks you to come home"
    here = (quest.latitude, quest.longitude)
    if not any(haversine_m(*here, lat, lon) > routing.QUEST_LOOP_MIN_M for lat, lon, _ in targets.points):
        return "No one way here: this quest has no place to end at"
    return None


def _one_way_km(quest: QuestInstance) -> float:
    here = (quest.latitude, quest.longitude)
    points = sorted(
        ((lat, lon) for lat, lon, _ in routing._quest_targets(quest).points), key=lambda p: haversine_m(*here, *p)
    )
    legs = [here, *points]
    return sum(haversine_m(*a, *b) for a, b in zip(legs, legs[1:], strict=False)) / 1000 * ONE_WAY_DETOUR


async def _plan(
    db: AsyncSession,
    settings: Settings,
    engine: RoutingEngine,
    llm: LLMClient,
    user: User,
    quest: QuestInstance,
    kind: str,
    loop_km: float,
) -> Route | None:
    """One way, planned from the quest's origin; None when the engine has none."""
    if kind == shapes.WAY_ONE_WAY:
        km, loop = _one_way_km(quest), False
    elif kind == shapes.WAY_LONG:
        km, loop = loop_km * shapes.LONG_WAY_SCALE, True
    else:
        km, loop = loop_km, True
    payload = RouteGenerateRequest(
        origin=Coordinate(latitude=quest.latitude, longitude=quest.longitude),
        questId=quest.id,
        distanceTargetKm=min(400.0, max(1.0, km)),
        loop=loop,
        activity=quest.activity,  # type: ignore[arg-type]
    )
    shared_engine = settings.routing_engine == "valhalla"
    try:
        with budget.background():
            results, _ = await routing.generate(
                db,
                settings,
                engine,
                llm,
                user,
                payload,
                max_variants=1,
                details=not shared_engine,
                way=kind,
                calls=WAY_CALLS,
            )
    except (RouteGenerationFailed, RoutingUnavailable) as exc:
        log.warning("quest_way_unavailable", quest_id=str(quest.id), way=kind, error=str(exc)[:200])
        return None
    route = results[0][0]
    _tag(route, kind, quest)
    return route


async def quest_ways(
    db: AsyncSession,
    settings: Settings,
    engine: RoutingEngine,
    llm: LLMClient,
    user: User,
    quest_id: uuid.UUID,
    origin: Coordinate | None = None,
) -> dict[str, Any]:
    """The quest's ways from where the rider is, the chosen one marked, and why any
    is missing. The loop comes first: it is the quest's own route."""
    chosen, _ = await routing.quest_route(db, settings, engine, llm, user, quest_id, origin)
    quest = await db.get(QuestInstance, quest_id)
    assert quest is not None
    if way_of(chosen) is None:
        # The quest's own route, planned before it had ways, or just now: the loop.
        _tag(chosen, shapes.WAY_LOOP, quest)
    if quest.template_id == SEALED or quest.party_id is not None:
        # The board picked a sealed quest's way; a party rides the leader's.
        note = "The board picked this way" if quest.template_id == SEALED else "Your party rides one way together"
        return _out(quest, [(way_of(chosen) or shapes.WAY_LOOP, chosen)], [note])

    stored = await _stored(db, quest)
    stored[way_of(chosen) or shapes.WAY_LOOP] = chosen
    loop = stored.get(shapes.WAY_LOOP)
    loop_km = loop.distance_meters / 1000 if loop is not None else quest.recommended_distance_km
    must = routing._must_cover_m(quest)
    kept: list[tuple[str, Route]] = []
    notes: list[str] = []
    loop_new = loop.new_territory_fraction if loop is not None else 0.0
    for kind in shapes.WAYS:
        why = _not_offered(kind, quest)
        if kind == shapes.WAY_NEW_GROUND and loop_new >= NEW_GROUND_LOOP_MAX and kind not in stored:
            # Nothing the loop does not already find: no request spent on looking.
            why = ALL_NEW
        if why:
            notes.append(why)
            continue
        route = stored.get(kind) or await _plan(db, settings, engine, llm, user, quest, kind, loop_km)
        if route is None:
            continue
        if (
            kind == shapes.WAY_NEW_GROUND
            and route.new_territory_fraction < loop_new + NEW_GROUND_GAIN
            and route.id != chosen.id
        ):
            notes.append(ALL_NEW if loop_new >= NEW_GROUND_LOOP_MAX else "New ground finds no more than the loop here")
            continue
        if must and route.distance_meters < must * 0.98 and route.id != chosen.id:
            notes.append(f"{_name(kind)} is too short for this quest's distance")
            continue
        same = shapes.duplicate_of(
            route.coordinates, route.distance_meters, [(k, r.coordinates, r.distance_meters) for k, r in kept]
        )
        if same is not None and route.id != chosen.id:
            notes.append(f"{_name(kind)} would be the {_name(same[0]).lower()} again here")
            continue
        kept.append((kind, route))
    await db.flush()
    return _out(quest, kept, notes)


def _out(quest: QuestInstance, kept: list[tuple[str, Route]], notes: list[str]) -> dict[str, Any]:
    return {
        "ways": [
            {
                "kind": kind,
                "name": _name(kind),
                "summary": _summary(kind, quest),
                "bonus": _bonus(kind),
                "route": routing.route_out(route),
            }
            for kind, route in kept
        ],
        "chosenRouteId": quest.suggested_route_id,
        "notes": notes,
    }


async def choose(db: AsyncSession, user: User, quest_id: uuid.UUID, route_id: uuid.UUID) -> QuestInstance:
    """One of the quest's ways becomes its route."""
    quest = await db.get(QuestInstance, quest_id)
    if quest is None or quest.user_id != user.id:
        raise NotFound("We couldn't find that quest. It may have ended, so check the quest board.")
    if quest.template_id == SEALED:
        raise Conflict("The board picked this quest's way. It can't be changed.", code="QUEST_SEALED")
    if quest.status not in OPEN:
        raise Conflict("This quest has ended, so its way can't be changed.", code="QUEST_INVALID_TRANSITION")
    route = await db.get(Route, route_id)
    if route is None or route.quest_id != quest.id or way_of(route) is None:
        raise NotFound("That isn't one of this quest's ways. Open the quest again to see them.")
    quest.suggested_route_id = route.id
    routing.settle_quest_distance(quest, route)
    await db.flush()
    return quest


async def bonus_earned(
    db: AsyncSession, ride: Ride, quest: QuestInstance | None, new_roads_m: float
) -> dict[str, Any] | None:
    """The way's bonus, when the finished quest was ridden on a way that has one and
    the journey did what it promised: {kind, name, xp, ac}, else None."""
    if quest is None or ride.route_id is None:
        return None
    route = await db.get(Route, ride.route_id)
    kind = way_of(route)
    rule = config()["bonus"].get(kind or "")
    if route is None or route.quest_id != quest.id or rule is None:
        return None
    if kind == shapes.WAY_LONG and ride.distance_meters < rule["shareOfRoute"] * route.distance_meters:
        return None
    if kind == shapes.WAY_NEW_GROUND and new_roads_m < rule["minNewRoadsM"]:
        return None
    return {"kind": kind, "name": _name(kind or ""), "xp": int(rule["xp"]), "ac": int(rule["ac"])}
