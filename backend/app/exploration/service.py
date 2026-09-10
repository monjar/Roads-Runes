"""Exploration persistence: cell state upserts and world queries."""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import datetime

import h3
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.discoveries.models import UserDiscovery
from app.exploration.cells import (
    TraversalResult,
    cell_center,
    cells_in_radius,
    merge_state,
    reconcile_client_cells,
    state_for,
)
from app.exploration.models import UserExplorationCell
from app.exploration.schemas import CellOut, ExplorationStats
from app.quests.models import QuestInstance
from app.rides.models import Ride


@dataclass
class ExplorationOutcome:
    new_cells: list[str] = field(default_factory=list)
    upgraded_cells: list[str] = field(default_factory=list)
    new_explored: int = 0
    new_territory_m: float = 0.0
    rejected_client_cells: list[str] = field(default_factory=list)
    cells_touched: int = 0


async def known_cells(db: AsyncSession, user_id: uuid.UUID) -> dict[str, str]:
    rows = (
        await db.execute(
            select(UserExplorationCell.h3_index, UserExplorationCell.state).where(
                UserExplorationCell.user_id == user_id
            )
        )
    ).all()
    return {h: s for h, s in rows}


async def record_traversal(
    db: AsyncSession,
    user_id: uuid.UUID,
    traversal: TraversalResult,
    client_cells: list[str],
    resolution: int,
    explored_threshold_m: float,
    at: datetime,
) -> ExplorationOutcome:
    outcome = ExplorationOutcome()
    accepted, rejected = reconcile_client_cells(traversal.cells.keys(), client_cells, resolution)
    outcome.rejected_client_cells = rejected
    if not accepted:
        return outcome
    existing_rows = (
        (
            await db.execute(
                select(UserExplorationCell).where(
                    UserExplorationCell.user_id == user_id,
                    UserExplorationCell.h3_index.in_(list(accepted)),
                )
            )
        )
        .scalars()
        .all()
    )
    existing = {row.h3_index: row for row in existing_rows}
    for cell in accepted:
        traversed = traversal.cells.get(cell)
        distance = traversed.distance_inside_m if traversed else 0.0
        entries = traversed.entries if traversed else 1
        new_state = state_for(distance, explored_threshold_m)
        row = existing.get(cell)
        if row is None:
            lat, lon = cell_center(cell)
            row = UserExplorationCell(
                user_id=user_id,
                h3_index=cell,
                resolution=resolution,
                state=new_state,
                latitude=lat,
                longitude=lon,
                distance_inside_m=distance,
                visit_count=entries,
                first_visited_at=at,
                last_visited_at=at,
                discovered_via="RIDE",
            )
            db.add(row)
            outcome.new_cells.append(cell)
            outcome.new_territory_m += distance
            if new_state == "EXPLORED":
                outcome.new_explored += 1
        else:
            was_unvisited = row.state == "DISCOVERED"
            previous = row.state
            row.distance_inside_m += distance
            row.visit_count += entries
            row.last_visited_at = at
            if row.first_visited_at is None:
                row.first_visited_at = at
            candidate = state_for(row.distance_inside_m, explored_threshold_m)
            row.state = merge_state(previous, candidate)
            if was_unvisited:
                outcome.new_cells.append(cell)
                outcome.new_territory_m += distance
            elif row.state != previous:
                outcome.upgraded_cells.append(cell)
                if row.state == "EXPLORED":
                    outcome.new_explored += 1
        outcome.cells_touched += 1
    await db.flush()
    return outcome


async def reveal(db: AsyncSession, user_id: uuid.UUID, cells: list[str], resolution: int, via: str) -> int:
    """Mark cells DISCOVERED (quest/ability reveal) without visiting."""
    if not cells:
        return 0
    existing = {
        r.h3_index
        for r in (
            await db.execute(
                select(UserExplorationCell).where(
                    UserExplorationCell.user_id == user_id, UserExplorationCell.h3_index.in_(cells)
                )
            )
        ).scalars()
    }
    added = 0
    for cell in cells:
        if cell in existing:
            continue
        lat, lon = cell_center(cell)
        db.add(
            UserExplorationCell(
                user_id=user_id,
                h3_index=cell,
                resolution=resolution,
                state="DISCOVERED",
                latitude=lat,
                longitude=lon,
                discovered_via=via,
            )
        )
        added += 1
    await db.flush()
    return added


async def cells_near(
    db: AsyncSession,
    user_id: uuid.UUID,
    latitude: float,
    longitude: float,
    radius_m: float,
    resolution: int,
) -> list[CellOut]:
    wanted = cells_in_radius(latitude, longitude, radius_m, resolution)
    if not wanted:
        return []
    rows = (
        (
            await db.execute(
                select(UserExplorationCell).where(
                    UserExplorationCell.user_id == user_id, UserExplorationCell.h3_index.in_(wanted)
                )
            )
        )
        .scalars()
        .all()
    )
    return [CellOut(h3=r.h3_index, state=r.state, firstVisitedAt=r.first_visited_at) for r in rows]


async def cells_in_bbox(
    db: AsyncSession,
    user_id: uuid.UUID,
    min_lat: float,
    min_lon: float,
    max_lat: float,
    max_lon: float,
) -> list[CellOut]:
    rows = (
        (
            await db.execute(
                select(UserExplorationCell).where(
                    UserExplorationCell.user_id == user_id,
                    UserExplorationCell.latitude >= min_lat,
                    UserExplorationCell.latitude <= max_lat,
                    UserExplorationCell.longitude >= min_lon,
                    UserExplorationCell.longitude <= max_lon,
                )
            )
        )
        .scalars()
        .all()
    )
    return [CellOut(h3=r.h3_index, state=r.state, firstVisitedAt=r.first_visited_at) for r in rows]


async def stats(db: AsyncSession, user_id: uuid.UUID, resolution: int) -> ExplorationStats:
    counts = dict(
        (
            await db.execute(
                select(UserExplorationCell.state, func.count())
                .where(UserExplorationCell.user_id == user_id)
                .group_by(UserExplorationCell.state)
            )
        ).all()
    )
    distance_in_cells = await db.scalar(
        select(func.coalesce(func.sum(UserExplorationCell.distance_inside_m), 0.0)).where(
            UserExplorationCell.user_id == user_id
        )
    )
    ride_q = select(
        func.count(Ride.id),
        func.coalesce(func.sum(Ride.distance_meters), 0.0),
        func.coalesce(func.sum(Ride.elevation_gain_meters), 0.0),
        func.avg(Ride.average_speed_mps),
        func.max(Ride.max_speed_mps),
    ).where(Ride.user_id == user_id, Ride.status == "PROCESSED")
    rides, total_distance, total_elev, avg_speed, max_speed = (await db.execute(ride_q)).one()
    quests_done = await db.scalar(
        select(func.count(QuestInstance.id)).where(
            QuestInstance.user_id == user_id, QuestInstance.status == "COMPLETED"
        )
    )
    story_done = await db.scalar(
        select(func.count(QuestInstance.id)).where(
            QuestInstance.user_id == user_id,
            QuestInstance.status == "COMPLETED",
            QuestInstance.story_quest_id.is_not(None),
        )
    )
    discoveries = await db.scalar(select(func.count(UserDiscovery.id)).where(UserDiscovery.user_id == user_id))
    visited = counts.get("VISITED", 0) + counts.get("EXPLORED", 0)
    # Regions: parent cells two resolutions up (~ neighbourhood scale).
    parents = set()
    for (h3_index,) in (
        await db.execute(
            select(UserExplorationCell.h3_index).where(
                UserExplorationCell.user_id == user_id, UserExplorationCell.state != "DISCOVERED"
            )
        )
    ).all():
        parents.add(h3.cell_to_parent(h3_index, max(0, resolution - 3)))
    return ExplorationStats(
        cellsVisited=visited,
        cellsExplored=counts.get("EXPLORED", 0),
        cellsDiscovered=counts.get("DISCOVERED", 0),
        newTerritoryKm=round(float(distance_in_cells or 0.0) / 1000, 1),
        uniqueRoadsKm=round(float(distance_in_cells or 0.0) / 1000, 1),
        regionsVisited=len(parents),
        questsCompleted=int(quests_done or 0),
        discoveriesFound=int(discoveries or 0),
        storyQuestsCompleted=int(story_done or 0),
        totalDistanceMeters=float(total_distance or 0.0),
        totalElevationMeters=float(total_elev or 0.0),
        ridesCompleted=int(rides or 0),
        averageSpeedMps=float(avg_speed) if avg_speed else None,
        maxSpeedMps=float(max_speed) if max_speed else None,
    )
