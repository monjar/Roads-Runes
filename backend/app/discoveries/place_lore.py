"""Place lore from Wikidata (0.9.0, flag `place_lore`, off by default).

At tile import, never per journey: the places with a `wikidata` tag get Wikidata's
one-line English description, fetched in one batch of at most 50 a tile with a
5 s timeout, and keep it in their tags as `lore` only if it passes `lore_ok`: at
most 120 characters, no number, and no capitalised word that is not already in
the place's own name or tags (so it claims nothing new about a real place), and
nothing about a place the game must leave alone. The app shows it as
"From Wikidata: …". A failure here never fails the import.
"""

from __future__ import annotations

import re
from collections.abc import Awaitable, Callable
from typing import Any

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.logging import get_logger
from app.discoveries.models import Discovery
from app.discoveries.sensitivity import is_sensitive

log = get_logger(__name__)

LoreFetcher = Callable[[list[str]], Awaitable[dict[str, str]]]
CAP_PER_TILE = 50
TIMEOUT_S = 5.0
MAX_CHARS = 120
WIKIDATA_API = "https://www.wikidata.org/w/api.php"
USER_AGENT = "RoadsAndRunes-backend/0.1 (place lore)"
_QID = re.compile(r"^Q\d+$")
_WORD = re.compile(r"[^\W\d_]+(?:['’][^\W\d_]+)*")


def _words(text: str) -> set[str]:
    return {w.lower() for w in _WORD.findall(text)}


def lore_ok(text: str | None, name: str, tags: dict[str, Any] | None) -> bool:
    """Whether a description may be shown for this place."""
    tags = tags or {}
    text = (text or "").strip()
    if not text or len(text) > MAX_CHARS:
        return False
    if any(ch.isdigit() for ch in text):
        return False
    if is_sensitive(name, tags) or is_sensitive(text, {}):
        return False
    known = _words(name)
    for key, value in tags.items():
        if key == "lore":
            continue
        known |= _words(str(value))
    return all(w.lower() in known for w in _WORD.findall(text) if w[0].isupper())


def wikidata_fetcher() -> LoreFetcher:
    """English descriptions for up to 50 entities in one request."""

    async def fetch(ids: list[str]) -> dict[str, str]:
        if not ids:
            return {}
        async with httpx.AsyncClient(timeout=TIMEOUT_S, headers={"User-Agent": USER_AGENT}) as client:
            response = await client.get(
                WIKIDATA_API,
                params={
                    "action": "wbgetentities",
                    "ids": "|".join(ids[:CAP_PER_TILE]),
                    "props": "descriptions",
                    "languages": "en",
                    "format": "json",
                },
            )
            response.raise_for_status()
            entities = response.json().get("entities") or {}
        out: dict[str, str] = {}
        for qid, entity in entities.items():
            value = (((entity or {}).get("descriptions") or {}).get("en") or {}).get("value")
            if value:
                out[str(qid)] = str(value)
        return out

    return fetch


async def add_lore(db: AsyncSession, osm_ids: list[str], fetch: LoreFetcher) -> int:
    """Gives the tile's places with a wikidata tag and no lore yet their line, when it
    passes. Returns how many were given one."""
    if not osm_ids:
        return 0
    rows: list[Discovery] = []
    for start in range(0, len(osm_ids), 500):
        chunk = osm_ids[start : start + 500]
        rows += list((await db.execute(select(Discovery).where(Discovery.osm_id.in_(chunk)))).scalars())
    wanted: dict[str, list[Discovery]] = {}
    for row in rows:
        tags = row.tags or {}
        qid = str(tags.get("wikidata") or "").strip()
        if not _QID.match(qid) or tags.get("lore") or is_sensitive(row.name, tags):
            continue
        if qid not in wanted and len(wanted) >= CAP_PER_TILE:
            continue
        wanted.setdefault(qid, []).append(row)
    if not wanted:
        return 0
    try:
        found = await fetch(sorted(wanted))
    except Exception as exc:  # noqa: BLE001 - lore is a nicety, never a failed import
        log.warning("place_lore_failed", error=str(exc)[:200])
        return 0
    given = 0
    for qid, places in wanted.items():
        text = (found.get(qid) or "").strip()
        for row in places:
            if lore_ok(text, row.name, row.tags):
                row.tags = {**(row.tags or {}), "lore": text}
                given += 1
    await db.flush()
    return given
