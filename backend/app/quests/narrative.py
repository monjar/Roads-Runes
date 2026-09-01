"""Optional LLM narrative (stage 2). Only text is replaced; objectives and
coordinates are untouched. Falls back to the template narrative silently."""

from __future__ import annotations

from typing import Any

from app.core.llm import LLMClient
from app.quests.generator import GeneratedQuest

SYSTEM = (
    "You write short, evocative fantasy-tinged quest text for a real-world cycling "
    "exploration game set in the rider's actual surroundings. Never invent place names "
    "beyond those given, never give directions, never mention speed or racing, and keep "
    "the tone warm and adventurous. Title max 6 words; hook max 45 words; completion max 35 words."
)

SCHEMA = '{"title": string, "hook": string, "completion": string}'


async def enrich(llm: LLMClient, quest: GeneratedQuest, locality: str | None = None) -> GeneratedQuest:
    if not llm.enabled:
        return quest
    facts: dict[str, Any] = {
        "template": quest.template_id,
        "class": quest.character_class,
        "difficulty": quest.difficulty,
        "distanceKm": quest.recommended_distance_km,
        "objectives": [o.title for o in quest.objectives],
        "placeNames": [o.extra.get("poiName") for o in quest.objectives if o.extra.get("poiName")],
        "locality": locality,
    }
    result = await llm.complete_json(SYSTEM, f"Quest facts: {facts}", SCHEMA)
    if not result:
        return quest
    title = str(result.get("title") or quest.title).strip()[:120]
    hook = str(result.get("hook") or quest.description).strip()[:2000]
    completion = result.get("completion")
    quest.title = title
    quest.description = hook
    quest.narrative = {"hook": hook, "completion": completion, "source": "llm"}
    return quest
