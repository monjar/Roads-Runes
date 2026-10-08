"""The pledge (0.7.3): one creature or quest promised for a day.

Kept, a journey's end says "You said you would. You did." Missed, nothing is ever
said or charged: a pledge whose day has passed is marked MISSED the next time the
pledges are read, and only today's and tomorrow's are ever shown.
"""

from __future__ import annotations

import uuid
from datetime import date, datetime, timedelta
from typing import Any

from sqlalchemy import delete, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.between.models import Pledge
from app.between.schemas import PledgeIn, PledgeOut, PledgeStanding
from app.core.errors import AppError, NotFound
from app.core.security import utcnow
from app.lore import catalog as lore
from app.quests.models import QuestInstance
from app.rides.models import Ride
from app.world_objects import variants
from app.world_objects.models import WorldObject

KEPT_LINE = "You said you would. You did."
TARGET_GONE = "That creature or quest isn't on your map any more. Pick another."
WRONG_DAY = "You can pledge for today or tomorrow. Pick one of those."
QUEST_ICON = "scroll"
OPEN_QUEST_STATES = ("AVAILABLE", "ACCEPTED", "ACTIVE")
NAME_WIDTH = 160


def creature_icon(payload: dict[str, Any] | None) -> str | None:
    """The creature's mark, as the app's GameIcon name."""
    species = lore.species_by_id().get(lore.species_of(payload) or "")
    return str(species["sigil"]["icon"]) if species else None


async def _live_creature(db: AsyncSession, user_id: uuid.UUID, target_id: uuid.UUID) -> WorldObject | None:
    obj = await db.get(WorldObject, target_id)
    if obj is None or obj.user_id != user_id or obj.kind != "MONSTER":
        return None
    if obj.status != "SPAWNED" or obj.expires_at <= utcnow():
        return None
    return obj


async def _open_quest(db: AsyncSession, user_id: uuid.UUID, target_id: uuid.UUID) -> QuestInstance | None:
    quest = await db.get(QuestInstance, target_id)
    if quest is None or quest.user_id != user_id or quest.status not in OPEN_QUEST_STATES:
        return None
    if quest.expires_at is not None and quest.expires_at <= utcnow():
        return None
    return quest


async def _quest_icon(db: AsyncSession, quest: QuestInstance | None) -> str:
    """A quest about a creature wears the creature's mark; any other, a scroll."""
    if quest is not None:
        for o in quest.objectives:
            wanted = (o.extra or {}).get("objectId")
            if o.objective_type == "SLAY_MONSTER" and wanted:
                try:
                    obj = await db.get(WorldObject, uuid.UUID(str(wanted)))
                except ValueError:
                    obj = None
                icon = creature_icon(obj.payload) if obj is not None else None
                if icon:
                    return icon
    return QUEST_ICON


async def icon_for(db: AsyncSession, pledge: Pledge) -> str | None:
    if pledge.target_kind == "CREATURE":
        obj = await db.get(WorldObject, pledge.target_id)
        return creature_icon(obj.payload) if obj is not None else None
    return await _quest_icon(db, await db.get(QuestInstance, pledge.target_id))


async def pledge_out(db: AsyncSession, pledge: Pledge) -> PledgeOut:
    return PledgeOut(
        day=pledge.day,
        targetKind=pledge.target_kind,
        targetId=pledge.target_id,
        targetName=pledge.target_name,
        icon=await icon_for(db, pledge),
        remindAt=pledge.remind_at,
        status=pledge.status,
    )


async def standing(db: AsyncSession, user_id: uuid.UUID, today: date) -> PledgeStanding:
    """Today's pledge and tomorrow's, on the phone's calendar. Any earlier one still
    waiting is missed now, quietly."""
    await db.execute(
        update(Pledge)
        .where(Pledge.user_id == user_id, Pledge.status == "PLEDGED", Pledge.day < today)
        .values(status="MISSED")
        .execution_options(synchronize_session=False)
    )
    rows = {
        p.day: p
        for p in (
            await db.execute(
                select(Pledge).where(Pledge.user_id == user_id, Pledge.day.in_([today, today + timedelta(days=1)]))
            )
        ).scalars()
    }
    found_today, found_tomorrow = rows.get(today), rows.get(today + timedelta(days=1))
    return PledgeStanding(
        today=await pledge_out(db, found_today) if found_today is not None else None,
        tomorrow=await pledge_out(db, found_tomorrow) if found_tomorrow is not None else None,
    )


def _day_is_near(day: date, now: datetime) -> bool:
    """Today or tomorrow somewhere on Earth: the server's UTC date, a day either side."""
    utc_today = now.date()
    return utc_today - timedelta(days=1) <= day <= utc_today + timedelta(days=2)


async def pledge(db: AsyncSession, user_id: uuid.UUID, payload: PledgeIn) -> Pledge:
    """Pledges the day to a live creature or an open quest; a second for the same
    day replaces the first."""
    if not _day_is_near(payload.day, utcnow()):
        raise AppError(WRONG_DAY, code="PLEDGE_DAY")
    if payload.targetKind == "CREATURE":
        obj = await _live_creature(db, user_id, payload.targetId)
        if obj is None:
            raise NotFound(TARGET_GONE)
        name = variants.display_name(obj.payload) or str((obj.payload or {}).get("name") or "Creature")
    else:
        quest = await _open_quest(db, user_id, payload.targetId)
        if quest is None:
            raise NotFound(TARGET_GONE)
        name = quest.title
    row = await db.scalar(select(Pledge).where(Pledge.user_id == user_id, Pledge.day == payload.day))
    if row is None:
        row = Pledge(user_id=user_id, day=payload.day)
        db.add(row)
    row.target_kind = payload.targetKind
    row.target_id = payload.targetId
    row.target_name = name[:NAME_WIDTH]
    row.remind_at = payload.remindAt
    row.status = "PLEDGED"
    row.kept_ride_id = None
    await db.flush()
    return row


async def withdraw(db: AsyncSession, user_id: uuid.UUID, day: date) -> None:
    """Takes the day's pledge back. Nothing pledged that day is not an error."""
    await db.execute(delete(Pledge).where(Pledge.user_id == user_id, Pledge.day == day))


def ride_days(ride: Ride) -> list[date]:
    """The day a journey keeps a pledge for: the phone's own date when it sent one;
    otherwise the start's UTC date, and a day either side, since a journey near
    midnight is on another calendar day somewhere."""
    if ride.local_date is not None:
        return [ride.local_date]
    day = ride.started_at.date()
    return [day, day - timedelta(days=1), day + timedelta(days=1)]


async def _quest_done_on(db: AsyncSession, quest_id: uuid.UUID, ride: Ride, ended: datetime) -> bool:
    """A quest finished during the journey without the journey carrying it: a chest
    quest opened by hand on the way."""
    quest = await db.get(QuestInstance, quest_id)
    if quest is None or quest.user_id != ride.user_id or quest.status != "COMPLETED":
        return False
    if quest.ride_id == ride.id:
        return True
    done = quest.completed_at
    return done is not None and ride.started_at <= done <= ended + timedelta(minutes=5)


async def keep(
    db: AsyncSession,
    ride: Ride,
    *,
    defeated: set[uuid.UUID],
    quest_completed: uuid.UUID | None,
    ended: datetime,
) -> dict[str, Any] | None:
    """The pledge this journey kept, if it kept one: the creature pledged was
    defeated, or the quest pledged was finished. A pledge already missed for that
    day is kept all the same (the journey may be counted after midnight). Run
    again on the same journey, it finds the same pledge."""
    days = ride_days(ride)
    rows = list(
        (
            await db.execute(
                select(Pledge).where(
                    Pledge.user_id == ride.user_id,
                    Pledge.day.in_(days),
                    or_(Pledge.status.in_(["PLEDGED", "MISSED"]), Pledge.kept_ride_id == ride.id),
                )
            )
        ).scalars()
    )
    rows.sort(key=lambda p: days.index(p.day))
    for row in rows:
        if row.status == "KEPT" and row.kept_ride_id == ride.id:
            hit = True  # counted again: what it defeated the first time is not there to defeat
        elif row.target_kind == "CREATURE":
            hit = row.target_id in defeated
        else:
            hit = row.target_id == quest_completed or await _quest_done_on(db, row.target_id, ride, ended)
        if not hit:
            continue
        row.status = "KEPT"
        row.kept_ride_id = ride.id
        await db.flush()
        return {
            "kept": True,
            "day": row.day.isoformat(),
            "targetKind": row.target_kind,
            "targetId": str(row.target_id),
            "targetName": row.target_name,
            "icon": await icon_for(db, row),
            "line": KEPT_LINE,
        }
    return None
