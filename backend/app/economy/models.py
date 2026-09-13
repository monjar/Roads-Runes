from __future__ import annotations

import uuid
from typing import Any

from sqlalchemy import ForeignKey, Index, Integer, String, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, JSONType, TimestampMixin, UUIDPrimaryKeyMixin


class Wallet(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """One per user. The balance is the sum of the ledger; it is kept for reading, not trusted for writing."""

    __tablename__ = "wallets"

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), unique=True, index=True)
    balance: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    lifetime_earned: Mapped[int] = mapped_column(Integer, default=0, nullable=False)


class WalletTransaction(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """Immutable ledger of every coin earned or spent, like `xp_events` for XP."""

    __tablename__ = "wallet_transactions"
    __table_args__ = (Index("ix_wallet_transactions_user_created", "user_id", "created_at"),)

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    wallet_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("wallets.id", ondelete="CASCADE"), index=True)
    amount: Mapped[int] = mapped_column(Integer, nullable=False)  # signed: earned > 0, spent < 0
    kind: Mapped[str] = mapped_column(String(32), nullable=False)
    ride_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("rides.id", ondelete="SET NULL"), nullable=True, index=True
    )
    quest_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("quest_instances.id", ondelete="SET NULL"), nullable=True
    )
    object_id: Mapped[uuid.UUID | None] = mapped_column(Uuid, nullable=True)
    payload: Mapped[dict[str, Any]] = mapped_column(JSONType, default=dict, nullable=False)
