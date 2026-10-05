"""What drops (config/loot.json). Pure: an object, its source and tier, and what
the player has had in; a drop or nothing out. No clock, no database.

A drop is seeded by the thing it came from (`loot:{objectId}`), so the same
creature or chest always gives the same thing. The ledger key `drop:{objectId}`
(inventory/service.py) means it gives it once.

* A creature defeated or a chest opened may drop something; a piece never does.
  Elders and bounties are likelier, a grudge always drops, a Mossy creature is
  twice as likely.
* A drop is gear seven times in ten, a consumable otherwise. Gear's rarity is
  weighted by tier. Better finds (LOOT_FIND) raise the chance and move weight
  from Common to Rare.
* A Legendary is one of each, ever: one already had becomes the Rare of its slot.
* Pity: five finishes without a Rare or better and the next finish drops one.
"""

from __future__ import annotations

import json
import random
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Any

from app.inventory import gear

CONFIG = Path(__file__).parent / "config" / "loot.json"
SOURCES = ("MONSTER", "CHEST", "COLLECTABLE")


@lru_cache
def book() -> dict[str, Any]:
    data = json.loads(CONFIG.read_text())
    for source in SOURCES:
        assert set(data["dropChance"][source]) == {"1", "2", "3"}, source
    for tier, weights in data["rarityWeights"].items():
        assert len(weights) == len(gear.RARITIES), tier
    assert set(data["consumableWeights"]) == {"LAMP", "MAP_FRAGMENT", "REST_TOKEN", "SEALED_CHEST"}
    prices = data["stall"]["prices"]
    assert {"COMMON", "RARE", *gear.CONSUMABLES} <= set(prices), "every stall offer has a price"
    assert set(data["stall"]["consumableWeights"]) <= set(gear.CONSUMABLES)
    return data


@dataclass(frozen=True)
class Drop:
    kind: str  # GEAR or CONSUMABLE
    item_id: str | None = None
    consumable: str | None = None
    rarity: str | None = None
    # Forced by the pity rule.
    pity: bool = False

    @property
    def rare_or_better(self) -> bool:
        return self.kind == "GEAR" and self.rarity in ("RARE", "LEGENDARY")


def drop_chance(
    source: str,
    tier: int,
    *,
    bounty: bool = False,
    grudge: bool = False,
    mossy: bool = False,
    loot_find: float = 0.0,
) -> float:
    rules = book()
    chance = float(rules["dropChance"].get(source, {}).get(str(max(1, min(3, tier))), 0.0))
    if chance <= 0 and not grudge:
        return 0.0
    if bounty:
        chance = min(1.0, chance + float(rules["bountyBonus"]))
    if mossy:
        chance = chance * float(rules["mossyScale"])
    if grudge:
        chance = max(chance, float(rules["grudgeChance"]))
    chance = chance * (1 + max(0.0, loot_find))
    return min(1.0, chance)


def rarity_weights(tier: int, loot_find: float = 0.0) -> list[float]:
    """COMMON, RARE, LEGENDARY. Better finds move p×100 points from Common to Rare."""
    common, rare, legendary = (float(w) for w in book()["rarityWeights"][str(max(1, min(3, tier)))])
    moved = min(common, max(0.0, loot_find) * 100)
    return [common - moved, rare + moved, legendary]


def _gear(rng: random.Random, rarity: str, had: set[str], slot: str | None = None) -> tuple[str, str]:
    """An item of this rarity (a slot picked at random unless given); a Legendary
    already had is the Rare of its slot."""
    slot = slot or rng.choice(gear.SLOTS)
    item_id = gear.item_for(slot, rarity)
    if rarity == "LEGENDARY" and item_id in had:
        rarity = "RARE"
        item_id = gear.item_for(slot, rarity)
    return item_id, rarity


def roll(
    object_id: str,
    source: str,
    tier: int,
    *,
    bounty: bool = False,
    grudge: bool = False,
    mossy: bool = False,
    loot_find: float = 0.0,
    pity_due: bool = False,
    had_legendaries: set[str] | frozenset[str] = frozenset(),
) -> Drop | None:
    """What one finish drops, or None."""
    rules = book()
    rng = random.Random(f"loot:{object_id}")
    chance = drop_chance(source, tier, bounty=bounty, grudge=grudge, mossy=mossy, loot_find=loot_find)
    hit = rng.random() < chance
    if source == "COLLECTABLE" or (not hit and not pity_due):
        return None
    is_gear = rng.random() < float(rules["gearShare"])
    if pity_due or is_gear:
        rarity = rng.choices(gear.RARITIES, weights=rarity_weights(tier, loot_find), k=1)[0]
        if pity_due and rarity == "COMMON":
            rarity = "RARE"
        item_id, rarity = _gear(rng, rarity, set(had_legendaries))
        return Drop("GEAR", item_id=item_id, rarity=rarity, pity=pity_due)
    weights = rules["consumableWeights"]
    picked = rng.choices(list(weights), weights=[float(w) for w in weights.values()], k=1)[0]
    if picked == "SEALED_CHEST":
        rare_from = int(rules["sealedChestRareFromTier"])
        picked = "SEALED_CHEST_RARE" if tier >= rare_from else "SEALED_CHEST_COMMON"
    return Drop("CONSUMABLE", consumable=picked)


def sealed_item(key: str, rarity: str, had_legendaries: set[str] | frozenset[str] = frozenset()) -> str:
    """The item inside a sealed chest of this rarity, seeded by the ledger key."""
    rng = random.Random(f"loot:{key}")
    return _gear(rng, rarity, set(had_legendaries))[0]


def quest_reward(quest_id: str, difficulty: str | None) -> dict[str, Any] | None:
    """The item a quest offers when it is made: a Rare on a hard quest, a Legendary
    one time in four on an epic one (a Rare otherwise), nothing on the rest."""
    spec = book()["questRewards"].get(str(difficulty or ""))
    if spec is None:
        return None
    rng = random.Random(f"quest-item:{quest_id}")
    rarity = str(spec["rarity"])
    if "chance" in spec and rng.random() >= float(spec["chance"]):
        rarity = str(spec.get("fallback") or "RARE")
    item_id, _ = _gear(rng, rarity, set())
    return item_out(item_id)


def item_out(item_id: str) -> dict[str, Any]:
    """An item as a quest's reward names it."""
    entry = gear.by_id()[item_id]
    return {
        "itemId": item_id,
        "name": entry["name"],
        "rarity": entry["rarity"],
        "icon": entry["icon"],
        "slot": entry["slot"],
    }


# --- the stall ------------------------------------------------------------------


def stall_offers(user_id: str, week: str) -> list[dict[str, Any]]:
    """Four offers for the ISO week, seeded by player and week: two gear (Common or
    Rare, never Legendary) and two consumables, all different."""
    rules = book()["stall"]
    rng = random.Random(f"stall:{user_id}:{week}")
    short = week.split("-W")[-1]
    offers: list[dict[str, Any]] = []
    chosen: set[str] = set()
    rarity_weights = rules["gearRarityWeights"]
    while sum(1 for o in offers if o["kind"] == "GEAR") < int(rules["gearOffers"]):
        rarity = rng.choices(list(rarity_weights), weights=[float(w) for w in rarity_weights.values()], k=1)[0]
        item_id = gear.item_for(rng.choice(gear.SLOTS), rarity)
        if item_id in chosen:
            continue
        chosen.add(item_id)
        offers.append({"kind": "GEAR", "itemId": item_id, "rarity": rarity, "price": int(rules["prices"][rarity])})
    weights = rules["consumableWeights"]
    while sum(1 for o in offers if o["kind"] == "CONSUMABLE") < int(rules["consumableOffers"]):
        cid = rng.choices(list(weights), weights=[float(w) for w in weights.values()], k=1)[0]
        if cid in chosen:
            continue
        chosen.add(cid)
        offers.append({"kind": "CONSUMABLE", "consumable": cid, "price": int(rules["prices"][cid])})
    for i, offer in enumerate(offers):
        offer["id"] = f"w{short}-{i}"
    return offers
