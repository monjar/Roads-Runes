"""What the inventory API says (0.7.2): gear, the bag, consumables, the stall,
what each level pays, and what a journey found. Every field is new, so every
older client simply never asks."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Literal

from pydantic import Field

from app.core.schemas import APIModel

Slot = Literal["BELL", "LANTERN", "BAG", "MAP_CASE", "KEEPSAKE"]


class GearItemOut(APIModel):
    id: uuid.UUID
    itemId: str
    name: str
    slot: str
    rarity: str
    icon: str
    text: str
    # What selling it now would pay (more with a Tinker's Satchel worn).
    sellPrice: int
    equipped: bool
    acquiredAt: datetime
    # MONSTER, BOUNTY, CHEST, QUEST, STALL or SEALED_CHEST.
    source: str


class SlotOut(APIModel):
    slot: str
    name: str
    opensAtLevel: int
    open: bool
    item: GearItemOut | None = None


class ConsumableOut(APIModel):
    id: str
    name: str
    icon: str
    text: str
    count: int = 0


class LevelRewardOut(APIModel):
    # SLOT, RUNE_SLOT, STALL, TITLE or CONSUMABLE.
    kind: str
    text: str
    icon: str
    consumable: str | None = None
    count: int | None = None
    # The gear slot a SLOT reward opens, and the level that pays it.
    slot: str | None = None
    level: int | None = None


class LevelOut(APIModel):
    level: int
    reached: bool
    rewards: list[LevelRewardOut]


class InventoryOut(APIModel):
    slots: list[SlotOut]
    bag: list[GearItemOut]
    bagSize: int
    # Always all five, with a count of 0 for none.
    consumables: list[ConsumableOut]
    finishesSinceRare: int = 0
    # Paid on this call: the levels reached before 0.7.2, once. Empty otherwise.
    levelRewardsPaid: list[LevelRewardOut] = []
    # After a sale: what it paid, and the purse after it.
    soldFor: int | None = None
    walletBalance: int | None = None


class ItemFoundOut(APIModel):
    # GEAR or CONSUMABLE.
    kind: str
    inventoryItemId: uuid.UUID | None = None
    itemId: str | None = None
    consumable: str | None = None
    name: str
    icon: str
    rarity: str | None = None
    slot: str | None = None
    # MONSTER, CHEST, QUEST or BOUNTY (and STALL for a purchase).
    source: str
    fromName: str | None = None
    # Into a full bag an item is sold on the spot, for this.
    soldOnTheSpot: bool = False
    soldFor: int | None = None


class WearIn(APIModel):
    slot: Slot
    # An item from the bag (GearItemOut.id); null takes the slot's item off.
    itemId: uuid.UUID | None = None


class UseIn(APIModel):
    """Where the player is: a map piece needs it; a sealed chest does not."""

    latitude: float | None = Field(default=None, ge=-90, le=90)
    longitude: float | None = Field(default=None, ge=-180, le=180)


class ConsumableUseOut(APIModel):
    consumable: str
    # A map piece: the tiles it revealed round the hidden place it found.
    revealedTiles: int | None = None
    placeName: str | None = None
    latitude: float | None = None
    longitude: float | None = None
    # A sealed chest: what it held.
    itemFound: ItemFoundOut | None = None
    inventory: InventoryOut


class StallOfferOut(APIModel):
    id: str
    # GEAR or CONSUMABLE.
    kind: str
    itemId: str | None = None
    consumable: str | None = None
    name: str
    rarity: str | None = None
    icon: str
    slot: str | None = None
    text: str
    price: int
    bought: bool = False


class StallOut(APIModel):
    open: bool
    opensAtLevel: int
    week: str
    resetsAt: datetime
    offers: list[StallOfferOut]
