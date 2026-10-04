"""The character as the fight sees it: one value, built on the server and frozen
onto a ride when it starts (docs/ROADMAP.md, Appendix D).

The phone never works out a build; it folds the same fight over the sheet the
server froze, so the two cannot disagree about one. A ride with no sheet (an
old client, an offline start) uses `neutral()`, which deals exactly what an
untrained character would.

0.6.1 carries the trade's base only. Abilities, runes and gear fill the same
fields later without changing their shape.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any

from app.characters.models import Character

SHEET_VERSION = 1

# Today's class eases, as effort: a Warrior climbs and keeps going, an Explorer
# reads new ground, a Scribe's word lands harder, a Wizard's runes are cut true
# with a looser hand.
TRADE_BASE: dict[str, dict[str, float]] = {
    "WARRIOR": {"CLIMB": 0.30, "ROAD": 0.15},
    "EXPLORER": {"GROUND": 0.30},
    "SCRIBE": {"WORD": 0.30},
    "WIZARD": {},
}
RUNE_THRESHOLD = {"WIZARD": 0.30}
DEFAULT_RUNE_THRESHOLD = 0.22
DEFAULT_RUNE_REACH_M = 1000.0


@dataclass(frozen=True)
class CharacterSheet:
    version: int = SHEET_VERSION
    character_class: str = "EXPLORER"
    overall_level: int = 1
    class_level: int = 1
    # Summed percentages per kind of effort: 0.3 is +30%.
    damage_pct: dict[str, float] = field(default_factory=dict)
    rune_threshold: float = DEFAULT_RUNE_THRESHOLD
    rune_reach_m: float = DEFAULT_RUNE_REACH_M
    coin_pct: dict[str, float] = field(default_factory=dict)
    xp_pct: dict[str, float] = field(default_factory=dict)

    @classmethod
    def neutral(cls) -> CharacterSheet:
        return cls()

    def to_dict(self) -> dict[str, Any]:
        out = asdict(self)
        return {
            "version": out["version"],
            "characterClass": out["character_class"],
            "overallLevel": out["overall_level"],
            "classLevel": out["class_level"],
            "damagePct": out["damage_pct"],
            "runeThreshold": out["rune_threshold"],
            "runeReachMeters": out["rune_reach_m"],
            "coinPct": out["coin_pct"],
            "xpPct": out["xp_pct"],
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any] | None) -> CharacterSheet:
        if not data:
            return cls.neutral()
        return cls(
            version=int(data.get("version", SHEET_VERSION)),
            character_class=str(data.get("characterClass", "EXPLORER")),
            overall_level=int(data.get("overallLevel", 1)),
            class_level=int(data.get("classLevel", 1)),
            damage_pct={k: float(v) for k, v in (data.get("damagePct") or {}).items()},
            rune_threshold=float(data.get("runeThreshold", DEFAULT_RUNE_THRESHOLD)),
            rune_reach_m=float(data.get("runeReachMeters", DEFAULT_RUNE_REACH_M)),
            coin_pct={k: float(v) for k, v in (data.get("coinPct") or {}).items()},
            xp_pct={k: float(v) for k, v in (data.get("xpPct") or {}).items()},
        )


def build_sheet(character: Character | None) -> CharacterSheet:
    if character is None:
        return CharacterSheet.neutral()
    trade = character.character_class
    return CharacterSheet(
        character_class=trade,
        overall_level=character.overall_level,
        class_level=character.class_level,
        damage_pct=dict(TRADE_BASE.get(trade, {})),
        rune_threshold=RUNE_THRESHOLD.get(trade, DEFAULT_RUNE_THRESHOLD),
    )
