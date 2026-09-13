from __future__ import annotations

import uuid

from fastapi import APIRouter, status

from app.characters import service
from app.characters.schemas import (
    AbilityState,
    BikeIn,
    BikeOut,
    BikePatch,
    CharacterClassChange,
    CharacterCreate,
    CharacterOut,
    ClassInfo,
    RiderProfileIO,
)
from app.core.deps import CurrentUser, DBDep, SettingsDep

router = APIRouter(prefix="/character", tags=["character"])


@router.get("/classes", response_model=list[ClassInfo])
async def classes(settings: SettingsDep) -> list[ClassInfo]:
    return service.class_list(settings)


@router.post("", response_model=CharacterOut, status_code=status.HTTP_201_CREATED)
async def create(payload: CharacterCreate, user: CurrentUser, db: DBDep, settings: SettingsDep) -> CharacterOut:
    return await service.character_out(db, await service.create_character(db, settings, user, payload))


@router.get("", response_model=CharacterOut)
async def get(user: CurrentUser, db: DBDep) -> CharacterOut:
    return await service.character_out(db, await service.get_character(db, user))


@router.patch("", response_model=CharacterOut)
async def change_class(
    payload: CharacterClassChange, user: CurrentUser, db: DBDep, settings: SettingsDep
) -> CharacterOut:
    character = await service.get_character(db, user)
    return await service.character_out(db, await service.change_class(db, settings, character, payload.characterClass))


@router.delete("", status_code=status.HTTP_204_NO_CONTENT)
async def reset(user: CurrentUser, db: DBDep) -> None:
    await service.reset_character(db, user)


@router.get("/abilities", response_model=list[AbilityState])
async def abilities(user: CurrentUser, db: DBDep) -> list[AbilityState]:
    return service.ability_states(await service.get_character(db, user))


@router.post("/abilities/{ability_id}/unlock", response_model=CharacterOut)
async def unlock(ability_id: str, user: CurrentUser, db: DBDep) -> CharacterOut:
    character = await service.get_character(db, user)
    return await service.character_out(db, await service.unlock_ability(db, character, ability_id))


@router.get("/bikes", response_model=list[BikeOut])
async def bikes(user: CurrentUser, db: DBDep) -> list[BikeOut]:
    return [service.bike_out(b) for b in await service.list_bikes(db, user)]


@router.post("/bikes", response_model=BikeOut, status_code=status.HTTP_201_CREATED)
async def create_bike(payload: BikeIn, user: CurrentUser, db: DBDep) -> BikeOut:
    return service.bike_out(await service.create_bike(db, user, payload))


@router.patch("/bikes/{bike_id}", response_model=BikeOut)
async def patch_bike(bike_id: uuid.UUID, payload: BikePatch, user: CurrentUser, db: DBDep) -> BikeOut:
    return service.bike_out(await service.update_bike(db, user, bike_id, payload))


@router.delete("/bikes/{bike_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_bike(bike_id: uuid.UUID, user: CurrentUser, db: DBDep) -> None:
    await service.delete_bike(db, user, bike_id)


@router.get("/rider-profile", response_model=RiderProfileIO)
async def rider_profile(user: CurrentUser, db: DBDep) -> RiderProfileIO:
    return service.rider_profile_out(await service.get_rider_profile(db, user.id))


@router.put("/rider-profile", response_model=RiderProfileIO)
async def put_rider_profile(payload: RiderProfileIO, user: CurrentUser, db: DBDep) -> RiderProfileIO:
    return service.rider_profile_out(await service.put_rider_profile(db, user, payload))
