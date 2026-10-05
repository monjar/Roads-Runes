"""The pledge and letters (0.7.3)."""

from __future__ import annotations

import uuid
from datetime import date

from fastapi import APIRouter, status

from app.between import letters, pledges
from app.between.schemas import LetterIn, LetterOut, PledgeIn, PledgeOut, PledgeStanding
from app.core.deps import CurrentUser, DBDep, SettingsDep
from app.core.feature_flags import require_flag
from app.core.security import utcnow

pledge_router = APIRouter(prefix="/pledge", tags=["between"])
letters_router = APIRouter(prefix="/letters", tags=["between"])


@pledge_router.get("", response_model=PledgeStanding)
async def get_pledges(user: CurrentUser, db: DBDep, settings: SettingsDep, today: date | None = None) -> PledgeStanding:
    """Today's and tomorrow's pledge. `today` is the phone's own date; without it, the
    server's UTC date."""
    require_flag(settings, "pledge")
    return await pledges.standing(db, user.id, today or utcnow().date())


@pledge_router.put("", response_model=PledgeOut)
async def put_pledge(payload: PledgeIn, user: CurrentUser, db: DBDep, settings: SettingsDep) -> PledgeOut:
    require_flag(settings, "pledge")
    return await pledges.pledge_out(db, await pledges.pledge(db, user.id, payload))


@pledge_router.delete("/{day}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_pledge(day: date, user: CurrentUser, db: DBDep, settings: SettingsDep) -> None:
    require_flag(settings, "pledge")
    await pledges.withdraw(db, user.id, day)


@letters_router.post("", response_model=LetterOut, status_code=status.HTTP_201_CREATED)
async def write_letter(payload: LetterIn, user: CurrentUser, db: DBDep) -> LetterOut:
    return letters.letter_out(await letters.write(db, user.id, payload))


@letters_router.get("", response_model=list[LetterOut])
async def list_letters(user: CurrentUser, db: DBDep) -> list[LetterOut]:
    """The player's letters, newest first."""
    return [letters.letter_out(row) for row in await letters.mine(db, user.id)]


@letters_router.delete("/{letter_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_letter(letter_id: uuid.UUID, user: CurrentUser, db: DBDep) -> None:
    await letters.remove(db, user.id, letter_id)
