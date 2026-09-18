from __future__ import annotations

import uuid

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.characters.models import Character
from app.core.errors import NotFound
from app.discoveries.models import UserDiscovery
from app.quests.models import QuestInstance
from app.rides.models import Ride
from app.social.schemas import FriendSummary
from app.social.service import relationship_state
from app.users.models import User
from app.users.schemas import (
    AdventureSummaryPublic,
    PublicProfile,
    UserOut,
    UserSettings,
    UserUpdate,
)


async def to_user_out(db: AsyncSession, user: User) -> UserOut:
    character = await db.scalar(select(Character.id).where(Character.user_id == user.id))
    return UserOut(
        id=user.id,
        displayName=user.display_name,
        avatarUrl=user.avatar_url,
        createdAt=user.created_at,
        hasCharacter=character is not None,
        settings=UserSettings(**user.effective_settings()),
    )


async def update_user(db: AsyncSession, user: User, patch: UserUpdate) -> User:
    if patch.displayName is not None:
        user.display_name = patch.displayName.strip()
    if patch.avatarUrl is not None:
        user.avatar_url = patch.avatarUrl
    if patch.settings is not None:
        validated = UserSettings(**{**user.effective_settings(), **patch.settings})
        user.settings = validated.model_dump()
    await db.flush()
    return user


async def public_profile(db: AsyncSession, viewer: User, user_id: uuid.UUID) -> PublicProfile:
    user = await db.get(User, user_id)
    if user is None or user.deleted_at is not None:
        raise NotFound("User not found")
    character = await db.scalar(select(Character).where(Character.user_id == user.id))
    quests = await db.scalar(
        select(func.count(QuestInstance.id)).where(
            QuestInstance.user_id == user.id, QuestInstance.status == "COMPLETED"
        )
    )
    discoveries = await db.scalar(select(func.count(UserDiscovery.id)).where(UserDiscovery.user_id == user.id))
    friendship = await relationship_state(db, viewer.id, user.id)
    visible = ["PUBLIC"] if friendship != "FRIENDS" else ["PUBLIC", "FRIENDS"]
    if viewer.id == user.id:
        visible = ["PUBLIC", "FRIENDS", "PRIVATE"]
    rides = (
        (
            await db.execute(
                select(Ride)
                .where(
                    Ride.user_id == user.id,
                    Ride.status == "PROCESSED",
                    Ride.visibility.in_(visible),
                )
                .order_by(Ride.ended_at.desc())
                .limit(5)
            )
        )
        .scalars()
        .all()
    )
    recent = []
    for ride in rides:
        result = ride.processing_result or {}
        recent.append(
            AdventureSummaryPublic(
                rideId=ride.id,
                questTitle=result.get("questTitle"),
                completedAt=ride.ended_at or ride.started_at,
                distanceMeters=ride.distance_meters,
                newTerritoryMeters=float(result.get("newTerritoryMeters", 0.0)),
                xpAwarded=int(result.get("xpAwarded", 0)),
            )
        )
    # Never expose start/end coordinates, home area or live position here.
    return PublicProfile(
        id=user.id,
        displayName=user.display_name,
        avatarUrl=user.avatar_url,
        characterClass=character.character_class if character else None,
        overallLevel=character.overall_level if character else None,
        title=character.title if character else None,
        questsCompleted=int(quests or 0),
        discoveriesFound=int(discoveries or 0),
        favouriteTerrain=None,
        friendship=friendship,
        recentAdventures=recent,
    )


async def search_users(db: AsyncSession, me: User, query: str, limit: int) -> list[FriendSummary]:
    """People by display name, nearest match first, never oneself and never
    anyone who has blocked or been blocked by the searcher."""
    from app.social.service import summary

    needle = query.strip().lower()
    if not needle:
        return []
    rows = (
        (
            await db.execute(
                select(User)
                .where(func.lower(User.display_name).contains(needle), User.id != me.id)
                .order_by(func.length(User.display_name), User.display_name)
                .limit(limit * 2)
            )
        )
        .scalars()
        .all()
    )
    found: list[FriendSummary] = []
    for other in rows:
        if await relationship_state(db, me.id, other.id) == "BLOCKED":
            continue
        found.append(await summary(db, other))
        if len(found) >= limit:
            break
    return found
