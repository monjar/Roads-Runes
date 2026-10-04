"""The character as the fight sees it: one value, built on the server and frozen
onto a ride when it starts (docs/ROADMAP.md, Appendix D).

The phone never works out a build; it folds the same fight over the sheet the
server froze, so the two cannot disagree about one. A ride with no sheet (an
old client, an offline start) uses `neutral()`, which deals exactly what an
untrained character would.

0.6.1 carried the trade's base only; 0.6.2 adds the current trade's knacks
(characters/config/abilities.json). Runes and gear fill the same fields later
without changing their shape. Every field added since version 1 is optional on
the phone.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any

from app.characters.models import Character

SHEET_VERSION = 2
KINDS = ("ROAD", "GROUND", "CLIMB", "RUNE", "WORD")

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
    # Knacks that depend on the thing or the outing, applied per fight
    # (world_objects/service.py, and the phone's FightTracker).
    vs_elders_pct: float = 0.0
    late_road_pct: float = 0.0
    late_road_after_m: float = 10_000.0
    word_old_places_pct: float = 0.0

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
            "vsEldersPct": out["vs_elders_pct"],
            "lateRoadPct": out["late_road_pct"],
            "lateRoadAfterMeters": out["late_road_after_m"],
            "wordOldPlacesPct": out["word_old_places_pct"],
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
            vs_elders_pct=float(data.get("vsEldersPct", 0.0)),
            late_road_pct=float(data.get("lateRoadPct", 0.0)),
            late_road_after_m=float(data.get("lateRoadAfterMeters", 10_000.0)),
            word_old_places_pct=float(data.get("wordOldPlacesPct", 0.0)),
        )

    def pct_against(self, *, elder: bool, old_place: bool, made_good_m: float, foot: bool) -> dict[str, float]:
        """The build against one thing on one outing: the sheet's own percentages,
        plus what depends on the thing (an elder or a bounty, an old place) and on
        how far the outing went."""
        pct = dict(self.damage_pct)
        if elder and self.vs_elders_pct:
            for kind in KINDS:
                pct[kind] = pct.get(kind, 0.0) + self.vs_elders_pct
        if self.late_road_pct and made_good_m > self.late_road_after_m / (2 if foot else 1):
            pct["ROAD"] = pct.get("ROAD", 0.0) + self.late_road_pct
        if old_place and self.word_old_places_pct:
            pct["WORD"] = pct.get("WORD", 0.0) + self.word_old_places_pct
        return pct


def build_sheet(character: Character | None) -> CharacterSheet:
    if character is None:
        return CharacterSheet.neutral()
    from app.characters import catalog

    trade = character.character_class
    # The current trade's knacks only; another trade's stay learned and wait.
    own = {a["id"] for a in catalog.abilities_for_class(trade)}
    knacks = {a.ability_id: a.rank for a in character.abilities if a.ability_id in own}
    damage = dict(TRADE_BASE.get(trade, {}))
    for kind, pct in catalog.effects_by_kind(knacks, "DAMAGE_PCT").items():
        damage[kind] = round(damage.get(kind, 0.0) + pct, 4)
    xp = {
        "FIRST_CELLS": catalog.effect_total(knacks, "XP_DOUBLE_FIRST_CELLS"),
        "FAR_CELLS": catalog.effect_total(knacks, "XP_BONUS_FAR_CELLS"),
        "LONG_DISTANCE": catalog.effect_total(knacks, "XP_BONUS_LONG_DISTANCE"),
        "DISCOVERY_WITH_NOTE": catalog.effect_total(knacks, "XP_BONUS_DISCOVERY_WITH_NOTE"),
    }
    return CharacterSheet(
        version=SHEET_VERSION,
        character_class=trade,
        overall_level=character.overall_level,
        class_level=character.class_level,
        damage_pct=damage,
        rune_threshold=RUNE_THRESHOLD.get(trade, DEFAULT_RUNE_THRESHOLD),
        rune_reach_m=DEFAULT_RUNE_REACH_M + catalog.effect_total(knacks, "RUNE_REACH_M"),
        coin_pct=catalog.effects_by_kind(knacks, "COIN_PCT"),
        xp_pct={k: round(v, 4) for k, v in xp.items() if v},
        vs_elders_pct=catalog.effect_total(knacks, "VS_ELDERS_PCT"),
        late_road_pct=catalog.effect_total(knacks, "LATE_ROAD_PCT"),
        word_old_places_pct=catalog.effect_total(knacks, "WORD_OLD_PLACES_PCT"),
    )
