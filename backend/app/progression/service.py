"""Reward service: the only code path that changes XP, levels, ability points
and titles. Everything is recorded as XPEvent / RewardEvent rows."""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from app.characters import catalog
from app.characters.models import Character
from app.progression.engine import XPLine, apply_xp, load_xp_rules
from app.progression.models import RewardEvent, XPEvent


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
    old_title = character.title
    character.overall_xp = result.overall_xp
    character.class_xp = result.class_xp
    character.overall_level = result.overall_level
    character.class_level = result.class_level
    character.ability_points += result.ability_points_gained
    titles: list[str] = []
    if result.title and result.title != old_title:
        character.title = result.title
        titles.append(result.title)

    level_ups = [{"kind": lu.kind, "from": lu.from_level, "to": lu.to_level} for lu in result.level_ups]
    for lu in level_ups:
        db.add(
            RewardEvent(
                user_id=character.user_id,
                character_id=character.id,
                reward_type="LEVEL_UP",
                ride_id=ride_id,
                payload=lu,
            )
        )
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
    for title in titles:
        db.add(
            RewardEvent(
                user_id=character.user_id,
                character_id=character.id,
                reward_type="TITLE",
                ride_id=ride_id,
                payload={"title": title},
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
