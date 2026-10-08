"""The model-written entry (docs/ROADMAP.md 0.7.2; flag `chronicle_llm`, off).

Written by a job after a ride's summary is committed, so Journey's end never
waits on it. The model is given categories only (the activity, a distance band,
the creatures' species names, how many chests and new tiles, whether a quest was
done, the streak), never a place name. What it writes is checked before it is
kept: docs/VOICE.md's lint, two or three sentences, and no capitalised word or
number that is not in the facts. A pass is stored beside the composed entry as
`processing_result["entryWritten"] = {"lines": [...], "by": "model"}`; the
composed `entry` always stays. At most six a day per player; eight seconds and
200 tokens a try.
"""

from __future__ import annotations

import asyncio
import json
import re
import uuid
from datetime import datetime, time
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.activity import DISTANCE_SCALE, normalise
from app.core.feature_flags import is_enabled
from app.core.logging import get_logger
from app.core.security import utcnow
from app.lore import catalog as lore
from app.lore.voice import violations

log = get_logger(__name__)

DAILY_LIMIT = 6
TIMEOUT_S = 8.0
MAX_TOKENS = 200

SYSTEM = """You write the journal entry for one journey in Roads & Runes, a warm, simple fantasy game played on real rides, runs and walks. Creatures live at places on the map and are defeated by riding, exploring, climbing, rune shapes and notes.

Write two or three short sentences about this journey from the facts you are given, and nothing else.
- Plain, warm words, a little playful. Never gloomy, never a riddle, never creepy.
- Use only the facts. Never name a place, a street, a town or a person. Never add a number that is not in the facts.
- Name creatures exactly as given. Say "defeated" or "weakened"; nothing gory.
- Never praise speed. Say journey, ride, run or walk; tiles explored; chests; coins.
- No exclamation marks, unless a creature was defeated or a quest was done, and then one at most.
- No emoji, no lists, no quotation marks.
Reply with the sentences only."""

# Words that may start a sentence without being in the facts.
STARTERS = {
    "a", "after", "along", "an", "and", "another", "at", "back", "before", "both", "but", "by", "each", "even",
    "every", "for", "from", "halfway", "here", "home", "in", "it", "its", "it's", "just", "later", "more", "most",
    "no", "not", "nothing", "now", "on", "one", "out", "over", "some", "somewhere", "still", "that", "the", "then",
    "there", "this", "three", "through", "to", "today", "two", "up", "what", "when", "where", "while", "with", "you",
    "your", "you've", "yesterday", "quite", "plenty", "all", "as", "so", "few", "several", "new",
}  # fmt: skip
# Words that may stand capitalised anywhere: the game's own.
OWN_WORDS = {"I", "XP", "Journal", "Codex", "Journey's"}
NUMBER_WORDS = {
    "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    "eleven": 11, "twelve": 12,
}  # fmt: skip


def distance_band(activity: str, meters: float) -> str:
    """A category, never the number: short, medium, long or very long, for the activity."""
    km = meters / 1000 / DISTANCE_SCALE.get(normalise(activity), 1.0)
    if km < 5:
        return "short"
    if km < 20:
        return "medium"
    if km < 50:
        return "long"
    return "very long"


def _species_name(name: str | None = None, species_id: str | None = None) -> str | None:
    """A creature's kind, never what it was called that day (an elder, a grudge)."""
    sid = species_id if species_id in lore.species_by_id() else lore.species_of({"name": name})
    return str(lore.species_by_id()[sid]["name"]) if sid else None


def facts_for(activity: str, distance_m: float, summary: dict[str, Any]) -> dict[str, Any]:
    """The categories the model is given: nothing it could put a place name from."""
    world = summary.get("worldObjects") or {}
    defeated: list[str] = []
    weakened: list[str] = []
    fights = world.get("fights") or []
    for fight in fights:
        kind = _species_name(fight.get("name"), fight.get("speciesId"))
        if kind and fight.get("outcome") == "SEEN_OFF":
            defeated.append(kind)
        elif kind and fight.get("outcome") == "LOOSENED":
            weakened.append(kind)
    if not fights:
        for claimed in world.get("claimed") or []:
            kind = _species_name(claimed.get("name")) if claimed.get("kind") == "MONSTER" else None
            if kind:
                defeated.append(kind)
    chests = sum(1 for c in world.get("claimed") or [] if c.get("kind") == "CHEST")
    return {
        "activity": normalise(activity).lower(),
        "distance": distance_band(activity, distance_m),
        "creaturesDefeated": sorted(set(defeated)),
        "creaturesWeakened": sorted(set(weakened) - set(defeated)),
        "chestsOpened": chests,
        "newTiles": int(summary.get("newCells") or 0),
        "questDone": bool(summary.get("questCompleted")),
        "streakDays": int((summary.get("streak") or {}).get("days") or 0),
    }


def prompt_for(facts: dict[str, Any]) -> str:
    return "The facts of this journey:\n" + json.dumps(facts, indent=1) + "\n\nWrite the entry."


def sentences(text: str | None) -> list[str]:
    text = re.sub(r"\s+", " ", (text or "").strip())
    return [s.strip() for s in re.split(r"(?<=[.!?])\s+", text) if s.strip()]


def problems(lines: list[str], facts: dict[str, Any]) -> list[str]:
    """Why a written entry cannot be kept; empty if it can."""
    out: list[str] = []
    if not 2 <= len(lines) <= 3:
        out.append(f"{len(lines)} sentences, not two or three")
    celebration = bool(facts.get("creaturesDefeated") or facts.get("questDone"))
    names = {w for n in [*facts.get("creaturesDefeated", []), *facts.get("creaturesWeakened", [])] for w in n.split()}
    numbers = {int(facts.get(k) or 0) for k in ("chestsOpened", "newTiles", "streakDays")} - {0}
    exclamations = 0
    for line in lines:
        out += violations(line, glossary=True, celebration=celebration)
        exclamations += line.count("!")
        if len(line) > 220:
            out.append(f"a sentence too long to read: {line[:40]!r}")
        if '"' in line or "“" in line:
            out.append("quotation marks")
        words = re.findall(r"[A-Za-z][A-Za-z'’-]*", line)
        for i, word in enumerate(words):
            if word[0].isupper() and word not in names and word not in OWN_WORDS:
                if not (i == 0 and word.lower() in STARTERS):
                    out.append(f"a name that is not in the facts: {word!r}")
            if word.lower() in NUMBER_WORDS and NUMBER_WORDS[word.lower()] not in numbers:
                out.append(f"a number that is not in the facts: {word!r}")
        for number in re.findall(r"\d+(?:[.,]\d+)?", line):
            if not number.isdigit() or int(number) not in numbers:
                out.append(f"a number that is not in the facts: {number!r}")
    if exclamations > 1:
        out.append("more than one exclamation mark")
    return out


async def written_today(db: AsyncSession, user_id: uuid.UUID, now: datetime | None = None) -> int:
    """Tries today, written or not: the model is asked at most six times a day."""
    from app.rides.models import Ride

    now = now or utcnow()
    start = datetime.combine(now.date(), time.min, tzinfo=now.tzinfo)
    rows = await db.execute(select(Ride.processing_result).where(Ride.user_id == user_id, Ride.processed_at >= start))
    return sum(1 for (result,) in rows if (result or {}).get("entryTried"))


async def write_entry(db: AsyncSession, settings: Any, llm: Any, ride_id: uuid.UUID) -> dict[str, Any] | None:
    """Asks the model for the entry and keeps it if it passes. Returns what was kept."""
    from app.rides.models import Ride

    if not is_enabled(settings, "chronicle_llm") or not getattr(llm, "enabled", False) or not hasattr(llm, "write"):
        return None
    ride = await db.get(Ride, ride_id)
    result = dict((ride.processing_result if ride else None) or {})
    if ride is None or ride.status != "PROCESSED" or not result.get("entry"):
        return None
    if result.get("entryWritten") or result.get("entryTried"):
        return result.get("entryWritten")
    if await written_today(db, ride.user_id) >= DAILY_LIMIT:
        return None
    facts = facts_for(ride.activity, float(ride.distance_meters or 0), result)
    try:
        text = await asyncio.wait_for(
            llm.write(SYSTEM, prompt_for(facts), max_tokens=MAX_TOKENS, timeout=TIMEOUT_S), TIMEOUT_S + 0.5
        )
    except Exception as exc:  # noqa: BLE001 - the composed entry stands
        log.warning("entry_write_failed", ride_id=str(ride_id), error=str(exc)[:200])
        text = None
    lines = sentences(text)
    wrong = problems(lines, facts) if lines else ["nothing written"]
    result["entryTried"] = True
    if wrong:
        log.info("entry_written_refused", ride_id=str(ride_id), problems=wrong[:5])
    else:
        result["entryWritten"] = {"lines": lines, "by": "model"}
    # Reassigned, not edited in place: the JSON column does not see edits.
    ride.processing_result = result
    await db.flush()
    return result.get("entryWritten")
