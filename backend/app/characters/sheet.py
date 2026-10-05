"""The character as the fight sees it: one value, built on the server and frozen
onto a ride when it starts (docs/ROADMAP.md, Appendix D).

The phone never works out a build; it folds the same fight over the sheet the
server froze, so the two cannot disagree about one. A ride with no sheet (an
old client, an offline start) uses `neutral()`, which deals exactly what an
untrained character would.

0.6.1 carried the trade's base only; 0.6.2 adds the current trade's knacks
(characters/config/abilities.json); 0.7.0 the inscribed runes' rules; 0.7.2
(version 4) the gear worn in open slots, whose rules merge with the runes' into
the one `rules` dict (inventory/gear.py merge_rules), and better finds; 0.8.0
(version 5) the capstone skills against legends (`vs_legends_pct`, by kind, and
how far a note reaches a legend). Every field added since version 1 is optional
on the phone.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any

from app.characters.models import Character

SHEET_VERSION = 5
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
    # 0.7.0: the runes inscribed, by rank, and the rules they make (inventory/catalog.py).
    inscribed: dict[str, int] = field(default_factory=dict)
    rules: dict[str, float] = field(default_factory=dict)
    # 0.7.2: the gear worn in open slots, by slot ({"BELL": "tin-bell"}), and better
    # finds (Poacher's Pocket): a drop's chance × (1 + p), and p×100 points moved
    # from Common to Rare.
    gear: dict[str, str] = field(default_factory=dict)
    loot_find_pct: float = 0.0
    # 0.8.0: the capstone skills, against legends only: a percentage by kind of
    # effort ({"GROUND": 0.25}), and how far a note reaches a legend (Loremaster).
    vs_legends_pct: dict[str, float] = field(default_factory=dict)
    legend_word_radius_m: float = 0.0

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
            "inscribed": out["inscribed"],
            "rules": out["rules"],
            "gear": out["gear"],
            "lootFindPct": out["loot_find_pct"],
            "vsLegendsPct": out["vs_legends_pct"],
            "legendWordRadiusMeters": out["legend_word_radius_m"],
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
            inscribed={k: int(v) for k, v in (data.get("inscribed") or {}).items()},
            rules={k: float(v) for k, v in (data.get("rules") or {}).items()},
            gear={str(k): str(v) for k, v in (data.get("gear") or {}).items()},
            loot_find_pct=float(data.get("lootFindPct", 0.0)),
            vs_legends_pct={k: float(v) for k, v in (data.get("vsLegendsPct") or {}).items()},
            legend_word_radius_m=float(data.get("legendWordRadiusMeters", 0.0)),
        )

    def woken(self, rune_id: str) -> CharacterSheet:
        """The sheet with one inscribed rune a rank deeper, for the outing that woke it
        (two ranks with the Runesmith's Nail). The gear's rules stay as they were."""
        from dataclasses import replace

        from app.inventory import catalog as runes
        from app.inventory import gear

        if rune_id not in self.inscribed:
            return self
        extra = int(self.rules.get("WOKEN_EXTRA", 0))
        deeper = {**self.inscribed, rune_id: self.inscribed[rune_id] + 1 + extra}
        worn, _ = gear.split_coins(gear.rules_for(self.gear.values()))
        rules = gear.merge_rules(runes.rules_for(deeper), worn)
        reach = max(self.rune_reach_m, rules.get("RUNE_REACH_M", 0.0))
        return replace(self, inscribed=deeper, rules=rules, rune_reach_m=reach)

    def fight_cfg(self, cfg: dict[str, Any], *, first_outings_today: int = 1) -> dict[str, Any]:
        """The combat constants with what the inscribed runes and the gear change:
        the opening blow (Raido, the Drover's Bell), how far the word reaches
        (Ansuz), "does not mind" on the first outings of the day (Dagaz), a creature
        left under a tenth defeated (the Unrung Bell), what a new tile counts
        for (the Cartographer's Atlas), how near counts as met (Nauthiz) and how
        far climbing is shared (Uruz)."""
        out = dict(cfg)
        if self.rules.get("CARRIED_SCALE"):
            out["carriedFraction"] = float(cfg["carriedFraction"]) * self.rules["CARRIED_SCALE"]
        if self.rules.get("FINISH_UNDER"):
            out["finishUnder"] = float(self.rules["FINISH_UNDER"])
        if self.rules.get("GROUND_CELL_SCALE"):
            out["groundCellScale"] = float(self.rules["GROUND_CELL_SCALE"])
        if self.rules.get("WORD_RADIUS_M"):
            out["wordRadiusMeters"] = max(float(cfg["wordRadiusMeters"]), self.rules["WORD_RADIUS_M"])
        if self.rules.get("MINDS_NEUTRAL_FIRST") and first_outings_today <= self.rules["MINDS_NEUTRAL_FIRST"]:
            out["minds"] = 1.0
        if self.rules.get("ENGAGE_M"):
            out["engageMeters"] = max(float(cfg["engageMeters"]), self.rules["ENGAGE_M"])
        if self.rules.get("CLIMB_SHARED_M"):
            out["climbSharedMeters"] = float(self.rules["CLIMB_SHARED_M"])
        return out

    def foe_cfg(self, cfg: dict[str, Any], *, elder: bool, quarry: bool = False) -> dict[str, Any]:
        """The constants against one thing, after `fight_cfg`: Thurisaz makes the
        opening blow on an elder, a bounty or a legend that many times stronger, and
        Tiwaz (0.9.0) the opening blow on the journey's quarry, the creature it was
        planned for (each scales the fraction; the cap on it stays)."""
        out = cfg
        scale = float(self.rules.get("ELDER_CARRIED_SCALE", 0.0))
        if elder and scale > 0:
            out = {**out, "carriedFraction": float(out.get("carriedFraction", 0.0)) * scale}
        scale = float(self.rules.get("QUARRY_CARRIED_SCALE", 0.0))
        if quarry and scale > 0:
            out = {**out, "carriedFraction": float(out.get("carriedFraction", 0.0)) * scale}
        return out

    def legend_cfg(self, cfg: dict[str, Any], *, quarry: bool = False) -> dict[str, Any]:
        """The constants against a legend, after `fight_cfg`: an elder's, and a note
        reaching as far as the Loremaster's."""
        out = self.foe_cfg(cfg, elder=True, quarry=quarry)
        if self.legend_word_radius_m:
            out = {**out, "wordRadiusMeters": max(float(out["wordRadiusMeters"]), self.legend_word_radius_m)}
        return out

    def pct_against_legend(self, *, made_good_m: float, foot: bool) -> dict[str, float]:
        """The build against a legend: as against an elder (a legend is one, for
        Vanguard), plus the capstone skills' percentages, kind by kind."""
        pct = self.pct_against(elder=True, old_place=False, made_good_m=made_good_m, foot=foot)
        for kind, extra in self.vs_legends_pct.items():
            pct[kind] = pct.get(kind, 0.0) + extra
        return pct

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


def build_sheet(
    character: Character | None, inscribed: dict[str, int] | None = None, gear: dict[str, str] | None = None
) -> CharacterSheet:
    """The sheet from the character's trade, knacks, inscribed runes (`inscribed`,
    from inventory.service.inscribed, by rank) and worn gear (`gear`, slot to item
    id, from inventory.service.worn; only open slots count)."""
    if character is None:
        return CharacterSheet.neutral()
    from app.characters import catalog
    from app.inventory import catalog as runes
    from app.inventory import gear as gear_book

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
    inscribed = dict(inscribed or {})
    worn = gear_book.worn(gear, character.overall_level)
    gear_rules, gear_coins = gear_book.split_coins(gear_book.rules_for(worn.values()))
    rules = gear_book.merge_rules(runes.rules_for(inscribed), gear_rules)
    coin_pct = catalog.effects_by_kind(knacks, "COIN_PCT")
    for kind, pct in gear_coins.items():
        coin_pct[kind] = round(coin_pct.get(kind, 0.0) + pct, 4)
    # Gebo (0.9.0): chests give v× coins, on top of what the knacks and gear add.
    if rules.get("CHEST_COINS_SCALE"):
        coin_pct["CHEST"] = round((1 + coin_pct.get("CHEST", 0.0)) * float(rules["CHEST_COINS_SCALE"]) - 1, 4)
    reach = DEFAULT_RUNE_REACH_M + catalog.effect_total(knacks, "RUNE_REACH_M")
    threshold = RUNE_THRESHOLD.get(trade, DEFAULT_RUNE_THRESHOLD)
    return CharacterSheet(
        version=SHEET_VERSION,
        character_class=trade,
        overall_level=character.overall_level,
        class_level=character.class_level,
        damage_pct=damage,
        # The Hagstone matches as kindly as a Wizard's hand; never less kindly.
        rune_threshold=max(threshold, rules.get("RUNE_THRESHOLD", 0.0)),
        # Sowilo and the Rowan Twig set how far a cut reaches; the knacks' reach is the floor.
        rune_reach_m=max(reach, rules.get("RUNE_REACH_M", 0.0)),
        inscribed=inscribed,
        rules=rules,
        gear=worn,
        loot_find_pct=float(rules.get("LOOT_FIND", 0.0)),
        coin_pct=coin_pct,
        xp_pct={k: round(v, 4) for k, v in xp.items() if v},
        vs_elders_pct=catalog.effect_total(knacks, "VS_ELDERS_PCT"),
        late_road_pct=catalog.effect_total(knacks, "LATE_ROAD_PCT"),
        word_old_places_pct=catalog.effect_total(knacks, "WORD_OLD_PLACES_PCT"),
        vs_legends_pct=_vs_legends(knacks),
        legend_word_radius_m=catalog.effect_total(knacks, "LEGEND_WORD_RADIUS_M"),
    )


def _vs_legends(knacks: dict[str, int]) -> dict[str, float]:
    """The capstones' percentages against legends, by kind: an effect that names a
    kind is that kind's; one that names none is every kind's."""
    from app.characters import catalog

    out = catalog.effects_by_kind(knacks, "VS_LEGENDS_PCT")
    every = catalog.effect_total_kindless(knacks, "VS_LEGENDS_PCT")
    if every:
        for kind in KINDS:
            out[kind] = out.get(kind, 0.0) + every
    return {k: round(v, 4) for k, v in out.items() if v}
