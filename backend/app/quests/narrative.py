"""Quest stories. Every quest gets a paragraph: composed from its own facts when no
model is configured, written by the model when one is. Only text is replaced;
objectives and coordinates are untouched."""

from __future__ import annotations

from typing import Any

from app.core.activity import noun, verb
from app.core.llm import LLMClient
from app.lore.catalog import articled
from app.lore.voice import violations
from app.quests.generator import GeneratedQuest

SYSTEM = (
    "You write the story paragraph for a quest in a real-world exploration game played by "
    "riding, running or walking in the player's actual surroundings. The game's premise: every "
    "road was written once, by people who cut a rune where two ways met; people still use the "
    "roads but nobody reads them, and a road used and not read goes vague, which is the fog; "
    "small local things settle in the vague parts; the player reads the roads back. "
    "Write in second person, present tense, in a dry, plain, understated British voice: short "
    "declarative sentences, things want and wait and remember, the joke (if any) in the facts "
    "rather than the wording. One paragraph of 3 or 4 sentences, 50 to 80 words: give the place "
    "its due using only the facts supplied, say what is being asked, and end plainly. Use only the "
    "place, creature and object names given; never invent names, history, dates, directions, "
    "speeds or distances, and never mention racing, speed, other players or the game itself. No "
    "exclamation marks, no archaic words (thou, realm, destiny, hero, traveller), no gore, no "
    "emoji. Match the activity (a run is a run, a walk is a walk). "
    "Title: at most 6 words, no quotation marks. Completion: at most 25 words, past tense, "
    "plain, said when the quest is done."
)

SCHEMA = '{"title": string, "story": string, "completion": string}'

# One line per trade (docs/WORLD.md), for the composed paragraph.
CLASS_LINES = {
    "EXPLORER": "Every road you have not taken is still a rumour, and this turns a few of them into roads.",
    "WIZARD": "There is more to this place than the map admits. Look twice, then once more.",
    "WARRIOR": "It will ask something of your legs and your lungs. That is rather the point.",
    "SCRIBE": "Somebody ought to write this down while it is still there, and it may as well be you.",
    "ANY": "It needs no trade and no preparation, only the going.",
}

EFFORT_LINES = {
    "EASY": "an easy outing, more air than effort",
    "MODERATE": "a proper outing, enough to feel it",
    "HARD": "a hard day out, and worth telling afterwards",
    "EPIC": "the kind of day you plan the week around",
}

WAYS = {"RIDE": "by bike", "RUN": "at a run", "WALK": "on foot"}


def is_puzzle(quest: GeneratedQuest) -> bool:
    """A riddle withholds its place: nothing written about the quest may name it."""
    return any((o.extra or {}).get("hidden") for o in quest.objectives)


def compose_story(quest: GeneratedQuest) -> str:
    """A paragraph from the quest's own facts: the template's hook, what the map
    knows about the place, what the class makes of it, and how big a day it is."""
    variables = quest.variables or {}
    sentences = [quest.description.strip()]
    place = None if is_puzzle(quest) else variables.get("poiName")
    fact = variables.get("poiFact")
    if place and fact and str(fact) not in quest.description:
        sentences.append(f"{place} is on every map and in nobody's plans. {fact}")
    thing, where = variables.get("objectName"), variables.get("objectPlace")
    if thing and where and str(thing) not in quest.description:
        line = f"The {thing} at {where} will not wait for ever; these things are gone in a few days."
        sentences.append(articled(line, str(thing)))
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
        # A riddle's place is never named, not even to the model.
        "placeNames": []
        if is_puzzle(quest)
        else [o.extra.get("poiName") for o in quest.objectives if o.extra.get("poiName")],
        "whatTheMapSaysOfThePlace": None if is_puzzle(quest) else variables.get("poiFact"),
        "monsterOrObject": variables.get("objectName"),
        "monsterOrObjectIsAt": variables.get("objectPlace"),
        "locality": locality,
    }
    facts = {k: v for k, v in facts.items() if v not in (None, [], "")}
    result = await llm.complete_json(SYSTEM, f"Quest facts: {facts}", SCHEMA)
    if not result:
        return quest
    story = str(result.get("story") or result.get("hook") or "").strip()
    title = str(result.get("title") or quest.title).strip().strip('"')[:120]
    completion = str(result.get("completion") or "").strip() or None
    if len(story) < 120:  # not a paragraph; keep the composed one
        return quest
    if violations(story) or violations(title) or (completion and violations(completion)):
        # A model line that breaks the voice is not used; the composed one is.
        return quest
    quest.title = title
    quest.description = story[:2000]
    narrative = dict(quest.narrative or {})
    # Merge, never replace: the giver, and an authored completion line, stay.
    narrative.update({"hook": quest.description, "source": "llm"})
    if not narrative.get("completion"):
        narrative["completion"] = completion
    quest.narrative = narrative
    return quest
