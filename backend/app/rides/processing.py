"""Post-ride processing job (spec §15, §35, §40, §66).

Steps: validate points → recompute metrics → exploration cells → discoveries →
objective validation → quest completion → XP via the reward service → summary.
Runs in a background job; the API only enqueues it.
"""

from __future__ import annotations

import uuid
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.characters.models import Character
from app.core.config import Settings
from app.core.errors import InvalidTransition, NotFound, RideInvalidState
from app.core.geo import encode_polyline, haversine_m
from app.core.logging import EVENT_EXPLORATION_VALIDATION_FAILED, get_logger
from app.core.security import utcnow
from app.discoveries.models import Discovery
from app.discoveries.service import discoveries_along, mark_found
from app.exploration.cells import cell_for, traverse
from app.exploration.service import ExplorationOutcome, record_traversal
from app.progression.engine import RideRewardInput, compute_ride_xp
from app.progression.service import grant
from app.quests.models import QuestInstance, QuestObjective
from app.quests.service import all_required_complete, completion_payload, quest_out
from app.quests.state_machine import assert_transition
from app.rides.models import Ride, RidePoint, RideRoute
from app.rides.validation import CleanPoint, check_cell_plausibility, validate_points
from app.social.service import publish
from app.users.models import User

log = get_logger(__name__)


def _simplify(points: list[CleanPoint], max_points: int = 1500) -> list[list[float]]:
    if len(points) <= max_points:
        return [[p.longitude, p.latitude] for p in points]
    step = len(points) / max_points
    return [[points[int(i * step)].longitude, points[int(i * step)].latitude] for i in range(max_points)] + [
        [points[-1].longitude, points[-1].latitude]
    ]


def evaluate_objectives(
    quest: QuestInstance,
    points: list[CleanPoint],
    *,
    distance_m: float,
    elevation_gain_m: float,
    new_roads_m: float,
    new_cells: set[str],
    resolution: int,
    client_events: list[dict[str, Any]],
) -> list[QuestObjective]:
    """Server-authoritative objective evaluation against the GPS trace."""
    completed: list[QuestObjective] = []
    coords = [(p.latitude, p.longitude) for p in points]
    start = coords[0] if coords else None
    trace_cells = {cell_for(lat, lon, resolution) for lat, lon in coords[::2]} if coords else set()
    client_by_objective = {str(e.get("objectiveId")): e for e in client_events}

    def visited_within(lat: float, lon: float, radius: float) -> bool:
        return any(haversine_m(lat, lon, plat, plon) <= radius for plat, plon in coords)

    for o in quest.objectives:
        if o.status == "COMPLETED" and not o.provisional:
            continue
        done = False
        t = o.objective_type
        if t in ("VISIT_LOCATION", "VISIT_POI", "VISIT_REGION"):
            if o.target_cells:
                done = any(c in trace_cells for c in o.target_cells)
            elif o.latitude is not None and o.longitude is not None:
                done = visited_within(o.latitude, o.longitude, (o.radius_meters or 60) * 1.25)
            o.progress_current = 1.0 if done else 0.0
        elif t == "VISIT_MULTIPLE_LOCATIONS":
            cells = o.target_cells or []
            hits = sum(1 for c in cells if c in trace_cells)
            if not cells and o.extra.get("cells"):
                hits = sum(
                    1
                    for c in o.extra["cells"]
                    if visited_within(float(c["latitude"]), float(c["longitude"]), o.radius_meters or 250)
                )
            o.progress_current = float(hits)
            done = hits >= (o.target_count or len(cells) or 1)
        elif t == "EXPLORE_NEW_ROADS":
            o.progress_current = min(o.progress_target, new_roads_m)
            done = new_roads_m >= (o.target_meters or 0)
        elif t == "EXPLORE_DISTANCE":
            o.progress_current = min(o.progress_target, new_roads_m)
            done = new_roads_m >= (o.target_meters or 0)
        elif t == "COMPLETE_DISTANCE":
            o.progress_current = min(o.progress_target, distance_m)
            done = distance_m >= (o.target_meters or 0)
        elif t in ("REACH_ELEVATION", "COMPLETE_CLIMB"):
            o.progress_current = min(o.progress_target, elevation_gain_m)
            done = elevation_gain_m >= (o.target_elevation_meters or 0)
        elif t == "RETURN_TO_START":
            if start and coords:
                end = coords[-1]
                done = haversine_m(start[0], start[1], end[0], end[1]) <= (o.radius_meters or 300) and distance_m > 1000
            o.progress_current = 1.0 if done else 0.0
        elif t in ("PHOTO_LOCATION", "WRITE_NOTE"):
            # Requires explicit user action; accept the client event if position matches.
            ev = client_by_objective.get(str(o.id))
            if ev is not None:
                if o.latitude is None or ev.get("latitude") is None:
                    done = True
                else:
                    done = (
                        haversine_m(o.latitude, o.longitude, float(ev["latitude"]), float(ev["longitude"]))
                        <= (o.radius_meters or 120) * 1.5
                    )
            o.progress_current = 1.0 if done else 0.0
        elif t == "COMPLETE_ROUTE":
            done = distance_m >= (o.target_meters or 0) * 0.9
            o.progress_current = min(o.progress_target, distance_m)
        elif t == "COMPLETE_WITH_FRIEND":
            done = bool(o.extra.get("friendConfirmed"))
        if done:
            o.status = "COMPLETED"
            o.provisional = False
            if o.completed_at is None:
                o.completed_at = utcnow()
            completed.append(o)
        elif o.status == "COMPLETED" and o.provisional:
            # Client claimed it, trace does not support it.
            o.status = "PENDING"
            o.provisional = False
            o.completed_at = None
    return completed


async def _reward_for_ride(
    db: AsyncSession,
    character: Character,
    ride: Ride,
    quest: QuestInstance | None,
    quest_completed: bool,
    objectives_completed: list[QuestObjective],
    exploration: ExplorationOutcome,
    discoveries: list[Discovery],
) -> dict[str, Any]:
    inp = RideRewardInput(
        character_class=character.character_class,
        quest_completed=quest_completed,
        quest_difficulty=quest.difficulty if quest else None,
        quest_base_xp=quest.base_xp if quest else 0,
        is_story_quest=bool(quest and quest.story_quest_id),
        objectives_completed_required=sum(1 for o in objectives_completed if o.required),
        objectives_completed_optional=sum(1 for o in objectives_completed if not o.required),
        new_cells=len(exploration.new_cells),
        new_cells_explored=exploration.new_explored,
        new_roads_meters=exploration.new_territory_m,
        discovery_categories=[d.category for d in discoveries],
        distance_meters=ride.distance_meters,
        elevation_gain_meters=ride.elevation_gain_meters,
    )
    lines = compute_ride_xp(inp)
    outcome = await grant(db, character, lines, ride_id=ride.id, quest_id=quest.id if quest else None)
    return outcome.to_dict()


async def process_ride(db: AsyncSession, settings: Settings, ride_id: uuid.UUID) -> dict[str, Any]:
    ride = await db.get(Ride, ride_id)
    if ride is None:
        raise NotFound("Ride not found")
    if ride.status not in ("UPLOADED", "PROCESSING"):
        raise RideInvalidState(f"Ride is {ride.status}, cannot process")
    ride.status = "PROCESSING"
    await db.flush()
    character = await db.scalar(select(Character).where(Character.user_id == ride.user_id))
    points_rows = (
        (await db.execute(select(RidePoint).where(RidePoint.ride_id == ride.id).order_by(RidePoint.sequence)))
        .scalars()
        .all()
    )
    raw = [
        {
            "latitude": p.latitude,
            "longitude": p.longitude,
            "timestamp": p.timestamp,
            "altitudeMeters": p.altitude_meters,
            "horizontalAccuracyMeters": p.horizontal_accuracy_meters,
            "speedMps": p.speed_mps,
            "heartRateBpm": p.heart_rate_bpm,
        }
        for p in points_rows
    ]
    validation = validate_points(raw, client_distance_m=ride.distance_meters)
    flags = list(validation.flags)
    points = validation.points

    # Authoritative metrics: trust the trace when we have one.
    if points:
        ride.distance_meters = round(
            min(
                ride.distance_meters or validation.computed_distance_m,
                validation.computed_distance_m * 1.05,
            )
            if ride.distance_meters
            else validation.computed_distance_m,
            1,
        )
        if validation.computed_elevation_gain_m and (
            ride.elevation_gain_meters == 0 or ride.elevation_gain_meters > validation.computed_elevation_gain_m * 1.5
        ):
            ride.elevation_gain_meters = round(validation.computed_elevation_gain_m, 1)
        ride.max_speed_mps = round(validation.max_speed_mps, 2)
        if not ride.moving_seconds:
            ride.moving_seconds = validation.moving_seconds
    if ride.moving_seconds:
        ride.average_speed_mps = round(ride.distance_meters / ride.moving_seconds, 2)
    ride.point_count = len(points)

    ended = ride.ended_at or utcnow()
    exploration = ExplorationOutcome()
    if points:
        traversal = traverse([(p.latitude, p.longitude) for p in points], settings.h3_resolution)
        try:
            exploration = await record_traversal(
                db,
                ride.user_id,
                traversal,
                list(ride.client_cells or []),
                settings.h3_resolution,
                settings.explored_distance_threshold_meters,
                ended,
            )
        except Exception as exc:  # noqa: BLE001
            log.error(EVENT_EXPLORATION_VALIDATION_FAILED, ride_id=str(ride.id), error=str(exc))
            flags.append("EXPLORATION_ERROR")
        if exploration.rejected_client_cells:
            flags.append("REJECTED_CLIENT_CELLS")
        plaus = check_cell_plausibility(len(exploration.new_cells), ride.distance_meters)
        if plaus:
            flags.append(plaus)
    if validation.suspicious:
        # Suspicious rides still count for the journal but earn no exploration or XP.
        exploration = ExplorationOutcome()

    # Ride geometry stored separately.
    if points:
        coords = _simplify(points)
        lats = [c[1] for c in coords]
        lons = [c[0] for c in coords]
        db.add(
            RideRoute(
                ride_id=ride.id,
                coordinates=coords,
                encoded_polyline=encode_polyline((c[1], c[0]) for c in coords),
                min_lat=min(lats),
                min_lon=min(lons),
                max_lat=max(lats),
                max_lon=max(lons),
            )
        )

    discoveries: list[Discovery] = []
    if points and not validation.suspicious:
        discoveries = await discoveries_along(
            db, ride.user_id, [(p.latitude, p.longitude) for p in points], ride.id, ended
        )

    quest: QuestInstance | None = None
    quest_completed = False
    objectives_completed: list[QuestObjective] = []
    if ride.quest_id:
        quest = await db.get(QuestInstance, ride.quest_id)
        if (
            quest is not None
            and quest.user_id == ride.user_id
            and quest.status == "ACTIVE"
            and not validation.suspicious
        ):
            objectives_completed = evaluate_objectives(
                quest,
                points,
                distance_m=ride.distance_meters,
                elevation_gain_m=ride.elevation_gain_meters,
                new_roads_m=exploration.new_territory_m,
                new_cells=set(exploration.new_cells),
                resolution=settings.h3_resolution,
                client_events=list(ride.objective_events or []),
            )
            for o in objectives_completed:
                if o.discovery_id:
                    d = await db.get(Discovery, o.discovery_id)
                    if d is not None:
                        ud = await mark_found(db, ride.user_id, d, ride.id, ended)
                        if ud is not None:
                            discoveries.append(d)
            if all_required_complete(quest):
                assert_transition(quest.status, "COMPLETED")
                quest.status = "COMPLETED"
                quest.completed_at = ended
                quest.ride_id = ride.id
                quest_completed = True
        elif quest is not None and quest.status != "ACTIVE":
            quest = None

    reward: dict[str, Any] = {
        "xpAwarded": 0,
        "xpBreakdown": [],
        "levelUps": [],
        "abilitiesUnlocked": [],
        "titlesUnlocked": [],
    }
    if character is not None and not validation.suspicious:
        reward = await _reward_for_ride(
            db,
            character,
            ride,
            quest,
            quest_completed,
            objectives_completed,
            exploration,
            discoveries,
        )

    if quest_completed and quest is not None:
        await publish(
            db,
            ride.user_id,
            "FRIEND_QUEST_COMPLETED",
            {"questTitle": quest.title, "difficulty": quest.difficulty},
        )
    for lu in reward.get("levelUps", []):
        await publish(db, ride.user_id, "FRIEND_LEVEL_UP", lu)
    for d in discoveries[:3]:
        await publish(db, ride.user_id, "FRIEND_DISCOVERY", {"name": d.name, "category": d.category})
    if len(exploration.new_cells) >= 10:
        await publish(db, ride.user_id, "FRIEND_NEW_REGION", {"newCells": len(exploration.new_cells)})

    summary = {
        "questTitle": quest.title if quest else None,
        "questId": str(quest.id) if quest else None,
        "questCompleted": quest_completed,
        "questCompletion": completion_payload(quest, reward) if quest_completed and quest else None,
        "objectivesCompleted": [str(o.id) for o in objectives_completed],
        "xpAwarded": reward["xpAwarded"],
        "xpBreakdown": reward["xpBreakdown"],
        "levelUps": reward["levelUps"],
        "abilitiesUnlocked": reward["abilitiesUnlocked"],
        "titlesUnlocked": reward["titlesUnlocked"],
        "newCells": len(exploration.new_cells),
        "upgradedCells": len(exploration.upgraded_cells),
        "newTerritoryMeters": round(exploration.new_territory_m, 1),
        "newRoadsMeters": round(exploration.new_territory_m, 1),
        "discoveries": [
            {
                "id": str(d.id),
                "name": d.name,
                "category": d.category,
                "latitude": d.latitude,
                "longitude": d.longitude,
                "source": d.source,
                "discoveredByUser": True,
            }
            for d in discoveries
        ],
        "droppedPoints": validation.dropped_points,
        "flags": flags,
    }
    ride.flags = flags
    ride.processing_result = summary
    ride.processed_at = utcnow()
    ride.status = "FLAGGED" if validation.suspicious else "PROCESSED"
    await db.flush()
    return summary


async def complete_quest_with_ride(
    db: AsyncSession, settings: Settings, user: User, quest: QuestInstance, ride_id: uuid.UUID
) -> dict[str, Any]:
    """Explicit completion call from the client: relies on processed ride data."""
    ride = await db.get(Ride, ride_id)
    if ride is None or ride.user_id != user.id:
        raise NotFound("Ride not found")
    if quest.status == "COMPLETED" and ride.processing_result and ride.processing_result.get("questCompletion"):
        return ride.processing_result["questCompletion"]
    if ride.status in ("UPLOADED", "PROCESSING"):
        raise RideInvalidState("Ride is still processing; poll /rides/{id}/summary", details={"rideId": str(ride.id)})
    if ride.status == "RECORDING":
        raise RideInvalidState("Complete the ride first")
    assert_transition(quest.status, "COMPLETED")
    if not all_required_complete(quest):
        raise InvalidTransition(
            "Required objectives are not complete",
            code="QUEST_OBJECTIVES_INCOMPLETE",
            details={"pending": [str(o.id) for o in quest.objectives if o.required and o.status != "COMPLETED"]},
        )
    quest.status = "COMPLETED"
    quest.completed_at = utcnow()
    quest.ride_id = ride.id
    character = await db.scalar(select(Character).where(Character.user_id == user.id))
    reward = (
        await _reward_for_ride(
            db,
            character,
            ride,
            quest,
            True,
            [o for o in quest.objectives if o.status == "COMPLETED"],
            ExplorationOutcome(),
            [],
        )
        if character
        else {}
    )
    return completion_payload(quest, reward)


async def complete_quest_without_ride(
    db: AsyncSession, settings: Settings, user: User, quest: QuestInstance
) -> dict[str, Any]:
    """Allowed only when every required objective was validated by a processed ride."""
    assert_transition(quest.status, "COMPLETED")
    if not all_required_complete(quest) or any(o.provisional for o in quest.objectives if o.required):
        raise InvalidTransition("Required objectives are not validated yet", code="QUEST_OBJECTIVES_INCOMPLETE")
    quest.status = "COMPLETED"
    quest.completed_at = utcnow()
    character = await db.scalar(select(Character).where(Character.user_id == user.id))
    lines = compute_ride_xp(
        RideRewardInput(
            character_class=character.character_class if character else "EXPLORER",
            quest_completed=True,
            quest_difficulty=quest.difficulty,
            quest_base_xp=quest.base_xp,
        )
    )
    reward = (await grant(db, character, lines, quest_id=quest.id)).to_dict() if character else {}
    return completion_payload(quest, reward)


def quest_snapshot(quest: QuestInstance | None) -> dict[str, Any] | None:
    return quest_out(quest).model_dump(mode="json") if quest else None
