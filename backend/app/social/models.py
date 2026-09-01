from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import ForeignKey, Index, String, UniqueConstraint, Uuid
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base, JSONType, TimestampMixin, TZDateTime, UUIDPrimaryKeyMixin


class Friendship(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """Directed edge requester -> addressee with a status. Both directions are
    inspected to derive the relationship state (spec §55)."""

    __tablename__ = "friends"
    __table_args__ = (
        UniqueConstraint("requester_id", "addressee_id"),
        Index("ix_friends_addressee_status", "addressee_id", "status"),
    )

    requester_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    addressee_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    status: Mapped[str] = mapped_column(String(10), nullable=False)  # PENDING/ACCEPTED/BLOCKED
    responded_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)


class Party(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    __tablename__ = "parties"

    owner_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    source_quest_id: Mapped[uuid.UUID | None] = mapped_column(Uuid, nullable=True)
    route_id: Mapped[uuid.UUID | None] = mapped_column(Uuid, nullable=True)
    status: Mapped[str] = mapped_column(String(10), nullable=False, default="FORMING")
    completion_rule: Mapped[str] = mapped_column(String(12), nullable=False, default="INDIVIDUAL")
    started_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    ended_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)

    members: Mapped[list[PartyMember]] = relationship(
        back_populates="party", cascade="all, delete-orphan", lazy="selectin"
    )


class PartyMember(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    __tablename__ = "party_members"
    __table_args__ = (UniqueConstraint("party_id", "user_id"),)

    party_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("parties.id", ondelete="CASCADE"), index=True)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    role: Mapped[str] = mapped_column(String(10), nullable=False, default="MEMBER")  # OWNER/MEMBER
    status: Mapped[str] = mapped_column(String(10), nullable=False, default="INVITED")  # INVITED/JOINED/READY/LEFT
    quest_instance_id: Mapped[uuid.UUID | None] = mapped_column(Uuid, nullable=True)

    party: Mapped[Party] = relationship(back_populates="members")


class FeedEvent(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    __tablename__ = "feed_events"
    __table_args__ = (Index("ix_feed_events_user_created", "user_id", "created_at"),)

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    event_type: Mapped[str] = mapped_column(String(32), nullable=False)
    visibility: Mapped[str] = mapped_column(String(10), nullable=False, default="FRIENDS")
    payload: Mapped[dict[str, Any]] = mapped_column(JSONType, default=dict, nullable=False)
