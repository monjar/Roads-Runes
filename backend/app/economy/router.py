from __future__ import annotations

from fastapi import APIRouter

from app.core.deps import CurrentUser, DBDep
from app.core.pagination import Page, clamp_limit
from app.economy import service
from app.economy.schemas import WalletOut, WalletTransactionOut

router = APIRouter(prefix="/wallet", tags=["wallet"])


@router.get("", response_model=WalletOut)
async def wallet(user: CurrentUser, db: DBDep) -> WalletOut:
    found = await service.get_wallet(db, user.id)
    return WalletOut(balance=found.balance if found else 0, lifetimeEarned=found.lifetime_earned if found else 0)


@router.get("/transactions", response_model=Page[WalletTransactionOut])
async def transactions(
    user: CurrentUser, db: DBDep, limit: int | None = None, cursor: str | None = None
) -> Page[WalletTransactionOut]:
    rows, next_cursor = await service.transactions(db, user.id, clamp_limit(limit), cursor)
    return Page(
        items=[
            WalletTransactionOut(
                id=row.id,
                amount=row.amount,
                kind=row.kind,
                rideId=row.ride_id,
                questId=row.quest_id,
                objectId=row.object_id,
                payload=row.payload,
                createdAt=row.created_at,
            )
            for row in rows
        ],
        nextCursor=next_cursor,
    )
