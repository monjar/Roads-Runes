"""Quest lifecycle: generation, listing, state transitions, progress."""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.characters import catalog
from app.characters.models import Character
from app.characters.service import ability_map, default_bike, get_rider_profile
from app.core.activity import comfortable_distance_km, normalise
from app.core.config import Settings
from app.core.errors import NotFound, QuestGenerationFailed
from app.core.geo import haversine_m
from app.core.llm import LLMClient
from app.core.logging import EVENT_QUEST_GENERATION_FAILED, get_logger
from app.core.schemas import Coordinate
from app.core.security import utcnow
from app.discoveries import osm_import
from app.discoveries.service import nearby as discoveries_nearby
from app.exploration.cells import cell_for
from app.exploration.service import known_cells, reveal
from app.quests import narrative
from app.quests.generator import GeneratedQuest, GenerationContext, POICandidate, WorldObjectCandidate, generate
from app.quests.models import QuestInstance, QuestObjective, QuestProgressEvent
from app.quests.schemas import ObjectiveEventIn, ObjectiveOut, ObjectiveProgress, QuestOut
from app.quests.state_machine import assert_transition
from app.quests.templates import ANY_CLASS
from app.users.models import User
from app.world_objects import service as world_objects

log = get_logger(__name__)

QUEST_TTL_DAYS = 14
NEARBY_RADIUS_M = 25_000.0


def objective_out(o: QuestObjective) -> ObjectiveOut:
    # A puzzle objective keeps its coordinates until it is done: the planned route
    # still leads there, but the app cannot name the place or pin it on the map.
    hidden = bool((o.extra or {}).get("hidden")) and o.status != "COMPLETED"
    return ObjectiveOut(
        id=o.id,
        objectiveType=o.objective_type,
        title=o.title,
        latitude=None if hidden else o.latitude,
        longitude=None if hidden else o.longitude,
        radiusMeters=o.radius_meters,
        targetMeters=o.target_meters,
        targetCells=o.target_cells,
        targetElevationMeters=o.target_elevation_meters,
        targetCount=o.target_count,
        discoveryId=o.discovery_id,
        required=o.required,
        order=o.order,
        completionRule=o.completion_rule,
        status=o.status,
        completedAt=o.completed_at,
        provisional=o.provisional,
        progress=ObjectiveProgress(current=o.progress_current, target=o.progress_target),
        extra=o.extra or {},
    )


def quest_out(q: QuestInstance) -> QuestOut:
    return QuestOut(
        id=q.id,
        questType=q.quest_type,
        characterClass=q.character_class,
        activity=normalise(q.activity),
        templateId=q.template_id,
        title=q.title,
        description=q.description,
        narrative=q.narrative or {},
        difficulty=q.difficulty,
        recommendedDistanceKm=q.recommended_distance_km,
        estimatedDurationMinutes=q.estimated_duration_minutes,
        baseXP=q.base_xp,
        status=q.status,
        expiresAt=q.expires_at,
        storyQuestId=q.story_quest_id,
        partyId=q.party_id,
        origin=Coordinate(latitude=q.latitude, longitude=q.longitude),
        objectives=[objective_out(o) for o in q.objectives],
        rewards=q.rewards or {},
        suggestedRouteId=q.suggested_route_id,
        rideId=q.ride_id,
        acceptedAt=q.accepted_at,
        startedAt=q.started_at,
        completedAt=q.completed_at,
        createdAt=q.created_at,
    )


async def get_quest(db: AsyncSession, user: User, quest_id: uuid.UUID) -> QuestInstance:
    quest = await db.get(QuestInstance, quest_id)
    if quest is None or quest.user_id != user.id:
        raise NotFound("Quest not found")
    return quest


async def expire_stale(db: AsyncSession, user_id: uuid.UUID) -> None:
    now = utcnow()
    rows = (
        (
            await db.execute(
                select(QuestInstance).where(
                    QuestInstance.user_id == user_id,
                    QuestInstance.status.in_(["AVAILABLE", "ACCEPTED"]),
                    QuestInstance.expires_at.is_not(None),
                    QuestInstance.expires_at < now,
                )
            )
        )
        .scalars()
        .all()
    )
    for row in rows:
        row.status = "EXPIRED"


async def list_quests(
    db: AsyncSession,
    user: User,
    status: str | None,
    latitude: float | None,
    longitude: float | None,
    limit: int,
) -> list[QuestInstance]:
    await expire_stale(db, user.id)
    stmt = select(QuestInstance).where(QuestInstance.user_id == user.id)
    if status:
        stmt = stmt.where(QuestInstance.status == status)
    stmt = stmt.order_by(QuestInstance.created_at.desc()).limit(limit * 3)
    rows = list((await db.execute(stmt)).scalars())
    if latitude is not None and longitude is not None:
        rows = [
            r
            for r in rows
            if haversine_m(latitude, longitude, r.latitude, r.longitude) <= NEARBY_RADIUS_M
            or r.status in ("ACCEPTED", "ACTIVE")
        ]
    return rows[:limit]


async def build_context(
    db: AsyncSession,
    settings: Settings,
    user: User,
    character: Character,
    latitude: float,
    longitude: float,
    requested_distance_km: float | None = None,
    activity: str | None = None,
) -> GenerationContext:
    profile = await get_rider_profile(db, user.id)
    # Asked for, or however this player usually moves.
    activity = normalise(activity or profile.default_activity)
    bike = await default_bike(db, user.id)
    cells = await known_cells(db, user.id)
    explored = {h for h, s in cells.items() if s == "EXPLORED"}
    visited = {h for h, s in cells.items() if s in ("VISITED", "EXPLORED")}
    abilities = ability_map(character)
    poi_bonus = catalog.effect_total(abilities, "QUEST_POI_VISIBILITY")
    # Places come from OpenStreetMap the first time an area is used, so quests work anywhere.
    await osm_import.ensure_pois(settings, latitude, longitude)
    pois = await discoveries_nearby(db, latitude, longitude, 30_000 * (1 + poi_bonus), limit=800)
    # And the chests, pieces and monsters already placed here, for the quests that point at them.
    placed = await world_objects.ensure_spawned(
        db, settings, user.id, latitude, longitude, 6000, character_class=character.character_class, activity=activity
    )
    completed = [
        r
        for (r,) in (
            await db.execute(
                select(QuestInstance.template_id)
                .where(QuestInstance.user_id == user.id, QuestInstance.status == "COMPLETED")
                .order_by(QuestInstance.completed_at)
            )
        ).all()
    ]
    return GenerationContext(
        latitude=latitude,
        longitude=longitude,
        character_class=character.character_class,
        overall_level=character.overall_level,
        class_level=character.class_level,
        comfortable_distance_km=comfortable_distance_km(profile, activity),
        comfortable_elevation_gain=profile.comfortable_elevation_gain,
        gravel_comfort=profile.gravel_comfort,
        bike_allows_gravel=bike.allow_gravel if bike else True,
        bike_allows_trails=bike.allow_trails if bike else False,
        explored_cells=explored,
        visited_cells=visited,
        completed_template_ids=completed,
        pois=[
            POICandidate(str(p.id), p.name, p.category, p.latitude, p.longitude, p.tags or {}, p.h3_index) for p in pois
        ],
        unlocked_templates=catalog.unlocked_templates(abilities),
        resolution=settings.h3_resolution,
        seed=f"{user.id}:{utcnow().date().isoformat()}",
        requested_distance_km=requested_distance_km,
        poi_visibility_bonus=poi_bonus,
        activity=activity,
        world_objects=[
            WorldObjectCandidate(
                str(o.id),
                o.kind,
                str(o.payload.get("name", o.kind.title())),
                o.payload.get("anchorName"),
                o.latitude,
                o.longitude,
            )
            for o in placed
        ],
    )


def _persist(user: User, generated: GeneratedQuest, now: datetime) -> QuestInstance:
    quest = QuestInstance(
        user_id=user.id,
        template_id=generated.template_id,
        quest_type=generated.quest_type,
        character_class=generated.character_class,
        activity=generated.activity,
        title=generated.title,
        description=generated.description,
        narrative=generated.narrative,
        difficulty=generated.difficulty,
        recommended_distance_km=generated.recommended_distance_km,
        estimated_duration_minutes=generated.estimated_duration_minutes,
        base_xp=generated.base_xp,
        status="AVAILABLE",
        expires_at=now + timedelta(days=QUEST_TTL_DAYS),
        latitude=generated.latitude,
        longitude=generated.longitude,
        rewards=generated.rewards,
        generation_seed=generated.seed,
    )
    for o in generated.objectives:
        quest.objectives.append(
            QuestObjective(
                objective_type=o.objective_type,
                title=o.title,
                latitude=o.latitude,
                longitude=o.longitude,
                radius_meters=o.radius_meters,
                target_meters=o.target_meters,
                target_cells=o.target_cells,
                target_elevation_meters=o.target_elevation_meters,
                target_count=o.target_count,
                discovery_id=uuid.UUID(o.discovery_id) if o.discovery_id else None,
                required=o.required,
                order=o.order,
                progress_target=o.progress_target,
                extra=o.extra,
            )
        )
    return quest


async def generate_quests(
    db: AsyncSession,
    settings: Settings,
    llm: LLMClient,
    user: User,
    character: Character,
    latitude: float,
    longitude: float,
    count: int,
    request: str | None = None,
    activity: str | None = None,
    only_any: bool = False,
) -> list[QuestInstance]:
    requested_km = None
    if request:
        from app.routing.preferences import parse_request

        parsed = await parse_request(request, llm)
        if parsed.preferences.distanceKm:
            requested_km = parsed.preferences.distanceKm["target"]
    ctx = await build_context(db, settings, user, character, latitude, longitude, requested_km, activity)
    existing = (
        await db.execute(
            select(QuestInstance.template_id).where(
                QuestInstance.user_id == user.id,
                QuestInstance.status.in_(["AVAILABLE", "ACCEPTED", "ACTIVE"]),
            )
        )
    ).all()
    try:
        generated = generate(ctx, count, exclude_template_ids={t for (t,) in existing}, only_any=only_any)
    except Exception as exc:  # noqa: BLE001
        log.error(EVENT_QUEST_GENERATION_FAILED, error=str(exc))
        raise QuestGenerationFailed("Quest generation failed") from exc
    if not generated:
        generated = generate(ctx, count, only_any=only_any)  # allow repeats rather than returning nothing
    now = utcnow()
    quests: list[QuestInstance] = []
    for g in generated:
        if settings.flags.get("llm_narrative"):
            g = await narrative.enrich(llm, g)
        quest = _persist(user, g, now)
        db.add(quest)
        quests.append(quest)
    await db.flush()
    # Reveal target regions on the map (DISCOVERED state) so the fog shows where to go.
    reveal_cells: list[str] = []
    for quest in quests:
        for o in quest.objectives:
            if o.target_cells:
                reveal_cells.extend(o.target_cells)
            elif (
                o.latitude is not None
                and o.longitude is not None
                and o.objective_type in ("VISIT_POI", "VISIT_LOCATION", "SLAY_MONSTER", "OPEN_CHEST", "COLLECT")
            ):
                reveal_cells.append(cell_for(o.latitude, o.longitude, settings.h3_resolution))
    await reveal(db, user.id, list(dict.fromkeys(reveal_cells)), settings.h3_resolution, "QUEST")
    for quest in quests:
        await db.refresh(quest)
    return quests


async def ensure_available(
    db: AsyncSession,
    settings: Settings,
    llm: LLMClient,
    user: User,
    character: Character,
    latitude: float,
    longitude: float,
    minimum: int = 3,
    activity: str | None = None,
) -> list[QuestInstance]:
    available = await list_quests(db, user, "AVAILABLE", latitude, longitude, 20)
    if len(available) < minimum:
        await generate_quests(
            db, settings, llm, user, character, latitude, longitude, minimum - len(available), activity=activity
        )
        available = await list_quests(db, user, "AVAILABLE", latitude, longitude, 20)
    # A board with nothing for anyone on it gets one open quest, whatever the class.
    if available and not any(q.character_class == ANY_CLASS for q in available):
        await generate_quests(
            db, settings, llm, user, character, latitude, longitude, 1, activity=activity, only_any=True
        )
        available = await list_quests(db, user, "AVAILABLE", latitude, longitude, 20)
    return available


# Transitions --------------------------------------------------------------


async def accept(db: AsyncSession, user: User, quest_id: uuid.UUID) -> QuestInstance:
    quest = await get_quest(db, user, quest_id)
    assert_transition(quest.status, "ACCEPTED")
    quest.status = "ACCEPTED"
    quest.accepted_at = utcnow()
    await db.flush()
    return quest


async def start(db: AsyncSession, user: User, quest_id: uuid.UUID, ride_id: uuid.UUID | None) -> QuestInstance:
    quest = await get_quest(db, user, quest_id)
    assert_transition(quest.status, "ACTIVE")
    # Only one active quest at a time keeps navigation simple (spec: "active quest").
    others = (
        (
            await db.execute(
                select(QuestInstance).where(
                    QuestInstance.user_id == user.id,
                    QuestInstance.status == "ACTIVE",
                    QuestInstance.id != quest.id,
                )
            )
        )
        .scalars()
        .all()
    )
    for other in others:
        other.status = "ACCEPTED"
        other.started_at = None
    quest.status = "ACTIVE"
    quest.started_at = utcnow()
    quest.ride_id = ride_id
    await db.flush()
    return quest


async def abandon(db: AsyncSession, user: User, quest_id: uuid.UUID) -> QuestInstance:
    quest = await get_quest(db, user, quest_id)
    assert_transition(quest.status, "ABANDONED")
    quest.status = "ABANDONED"
    await db.flush()
    return quest


async def record_progress(
    db: AsyncSession, user: User, quest_id: uuid.UUID, events: list[ObjectiveEventIn]
) -> QuestInstance:
    """Client-observed objective completions. Marked provisional until ride processing validates them."""
    quest = await get_quest(db, user, quest_id)
    if quest.status != "ACTIVE":
        assert_transition(quest.status, "ACTIVE")  # raises with a clear message
    by_id = {o.id: o for o in quest.objectives}
    for event in events:
        objective = by_id.get(event.objectiveId)
        if objective is None:
            continue
        db.add(
            QuestProgressEvent(
                quest_id=quest.id,
                objective_id=objective.id,
                occurred_at=event.occurredAt,
                latitude=event.latitude,
                longitude=event.longitude,
                value=event.value,
                source="CLIENT",
            )
        )
        if objective.status == "COMPLETED":
            continue
        if objective.objective_type in (
            "VISIT_LOCATION",
            "VISIT_POI",
            "VISIT_REGION",
            "RETURN_TO_START",
            "PHOTO_LOCATION",
            "WRITE_NOTE",
        ):
            if objective.latitude is not None and event.latitude is not None and objective.radius_meters:
                if (
                    haversine_m(objective.latitude, objective.longitude, event.latitude, event.longitude)
                    > objective.radius_meters * 1.5
                ):
                    continue
            objective.progress_current = objective.progress_target
        elif objective.objective_type == "VISIT_MULTIPLE_LOCATIONS":
            if event.latitude is None:
                continue
            visited = list(objective.extra.get("visitedCells", []))
            for cell in objective.extra.get("cells", []):
                if cell["h3"] in visited:
                    continue
                radius = (objective.radius_meters or 250) * 1.5
                if (
                    haversine_m(float(cell["latitude"]), float(cell["longitude"]), event.latitude, event.longitude)
                    <= radius
                ):
                    visited.append(cell["h3"])
            objective.extra = {**objective.extra, "visitedCells": visited}
            objective.progress_current = float(len(visited))
        elif event.value is not None:
            objective.progress_current = min(
                objective.progress_target, max(objective.progress_current, float(event.value))
            )
        if objective.progress_current >= objective.progress_target:
            objective.status = "COMPLETED"
            objective.provisional = True
            objective.completed_at = event.occurredAt
    await db.flush()
    return quest


def all_required_complete(quest: QuestInstance) -> bool:
    return all(o.status == "COMPLETED" for o in quest.objectives if o.required)


async def active_quest(db: AsyncSession, user_id: uuid.UUID) -> QuestInstance | None:
    return await db.scalar(
        select(QuestInstance).where(QuestInstance.user_id == user_id, QuestInstance.status == "ACTIVE")
    )


def completion_payload(quest: QuestInstance, reward: dict[str, Any] | None) -> dict[str, Any]:
    reward = reward or {}
    return {
        "quest": quest_out(quest).model_dump(mode="json"),
        "xpAwarded": reward.get("xpAwarded", 0),
        "xpBreakdown": reward.get("xpBreakdown", []),
        "levelUps": reward.get("levelUps", []),
        "abilitiesUnlocked": reward.get("abilitiesUnlocked", []),
        "titlesUnlocked": reward.get("titlesUnlocked", []),
        "storyProgress": None,
    }
