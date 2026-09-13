"""Wallet service: the only code path that changes a balance. Every change is a WalletTransaction."""

from __future__ import annotations

import uuid
from typing import Any

from sqlalchemy import and_, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import Conflict
from app.core.pagination import decode_cursor, encode_cursor
from app.economy.models import Wallet, WalletTransaction
from app.economy.rules import ACLine


async def get_wallet(db: AsyncSession, user_id: uuid.UUID) -> Wallet | None:
    return await db.scalar(select(Wallet).where(Wallet.user_id == user_id))


async def get_or_create_wallet(db: AsyncSession, user_id: uuid.UUID) -> Wallet:
    wallet = await get_wallet(db, user_id)
    if wallet is None:
        wallet = Wallet(user_id=user_id, balance=0, lifetime_earned=0)
        db.add(wallet)
        await db.flush()
    return wallet


async def balance(db: AsyncSession, user_id: uuid.UUID) -> int:
    wallet = await get_wallet(db, user_id)
    return wallet.balance if wallet else 0


async def credit(
    db: AsyncSession,
    user_id: uuid.UUID,
    amount: int,
    kind: str,
    *,
    ride_id: uuid.UUID | None = None,
    quest_id: uuid.UUID | None = None,
    object_id: uuid.UUID | None = None,
    payload: dict[str, Any] | None = None,
) -> WalletTransaction:
    if amount <= 0:
        raise ValueError("credit needs a positive amount")
    wallet = await get_or_create_wallet(db, user_id)
    wallet.balance += amount
    wallet.lifetime_earned += amount
    transaction = WalletTransaction(
        user_id=user_id,
        wallet_id=wallet.id,
        amount=amount,
        kind=kind,
        ride_id=ride_id,
        quest_id=quest_id,
        object_id=object_id,
        payload=payload or {},
    )
    db.add(transaction)
    await db.flush()
    return transaction


async def debit(
    db: AsyncSession,
    user_id: uuid.UUID,
    amount: int,
    kind: str,
    *,
    payload: dict[str, Any] | None = None,
) -> WalletTransaction:
    if amount <= 0:
        raise ValueError("debit needs a positive amount")
    wallet = await get_or_create_wallet(db, user_id)
    if wallet.balance < amount:
        raise Conflict(
            f"That costs {amount} Active Coins and you have {wallet.balance}",
            code="INSUFFICIENT_AC",
            details={"cost": amount, "balance": wallet.balance},
        )
    wallet.balance -= amount
    transaction = WalletTransaction(
        user_id=user_id, wallet_id=wallet.id, amount=-amount, kind=kind, payload=payload or {}
    )
    db.add(transaction)
    await db.flush()
    return transaction


async def credit_lines(
    db: AsyncSession,
    user_id: uuid.UUID,
    lines: list[ACLine],
    *,
    ride_id: uuid.UUID | None = None,
    quest_id: uuid.UUID | None = None,
) -> dict[str, Any]:
    """One transaction per line, one balance. The shape mirrors the XP envelope."""
    awarded = 0
    for line in lines:
        if line.ac <= 0:
            continue
        await credit(
            db,
            user_id,
            line.ac,
            line.kind,
            ride_id=ride_id,
            quest_id=quest_id if line.kind == "QUEST_COMPLETED" else None,
            object_id=line.detail.get("objectId") if isinstance(line.detail.get("objectId"), uuid.UUID) else None,
            payload=line.detail,
        )
        awarded += line.ac
    return {
        "acAwarded": awarded,
        "acBreakdown": [line.to_dict() for line in lines if line.ac > 0],
        "walletBalance": await balance(db, user_id),
    }


async def transactions(
    db: AsyncSession, user_id: uuid.UUID, limit: int, cursor: str | None
) -> tuple[list[WalletTransaction], str | None]:
    query = select(WalletTransaction).where(WalletTransaction.user_id == user_id)
    after = decode_cursor(cursor)
    if after is not None:
        sort_key, item_id = after
        query = query.where(
            or_(
                WalletTransaction.created_at < sort_key,
                and_(WalletTransaction.created_at == sort_key, WalletTransaction.id < item_id),
            )
        )
    rows = list(
        (
            await db.execute(
                query.order_by(WalletTransaction.created_at.desc(), WalletTransaction.id.desc()).limit(limit + 1)
            )
        ).scalars()
    )
    next_cursor = None
    if len(rows) > limit:
        rows = rows[:limit]
        next_cursor = encode_cursor(rows[-1].created_at, rows[-1].id)
    return rows, next_cursor
