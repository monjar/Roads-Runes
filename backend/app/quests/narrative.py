"""Quest stories. Every quest gets a paragraph: composed from its own facts when no
model is configured, written by the model when one is. Only text is replaced;
objectives and coordinates are untouched."""

from __future__ import annotations

from typing import Any

from app.core.activity import noun, verb
from app.core.llm import LLMClient
from app.quests.generator import GeneratedQuest

SYSTEM = (
    "You write the story paragraph for a quest in a real-world exploration game played by "
    "riding, running or walking in the player's actual surroundings. Write in second person, "
    "present tense, warm and a little fantastical, as if the map itself were speaking. "
    "One paragraph of 4 to 6 sentences, 70 to 110 words: open with an image, give the place its "
    "due using only the facts supplied, say what is being asked in the story's own terms, and "
    "close with an invitation to go. Use only the place, monster and object names given; never "
    "invent names, history, directions, speeds or distances, and never mention racing or other "
    "players. Match the activity (a run is a run, a walk is a walk). "
    "Title: at most 6 words, no quotation marks. Completion: at most 35 words, past tense, "
    "said when the quest is done."
)

SCHEMA = '{"title": string, "story": string, "completion": string}'

CLASS_LINES = {
    "EXPLORER": "Every street you have never travelled is a line missing from your map, and this fills a few of them in.",
    "WIZARD": "There is more to this place than the map admits; look twice, and then once more.",
    "WARRIOR": "It will ask something of your legs and your lungs. That is rather the point.",
    "SCRIBE": "Somebody ought to write this down while it is still there, and it may as well be you.",
    "ANY": "It needs no class and no preparation, only the going.",
}

EFFORT_LINES = {
    "EASY": "an easy outing, more air than effort",
    "MODERATE": "a proper outing, enough to feel it",
    "HARD": "a hard day out, and worth telling afterwards",
    "EPIC": "the kind of day you plan the week around",
}

WAYS = {"RIDE": "by bike", "RUN": "at a run", "WALK": "on foot"}


def compose_story(quest: GeneratedQuest) -> str:
    """A paragraph from the quest's own facts: the template's hook, what the map
    knows about the place, what the class makes of it, and how big a day it is."""
    variables = quest.variables or {}
    sentences = [quest.description.strip()]
    place = variables.get("poiName")
    fact = variables.get("poiFact")
    if place and fact and str(fact) not in quest.description:
        sentences.append(f"{place} is on every map and in nobody's plans. {fact}")
    thing, where = variables.get("objectName"), variables.get("objectPlace")
    if thing and where and str(thing) not in quest.description:
        sentences.append(f"The {thing} at {where} will not wait for ever; these things are gone in a few days.")
    sentences.append(CLASS_LINES.get(quest.character_class, CLASS_LINES["ANY"]))
    effort = EFFORT_LINES.get(quest.difficulty, EFFORT_LINES["MODERATE"])
    way = WAYS.get(quest.activity, "by bike")
    sentences.append(f"{way.capitalize()} it is {effort}. {verb(quest.activity)} out when you are ready.")
    return " ".join(s if s.endswith((".", "!", "?")) else f"{s}." for s in sentences if s)


def with_story(quest: GeneratedQuest) -> GeneratedQuest:
    """The composed paragraph, for a quest the model did not write."""
    if (quest.narrative or {}).get("source") == "llm":
        return quest
    story = compose_story(quest)
    quest.description = story
    quest.narrative = {**(quest.narrative or {}), "hook": story, "source": "composed"}
    return quest


async def enrich(llm: LLMClient, quest: GeneratedQuest, locality: str | None = None) -> GeneratedQuest:
    if not llm.enabled:
        return quest
    variables = quest.variables or {}
    facts: dict[str, Any] = {
        "class": quest.character_class,
        "activity": noun(quest.activity),
        "difficulty": quest.difficulty,
        "distanceKm": quest.recommended_distance_km,
        "premise": quest.description,
        "objectives": [o.title for o in quest.objectives],
        "placeNames": [o.extra.get("poiName") for o in quest.objectives if o.extra.get("poiName")],
        "whatTheMapSaysOfThePlace": variables.get("poiFact"),
        "monsterOrObject": variables.get("objectName"),
        "monsterOrObjectIsAt": variables.get("objectPlace"),
        "locality": locality,
    }
    facts = {k: v for k, v in facts.items() if v not in (None, [], "")}
    result = await llm.complete_json(SYSTEM, f"Quest facts: {facts}", SCHEMA)
    if not result:
        return quest
    story = str(result.get("story") or result.get("hook") or "").strip()
    if len(story) < 120:  # not a paragraph; keep the composed one
        return quest
    quest.title = str(result.get("title") or quest.title).strip().strip('"')[:120]
    quest.description = story[:2000]
    quest.narrative = {"hook": quest.description, "completion": result.get("completion"), "source": "llm"}
    return quest
