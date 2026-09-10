from __future__ import annotations

import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.characters import catalog
from app.characters.models import Bike, Character, CharacterAbility, RiderProfile
from app.characters.schemas import (
    AbilityOut,
    AbilityState,
    BikeIn,
    BikeOut,
    BikePatch,
    CharacterCreate,
    CharacterOut,
    ClassInfo,
    RiderProfileIO,
)
from app.core.config import Settings
from app.core.errors import Conflict, FeatureDisabled, NotFound
from app.core.feature_flags import class_enabled
from app.progression.engine import level_bounds
from app.users.models import User

BIKE_DEFAULTS = {
    "ROAD": (False, False, 0),
    "GRAVEL": (True, True, 2),
    "MOUNTAIN": (True, True, 3),
    "HYBRID": (True, False, 1),
    "FOLDING": (False, False, 0),
    "OTHER": (True, False, 1),
}


async def get_character(db: AsyncSession, user: User) -> Character:
    character = await db.scalar(select(Character).where(Character.user_id == user.id))
    if character is None:
        raise NotFound("Create a character first", code="NO_CHARACTER")
    return character


async def maybe_character(db: AsyncSession, user_id: uuid.UUID) -> Character | None:
    return await db.scalar(select(Character).where(Character.user_id == user_id))


def ability_map(character: Character) -> dict[str, int]:
    return {a.ability_id: a.rank for a in character.abilities}


def ability_states(character: Character) -> list[AbilityState]:
    owned = ability_map(character)
    states = []
    for ability in catalog.abilities_for_class(character.character_class):
        rank = owned.get(ability["id"], 0)
        can_unlock = (
            character.ability_points > 0
            and character.class_level >= ability["requiredClassLevel"]
            and rank < ability["maxRank"]
        )
        states.append(AbilityState(ability=AbilityOut(**ability), rank=rank, unlocked=rank > 0, canUnlock=can_unlock))
    return states


def to_character_out(character: Character) -> CharacterOut:
    o_floor, o_next = level_bounds(character.overall_level, "overall")
    c_floor, c_next = level_bounds(character.class_level, "class")
    return CharacterOut(
        id=character.id,
        name=character.name,
        characterClass=character.character_class,
        overallLevel=character.overall_level,
        overallXP=character.overall_xp,
        nextOverallLevelXP=o_next,
        overallLevelFloorXP=o_floor,
        classLevel=character.class_level,
        classXP=character.class_xp,
        nextClassLevelXP=c_next,
        classLevelFloorXP=c_floor,
        title=character.title,
        abilities=ability_states(character),
        unspentAbilityPoints=character.ability_points,
        createdAt=character.created_at,
    )


def class_list(settings: Settings) -> list[ClassInfo]:
    return [
        ClassInfo(
            id=cid,
            name=c["name"],
            tagline=c["tagline"],
            description=c["description"],
            enabled=class_enabled(settings, cid),
        )
        for cid, c in catalog.classes().items()
    ]


async def create_character(db: AsyncSession, settings: Settings, user: User, payload: CharacterCreate) -> Character:
    if await maybe_character(db, user.id) is not None:
        raise Conflict("Character already exists")
    if payload.characterClass not in catalog.classes():
        raise NotFound("Unknown class")
    if not class_enabled(settings, payload.characterClass):
        raise FeatureDisabled(f"Class {payload.characterClass} is not available yet")
    character = Character(
        user_id=user.id,
        name=payload.name.strip(),
        character_class=payload.characterClass,
        title="Novice",
    )
    db.add(character)
    # Every rider gets a default profile; it is separate from the RPG character.
    if await db.scalar(select(RiderProfile).where(RiderProfile.user_id == user.id)) is None:
        db.add(RiderProfile(user_id=user.id))
    await db.flush()
    await db.refresh(character)
    return character


async def unlock_ability(db: AsyncSession, character: Character, ability_id: str) -> Character:
    ability = catalog.abilities_by_id().get(ability_id)
    if ability is None or ability["characterClass"] != character.character_class:
        raise NotFound("Ability not available for this class")
    if character.class_level < ability["requiredClassLevel"]:
        raise Conflict("Class level too low", code="ABILITY_LOCKED")
    if character.ability_points <= 0:
        raise Conflict("No ability points available", code="NO_ABILITY_POINTS")
    existing = next((a for a in character.abilities if a.ability_id == ability_id), None)
    if existing and existing.rank >= ability["maxRank"]:
        raise Conflict("Ability already at max rank", code="ABILITY_MAX_RANK")
    if existing:
        existing.rank += 1
    else:
        character.abilities.append(CharacterAbility(character_id=character.id, ability_id=ability_id, rank=1))
    character.ability_points -= 1
    await db.flush()
    return character


# Bikes -------------------------------------------------------------------


def bike_out(bike: Bike) -> BikeOut:
    return BikeOut(
        id=bike.id,
        name=bike.name,
        bikeType=bike.bike_type,
        allowGravel=bike.allow_gravel,
        allowTrails=bike.allow_trails,
        maxTechnicalSurface=bike.max_technical_surface,
        isDefault=bike.is_default,
    )


async def list_bikes(db: AsyncSession, user: User) -> list[Bike]:
    return list(
        (
            await db.execute(
                select(Bike).where(Bike.user_id == user.id, Bike.archived.is_(False)).order_by(Bike.created_at)
            )
        ).scalars()
    )


async def default_bike(db: AsyncSession, user_id: uuid.UUID) -> Bike | None:
    bikes = list((await db.execute(select(Bike).where(Bike.user_id == user_id, Bike.archived.is_(False)))).scalars())
    return next((b for b in bikes if b.is_default), bikes[0] if bikes else None)


async def create_bike(db: AsyncSession, user: User, payload: BikeIn) -> Bike:
    gravel, trails, technical = BIKE_DEFAULTS[payload.bikeType]
    existing = await list_bikes(db, user)
    bike = Bike(
        user_id=user.id,
        name=payload.name.strip(),
        bike_type=payload.bikeType,
        allow_gravel=gravel if payload.allowGravel is None else payload.allowGravel,
        allow_trails=trails if payload.allowTrails is None else payload.allowTrails,
        max_technical_surface=technical if payload.maxTechnicalSurface is None else payload.maxTechnicalSurface,
        is_default=payload.isDefault or not existing,
    )
    if bike.is_default:
        for other in existing:
            other.is_default = False
    db.add(bike)
    await db.flush()
    return bike


async def update_bike(db: AsyncSession, user: User, bike_id: uuid.UUID, patch: BikePatch) -> Bike:
    bike = await db.get(Bike, bike_id)
    if bike is None or bike.user_id != user.id or bike.archived:
        raise NotFound("Bike not found")
    if patch.name is not None:
        bike.name = patch.name.strip()
    if patch.bikeType is not None:
        bike.bike_type = patch.bikeType
    if patch.allowGravel is not None:
        bike.allow_gravel = patch.allowGravel
    if patch.allowTrails is not None:
        bike.allow_trails = patch.allowTrails
    if patch.maxTechnicalSurface is not None:
        bike.max_technical_surface = patch.maxTechnicalSurface
    if patch.isDefault:
        for other in await list_bikes(db, user):
            other.is_default = other.id == bike.id
    await db.flush()
    return bike


async def delete_bike(db: AsyncSession, user: User, bike_id: uuid.UUID) -> None:
    bike = await db.get(Bike, bike_id)
    if bike is None or bike.user_id != user.id:
        raise NotFound("Bike not found")
    bike.archived = True
    bike.is_default = False
    await db.flush()


# Rider profile -------------------------------------------------------------


async def get_rider_profile(db: AsyncSession, user_id: uuid.UUID) -> RiderProfile:
    profile = await db.scalar(select(RiderProfile).where(RiderProfile.user_id == user_id))
    if profile is None:
        profile = RiderProfile(user_id=user_id)
        db.add(profile)
        await db.flush()
    return profile


def rider_profile_out(profile: RiderProfile) -> RiderProfileIO:
    return RiderProfileIO(
        comfortableDistanceKm=profile.comfortable_distance_km,
        comfortableElevationGain=profile.comfortable_elevation_gain,
        maxPreferredGradient=profile.max_preferred_gradient,
        trafficTolerance=profile.traffic_tolerance,
        gravelComfort=profile.gravel_comfort,
        technicalTrailComfort=profile.technical_trail_comfort,
        cyclewayPreference=profile.cycleway_preference,
    )


async def put_rider_profile(db: AsyncSession, user: User, payload: RiderProfileIO) -> RiderProfile:
    profile = await get_rider_profile(db, user.id)
    profile.comfortable_distance_km = payload.comfortableDistanceKm
    profile.comfortable_elevation_gain = payload.comfortableElevationGain
    profile.max_preferred_gradient = payload.maxPreferredGradient
    profile.traffic_tolerance = payload.trafficTolerance
    profile.gravel_comfort = payload.gravelComfort
    profile.technical_trail_comfort = payload.technicalTrailComfort
    profile.cycleway_preference = payload.cyclewayPreference
    await db.flush()
    return profile
