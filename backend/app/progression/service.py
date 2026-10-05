"""Reward service: the only code path that changes XP, levels, ability points
and titles. Everything is recorded as XPEvent / RewardEvent rows. A level
reached is paid here too (0.7.2, progression/levels.py), through
inventory.service.pay_level, once per level."""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.characters import catalog
from app.characters.models import Character
from app.core.security import utcnow
from app.progression import levels
from app.progression import titles as title_catalogue
from app.progression.engine import XPLine, apply_xp, load_xp_rules
from app.progression.models import CharacterTitle, RewardEvent, XPEvent


@dataclass
class RewardOutcome:
    xp_awarded: int
    breakdown: list[dict[str, Any]]
    level_ups: list[dict[str, Any]]
    abilities_unlocked: list[dict[str, Any]]
    titles_unlocked: list[str]
    ability_points_gained: int = 0
    extra: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "xpAwarded": self.xp_awarded,
            "xpBreakdown": self.breakdown,
            "levelUps": self.level_ups,
            "abilitiesUnlocked": self.abilities_unlocked,
            "titlesUnlocked": self.titles_unlocked,
            "abilityPointsGained": self.ability_points_gained,
        }


async def xp_today(db: AsyncSession, character: Character) -> int:
    """XP this character has been granted since midnight UTC."""
    from datetime import datetime, time

    from sqlalchemy import func

    start = datetime.combine(utcnow().date(), time.min, tzinfo=utcnow().tzinfo)
    total = await db.scalar(
        select(func.coalesce(func.sum(XPEvent.xp), 0)).where(
            XPEvent.character_id == character.id, XPEvent.created_at >= start
        )
    )
    return int(total or 0)


async def earned_titles(db: AsyncSession, character: Character) -> list[CharacterTitle]:
    return list(
        (
            await db.execute(
                select(CharacterTitle)
                .where(CharacterTitle.character_id == character.id)
                .order_by(CharacterTitle.earned_at, CharacterTitle.slug)
            )
        ).scalars()
    )


async def award_title(
    db: AsyncSession, character: Character, slug: str, *, ride_id: uuid.UUID | None = None
) -> str | None:
    """The only way a title is earned. Once per title; worn at once unless the
    player has chosen what they wear. Returns its name when it is new."""
    entry = title_catalogue.by_slug().get(slug)
    if entry is None:
        raise KeyError(f"no such title: {slug}")
    have = await db.scalar(
        select(CharacterTitle).where(CharacterTitle.character_id == character.id, CharacterTitle.slug == slug)
    )
    if have is not None:
        return None
    db.add(CharacterTitle(user_id=character.user_id, character_id=character.id, slug=slug, earned_at=utcnow()))
    if not character.title_pinned:
        character.title = entry["name"]
    db.add(
        RewardEvent(
            user_id=character.user_id,
            character_id=character.id,
            reward_type="TITLE",
            ride_id=ride_id,
            payload={"title": entry["name"], "slug": slug, **({"arc": entry["arc"]} if entry.get("arc") else {})},
        )
    )
    await db.flush()
    return str(entry["name"])


async def wear_title(db: AsyncSession, character: Character, slug: str | None) -> None:
    """The player chooses what they wear; `None` goes back to the newest earned."""
    earned = await earned_titles(db, character)
    if slug is None:
        character.title_pinned = False
        newest = max(earned, key=lambda t: t.earned_at, default=None)
        entry = title_catalogue.by_slug().get(newest.slug) if newest else None
        character.title = entry["name"] if entry else character.title
    else:
        if slug not in {t.slug for t in earned}:
            from app.core.errors import Conflict

            raise Conflict("You haven't earned that title yet. Pick one you have.", code="TITLE_NOT_EARNED")
        character.title = title_catalogue.by_slug()[slug]["name"]
        character.title_pinned = True
    await db.flush()


async def grant(
    db: AsyncSession,
    character: Character,
    lines: list[XPLine],
    *,
    ride_id: uuid.UUID | None = None,
    quest_id: uuid.UUID | None = None,
) -> RewardOutcome:
    total = sum(line.xp for line in lines)
    rules = load_xp_rules()
    class_share = rules["classXpShare"]
    for line in lines:
        db.add(
            XPEvent(
                user_id=character.user_id,
                character_id=character.id,
                event_type=line.source,
                xp=line.xp,
                class_xp=int(round(line.xp * class_share)),
                ride_id=ride_id,
                quest_id=quest_id,
                payload=line.detail,
            )
        )
    result = apply_xp(
        character.overall_xp,
        character.class_xp,
        character.overall_level,
        character.class_level,
        total,
    )
    old_level = character.overall_level
    character.overall_xp = result.overall_xp
    character.class_xp = result.class_xp
    character.overall_level = result.overall_level
    character.class_level = result.class_level
    character.ability_points += result.ability_points_gained
    # A level title reached on the way; a title earned another way (an arc) stays
    # worn until a level brings a new one, and never once the player has chosen.
    titles: list[str] = []
    for reached in title_catalogue.level_titles_between(old_level, result.overall_level):
        name = await award_title(db, character, reached["slug"], ride_id=ride_id)
        if name:
            titles.append(name)

    level_ups: list[dict[str, Any]] = [
        {"kind": lu.kind, "from": lu.from_level, "to": lu.to_level} for lu in result.level_ups
    ]
    for lu in level_ups:
        db.add(
            RewardEvent(
                user_id=character.user_id,
                character_id=character.id,
                reward_type="LEVEL_UP",
                ride_id=ride_id,
                payload=dict(lu),
            )
        )
    # Every level pays (0.7.2): what each level reached gives, given once.
    from app.inventory import service as inventory

    for lu in level_ups:
        if lu["kind"] != "OVERALL":
            continue
        rewards: list[dict[str, Any]] = []
        for n in range(int(lu["from"]) + 1, int(lu["to"]) + 1):
            await inventory.pay_level(db, character, n)
            rewards.extend({**r, "level": n} for r in levels.rewards_for_level(n))
        lu["rewards"] = rewards
    # Abilities newly *available* at the new class level (unlocking spends a point, done by the user).
    newly_available = [
        {k: v for k, v in a.items() if k != "effects"}
        for a in catalog.abilities_for_class(character.character_class)
        if any(lu["kind"] == "CLASS" and lu["from"] < a["requiredClassLevel"] <= lu["to"] for lu in level_ups)
    ]
    for ability in newly_available:
        db.add(
            RewardEvent(
                user_id=character.user_id,
                character_id=character.id,
                reward_type="ABILITY_AVAILABLE",
                ride_id=ride_id,
                payload=ability,
            )
        )
    await db.flush()
    return RewardOutcome(
        xp_awarded=total,
        breakdown=[
            {
                "source": line.source,
                "xp": line.xp,
                **({"detail": line.detail} if line.detail else {}),
            }
            for line in lines
        ],
        level_ups=level_ups,
        abilities_unlocked=newly_available,
        titles_unlocked=titles,
        ability_points_gained=result.ability_points_gained,
    )
