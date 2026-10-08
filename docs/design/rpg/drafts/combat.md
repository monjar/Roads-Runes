> **Superseded where it disagrees with [docs/ROADMAP.md](../../../ROADMAP.md).** This is one of five design drafts written independently on 2026-10-01, before an adversarial review. Known differences: coins, not pence; Hollow Sentry, not Hollow Knight; five cast (Ada Pym, Tam Hurdle, Enid Sallow, Walter Garth, Nell Foss), not six quest-givers; "the road", not "passage"; the old ones are the Blank, the Drowned Lane, the Long Drag, the Slow Coach and the Worn Stone, not the Bailiff; the build is runes, gear and abilities, not attributes plus fifteen systems. Read it for the written lines and the reasoning, not as the specification.

# C. Combat and the living world

Path prefixes: `BE` = `backend/app`, `CORE` = `ios/Packages/RoadsAndRunesCore/Sources/RoadsAndRunesCore`, `APP` = `ios/RoadsAndRunes`.

Nothing here was run or calibrated against real rides; every number is a design value until the replay test in section 5 has been done.

Assumed of neighbours:
- **A** may rename species, old ones and lines; I supply mechanics and placeholder copy in voice.
- **B** owns items, rarity names and the loadout; I consume a snapshot.
- **D** draws sigils, HP bars and the fight card.
- **E** owns quest copy and may point objectives at fights.

## 1. The idea in five lines

1. Every monster has hit points, and every kind of effort inside its ground takes some off: road, new ground, climbing, a traced rune, a written note.
2. Nothing is pass/fail. A monster you did not finish is wounded, stays wounded, and stays longer for it.
3. Each species lives somewhere that suits it and is weak to two kinds of effort and resistant to one. One that sees you off twice comes back with a name.
4. "Old ones" are persistent, take at least three outings, and arrive about one a week.
5. A fight can be followed by ear and wrist, and the reckoning tells it blow by blow. No clock is read anywhere.

## 2. The design

### 2.1 Damage model

**Visit.** A visit is a maximal run of the trace inside a foe's ground (1,000 m; it ends once the rider is 1,300 m away). It counts only if the trace comes within 150 m (`monsterNearMeters`) at some point. The approach counts, because a hill is climbed before the monster at the top is met. On the phone, damage before contact accrues silently and lands as an opening blow.

**Formula**, per increment, per foe:

`damage = units × rate[kind] × activityScale[kind][activity] × affinity × loadout[kind]`

- `affinity` is 2.0 if weak, 0.5 if resistant, 1 otherwise.
- The product of all multipliers is clamped to 0.25–3.0.

| Kind | Units | Rate | Code and copy |
|---|---|---|---|
| ROAD | metres made good in the visit, on 15 m stride anchors so jitter is nothing | 0.01 per m | "the road"; the known-ground trickle |
| GROUND | new cells first entered in the visit (`TraversedCell.first_seq`) | 15 per cell | "new ground" |
| CLIMB | metres gained in the visit, 3 m hysteresis (`claims.elevation_gain_m`) | 1.25 per m | "the climb" |
| RUNE | one blow per foe per ride, best `match_rune` in the visit | 100 | any of the five shapes; the foe's own shape if RUNE-weak is the ×2 |
| WORD | one blow per foe per ride; a note within 120 m | 60, +30 with a photo | "the word" |

**Constants** for `world_objects.json`:

```json
"combat": {
  "engageMeters": 150, "groundMeters": 1000, "breakOffMeters": 1300,
  "strideMeters": 15, "maxJumpMeters": 250, "climbHysteresisMeters": 3,
  "hpByTier": {"1": 100, "2": 220, "3": 400},
  "rates": {"ROAD": 0.01, "GROUND": 15, "CLIMB": 1.25, "RUNE": 100, "WORD": {"note": 60, "photo": 30}},
  "activityScale": {
    "ROAD":   {"RIDE": 1, "RUN": 1.6,  "WALK": 3},
    "GROUND": {"RIDE": 1, "RUN": 1.5,  "WALK": 3},
    "CLIMB":  {"RIDE": 1, "RUN": 1.25, "WALK": 1.5}
  },
  "weak": 2.0, "resist": 0.5, "multiplierClamp": [0.25, 3.0],
  "woundExtendsDays": 2, "maxLifeDays": 7, "woundXpShare": 0.5,
  "legacyKinds": {"PACE": "ROAD", "EXPLORE": "GROUND", "CLIMB": "CLIMB", "RUNE": "RUNE", "LORE": "WORD"}
}
```

**Calibration target.** Tier 1 falls to roughly five minutes of the right effort or ten of any. Tier 2 doubles that; tier 3 triples it. With a weakness, tier 1/2/3 need 40 / 88 / 160 m of climbing or 4 / 8 / 14 new cells on a bike, close to today's 40/80/150 m and 3/5/8.

**Wounds.**
- They persist in `payload.wounds` (`taken`, `byKind`, `rides[]`) until the monster expires. No migration and no healing.
- A wound moves `expires_at` to at least two days out, capped at seven days from spawn.
- "It got away" means a visit ended with HP left.
- XP: half the monster's XP is paid by share of HP removed (new source `BLOWS_LANDED`), the other half on the kill (`MONSTER_BEATEN`). Coins pay only on the kill. A one-ride kill pays what it does today.
- Monsters never hurt the player. There is no player HP.

**Speed is not an input.**
- `fight.resolve` takes `Fix(lat, lon, alt, ok)` and never a timestamp.
- `ok` is set upstream. It is false for a segment above the declared activity's vehicle cap (`SPEED_CAP_MPS`) or a jump over 250 m, so going fast can only remove damage.
- `activityScale` is a constant per declared activity. It favours the slower mode; it is not a measured speed.
- Test: `test_a_slow_rider_does_the_same_damage` stretches every timestamp ×3 and asserts an identical result.

### 2.2 Three outings (neutral loadout)

**A. 6 km walk, flat.**
- Rook Lord, tier 1, 100 HP, weak GROUND and WORD.
  - Visit of 3,400 m; road is 0.03 per m on foot.
  - Contact at 800 m: opening blow 24.
  - At 2,100 m (road 63) the first new cell lands 15 × 3 × 2 = 90.
  - Beaten. Reported: road 63, new ground 37, finisher new ground.
- Gutter Drake, tier 1, weak ROAD.
  - The last 900 m before home are in its ground: 900 × 0.03 × 2 = 54.
  - Got away, hurt, 46 of 100 left, there three more days.

**B. 25 km flat ride.**
- Fen Troll, tier 2, 220 HP, at a lock, weak ROAD and RUNE (loop).
  - Out leg, 2,000 m chord: 40.
  - Return: 1,000 m in (20), a 700 m loop round the basin (14), then the loop closes for 100 × 2 = 200.
  - Beaten. Road 74, rune 146, finisher the rune. Without the loop: 80 dealt, 140 left.
- Bog Wraith, tier 1, weak GROUND, on an unridden spur: falls at the third new cell (road 10, new ground 90).

**C. 40 km, 620 m of climbing.**
- Grey Stag, tier 3, 400 HP, at a viewpoint, weak CLIMB and GROUND, resists ROAD.
  - Visit of 2,300 m, 95 m gained, 4 new cells.
  - Road 11.5, climb 237.5, new ground 120: 369 dealt, 31 left.
  - "Another 13 m of climbing would have done it." Wound XP 0.5 × 220 × 0.92 = 101.
- Moss Golem, tier 2, weak CLIMB: falls about 85 m up the second hill.
- Ash Warden, tier 1, passed on a flat known road: 20 off, 80 left.

### 2.3 PACE and SUSTAIN_SPEED

**PACE is retired.**
- `_pick_methods` (`BE/world_objects/spawner.py:193`) stops choosing it; species define their weaknesses instead.
- Monsters already spawned keep their frozen payload. The resolver reads `killMethods[].method` through `legacyKinds`, so a PACE monster becomes ROAD-weak for its remaining days (at most three). No data migration.
- `to_out` rewrites its hint to "It wants wearing down. Stay near it."
- New spawns send `method: "ROAD"`. The 0.5.0 build decodes that as `.unknown` and skips it, so it cannot falsely call a win.
- Deleted in R2: `best_pace_window`, `CORE/Encounters/PaceWindow.swift`, the pace near-miss in `RewardCopy`, "It wants a fast kilometre", and the `ActivitySetupView.swift:53` line.
- Cinder Hound becomes: "It cannot be outrun. It can be outlasted."

**SUSTAIN_SPEED is demoted.**
- The "Tempo" template (`BE/quests/config/templates.json:956`) leaves the offer.
- The evaluator branch (`BE/rides/processing.py:134`) stays so issued quests still resolve.
- E replaces it with a `RIDE_DURATION` template: "Stay out forty minutes. Nobody is counting how far."

### 2.4 Ecology

**Habitat.**
- `Anchor` (`spawner.py:23`) gains `tags`, filled where anchors are built (`BE/world_objects/service.py:339-342`).
- The species is chosen after the anchor, replacing `rng.choice` at `spawner.py:163`. Weights: 6 for a tag match, 3 for a category match, 0.5 otherwise, so the odd one turns up lost.
- `_appeal` (`spawner.py:225`) gains +1 where any species fits.

| Species | Family | Lives at | Weak | Resists |
|---|---|---|---|---|
| Fen Troll | WATER | `waterway`, `water` | ROAD, RUNE loop | WORD |
| Bog Wraith | WATER | `waterway`, TRAIL | GROUND, WORD | CLIMB |
| Tide Serpent | WATER | `natural=beach` or `water` | ROAD, RUNE zigzag | WORD |
| Mire Hag | WATER | ponds, `nature_reserve` | WORD, GROUND | ROAD |
| Rook Lord | GREEN | `leisure=park` | GROUND, WORD | CLIMB |
| Grey Stag | GREEN | VIEWPOINT, `natural=peak` | CLIMB, GROUND | ROAD |
| Moss Golem | STONE | `historic=ruins`, `castle`, `fort` | CLIMB, WORD | GROUND |
| Hollow Knight | STONE | `historic=manor`, `memorial`, `monument` | RUNE square, WORD | ROAD |
| Ash Warden | STONE | `archaeological_site`, CULTURAL | WORD, RUNE triangle | CLIMB |
| Gutter Drake | STREET | FOOD, CAFE, PUB | ROAD, RUNE zigzag | WORD |
| Lamp Sprite | STREET | `artwork`, LANDMARK | RUNE star, GROUND | ROAD |
| Cinder Hound | STREET | CYCLING, LANDMARK | ROAD, CLIMB | RUNE |

**Tiers are different creatures** (`tiers` on each config entry). Written:
- Gutter Drake. "Small, quick, and fond of bins."
- Alley Drake. "Has a whole back lane and means to keep it."
- Market Wyrm. "Sleeps under the stalls. The stallholders say rats."
- Fen Troll. "Sleeps under the bridge; wakes for footsteps."
- Lock Troll. "Takes the toll in person. Nobody has asked what it does with it."
- Old Fen Troll. "It has held the towpath since the rune at the lock wore smooth."
- Rook Clerk. "Counts who comes in. Has not counted anyone out."
- Rook Lord. "Holds the park by the sheer number of rooks."
- Parliament of Rooks. "Every tree, and a quorum."

**Variants** (15% of spawns):
- Stubborn: HP ×1.5, loot one rarity step up. "Same troll. More of it."
- Skittish: ground 600 m, HP ×0.75. "Leaves if you do."
- Mossed-over: a second resistance, double materials. "Has not moved since. It shows."

**Grudges.**
- A species that sees you off twice (expires wounded) returns once at the same anchor as a named monster: HP ×1.25 per return (cap ×2), a guaranteed drop, loot one step up.
- The epithet comes from the kind that did most and failed: ROAD "the Unhurried", CLIMB "the Unclimbed", GROUND "the Unmoved", RUNE "the Unread", WORD "the Unimpressed".
- "Fen Troll the Unimpressed. You wrote it a note. It has read it."
- If it expires untouched, the grudge lapses.

**Time and weather.**
- No weather: it needs an external service on a 512 MB machine, and it would pay for riding in ice.
- No night bonus: it would pay for riding in the dark.
- Month-of-year species weights are free, because the day is already in the seed. Flavour only.

**Density and bounty.**
- Quota stays 5. Wounded monsters hold their slot, so nothing piles up.
- The bounty is capped at tier 2 so one outing can finish it, and it guarantees a drop.
- A wounded bounty at midnight lapses to an ordinary monster at the ordinary purse instead of vanishing. "The bounty lapsed. The Gutter Drake did not."

### 2.5 The old ones

The old ones are officials of neglect: the Bailiff, the Toll-Keeper, the Night Warden, the Beadle, the Ferryman, the High Reeve.

**Model and cadence.**
- New table `old_ones`: one live per player, keyed to the res-6 parent cell of its anchor.
- Anchor: a notable `Discovery` (prefers a `wikidata` tag) 1.5–5 km from the player's ground.
- The rumour is created lazily in `_ensure_spawned`, the hook the bounty uses (`service.py:360-382`). Conditions: three monsters beaten, no live old one, and `iso_week(last_beaten) != iso_week(now)`. No scheduler.
- It is sighted at 400 m. Ground 1,500 m, contact 250 m.
- This is the weekly goal from the 0.6 roadmap, which it supersedes.

**One phase per outing.** A ride's damage stops at the current phase floor, and at most one phase breaks per UTC day. So three phases means at least three outings, and three short rides in a day do not get round it.

**The Bailiff** (first boss; lives at `leisure=park`; 1,500 HP in three phases of 500):

| Phase | Weak | Resists | Line |
|---|---|---|---|
| Notice | GROUND, ROAD | WORD | "It wants to know where you have been. Show it somewhere new." |
| Distraint | CLIMB, RUNE square | ROAD | "It has stopped counting your visits. Walk its bounds." |
| Settlement | WORD, RUNE loop | GROUND | "It is down to its paperwork. Stop there and answer in writing." |

- Rumour: "Something has been collecting on a park north-east of here. Nobody has passed that way, so nobody has argued."
- Sighted: "The Bailiff. Holds {anchorName} in lieu of footsteps. It has papers. Nobody has read those either."
- Phase break: "The Bailiff gave ground. It will not give more today."
- Beaten: "The Bailiff has left {anchorName}. The debt was footsteps. You have paid it."

**Drops.**
- Each phase break: 150 AC, 300 XP, one item at UNCOMMON or better, one seal (material).
- The kill: 400 AC, 600 XP, one item at RARE or better (25% top rarity), a rune piece the player lacks.

**Ignored.**
- Computed from `last_damaged_at`, not ticked: it regains 10% of max HP per idle week, never past its phase ceiling.
- After four idle weeks it goes dormant and returns later as a rumour with its phase kept.
- It never takes anything. "The Bailiff has had a quiet week. It is better for it."

### 2.6 Lairs

Buildable from what exists, with one honest limit: a `Discovery` is a centre point, not a polygon.

- A lair is the 7 res-9 cells of `disk(anchor.h3_index, 1)` round a park or TRAIL discovery.
- It is cleared when 5 of 7 cells each take 400 m of trace since it opened (reuses `explored_distance_threshold_meters`).
- It lives 14 days, one at a time, as a row in `old_ones` with `kind=LAIR`.
- "{anchorName} has gone quiet. Walk it loud again: five of its seven parts."
- It pays a strongbox: a guaranteed UNCOMMON-or-better item and a missing rune piece.
- A small park will include the streets that touch it. Cemeteries need a query line and `TILE_VERSION` v3 in `BE/discoveries/osm_import.py`.

### 2.7 Loot rules (B owns the list)

| Source | Item chance | Rarity weights C / U / R / top |
|---|---|---|
| Tier 1 kill; Old chest | 35%; 20% | 80 / 18 / 2 / 0 |
| Tier 2 kill; Iron chest | 60%; 50% | 55 / 35 / 9 / 1 |
| Tier 3 kill; Gilded chest | 100% | 25 / 45 / 25 / 5 |
| Bounty, grudge | 100% | one step up |

- Every kill drops 1–3 of the family's material.
- A RUNE finishing blow always drops a rune piece.
- Pieces are pity-directed: always one not held (`pieces_owned`), which fixes today's uniform-random sets.
- Pity: five kills without UNCOMMON forces one; twenty without RARE forces one.
- Rolls are seeded from `object.seed`, so reprocessing gives the same drop.
- Items, materials and pieces are not coins or XP and bypass the per-ride caps.
- Old-one and lair purses are marked `uncapped`. `apply_cap` and the cap in `compute_ride_xp` skip those lines; the one-phase-a-day rule is the limit instead.
- Coins tapped during a ride come off that ride's cap budget, which closes the existing bypass.

### 2.8 Mid-ride feedback

Chimes sit at 294 Hz and above; a pocketed phone will not carry less.

| Event | Pri / shelf | Chime | Spoken (five words or fewer) | Pill | Watch |
|---|---|---|---|---|---|
| `engaged` | 4 / 12 s | D4, D4, A4 (knock, knock, call) | "Fen Troll has noticed you." | "Fen Troll · 76 of 100" | `.start`; "Fen Troll · 76/100 · climb" |
| `blow(tenth:)` | 1 / 5 s | double-struck note stepping down A5, G5, E5, D5, C5, A4, G4, E4, D4, one per tenth of HP | none | none (banner bar) | `.click` |
| `heavyBlow` | 4 / 20 s | A3 + E4 together, then A4 | "Rune landed." / "Word landed." | "A loop, drawn · 20 of 220" | `.directionDown` |
| `staggered` | 4 / 20 s | E4, B♭3, E4 | "It staggers." | "Fen Troll is at half" | `.directionDown` |
| kill (`claimed`) | 5 / 60 s | existing `win` | "Fen Troll beaten. 150 coins." | existing | `.success`, "YOURS" |
| escape (`lost`) | 4 / 20 s | existing `lost` | "Fen Troll got away, hurt." | "Got away · 46 of 100 left" | `.stop` |
| `oldOneStirs` / `phaseBroken` | 5 / 60 s | A3+E3 drone with A4 bell; A3, C4, E4, A4 | "The Bailiff is in." / "It gives ground." | phase name | `.success` |

Blows step down as the monster sinks, where new ground steps up. Watch haptics travel in a new `WatchMessageKind.encounterBeat`, which old Watch builds ignore.

### 2.9 The reckoning

One card per fight, from `worldObjects.fights[]`:
`{id, name, tier, variant, outcome, hpMax, hpBefore, hpAfter, damage[{kind, amount, units, multiplier}], finisher, drops[], expiresAt, wouldHaveDone}`

- Beaten: "Fen Troll, beaten. The road took 74. A loop round it finished the rest."
- Wounded: "Grey Stag got away at 31 of 400. The climb took 237, new ground 120. Another 13 m of climbing would have done it. It is hurt, and there three more days."
- Under 10% dealt: "Ash Warden shrugged it off. You took 20 off it in passing."

### 2.10 What I need from B

```python
@dataclass(frozen=True)
class Loadout:
    multipliers: dict[str, float]    # by ROAD|GROUND|CLIMB|RUNE|WORD, default 1.0
    vs_family: dict[str, float]      # WATER|GREEN|STONE|STREET
    rune_threshold: float = 0.22     # Wizard 0.30 today
    word_requires: tuple[str, ...] = ("note",)   # photo is the +30
    ground_bonus_m: float = 0.0      # at most 300
    loot_luck: float = 0.0           # at most 0.25
    version: str = ""                # stored with the fight
```

- It is snapshotted onto the ride at creation and sent to the phone; taken at processing if the ride started offline.
- Today's class eases become base loadouts, so nothing is lost: Warrior CLIMB ×1.3 and ROAD ×1.15, Explorer GROUND ×1.3, Wizard threshold 0.30, Scribe WORD ×1.3.

### 2.11 Still to write

- Tier-1 and tier-3 names and lines for nine species (27 lines).
- Three resist lines per kind.
- Five old ones in full (three phases, rumour, sighted, beaten, quiet-week lines).
- Lair lines per family.
- Month notes.

## 3. How it attaches

### Backend

- **New `BE/world_objects/fight.py`** (pure): `FightState.advance(fix)` and `resolve(track, foe, loadout, cells_at, rune_at, word_at, cfg)`. The server folds the same per-fix step the phone runs.
- **`BE/world_objects/service.py`**:
  - `claim_from_ride` (:457) calls `fight.resolve` in place of `_fight` (:492, :621) behind the new flag `effort_combat`.
  - Its unused `character_class` argument becomes `loadout`.
  - `expire_stale` (:192) handles the lapsed bounty and grudges.
  - `live_objects` (:205) judges by the ride's `ended` time, so a late upload still lands.
  - `ClaimOutcome.to_dict` adds `fights`.
- **`BE/rides/processing.py`**:
  - passes `{cell: first_seq}` from `traverse` (:263) and the `ok` flags into the claims call (:310-322);
  - builds `RideRewardInput.claims` (:199) and the summary (:470).
  - Mirror the new key in the fallback at `BE/jobs/handlers.py:37`.
- **New modules** `BE/world_objects/old_ones.py` and `loot.py`.
- **New config** `config/bestiary.json` and `config/old_ones.json`, each with an asserting `lru_cache` loader and a test that every species resolves a habitat, two weaknesses and three tiers.
- **Migration** (0008 or next free), guarded: `old_ones`, `bestiary_entries`, `combat_state`. All three join the `reset_character` delete list (`BE/characters/service.py:251-260`) and `BE/db/models.py`.
- **API**:
  - `MonsterOut` gains optional `hpMax`, `hpLeft`, `weakTo`, `resists`, `speciesId`, `family`, `variant`, `epithet`, `groundMeters`.
  - New `GET /world/old-ones` and `POST /world/old-ones/{id}/move`.
  - `GET /config` carries the `combat` block, so tuning needs no app release.

### iOS

- **New `CORE/Encounters/FightResolver.swift`**.
- **`CORE/Navigation/EncounterTracker.swift`**: `fight()` (:145-189) is replaced by the fold.
- **`CORE/Navigation/RideEvent.swift`**: new cases and chimes.
- **`CORE/Models/WorldObject.swift`**: `AttackKind: SafeEnum` and the fight report.
- **`CORE/Formatting/RewardCopy.swift`** and **`CORE/Watch/WatchMessages.swift`**.
- **`APP/Features/Ride/RideRecorder.swift`**:
  - passes new-cell centres at :346-349;
  - sightings (:423-446) and `encounterLine` (:511);
  - `resumeRecovered` (:876) reloads cached objects and replays the persisted points silently, so a crash keeps the fight.
- **Offline starts**: a `WorldObjectStore` beside `RoutePackageStore` caches the last objects. The server still judges from the trace either way.
- **Fixtures**: `backend/scripts/gen_fight_fixtures.py` writes `tests/fixtures/fight_tracks.json`, copied to the Core test `Resources` as `rune_tracks.json` is. Both ports must agree within 1 HP.

### Dormant things switched on

- `hp` (`spawner.py:170`) and `tier` on monsters.
- `update(newCellCentres:)`, which the recorder never passes today.
- The `character_class` argument of `claim_from_ride`.
- The LORE photo path.

### Anti-cheat

- Suspicious rides already skip claims, so they wound nothing.
- Monsters and old ones cannot be tapped.
- Phone claims for monsters are ignored; loot is rolled by the server.
- `wounds.rides[]` makes reprocessing idempotent.
- Declaring WALK on a bike trips `IMPOSSIBLE_SPEED`.

## 4. Phasing

| Piece | Effort | Depends on | Release |
|---|---|---|---|
| `fight.py`, config, tests, flag | M | none | R1 |
| Service wiring: wounds, expiry, `fights[]`, wound XP | M | above | R1 |
| Swift resolver, tracker, shared fixtures | M | above | R1 |
| Five ride events, chimes, Watch beat | M | tracker | R1 |
| PACE retired, Tempo demoted | S | resolver | R1 |
| Habitat matching and bestiary config | S code, M writing | A's names | R1 |
| `bestiary_entries` counts | S | migration | R1 |
| Tap-cap fix, late-upload judging | S | none | R1 |
| Loot rules and pity | M | B's items | R2 |
| Variants, grudges, month weights | M | bestiary | R2 |
| Offline cache, crash replay, PACE code deleted | M | tracker | R2 |
| Old ones and the Bailiff | L | migration, loot | R3 |
| Old-one events and reckoning card | S | above, D | R3 |
| Lairs, cemetery import | M | `old_ones` table | R3 |
| Five more old ones | M writing | A | R4 |

**R1 must contain** the first eight rows: HP, the five kinds, weaknesses read from existing payloads, wounds that persist, a fight you can hear, a fight card, and monsters that live where they belong. Until B ships items, drops are coins and pity-directed rune pieces.

**Roadmap.** This supersedes the 0.6 weekly goal (the old one) and serves "abilities that do something" through the loadout.

## 5. Risks, cheap tests, and what not to build

| Risk | Cheap test |
|---|---|
| Calibration; kills that happen without intent | A read-only `scripts/replay_fights.py` over the owner's last 30 stored rides, printing damage per kind and kills per ride. Tune `hpByTier` before the flag goes on. |
| Chimes unproven on a road | One ride with only `engaged` and `blow` enabled. Can tenths be counted from a pocket? |
| Phone says beaten, server disagrees | Shared fixtures. The phone applies ×0.95 so it under-claims. |
| `match_rune` now runs for every engaged foe, in-request | Time `process_ride` on the longest stored ride. Cap rune checks at the six closest foes. |
| An old one seated somewhere unreachable | 250 m contact, and one free move: "It is somewhere you cannot go. Ask again." |
| Walk scale too generous | The replay script on walks. It is one config line. |
| UTC weeks and midnights | Accept for now; note it in copy. |

**Not building:**
- player HP, death or healing;
- monsters that chase;
- timers or damage per minute;
- heart-rate damage (intensity is speed by another name);
- random crits (loot is the only dice);
- weather or night bonuses;
- on-screen choices;
- shared bosses.

### Critical Files for Implementation
- backend/app/world_objects/service.py
- backend/app/world_objects/spawner.py
- backend/app/world_objects/claims.py
- backend/app/rides/processing.py
- ios/Packages/RoadsAndRunesCore/Sources/RoadsAndRunesCore/Navigation/EncounterTracker.swift
