> **Superseded where it disagrees with [docs/ROADMAP.md](../../../ROADMAP.md).** This is one of five design drafts written independently on 2026-10-01, before an adversarial review. Known differences: coins, not pence; Hollow Sentry, not Hollow Knight; five cast (Ada Pym, Tam Hurdle, Enid Sallow, Walter Garth, Nell Foss), not six quest-givers; "the road", not "passage"; the old ones are the Blank, the Drowned Lane, the Long Drag, the Slow Coach and the Worn Stone, not the Bailiff; the build is runes, gear and abilities, not attributes plus fifteen systems. Read it for the written lines and the reasoning, not as the specification.

# B. Character systems — "what you carry and what you have done"

## 1. The idea in five lines

1. Five attributes (Legs, Lungs, Eyes, Hand, Ink), one per damage kind, that grow mostly from what the trace shows you did; none reads speed.
2. Runes become the build: found stones rank up from duplicates, a few are inscribed, and walking an inscribed rune's shape wakes it for the outing.
3. Five gear slots, 30 written items in four rarities, four consumables, and a shop that absorbs the purse.
4. All 16 abilities do something in numbers, scoped to the current class, with a capstone each; titles become a collection you choose from.
5. Every one of 50 levels pays something, and one frozen `CharacterSheet` per outing carries all of it into designer C's fight maths.

Assumed of neighbours: C owns HP, base damage per kind and loot tables per source, and consumes my sheet. A writes rune and item lore beyond the samples here. D draws every glyph, sheet and screen. E decides which quests carry item and title rewards.

## 2. The design

### Attributes

`attr = 1 + classBase + deed + points + gear`, where `deed = min(20, floor(sqrt(x / k)))`.

| Attribute | Deed counter `x` | k | Feeds damage | Also |
|---|---|---|---|---|
| Legs | km ÷ `DISTANCE_SCALE` (a run km counts 2.9, a walk km 5) | 8 | distance | +1%/pt coins per km |
| Lungs | metres climbed | 150 | climb | wounded monsters recover 1%/pt less between outings (if C has recovery) |
| Eyes | new cells | 15 | new ground | loot find +0.5%/pt; +1 reveal ring at 10/20/30 |
| Hand | rune stones found + 3 × runes traced | 2 | traced runes | +1%/pt chest coins |
| Ink | places found + 2 × notes left | 4 | stops | +1%/pt discovery XP |

- **Class base:** Explorer Eyes +2; Wizard Hand +2; Warrior Legs +1 and Lungs +1; Scribe Ink +2.
- **Points:** one per even overall level (25 by level 50), at most 12 in any one attribute.
- **Multiplier per damage kind:** `1 + 0.03 × attr + Σ%(runes, gear, abilities)`, hard cap ×3.0. Percentages add; they never multiply each other.
- **PACE:** there is no speed kind in the sheet. Nothing here touches PACE or SUSTAIN_SPEED, which demotes them by neglect.

Worked example: a Warrior putting points into Lungs, three outings a week of about 20 km and 250 m. Outing counts assume roughly 1,100 XP an outing, which is my estimate.

| Level | Outings | Lungs (base + deed + points + gear) | Climb multiplier |
|---|---|---|---|
| 1 | 0 | 2 | ×1.06 |
| 10 | ~6 | 2+3+5+1 = 11 | 1.33 + Uruz I 8% = ×1.41 |
| 25 | ~31 | 2+7+12+2 = 23 | 1.69 + Uruz III 16% + gear 8% + Mountainborn 10% = ×2.03 |
| 50 | ~120 | 2+14+12+3 = 31 | 1.93 + Uruz V 24% + gear 12% + 10% = ×2.39 |

The same character's Eyes at 50 is about 12 (×1.36). A flat-city Warrior of the same level has Lungs near 20 and Legs near 31.

### Runes as the build

- **Holding and rank.** The first find gives rank I. Every later find of that rune still pays the 10 coins and adds a shard.
  - Rank-up costs 1 / 2 / 3 / 4 shards and 40 / 100 / 250 / 500 coins (890 a rune, 21,360 for all 24).
  - Rank cap is III, rising to IV at level 25 and V at level 43.
  - A find at max rank pays 40 coins.
- **Inscription slots:** five, at levels 1, 7, 15, 27, 41. Only inscribed runes act. Changing them is free but refused while a ride is recording. An empty slot auto-fills with the highest-ranked rune, so old clients still benefit.
- **Pity.** At spawn the piece is weighted: unheld ×4, held ×1, max rank ×0.25. After four duplicate finds in a row (read from the ledger) the next rune stone placed is forced to an unheld rune. Levels 11, 19, 33 and 45 grant "a rune you do not hold".
- **Milled Coins** stay a plain set. Their duplicates pay face value: 5 / 10 / 20 / 40.

Effect = rank I value, rising linearly to rank V:

| Rune | Family | Effect I → V | Walking form |
|---|---|---|---|
| Raido | Edge | distance damage +8% → +24% | LOOP |
| Uruz | Edge | climb damage +8 → +24% | not yet |
| Kenaz | Sight | new-ground damage +4 → +12%; reveal rings beside the track 1 / 2 / 3 at I / III / V | TRIANGLE |
| Ansuz | Edge | stop damage +8 → +24% | R4 |
| Sowilo | Edge | rune damage +10 → +30% | ZIGZAG |
| Wunjo | Condition | +6 → +18% damage on ground already EXPLORED | R4 |
| Dagaz | Condition | +6 → +18% all damage on the first outing of the day | R4 (bowtie) |
| Fehu | Yield | monster and chest coins +6 → +18%, before the cap | not yet |
| Gebo | Yield | loot find +5 → +15% | not yet |
| Nauthiz | Keep | a monster left under 4 → 12% HP falls | not yet |
| Eihwaz | Keep | wounded monsters recover 10 → 50% less | not yet |
| Algiz | Keep | a wounded monster stays +1 / +2 / +3 days | not yet |
| Tiwaz | Edge | +8 → +24% against bounty and tier 3 | not yet |
| Ehwaz / Mannaz | Condition | +5 → +15% all damage on a ride / on foot | not yet |

To be numbered in the same families:
- Thurisaz — one heavy hit.
- Hagalaz — damage spread to neighbouring monsters.
- Isa — stops count sooner.
- Jera — first outing of the week.
- Perthro — chest tier up.
- Berkano — NATURE places.
- Laguz — things anchored at water.
- Ingwaz — SQUARE form, set and region bonus.
- Othala — held ground.

**Where glyph and trace meet.** Each rune may have a walking form, a shape the matcher already knows.
- Walk the form of an inscribed rune anywhere on the outing (existing 300–4000 m, threshold 0.22, Wizard 0.30) and it wakes.
- A woken rune counts two ranks higher for that outing and lands one rune-damage hit on every monster within 1 km of the figure.
- One wake per outing.
- A monster whose RUNE weakness is the form of an inscribed rune takes ×1.5 rune damage.
- R1 uses only the five existing shapes, so the matcher and fixtures are untouched. True glyph templates (bowtie Dagaz, hooked Laguz) are R4.

Voice sample for the inscribe screen: "Sowilo, the sun-rune. Walk it as a zigzag and it wakes. Asleep, it does nothing at all."

### Gear

Five slots: Bell (level 1), Lamp (3), Bag (5), Map case (13), Keepsake (21). The bike is not gear; it stays a routing input.

Rarities are Plain, Good, Old and Storied. Good and Old carry one rolled secondary line from a pool of ten. Storied is unique, with one copy and a fixed rule; a second Storied drop becomes an Old item.

| # | Item | Slot, rarity | Effect | Line |
|---|---|---|---|---|
| 1 | Tin Bell | Bell, Plain | +1 Legs | "Sounds like a spoon in a mug. Things move anyway." |
| 2 | Brass Ping | Bell, Plain | +4% distance damage | "One note. It has never needed another." |
| 3 | Drover's Bell | Bell, Good | +2 Legs; +6% damage on known ground | "Cattle used to follow it. Some things still do." |
| 4 | Ferryman's Bell | Bell, Good | +8% against anything anchored at water | "Rung for a crossing. The water remembers the tune." |
| 5 | Curfew Bell | Bell, Old | +3 Ink; +15% against bounties | "It rang the town indoors once. The monsters have not forgotten." |
| 6 | The Bell That Was Not Rung | Bell, Storied | +3 Hand; a monster left under 8% falls | "Hung eighty years and never struck. It is saving something up." |
| 7 | Stub of Candle | Lamp, Plain | +1 Eyes | "Lights about as far as your own feet. It is a start." |
| 8 | Bottle Lamp | Lamp, Plain | +4% new-ground damage | "A jar, a wick, and somebody's confidence." |
| 9 | Bull's-eye Lantern | Lamp, Good | +2 Eyes; +1 reveal ring | "Shows one thing at a time. Clearly." |
| 10 | Lamplighter's Pole | Lamp, Good | +8% new-ground damage; +10% discovery XP | "Reaches the lamps nobody else bothers with." |
| 11 | Storm Lantern | Lamp, Old | +3 Eyes; +12% new-ground damage | "It has been out in worse than this. It says so, in dents." |
| 12 | Wrecker's Light | Lamp, Storied | +3 Eyes; chests open from 150 m of the track | "Brought ships in on the wrong rocks. It finds chests now, and is sorry." |
| 13 | Bread Sack | Bag, Plain | +2 consumable stack size | "Smells of the last thing it carried. Always will." |
| 14 | Saddle Roll | Bag, Plain | +4% coins per km | "Holds less than you hoped and more than you packed." |
| 15 | Tinker's Satchel | Bag, Good | +8% chest coins; sells for +20% | "Every pocket has something in it. None of it is yours yet." |
| 16 | Postbag | Bag, Good | +2 Legs; +6% distance damage | "Still wants to be somewhere by noon." |
| 17 | Poacher's Pocket | Bag, Old | +2 Eyes; +10% loot find | "Sewn inside the coat. Nobody has asked what it was for." |
| 18 | The Beadle's Purse | Bag, Storied | per-outing coin cap 800 → 1,000; +10% monster coins | "It held the parish fines. It still likes to be full." |
| 19 | Folded Sheet | Map case, Plain | +1 Ink | "Out of date on the day it was printed." |
| 20 | Oilcloth Wrap | Map case, Plain | +4% stop damage | "Keeps the rain off the paper. Not off you." |
| 21 | Surveyor's Tube | Map case, Good | +2 Ink; map fragments reveal half as much again | "Brass ends, straight lines, firm opinions." |
| 22 | Pedlar's Road-book | Map case, Good | +8% stop damage; +10% discovery XP | "Lists every inn for forty miles. Half are still there." |
| 23 | Tithe Map | Map case, Old | +3 Ink; +12% damage on EXPLORED ground | "Says who owed what for every field. The fields have not paid." |
| 24 | The Blank Quarter | Map case, Storied | +3 Eyes; each new cell counts 1.25 for damage | "One corner was never drawn. The cartographer said he would go back." |
| 25 | Hagstone | Keepsake, Plain | +1 Hand | "A stone with a hole in it. You are meant to look through." |
| 26 | Horse Brass | Keepsake, Plain | +1 Lungs | "Polished by a hundred hills. None of them were yours." |
| 27 | Rowan Twig | Keepsake, Good | +2 Hand; +8% rune damage | "Tied with red thread, as it should be." |
| 28 | Hill-farmer's Bootlace | Keepsake, Good | +2 Lungs; +8% climb damage | "Has been up there more often than you have." |
| 29 | Lych-gate Nail | Keepsake, Old | +3 Hand; a woken rune counts three ranks higher, not two | "Iron, hand-cut, and bent from doing its job." |
| 30 | The Last Milestone's Chip | Keepsake, Storied | +2 to all five attributes | "The number has worn off. The distance has not." |

**Consumables** (stack limits 3 / 5 / 2 / 5):
- **Lure Bell**, 50 coins — the existing lure, finally given a button. "Ring it and see what comes. Something always does."
- **Map Fragment**, 90 coins — calls `exploration.reveal(via="ITEM")` on a k=2 disk (19 cells) round the nearest unknown place within 3 km. "A corner of somebody else's map. They did not need it back."
- **Rest Token**, 200 coins, and free at the 7-day streak — spent automatically when exactly one day is missed. "Good for one day of doing nothing at all."
- **Sealed Chest**, drop only — opened at a standstill; rolls one item of a stated minimum rarity. "Shut with wax and somebody's initials. Open it sitting down."

**Drops.** C owns the table per source. I supply `loot.roll(source, tier, find_pct, seed)`, seeded from the object's seed so a retry gives the same answer. Starting weights:

| Source | Chance of a drop | What |
|---|---|---|
| Chest tier 1 | 15% | Plain item |
| Chest tier 2 | 35% | Plain 60 / Good 35 / Old 5 |
| Chest tier 3 | always | Good 60 / Old 35 / Storied 5 |
| Monster tier 1 / 2 | 10% / 30% | as chest tier 1 / 2 |
| Monster tier 3 | 50% | Sealed Chest |

Loot find shifts weight one rarity up.

**Limits and selling.** 30 gear pieces. A drop into a full bag is sold on the spot and the reckoning says so. Selling pays 15 / 40 / 100; Storied cannot be sold. There is no second currency and no crafting.

**Quest rewards.** `quests/generator.py:493` fills `items` for HARD and EPIC quests (one Good, or one Old on EPIC), and gives EASY and MODERATE a 20% consumable. Arc final steps fill `titles`. The reward is shown on the board before the outing and granted on completion.

### Abilities made real

Today only Trail Sense's POI radius (`quests/service.py:176-180`) and Mountainborn's template (`catalog.py:46` → `quests/service.py:212`) are read. The other fourteen do nothing.

"Sheet" below means the effect is folded into the sheet by `characters/sheet.py`, so it needs no bespoke reader. **R** marks abilities redefined because the old promise touched routing or needs other players.

| Ability (max rank) | Effect per rank | Read at |
|---|---|---|
| Trail Sense (3) | POI radius +15% (kept); new-ground damage +5%; route key dropped | existing; sheet |
| Cartographer (3) | reveal +1 ring round new cells | `processing.py` after `record_traversal` (:265) → `exploration.reveal(via="ABILITY")` |
| Pathfinder (2) **R** | first 10 / 20 new cells of an outing deal double | sheet |
| Far Wanderer (3) | +10% XP on new cells over 5 km from the start | `engine.compute_ride_xp` via new `xp_pct` |
| Arcane Sight (3) **R** | +20% chance a spawned piece is a rune stone | `spawner.py:180` |
| Foresight (2) **R** | rune damage +6%; rank 2 shows a monster's drop beforehand | sheet; `to_out` |
| Ley Finder (2) **R** | rune reach 1 km → 1.5 / 2 km | sheet |
| Second Chance (1) | one missed optional objective counts | `processing._reward_for_ride` |
| Second Wind (2) **R** | distance damage in the last third of an outing +10% | sheet |
| Mountainborn (1) | template (kept); climb damage +10% | existing; sheet |
| Endurance (3) | +10% on the LONG_DISTANCE_ADVENTURE line | `engine.py:183-187` |
| Vanguard (2) **R** | +10% against tier 3 and bounties | sheet |
| Archivist (2) **R** | stop damage +8% | sheet |
| Rumour (3) **R** | loot find +5% | loot roll |
| Chronicler (1) **R** | discovery XP +20% on an outing with a note | `compute_ride_xp` |
| Historian (2) | stop damage +15% at HISTORICAL / CULTURAL / LANDMARK places; unlocks A's deeper place entry | sheet |

**Capstones** at class level 20, costing 2 points:
- Explorer, *Edge of the Map* — each 10 new cells adds +5% to all damage that outing, to +25%.
- Wizard, *Ley Line* — two wakes per outing, reaching 3 km.
- Warrior, *The Iron Hours* — climb past the first 300 m counts double.
- Scribe, *The Long Entry* — a noted stop hits every monster within 1.5 km.

**Fixes:**
- `ability_map` (`characters/service.py:61`) returns only the current class's rows, so old-class abilities stop acting.
- Points become derived per class: `ability_points_between(1, class_level) − ranks spent in this class`. That ends the farmable shared pool; the `ability_points` column is kept and written for old clients.
- Explorer's tree comes to 11 ranks + 2 = 13 against 12 points, so it must choose. The others get +1 max rank on their first two abilities (10 + 2 = 12).
- Respec costs 100 coins.
- Descriptions are rewritten with their numbers, and `AbilityOut` gains optional `rankText[]`.

### Titles

- **Table and writer.** `character_titles`, written only by `progression.service.award_title()`. `grant()` and the arc branch at `processing.py:391-401` both call it.
- **The overwrite fix.** A new title is worn automatically only until the player picks one (`title_pinned`). After that, nothing overwrites it. This fixes level titles replacing arc titles.
- **Collisions.** Level titles are renamed; abilities keep their names: 10 Wayfarer (was Pathfinder), 20 Roadwise (was Far Wanderer), 30 Rune Reader (was Cartographer).
- **Sources:** levels (7), arcs (5), deeds, sets, and C's bosses.

New deed titles:
- Keeper of Six — all six Old Runes held.
- Moneyer — the Milled Coins set. "Counted them twice. Still four."
- Hill Tax Paid — 10,000 m climbed.
- Shoe Leather — 100 km on foot.
- Rat-catcher — 25 monsters beaten.
- Regular — a 30-day streak.
- Fog-lifter — 1,000 cells.
- Sure Hand — 10 runes woken.
- Diarist — 50 notes.

### Fifty levels

Every even level gives +1 attribute point. Titles land at 10, 20, 30 (as renamed), 40 Worldwalker and 50 Legend of the Roads. Odd levels:

| Level | Pays | Level | Pays |
|---|---|---|---|
| 1 | Novice; slot I; Raido I; Bell slot + Tin Bell | 27 | inscription slot IV |
| 3 | Lamp slot + Stub of Candle | 29 | Sealed Chest (Old or better) |
| 5 | Wanderer; Bag slot + Bread Sack | 31 | route ink "Oak Gall" |
| 7 | inscription slot II | 33 | a rune you do not hold |
| 9 | the shop opens; one Lure Bell | 35 | bag holds 36; one Rest Token |
| 11 | a rune you do not hold | 37 | Sealed Chest (Old or better) |
| 13 | Map-case slot + Folded Sheet; one Map Fragment | 39 | a second saved loadout |
| 15 | inscription slot III | 41 | inscription slot V |
| 17 | re-forging opens | 43 | rune rank cap V |
| 19 | a rune you do not hold | 45 | a rune you do not hold |
| 21 | Keepsake slot + Hagstone | 47 | Sealed Chest (Storied) |
| 23 | Sealed Chest (Good or better) | 49 | crest frame "Gilt Edge" |
| 25 | rune rank cap IV | | |

### Economy

**Income, three outings a week, from `ac_rules.json`:**

| Per outing | Coins |
|---|---|
| 20 km at 2/km | 40 |
| ~15 new cells | 15 |
| MODERATE quest | 40 |
| two chests (weighted mean 40) | 80 |
| 0.7 monsters (weighted mean 100) | 70 |
| three pieces | 30 |
| streak | 5 |
| **Total** | **~280** |

- A week is about 840, plus a bounty (~100) and amortised set and arc purses (~45): **about 1,000 a week**.
- The ride counts (cells, chests, monsters per outing) are my assumptions, not measured.
- The 800 cap is not reached.

**Sinks at steady state:**

| Sink | Per week |
|---|---|
| one rune rank (mean 222) | 220 |
| shop gear, a Good piece a fortnight (Plain 120, Good 300, Old 750) | 150 |
| consumables (bell 50, fragment 90, token 200 a fortnight) | 240 |
| re-forging a secondary line (100 / 250 / 500) | 150 |
| cosmetics | 150 |
| respec and class change | 25 |
| **Total** | **~935** |

- Cosmetics are six route inks at 400, five map markers at 300 and four crest frames at 600: 6,300 in all.
- Total sink stock is about 21,000 (runes) + 6,300 (cosmetics) + gear: over a year of income, so the purse never idles.
- The shop shows four gear offers seeded by `user|ISO week`, computed on read, so no scheduler is needed. It never sells XP or Storied items.

**Caps.** Keep 3,000 XP and 800 coins.
- Add `caps.exemptKinds` (STORY_ARC, SET_COMPLETED, streak milestones, C's boss purse) and `caps.exemptSources` for XP, so large one-off payouts are not scaled away and do not shrink the rest. `apply_cap` (`economy/rules.py:85`) scales only the remainder.
- Yield percentages apply before the cap, so builds cannot break it.
- Enforce the dormant `perDayTotal: 8000` on the tap-claim path (`world_objects/router.py:95`).
- Fix the XP cap's `int()` remainder (`engine.py:233`).

## 3. How it attaches

Paths are under `backend/app/` unless shown.

### The interface to C

A pure builder in `characters/sheet.py`:

```python
@dataclass(frozen=True)
class CharacterSheet:
    version: int
    character_class: str
    overall_level: int
    class_level: int
    attributes: dict[str, int]          # LEGS LUNGS EYES HAND INK, totals
    damage_pct: dict[str, float]        # DISTANCE CLIMB EXPLORE RUNE STOP, already summed
    conditional: list[dict]             # {"when": {...}, "kind": "*"|kind, "pct": float}
    inscribed: list[dict]               # {"rune", "rank", "trace"}
    execute_pct: float
    recover_pct: float
    rune_reach_m: float
    wakes: int
    coin_pct: dict[str, float]
    xp_pct: dict[str, float]
    loot_find_pct: float
    reveal_rings: int
    chest_reach_m: float
    coin_cap: int
```

- **Frozen at ride start.** `rides/service.py:65 create_ride` builds the sheet and stores it in a new `rides.loadout_snapshot`. `RideOut` returns it as optional `loadout`.
- **Start-time conditions are baked in.** "First outing of the day" and similar are resolved into the snapshot.
- **The phone never computes the sheet.** It mirrors only C's damage maths over the snapshot. A shared fixture `tests/fixtures/sheets.json` is copied to the Core tests, like `rune_tracks.json`.
- **Edits while riding.** Loadout edits return 409 `LOADOUT_LOCKED` while a ride is RECORDING.
- **Old rides.** A null snapshot means `CharacterSheet.neutral()`, which is today's behaviour.

### Migration `0008_character_systems`

Guarded with the inspector check, as in `0006_streaks.py`. Models are imported in `db/models.py`.

| Table or column | Holds | Single writer |
|---|---|---|
| `character_deeds` | lifetime counters. Its own table because reset keeps rides. Filled lazily from rides and cells on first read. | `characters/deeds.record()` from `process_ride` |
| `characters.attributes`, `.title_pinned`, `.active_title_id`, `.cosmetics` | spent points, title choice, cosmetics | `characters/service` |
| `rune_holdings` (unique user, rune) | rank, shards. Backfilled from CLAIMED `world_objects` with `setId == "RUNES"`. | `inventory/service.grant_rune`, `rank_up_rune` |
| `inventory_items` | item id, kind, quantity, rolled line, status | `inventory/service.grant_item`, `consume`, `sell`, `reforge` |
| `item_events` | immutable ledger for all of the above: event, source, ride, quest and object ids, payload | same service |
| `loadouts` | gear by slot, inscriptions | `inventory/service.set_loadout` |
| `character_titles` | title id, source. Backfilled from `reward_events` TITLE rows. | `progression.service.award_title` |
| `rides.loadout_snapshot` | the frozen sheet | `create_ride` |

Level rewards are paid inside `grant()` and recorded as `RewardEvent(reward_type="LEVEL_REWARD")`, one per level, so they are idempotent.

`reset_character` (`characters/service.py:252-261`) adds `CharacterDeeds`, `RuneHolding`, `InventoryItem`, `ItemEvent`, `Loadout` and `CharacterTitle` to its delete list.

### Config

Each file sits behind an asserting `lru_cache` loader with an "every entry resolves" test:
- `characters/config/attributes.json`
- `inventory/config/{runes,items,loot,shop,cosmetics}.json`
- `progression/config/{titles,level_rewards}.json`
- `levels.json` — retitled, and `scripts/gen_levels.py` must stop dropping `titles` and `abilityPointLevels` when it regenerates.

### Endpoints

All new; all new fields optional; all enums `SafeEnum`.
- `GET /character/sheet`, `POST /character/attributes`
- `GET /inventory`, `POST /inventory/{id}/sell`, `/reforge`, `/use`
- `PUT /character/loadout`
- `GET /runes`, `POST /runes/{id}/rank-up`
- `GET /shop`, `POST /shop/buy`
- `GET /character/titles`, `PUT /character/title`
- `POST /character/abilities/respec`

`CharacterOut.title` stays a string, so old builds are unaffected.

### Summary and claim result

`AdventureSummary` and `ClaimResultOut` gain optional keys:
- `loot {items[], runes[{runeId, rank, isNew, shards, shardsNeeded}], consumables[], soldOnTheSpot[]}`
- `levelRewards[]`
- `attributeChanges[{attr, from, to}]`
- `wokenRune`
- `sheet`

The PROCESSING_ERROR fallback (`jobs/handlers.py:37`) gets the empty forms.

### Dormant things switched on

- `exploration.reveal()` for abilities and items (`exploration/service.py:124`).
- Six ability keys.
- The lure, which has no UI today.
- The quest `rewards.items` and `rewards.titles` arrays.
- `RewardEvent` "items" (its docstring already promises them).
- `perDayTotal`.

### Flags and iOS

Flags `character_sheet`, `inventory` and `shop` go in `DEFAULT_FLAGS` (`core/config.py:30`).

iOS, under `ios/Packages/RoadsAndRunesCore/Sources/RoadsAndRunesCore/`:
- New `Models/CharacterSheet.swift` and `Models/Inventory.swift`.
- Optional fields on `Models/Character.swift`, `Models/Ride.swift` and `Models/WorldObject.swift`.
- Each endpoint through `API/RoadsAndRunesAPI.swift`, `Endpoints.swift`, `APIClient.swift`, `MockAPI.swift` and `SampleData.swift`.
- Item, rune and title copy in `Formatting/RewardCopy.swift`.
- `Navigation/EncounterTracker.swift` takes the snapshot.

Screens are D's.

## 4. Phasing

| Piece | Effort | Depends on | Release |
|---|---|---|---|
| Title collection, `award_title`, picker endpoints, renames | S | — | R1 |
| Ability fixes: class scope, derived points, respec, numbered text, six dormant readers | M | — | R1 |
| Deeds, attributes, point spending, `CharacterSheet`, ride snapshot | M | — | R1 |
| Rune holdings, ranks, pity, inscriptions, six runes' effects, waking with existing shapes | M | sheet; C's damage | R1 |
| Level reward table and ledger | S | titles, runes | R1 |
| Cap exemptions, daily cap, rounding fix | S | — | R1 |
| Inventory, 30 items, loot roll, gear in loadout, quest `items` | L | sheet; C's tables | R2 |
| Consumables: lure button, fragment, rest token, sealed chest | M | inventory | R2 |
| Shop | M | inventory | R2 |
| Runes 7–15 and their sources | M | A's lore | R2 |
| Re-forging, capstones, second loadout | M | R2 | R3 |
| Cosmetics for marker, ink, crest | M | D's art | R3 |
| Runes 16–24; true glyph trace templates with fixtures on both sides | L | matcher study | R4 |

**R1 must contain** the first six rows: a sheet with five numbers that move after each outing, runes that rank and can be inscribed and woken, titles you choose, abilities that work, and a payoff at every level. Until R2, the gear-slot and sealed-chest levels pay 100 coins; the item is granted retroactively when R2 lands.

**Earlier roadmap:**
- Absorbs "abilities that do something" (0.6) into R1.
- Absorbs "a streak that allows a rest day" (0.6) as the Rest Token in R2.
- Supersedes "things to buy with coins" (0.7) with the R2 shop.
- Supplies the counters for "records that are not speed".
- Leaves held-ground rent to others; Othala and Wunjo hook into it.

## 5. Risks, cheap tests, and what not to build

| Risk | Cheap test |
|---|---|
| Stacked percentages run away | A `scripts/sim_character.py` that pushes 120 synthetic outings through `build_sheet` and prints the level 1 / 10 / 25 / 50 multipliers; a property test that nothing exceeds ×3.0. |
| Phone and server disagree | The phone only reads the snapshot; one shared sheet fixture on both sides. |
| Prices are guesses from one player | Before fixing `shop.json`, sum the owner's real `wallet_transactions` for the last eight weeks. Prices are config. |
| Waking a rune by accident (any block is a square) | Run the matcher over the owner's stored traces, filtered per shape, and count accidental matches per outing. If over one in five, require the figure to close within 150 m of a held place. |
| Gear is bookkeeping, not play | Ship R2 without secondary rolls. If over 70% of drops are sold unequipped after three weeks, drop re-forging from R3. |
| Slower reckoning on the 512 MB machine | The sheet is built at ride create (four small queries), not in processing. The whole-track rune scan runs only when an inscribed rune has a form, under the existing `MAX_CANDIDATES`. |
| Migration missing while tests pass | Add the six tables to `tests/test_character_reset.py`, and run the PostGIS job before the Fly deploy. |

**Not building:** a second currency or crafting materials; durability or repair; gear set bonuses; item levels or stat requirements; trading; paid currency; coins for XP; the bike as gear; any attribute, rune or item that reads speed or touches routing; branching trees beyond the one capstone.

### Critical Files for Implementation
- backend/app/progression/service.py
- backend/app/characters/service.py
- backend/app/rides/processing.py
- backend/app/world_objects/service.py
- ios/Packages/RoadsAndRunesCore/Sources/RoadsAndRunesCore/Models/Character.swift
