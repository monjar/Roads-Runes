from __future__ import annotations

import uuid
from datetime import datetime, timedelta

from sqlalchemy import delete, select, update
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
    ClassProgressOut,
    RiderProfileIO,
)
from app.core.activity import normalise
from app.core.config import Settings
from app.core.errors import Conflict, FeatureDisabled, NotFound
from app.core.feature_flags import class_enabled
from app.core.security import utcnow
from app.discoveries.models import UserDiscovery
from app.economy import service as economy
from app.economy.models import Wallet, WalletTransaction
from app.economy.rules import class_change_terms
from app.exploration.models import UserExplorationCell
from app.progression.engine import level_bounds
from app.progression.models import RewardEvent, XPEvent
from app.quests.models import QuestInstance, QuestObjective, QuestProgressEvent
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


def class_change_offer(character: Character) -> tuple[int, datetime | None]:
    """What the next class change costs, and when it is allowed (None: now).

    The first change is free: a class picked at onboarding, before a single ride,
    is a guess. After that a change costs coins and waits a day, so a class is a
    choice rather than a toggle.
    """
    terms = class_change_terms()
    cost = 0 if terms["firstFree"] and character.class_changes == 0 else int(terms["costAC"])
    next_at = None
    if character.class_changed_at is not None:
        next_at = character.class_changed_at + timedelta(hours=float(terms["cooldownHours"]))
        if next_at <= utcnow():
            next_at = None
    return cost, next_at


async def character_out(db: AsyncSession, character: Character) -> CharacterOut:
    return to_character_out(character, active_coins=await economy.balance(db, character.user_id))


def to_character_out(character: Character, *, active_coins: int = 0) -> CharacterOut:
    o_floor, o_next = level_bounds(character.overall_level, "overall")
    c_floor, c_next = level_bounds(character.class_level, "class")
    cost, next_at = class_change_offer(character)
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
        activeCoins=active_coins,
        classChanges=character.class_changes,
        nextClassChangeAt=next_at,
        classChangeCostAC=cost,
        classProgress={
            cid: ClassProgressOut(classXp=int(p.get("classXp", 0)), classLevel=int(p.get("classLevel", 1)))
            for cid, p in (character.class_progress or {}).items()
        },
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


async def change_class(db: AsyncSession, settings: Settings, character: Character, new_class: str) -> Character:
    """Switches class, keeping everything but the class itself.

    Overall level and XP, coins, discoveries and the ability points already
    earned all stay. Class XP and level are put away under the old class and the
    new class's own are taken back out (a class never played starts at 1), so
    switching back costs nothing but the fee. Quests still on offer for the old
    class are withdrawn; accepted and active ones are the rider's to finish.
    """
    if new_class not in catalog.classes():
        raise NotFound("Unknown class")
    if not class_enabled(settings, new_class):
        raise FeatureDisabled(f"Class {new_class} is not available yet")
    old_class = character.character_class
    if new_class == old_class:
        raise Conflict(f"Already a {catalog.classes()[new_class]['name']}", code="SAME_CLASS")
    cost, next_at = class_change_offer(character)
    if next_at is not None:
        raise Conflict(
            "You changed class recently; try again tomorrow",
            code="CLASS_CHANGE_COOLDOWN",
            details={"retryAt": next_at.isoformat()},
        )
    if cost:
        await economy.debit(db, character.user_id, cost, "CLASS_CHANGE", payload={"from": old_class, "to": new_class})
    progress = dict(character.class_progress or {})
    progress[old_class] = {"classXp": character.class_xp, "classLevel": character.class_level}
    restored = progress.get(new_class) or {}
    character.class_xp = int(restored.get("classXp", 0))
    character.class_level = int(restored.get("classLevel", 1))
    character.class_progress = progress
    character.character_class = new_class
    character.class_changes += 1
    character.class_changed_at = utcnow()
    await db.execute(
        update(QuestInstance)
        .where(
            QuestInstance.user_id == character.user_id,
            QuestInstance.status == "AVAILABLE",
            QuestInstance.character_class == old_class,
        )
        .values(status="EXPIRED")
    )
    await db.flush()
    await db.refresh(character)
    return character


async def reset_character(db: AsyncSession, user: User) -> None:
    """Starts the character over: the RPG side goes, the rides stay.

    Gone: the character and its abilities, every quest, the XP and coin ledgers,
    the explored cells and the places found. Kept: rides and their journal
    entries (they happened), bikes, the riding profile, friends and connections.
    """
    character = await maybe_character(db, user.id)
    if character is None:
        raise NotFound("Create a character first", code="NO_CHARACTER")
    quest_ids = select(QuestInstance.id).where(QuestInstance.user_id == user.id)
    await db.execute(delete(QuestProgressEvent).where(QuestProgressEvent.quest_id.in_(quest_ids)))
    await db.execute(delete(QuestObjective).where(QuestObjective.quest_id.in_(quest_ids)))
    await db.execute(delete(QuestInstance).where(QuestInstance.user_id == user.id))
    for model in (XPEvent, RewardEvent, WalletTransaction, Wallet, UserExplorationCell, UserDiscovery):
        await db.execute(delete(model).where(model.user_id == user.id))
    await db.delete(character)
    await db.flush()


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
        defaultActivity=normalise(profile.default_activity),
        runDistanceKm=profile.run_distance_km,
        walkDistanceKm=profile.walk_distance_km,
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
    profile.default_activity = normalise(payload.defaultActivity)
    profile.run_distance_km = payload.runDistanceKm
    profile.walk_distance_km = payload.walkDistanceKm
    await db.flush()
    return profile
