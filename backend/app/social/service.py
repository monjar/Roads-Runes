from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.characters.models import Character
from app.core.config import Settings
from app.core.errors import Conflict, Forbidden, NotFound
from app.core.feature_flags import require_flag
from app.core.security import utcnow
from app.quests.models import QuestInstance, QuestObjective
from app.social.models import FeedEvent, Friendship, Party, PartyMember
from app.social.schemas import (
    FeedEventOut,
    FriendRequestOut,
    FriendRequests,
    FriendSummary,
    PartyMemberOut,
    PartyOut,
)
from app.users.models import User


async def relationship_state(db: AsyncSession, me: uuid.UUID, other: uuid.UUID) -> str:
    if me == other:
        return "NONE"
    rows = (
        (
            await db.execute(
                select(Friendship).where(
                    or_(
                        (Friendship.requester_id == me) & (Friendship.addressee_id == other),
                        (Friendship.requester_id == other) & (Friendship.addressee_id == me),
                    )
                )
            )
        )
        .scalars()
        .all()
    )
    for row in rows:
        if row.status == "BLOCKED":
            return "BLOCKED"
    for row in rows:
        if row.status == "ACCEPTED":
            return "FRIENDS"
    for row in rows:
        if row.status == "PENDING":
            return "REQUEST_SENT" if row.requester_id == me else "REQUEST_RECEIVED"
    return "NONE"


async def are_friends(db: AsyncSession, a: uuid.UUID, b: uuid.UUID) -> bool:
    return await relationship_state(db, a, b) == "FRIENDS"


async def friend_ids(db: AsyncSession, me: uuid.UUID) -> list[uuid.UUID]:
    rows = (
        (
            await db.execute(
                select(Friendship).where(
                    Friendship.status == "ACCEPTED",
                    or_(Friendship.requester_id == me, Friendship.addressee_id == me),
                )
            )
        )
        .scalars()
        .all()
    )
    return [r.addressee_id if r.requester_id == me else r.requester_id for r in rows]


async def summary(db: AsyncSession, user: User, since: datetime | None = None) -> FriendSummary:
    character = await db.scalar(select(Character).where(Character.user_id == user.id))
    return FriendSummary(
        id=user.id,
        displayName=user.display_name,
        avatarUrl=user.avatar_url,
        characterClass=character.character_class if character else None,
        overallLevel=character.overall_level if character else None,
        title=character.title if character else None,
        since=since,
    )


async def list_friends(db: AsyncSession, me: User) -> list[FriendSummary]:
    rows = (
        (
            await db.execute(
                select(Friendship).where(
                    Friendship.status == "ACCEPTED",
                    or_(Friendship.requester_id == me.id, Friendship.addressee_id == me.id),
                )
            )
        )
        .scalars()
        .all()
    )
    out = []
    for row in rows:
        other_id = row.addressee_id if row.requester_id == me.id else row.requester_id
        other = await db.get(User, other_id)
        if other and other.deleted_at is None:
            out.append(await summary(db, other, row.responded_at))
    return out


async def list_requests(db: AsyncSession, me: User) -> FriendRequests:
    incoming = (
        (await db.execute(select(Friendship).where(Friendship.addressee_id == me.id, Friendship.status == "PENDING")))
        .scalars()
        .all()
    )
    outgoing = (
        (await db.execute(select(Friendship).where(Friendship.requester_id == me.id, Friendship.status == "PENDING")))
        .scalars()
        .all()
    )

    async def build(rows, pick):
        items = []
        for row in rows:
            other = await db.get(User, pick(row))
            if other:
                items.append(FriendRequestOut(id=row.id, user=await summary(db, other), createdAt=row.created_at))
        return items

    return FriendRequests(
        incoming=await build(incoming, lambda r: r.requester_id),
        outgoing=await build(outgoing, lambda r: r.addressee_id),
    )


async def send_request(db: AsyncSession, me: User, other_id: uuid.UUID) -> Friendship:
    if other_id == me.id:
        raise Conflict("Cannot befriend yourself")
    other = await db.get(User, other_id)
    if other is None or other.deleted_at is not None:
        raise NotFound("User not found")
    state = await relationship_state(db, me.id, other_id)
    if state == "BLOCKED":
        raise Forbidden("Cannot send request")
    if state in ("FRIENDS", "REQUEST_SENT"):
        raise Conflict(f"Relationship already {state}")
    if state == "REQUEST_RECEIVED":
        return await accept_request_between(db, me, other_id)
    row = Friendship(requester_id=me.id, addressee_id=other_id, status="PENDING")
    db.add(row)
    await db.flush()
    return row


async def accept_request_between(db: AsyncSession, me: User, other_id: uuid.UUID) -> Friendship:
    row = await db.scalar(
        select(Friendship).where(
            Friendship.requester_id == other_id,
            Friendship.addressee_id == me.id,
            Friendship.status == "PENDING",
        )
    )
    if row is None:
        raise NotFound("Request not found")
    row.status = "ACCEPTED"
    row.responded_at = utcnow()
    await db.flush()
    return row


async def respond(db: AsyncSession, me: User, request_id: uuid.UUID, accept: bool) -> Friendship | None:
    row = await db.get(Friendship, request_id)
    if row is None or row.addressee_id != me.id or row.status != "PENDING":
        raise NotFound("Request not found")
    if accept:
        row.status = "ACCEPTED"
        row.responded_at = utcnow()
        await db.flush()
        return row
    await db.delete(row)
    await db.flush()
    return None


async def remove_friend(db: AsyncSession, me: User, other_id: uuid.UUID) -> None:
    rows = (
        (
            await db.execute(
                select(Friendship).where(
                    or_(
                        (Friendship.requester_id == me.id) & (Friendship.addressee_id == other_id),
                        (Friendship.requester_id == other_id) & (Friendship.addressee_id == me.id),
                    ),
                    Friendship.status != "BLOCKED",
                )
            )
        )
        .scalars()
        .all()
    )
    for row in rows:
        await db.delete(row)
    await db.flush()


async def block(db: AsyncSession, me: User, other_id: uuid.UUID) -> None:
    await remove_friend(db, me, other_id)
    existing = await db.scalar(
        select(Friendship).where(Friendship.requester_id == me.id, Friendship.addressee_id == other_id)
    )
    if existing:
        existing.status = "BLOCKED"
    else:
        db.add(Friendship(requester_id=me.id, addressee_id=other_id, status="BLOCKED"))
    await db.flush()


# Feed -----------------------------------------------------------------------


async def publish(
    db: AsyncSession,
    user_id: uuid.UUID,
    event_type: str,
    payload: dict[str, Any],
    visibility: str = "FRIENDS",
) -> None:
    db.add(FeedEvent(user_id=user_id, event_type=event_type, visibility=visibility, payload=payload))


async def feed(db: AsyncSession, me: User, limit: int) -> list[FeedEventOut]:
    ids = await friend_ids(db, me.id)
    if not ids:
        return []
    rows = (
        (
            await db.execute(
                select(FeedEvent)
                .where(FeedEvent.user_id.in_(ids), FeedEvent.visibility.in_(["FRIENDS", "PUBLIC"]))
                .order_by(FeedEvent.created_at.desc())
                .limit(limit)
            )
        )
        .scalars()
        .all()
    )
    out = []
    for row in rows:
        user = await db.get(User, row.user_id)
        if user:
            out.append(
                FeedEventOut(
                    id=row.id,
                    eventType=row.event_type,
                    user=await summary(db, user),
                    payload=row.payload,
                    createdAt=row.created_at,
                )
            )
    return out


# Parties --------------------------------------------------------------------

PARTY_TRANSITIONS = {
    "FORMING": {"READY", "ACTIVE", "CANCELLED"},
    "READY": {"ACTIVE", "FORMING", "CANCELLED"},
    "ACTIVE": {"COMPLETED", "CANCELLED"},
    "COMPLETED": set(),
    "CANCELLED": set(),
}


async def party_out(db: AsyncSession, party: Party) -> PartyOut:
    members = []
    for m in party.members:
        user = await db.get(User, m.user_id)
        if user:
            members.append(
                PartyMemberOut(
                    user=await summary(db, user),
                    role=m.role,
                    status=m.status,
                    questId=m.quest_instance_id,
                )
            )
    return PartyOut(
        id=party.id,
        ownerId=party.owner_id,
        questId=party.source_quest_id,
        routeId=party.route_id,
        status=party.status,
        completionRule=party.completion_rule,
        members=members,
        createdAt=party.created_at,
    )


async def _clone_quest_for(
    db: AsyncSession, source: QuestInstance, user_id: uuid.UUID, party_id: uuid.UUID
) -> QuestInstance:
    clone = QuestInstance(
        user_id=user_id,
        template_id=source.template_id,
        quest_type=source.quest_type,
        character_class=source.character_class,
        title=source.title,
        description=source.description,
        narrative=dict(source.narrative),
        difficulty=source.difficulty,
        recommended_distance_km=source.recommended_distance_km,
        estimated_duration_minutes=source.estimated_duration_minutes,
        base_xp=source.base_xp,
        status="ACCEPTED",
        latitude=source.latitude,
        longitude=source.longitude,
        rewards=dict(source.rewards),
        party_id=party_id,
        generation_seed=source.generation_seed,
        accepted_at=utcnow(),
    )
    for o in source.objectives:
        clone.objectives.append(
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
                discovery_id=o.discovery_id,
                required=o.required,
                order=o.order,
                completion_rule=o.completion_rule,
                progress_target=o.progress_target,
                extra=dict(o.extra),
            )
        )
    db.add(clone)
    await db.flush()
    return clone


async def create_party(
    db: AsyncSession, settings: Settings, me: User, quest_id: uuid.UUID, member_ids: list[uuid.UUID]
) -> Party:
    require_flag(settings, "party_quests")
    quest = await db.get(QuestInstance, quest_id)
    if quest is None or quest.user_id != me.id:
        raise NotFound("Quest not found")
    party = Party(
        owner_id=me.id,
        source_quest_id=quest.id,
        route_id=quest.suggested_route_id,
        status="FORMING",
    )
    db.add(party)
    await db.flush()
    quest.party_id = party.id
    party.members.append(
        PartyMember(
            party_id=party.id,
            user_id=me.id,
            role="OWNER",
            status="JOINED",
            quest_instance_id=quest.id,
        )
    )
    for uid in member_ids:
        await invite(db, me, party, uid)
    await db.flush()
    return party


async def get_party(db: AsyncSession, me: User, party_id: uuid.UUID) -> Party:
    party = await db.get(Party, party_id)
    if party is None or not any(m.user_id == me.id for m in party.members):
        raise NotFound("Party not found")
    return party


async def invite(db: AsyncSession, me: User, party: Party, user_id: uuid.UUID) -> PartyMember:
    if party.owner_id != me.id:
        raise Forbidden("Only the owner can invite")
    if not await are_friends(db, me.id, user_id):
        raise Forbidden("Can only invite friends")
    if any(m.user_id == user_id for m in party.members):
        raise Conflict("Already in party")
    member = PartyMember(party_id=party.id, user_id=user_id, role="MEMBER", status="INVITED")
    party.members.append(member)
    await db.flush()
    return member


async def accept_invite(db: AsyncSession, me: User, party_id: uuid.UUID) -> Party:
    party = await db.get(Party, party_id)
    member = next((m for m in (party.members if party else []) if m.user_id == me.id), None)
    if party is None or member is None:
        raise NotFound("Invitation not found")
    if member.status == "INVITED":
        member.status = "JOINED"
        source = await db.get(QuestInstance, party.source_quest_id) if party.source_quest_id else None
        if source is not None:
            clone = await _clone_quest_for(db, source, me.id, party.id)
            member.quest_instance_id = clone.id
    await db.flush()
    return party


async def leave(db: AsyncSession, me: User, party_id: uuid.UUID) -> Party:
    party = await get_party(db, me, party_id)
    member = next(m for m in party.members if m.user_id == me.id)
    member.status = "LEFT"
    if party.owner_id == me.id and party.status in ("FORMING", "READY"):
        party.status = "CANCELLED"
    await db.flush()
    return party


async def set_status(db: AsyncSession, me: User, party_id: uuid.UUID, new_status: str) -> Party:
    party = await get_party(db, me, party_id)
    if new_status == "READY":
        member = next(m for m in party.members if m.user_id == me.id)
        member.status = "READY"
        if all(m.status in ("READY", "LEFT") for m in party.members):
            party.status = "READY"
        await db.flush()
        return party
    if party.owner_id != me.id:
        raise Forbidden("Only the owner can change party status")
    if new_status not in PARTY_TRANSITIONS[party.status]:
        raise Conflict(
            f"Party cannot move from {party.status} to {new_status}",
            code="PARTY_INVALID_TRANSITION",
        )
    party.status = new_status
    if new_status == "ACTIVE":
        party.started_at = utcnow()
    if new_status in ("COMPLETED", "CANCELLED"):
        party.ended_at = utcnow()
    await db.flush()
    return party
