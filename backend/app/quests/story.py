"""Authored quest chains: the spine under the daily board (spec §21, §85–96 phase 9).

The board is generated — a different three quests every time, none of them going
anywhere. A story arc is the opposite: a fixed order of steps, written by hand,
where finishing one is what unlocks the next. The arcs live in
`config/story_arcs.json` (the spec asks for JSON "initially") and are synced into
`story_arcs` / `story_quests` so a quest can point at the step it belongs to.

Each step still *generates*: it names a template, and the rider's own position,
profile and explored ground decide where it actually sends them. Only the title
and description are authored, so an arc reads the same in London and in Lisbon
while sending each rider somewhere real near them.

Progress is derived, never stored: a step is done when a quest carrying its id is
COMPLETED. There is no second source of truth to drift.
"""

from __future__ import annotations

import json
import uuid
from dataclasses import replace
from datetime import datetime
from functools import lru_cache
from pathlib import Path
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.characters.models import Character
from app.core.config import Settings
from app.core.llm import LLMClient
from app.core.logging import get_logger
from app.quests.models import QuestInstance, StoryArc, StoryQuest
from app.quests.templates import ANY_CLASS, template_by_id
from app.users.models import User

log = get_logger(__name__)

CONFIG_DIR = Path(__file__).parent / "config"

# A step the rider has open, accepted or is riding. One at a time: a chain read
# three-at-once is not a chain.
LIVE_STATES = ("AVAILABLE", "ACCEPTED", "ACTIVE")

COMPLETED = "COMPLETED"
OPEN = "OPEN"
READY = "READY"
LOCKED = "LOCKED"


@lru_cache
def load_arcs() -> list[dict[str, Any]]:
    """The authored arcs, checked against the templates they are built on.

    An arc that names a template nobody has, or one belonging to another class,
    would generate nothing and show the rider a step they can never take — so it
    fails here, at import, rather than silently on the board.
    """
    data = json.loads((CONFIG_DIR / "story_arcs.json").read_text())
    arcs = data["arcs"]
    templates = template_by_id()
    seen_arcs: set[str] = set()
    seen_quests: set[str] = set()
    for arc in arcs:
        assert arc["slug"] not in seen_arcs, f"duplicate arc slug {arc['slug']}"
        seen_arcs.add(arc["slug"])
        character_class = arc.get("characterClass")
        assert arc["quests"], f"{arc['slug']} has no steps"
        for index, step in enumerate(arc["quests"]):
            assert step["slug"] not in seen_quests, f"duplicate step slug {step['slug']}"
            seen_quests.add(step["slug"])
            template = templates.get(step["templateId"])
            assert template, f"{step['slug']} names a template nobody has: {step['templateId']}"
            assert not template.get("retired"), f"{step['slug']} is built on a retired template"
            # Speed is never asked for: no step may rest on an average-speed objective.
            assert not any(o.get("type") == "SUSTAIN_SPEED" for o in template.get("objectives", [])), (
                f"{step['slug']} asks for a speed"
            )
            owner = template["characterClass"]
            assert owner in (ANY_CLASS, character_class), (
                f"{step['slug']} is in a {character_class or 'open'} arc but its template is {owner}'s"
            )
            # The step before it, unless the author named something else.
            step.setdefault("prerequisiteSlug", arc["quests"][index - 1]["slug"] if index else None)
            step["sequence"] = index + 1
    return arcs


_synced = False


async def sync(db: AsyncSession) -> None:
    """Put the authored arcs in the database, by slug. Idempotent, and cheap
    enough to run on the way past: fifteen rows, once per process."""
    global _synced
    if _synced:
        return
    arcs = {a.slug: a for a in (await db.execute(select(StoryArc))).scalars()}
    steps = {q.slug: q for q in (await db.execute(select(StoryQuest))).scalars()}
    for authored in load_arcs():
        arc = arcs.get(authored["slug"])
        if arc is None:
            arc = StoryArc(slug=authored["slug"])
            db.add(arc)
        arc.title = authored["title"]
        arc.description = authored["description"]
        arc.character_class = authored.get("characterClass")
        arc.min_level = int(authored.get("minLevel", 1))
        arc.enabled = bool(authored.get("enabled", True))
        await db.flush()
        for authored_step in authored["quests"]:
            step = steps.get(authored_step["slug"])
            if step is None:
                step = StoryQuest(slug=authored_step["slug"])
                db.add(step)
            step.arc_id = arc.id
            step.sequence = authored_step["sequence"]
            step.title = authored_step["title"]
            step.description = authored_step["description"]
            step.template_id = authored_step["templateId"]
            step.prerequisite_slug = authored_step["prerequisiteSlug"]
            step.definition = authored_step.get("definition") or {}
    await db.flush()
    _synced = True


def reset_sync_cache() -> None:
    """Tests build a fresh database per case; the process-wide memo must not
    outlive it."""
    global _synced
    _synced = False


def _unlocked(arc: StoryArc, character: Character) -> bool:
    """A class arc is that class's, and measured against their class level; an
    open arc is anyone's, measured against how far they have come overall."""
    if not arc.enabled:
        return False
    if arc.character_class and arc.character_class != character.character_class:
        return False
    level = character.class_level if arc.character_class else character.overall_level
    return level >= arc.min_level


async def _quests_by_step(db: AsyncSession, user: User) -> dict[uuid.UUID, QuestInstance]:
    """The rider's quest for each story step, latest first — a step abandoned and
    offered again is the one they have now."""
    rows = (
        await db.execute(
            select(QuestInstance)
            .where(QuestInstance.user_id == user.id, QuestInstance.story_quest_id.is_not(None))
            .order_by(QuestInstance.created_at.desc())
        )
    ).scalars()
    out: dict[uuid.UUID, QuestInstance] = {}
    for quest in rows:
        # A completed attempt outranks a later abandoned one: the step is done.
        current = out.get(quest.story_quest_id)  # type: ignore[arg-type]
        if current is None or (quest.status == COMPLETED and current.status != COMPLETED):
            out[quest.story_quest_id] = quest  # type: ignore[index]
    return out


def _state(step: StoryQuest, quest: QuestInstance | None, done: set[str]) -> str:
    if quest is not None and quest.status == COMPLETED:
        return COMPLETED
    if quest is not None and quest.status in LIVE_STATES:
        return OPEN
    if step.prerequisite_slug and step.prerequisite_slug not in done:
        return LOCKED
    return READY


async def _arcs(db: AsyncSession) -> list[StoryArc]:
    await sync(db)
    return list((await db.execute(select(StoryArc).order_by(StoryArc.min_level, StoryArc.slug))).scalars())


async def progress(db: AsyncSession, user: User, character: Character) -> list[dict[str, Any]]:
    """Every arc and where the rider stands in it, for the Story tab."""
    by_step = await _quests_by_step(db, user)
    done = {
        step_slug
        for step_slug, quest in ((step.slug, by_step.get(step.id)) for arc in await _arcs(db) for step in arc.quests)
        if quest is not None and quest.status == COMPLETED
    }
    out = []
    for arc in await _arcs(db):
        steps = []
        for step in arc.quests:
            quest = by_step.get(step.id)
            steps.append(
                {
                    "slug": step.slug,
                    "sequence": step.sequence,
                    "title": step.title,
                    "description": step.description,
                    "state": _state(step, quest, done),
                    "questId": quest.id if quest is not None and quest.status != COMPLETED else None,
                }
            )
        out.append(
            {
                "slug": arc.slug,
                "title": arc.title,
                "description": arc.description,
                "characterClass": arc.character_class,
                "minLevel": arc.min_level,
                "unlocked": _unlocked(arc, character),
                "quests": steps,
            }
        )
    return out


async def due(db: AsyncSession, user: User, character: Character) -> list[StoryQuest]:
    """Every step the rider could be given next: the first unridden one of each
    unlocked arc, in arc order. Empty when a step is already open, or when
    everything unlocked is finished.

    A list rather than one step, because a step can turn out to be unplaceable
    *here* — "Somewhere to Look From" needs high ground, and a flat city has none.
    One arc waiting on suitable ground must not stop every other arc: the caller
    takes the first that can actually be built, and the waiting one comes back the
    day the rider is somewhere it works.
    """
    by_step = await _quests_by_step(db, user)
    if any(q.status in LIVE_STATES for q in by_step.values()):
        return []
    arcs = await _arcs(db)
    done = {step.slug for arc in arcs for step in arc.quests if (q := by_step.get(step.id)) and q.status == COMPLETED}
    candidates: list[StoryQuest] = []
    for arc in arcs:
        if not _unlocked(arc, character):
            continue
        for step in arc.quests:
            if step.slug in done:
                continue
            if step.prerequisite_slug and step.prerequisite_slug not in done:
                break  # the chain stops here; later steps of this arc are not due either
            candidates.append(step)
            break
    return candidates


def arc_reward(slug: str) -> dict[str, Any]:
    """What finishing an arc gives: a title to wear and a purse."""
    for arc in load_arcs():
        if arc["slug"] == slug:
            return dict(arc.get("reward") or {})
    return {}


async def standing(db: AsyncSession, user: User, quest: QuestInstance) -> dict[str, Any] | None:
    """Where finishing this step leaves the rider in its arc.

    An arc had no ending: the third step paid like the first and the arc simply
    stopped. This says how far along they are, what comes next, and — when this
    was the last step — that the arc is done and what it gave.
    """
    if quest.story_quest_id is None:
        return None
    step = await db.get(StoryQuest, quest.story_quest_id)
    arc = await db.get(StoryArc, step.arc_id) if step is not None else None
    if step is None or arc is None:
        return None
    by_step = await _quests_by_step(db, user)
    done = {s.id for s in arc.quests if (q := by_step.get(s.id)) is not None and q.status == COMPLETED}
    done.add(step.id)
    completed = len(done) == len(arc.quests)
    upcoming = next((s for s in arc.quests if s.id not in done), None)
    return {
        "arcSlug": arc.slug,
        "arcTitle": arc.title,
        "stepTitle": step.title,
        "stepsDone": len(done),
        "stepsTotal": len(arc.quests),
        "arcCompleted": completed,
        "nextTitle": upcoming.title if upcoming is not None else None,
        "reward": arc_reward(arc.slug) if completed else None,
    }


async def settle_arc(
    db: AsyncSession,
    user: User,
    character: Character | None,
    quest: QuestInstance,
    *,
    ride_id: uuid.UUID | None = None,
) -> dict[str, Any] | None:
    """Pays an arc's ending once, whichever way its last step was finished: on a
    ride, by a tap at a chest, or by the complete button. It used to be paid only
    on a ride, so an arc whose last step was a chest opened by hand ended unpaid.

    The ending is its title, its purse (outside the per-ride cap) and its XP, and
    is keyed by arc: a second completion of the same arc pays nothing. Returns
    where the step leaves the rider (`standing`), with `reward` only when this
    call paid it.
    """
    from app.economy import service as economy
    from app.progression.engine import XPLine, load_xp_rules
    from app.progression.models import RewardEvent
    from app.progression.service import award_title, grant
    from app.progression.titles import arc_title

    arc = await standing(db, user, quest)
    if arc is None or not arc["arcCompleted"] or character is None:
        return arc
    settled = (
        await db.execute(
            select(RewardEvent).where(
                RewardEvent.character_id == character.id, RewardEvent.reward_type == "ARC_SETTLED"
            )
        )
    ).scalars()
    if any((r.payload or {}).get("arc") == arc["arcSlug"] for r in settled):
        return {**arc, "reward": None}
    reward = arc_reward(arc["arcSlug"])
    db.add(
        RewardEvent(
            user_id=user.id,
            character_id=character.id,
            reward_type="ARC_SETTLED",
            ride_id=ride_id,
            payload={"arc": arc["arcSlug"], **reward},
        )
    )
    if reward.get("ac"):
        await economy.credit(
            db, user.id, int(reward["ac"]), "STORY_ARC", ride_id=ride_id, payload={"arc": arc["arcTitle"]}
        )
    bonus = int(load_xp_rules()["storyArcBonus"])
    outcome = await grant(
        db, character, [XPLine("STORY_ARC_COMPLETED", bonus, {"arc": arc["arcSlug"]})], ride_id=ride_id
    )
    # The arc's title last, so it is the one worn even when its XP brought a level title too.
    entry = arc_title(arc["arcSlug"])
    title = await award_title(db, character, entry["slug"], ride_id=ride_id) if entry else None
    await db.flush()
    return {
        **arc,
        "reward": {**reward, **({"title": title} if title else {})},
        "_xp": outcome.to_dict(),
    }


def _authored(text: str, variables: dict[str, Any]) -> str:
    """Authored text may name what the generator found ({poiName}); text that
    names nothing, or names something this template does not produce, is used as
    written rather than dropped."""
    try:
        return text.format(**variables)
    except (KeyError, IndexError, ValueError):
        return text


async def offer(
    db: AsyncSession,
    settings: Settings,
    llm: LLMClient,
    user: User,
    character: Character,
    latitude: float,
    longitude: float,
    now: datetime,
    activity: str | None = None,
) -> QuestInstance | None:
    """Put the rider's next story step on the board, here, now.

    The step names a template; where it sends them is generated from their own
    position and explored ground like any other quest. Only the words are
    authored. Story steps never expire — an arc waits for the rider, not the
    other way round.
    """
    from app.quests.generator import instantiate
    from app.quests.service import _persist, build_context

    candidates = await due(db, user, character)
    if not candidates:
        return None
    ctx = await build_context(db, settings, user, character, latitude, longitude, None, activity)

    step: StoryQuest | None = None
    generated = None
    for candidate in candidates:
        template = template_by_id().get(candidate.template_id)
        if template is None:  # load_arcs asserts this, but a row can outlive a template
            log.warning("story_template_missing", step=candidate.slug, template=candidate.template_id)
            continue
        for salt in range(8):
            generated = instantiate(template, ctx, salt=salt)
            if generated is not None:
                step = candidate
                break
        if step is not None:
            break
        # Nothing here fits this step — no POI of the kind it needs, no unexplored
        # ground within reach. That arc waits for better ground; try the next one.
        log.info("story_step_not_placeable", step=candidate.slug, template=candidate.template_id)
    if step is None or generated is None:
        return None

    generated = replace(
        generated,
        title=_authored(step.title, generated.variables),
        description=_authored(step.description, generated.variables),
        narrative={"hook": _authored(step.description, generated.variables), "completion": None, "source": "story"},
    )
    quest = _persist(user, generated, now)
    quest.story_quest_id = step.id
    quest.expires_at = None
    db.add(quest)
    await db.flush()
    await db.refresh(quest)
    log.info("story_step_offered", step=step.slug, quest_id=str(quest.id))
    return quest
