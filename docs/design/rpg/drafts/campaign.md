> **Superseded where it disagrees with [docs/ROADMAP.md](../../../ROADMAP.md).** This is one of five design drafts written independently on 2026-10-01, before an adversarial review. Known differences: coins, not pence; Hollow Sentry, not Hollow Knight; five cast (Ada Pym, Tam Hurdle, Enid Sallow, Walter Garth, Nell Foss), not six quest-givers; "the road", not "passage"; the old ones are the Blank, the Drowned Lane, the Long Drag, the Slow Coach and the Worn Stone, not the Bailiff; the build is runes, gear and abilities, not attributes plus fifteen systems. Read it for the written lines and the reasoning, not as the specification.

Paths: `BE` = `backend/app`, `IOS` = `ios/RoadsAndRunes`, `CORE` = `ios/Packages/RoadsAndRunesCore/Sources/RoadsAndRunesCore`.

# E. CAMPAIGN

## 1. The idea in five lines

- A main campaign, "The Old Roads": 5 acts, 19 chapters, 69 authored steps on the existing arc machinery, so it works in any city and lasts 6 to 11 months at three outings a week.
- Every notice has a poster with a voice, and standing with them grows from what you finish. There is no dialogue.
- What you did on the outing (came home another way, stopped to write, took the water or the hill) is remembered and changes later text and chapter order.
- Districts become named ledgers with an honest percentage, completion pay and "held ground".
- A weekly notice, a rest-day streak and quarter-day seasons give a reason to come back, all derived from the date; every outing gets a short written entry.

Assumed of neighbours:
- **A** names the cast, region epithets, rune meanings and codex prose; my giver names are placeholders.
- **B** turns the title into a collection and provides one writer for granting runes and items.
- **C** gives monsters habitat and persistent bosses, and exposes damage per object on `ClaimOutcome`.
- **D** draws all of it.

## 2. The design

### 2.1 Campaign shape

A chapter is an arc in `story_arcs.json`; an act is a field on it. Chapters chain with `prerequisiteSlug`, which already resolves across arcs (`BE/quests/story.py:228` builds one `done` set).

New arc fields: `track`, `act`, `chapter`, `requires`. `requires` is a set of deeds (`cellsVisited`, `monstersBeaten`, `placesFound`, `regionsHeld`) checked in `_unlocked` (`story.py:131`) from counts the database already holds.

Open arcs may only use ANY templates (`story.py:77`), and there are eight. So the campaign adds 12 story-only ANY templates, most of them JSON-only on existing rule keys; `ANY_FORK` and `ANY_CARRY` wait on the second-POI rule in 2.5. They carry `"storyOnly": true`, which `templates_for` (`BE/quests/templates.py:55`) skips unless unlocked.

The campaign never uses `SUSTAIN_SPEED`. I also demote it: The Iron Hours step 1 moves to `WARRIOR_LONG_HAUL` (slug kept), and `WARRIOR_STEADY_TEMPO` drops from weight 3 to 1.

| # | Chapter (gate) | Asks | Reveals | Reward |
|---|---|---|---|---|
| **I The Board** | | | | |
| 1 | First Light (L1) | new ground; a green place; a high place | There is a board and somebody keeps it. Fog is forgetting. | Early Riser, 100 |
| 2 | What Settles (L2) | a chest; three pieces; one monster | Coins were left for whoever came next. Pieces are broken marks. Things move in where footfall drops. | Local Nuisance, 150 |
| 3 | The Rune at the Crossing (L3, 40 cells) | an old place; three crossings; out and back another way | Who cut the runes, and what Raido is. | Cutter's Apprentice, 200, Raido |
| **II Five More Cuts** (4 steps each: learn, fetch, prove, cut) | | | | |
| 4 | Kenaz, the Torch (L4) | four frontier places; the ground round a park; a half-new loop; cut | A torch lights only where it is carried. | rune, 200 |
| 5 | Ansuz, the Word (L5, 5 places) | record a place; carry a word A to B; a note; cut | A place nobody describes goes the way of a road nobody uses. | rune, 200 |
| 6 | Wunjo, the Glad Rune (L6) | a stop; a green hour; water or hill; cut | Roads were also for going somewhere pleasant. | rune, 200 |
| 7 | Sowilo, the Sun (L8) | high ground; a climb; three points on a line; cut | Cutters took sightings from high places; the lines between are the oldest roads. | rune, 250 |
| 8 | Dagaz, the Day (L10, runes 4-7) | a long day; three waters; far out and back; cut | A full day and the turn for home. What six runes together are. | Holds All Six, 300 |
| **III What Holds the Ground** | | | | |
| 9 | Habits (L10, 5 beaten) | three kinds, each where it belongs | Each thing keeps to what suits it. | bestiary pages, 200 |
| 10 | The Lair (L12) | clear the ground round a park; beat what is in it | A lair is a place left alone long enough. | 250 |
| 11 | The One That Stayed (L14) | wound a boss over three outings; finish it | Big ones are small ones nobody saw off. | title, item (B), 400 |
| 12 | Double Pay (L15) | three bounties; carry proof to the poster | Who posts bounties: it is cheaper than mending. | 300 |
| **IV The Parish** | | | | |
| 13 | Home Ground (L16) | half your home district | Districts have names and a ledger. | 300 |
| 14 | Beating the Bounds (L18) | ride its edge in four places, twice | The old custom of walking a boundary so it is not forgotten. | title, 300 |
| 15 | The Next Parish (L20, 1 held) | hold a second district; carry between them | Rent, quarter days, held ground. | 400 |
| 16 | Going Quiet (L22) | return to a district left 30 days; see off what settled | Nothing is won for good. | 400 |
| **V The Long Way Round** | | | | |
| 17 | The Far Board (L24) | 15-30 km out, new ground | Another board, in another hand. | 400 |
| 18 | The Line (L28) | a long line; water followed; a long day | The roads join up further than anyone checked. | 500 |
| 19 | The Last Cut (L32) | out, and a rune cut where you began | There is no last rune. The keeper was the last person who went further than most. | Reader of Roads, 600 |

Closing line: "Somebody has to keep the board. It has been you for a while."

### 2.2 Act I, written out

Text is activity-neutral ("outing"; never ride, pedals or wheel).

**1. First Light.** Arc text: "There is a board, and somebody keeps it. The notices are small: a road nobody has taken lately, a green place gone quiet, a hill with a view of both. Three outings, in order."

- **Out of the Door** [`ANY_NEW_GROUND`], the board-keeper: "Start with a road you have not been down. Any will do. They are all forgetting at about the same rate."
  - "Every road was written once. Somebody cut a mark where two ways met, and the way remembered who used it. Nobody reads the marks now, and a road nobody reads goes vague at the edges. That is the fog. Take {newTerritoryKm} km you have never taken. It is not much. It is how all of it starts."
  - Done: "The road knows it has been used. It will not say so."
- **Something Green** [`ANY_GREEN_HOUR`], keeper: "Come back another way if you can. I like to know which."
  - "Every town keeps a green place and then stops going to it. {poiName} has had a quiet few years, and quiet is when things settle. Go and stand in it."
  - Done: "{poiName} has been looked at. Whatever was thinking of moving in will think again."
- **Somewhere to Look From** [`ANY_HIGH_GROUND`], keeper: "Go up and look. Then you will know what you are asking for."
  - "From {poiName} you can see the ground you have covered and the ground you have not. The second is larger. It always is."
  - Done: "You have seen the size of it. The keeper nods, which is the most you will get."

**2. What Settles.** "Where nobody passes, something moves in. Nothing grand. This is how you find out what."

- **Something Left Behind** [`ANY_UNLOCK_CHEST`], keeper: "Finders keepers. That was the arrangement."
  - "The people who kept the roads left things at the turnings for whoever came next. A few coins, mostly, against the day. There is a {objectName} at {objectPlace} that nobody came next for. You are next."
  - Done: "Coins older than the kerb they were under. The purse does not mind where they have been."
- **Pieces** [`ANY_GATHER_THREE`], the rune-cutter: "Bring me three and I will tell you what you have."
  - "The marks did not all wear away. Some broke off. They turn up near {objectPlace} and places like it: a sliver of a rune, an old coin pressed into the mortar for luck. Pick up three on one outing."
  - Done: "Three pieces. None is a whole rune yet. You know what one looks like now."
- **The First of Them** [`ANY_SLAY_NEARBY`], keeper: "It will tell you what it cannot stand. They always do."
  - "The {objectName} at {objectPlace} moved in when the footfall dropped and has seen no reason to leave. Give it one."
  - Done: "The {objectName} has gone to find somewhere quieter. There are fewer of those than there were this morning."

**3. The Rune at the Crossing.** "A rune was cut where two ways met, so each road knew about the other. One of them is yours to cut again."

- **Older Than the Road** [`ANY_OLD_STONE`: visit a HISTORICAL place, optional note], cutter: "If you stop, write one thing down. The clerk collects those."
  - "{poiName} was here before the road was. {poiFact} The cutters worked outwards from places like it. Go and look."
  - Done: "{poiName} is on your map and in the clerk's book. It has been in neither for a while."
- **Where Two Ways Meet** [`ANY_THREE_WAYS`: three unvisited cells], the lengthsman: "Any order. The roads do not care which you take first."
  - "Three crossings near you have gone unread. Pass through all three in one outing."
  - Done: "Three crossings, read. The ways between them have started to firm up."
- **Raido** [`ANY_OUT_AND_BACK` in R1; `INSCRIBE_RUNE` from R2], cutter: "Out, and back by another way. That is the whole shape of it."
  - "Raido is the road-rune. The road is cut twice and neither cut is the same. Go out to the far crossing, come home differently, and end where you began."
  - Done: "Raido, cut again. The way remembers you."

### 2.3 One live step: lifted, to one per track

Tracks are MAIN, SIDE (class arcs) and SEASON. `story.due` (`story.py:225`) currently returns nothing while any step is live; it becomes per-track, and `ensure_available` (`BE/quests/service.py:504`) offers until each track has one.

Why: main chapters are gated by level and deed, and a step can be unplaceable here. With one global step the campaign stalls silently and takes the class arc with it. Three rails at most is still a chain.

A step that cannot be placed reports state `WAITING` with a reason ("Needs high ground. It will come up when you are near some.").

### 2.4 Quest-givers

Every template and step names a `giver`; a line is picked from that giver's pool by the quest seed and stored in the free-form `narrative` JSON (`giver`, `giverLine`). Lines are authored, never model-written.

| Placeholder | Posts | Sample |
|---|---|---|
| the board-keeper | ANY | "It has been up a week and nobody has touched it. I would not read much into that." |
| the lengthsman | Explorer | "My length ends at the last road you know. Make it longer and I shall have to walk it. Do it anyway." |
| the rune-cutter | Wizard | "It is a mark on a stone. So is your name on a letter." |
| the carrier | Warrior | "The hill was there first. It is not going to meet you halfway." |
| the clerk | Scribe | "If it is not written down it did not happen. I do not make the rules. I do write them down." |
| the reeve | bounty | "Double for this one. It has been at the allotments and people are upset." |

Standing is derived, not stored: completed notices from that giver, plus one for each with an optional objective done.

| Rank | Count | Gives |
|---|---|---|
| Stranger | 0 | nothing |
| Nodded at | 3 | their codex page |
| Known | 8 | one of their story-only templates joins your board |
| Trusted | 15 | 150 coins and a second page |
| Kept a chair for | 25 | a title |

Rank-ups are paid once, keyed on a `RewardEvent` of type `STANDING`.

### 2.5 Consequences without choices

A step's `definition.sets` maps an optional objective to a flag. Flags are derived from the completed quest's objective rows, so no table. A later step may carry `variants: {flag: {giverLine, description}}`, and an arc may `requires` a flag. Nothing is ever locked out; the other road opens later.

1. **Came home round.** Something Green has optional `RETURN_TO_START`. If done, chapter 2 opens with: "You came back by the far gate. I noticed. Most do not." The lengthsman's first notice arrives a chapter early.
2. **Left a word.** Older Than the Road has optional `WRITE_NOTE`.
   - Done: Ansuz opens "The clerk already has a line of yours. It is filed under Miscellaneous. Do not take that personally." and the place's codex page quotes the note.
   - Not done: "You went to the old stone and wrote nothing down. The clerk has not forgotten."
3. **Water or hill.** Wunjo step 3 is `ANY_FORK`: required `EXPLORE_NEW_ROADS`, optional `VISIT_POI` at water, optional `VISIT_POI` at a viewpoint. Whichever you reach sets `took_water` or `took_hill`. That decides whether Sowilo or the water steps of Dagaz come first, who speaks, and (assuming C's habitats) what the chapter 11 boss is.

Example 3 needs one generator change: a second place slot (`poiCategoryB`) in `instantiate`.

### 2.6 New objective types

| Candidate | Verdict | What moves |
|---|---|---|
| `INSCRIBE_RUNE` | Yes, R2. Reuses `claims.match_rune` (`BE/world_objects/claims.py:303`) at a crossing; phone feedback from `RuneMatcher`. Required steps use LOOP, TRIANGLE, SQUARE, ZIGZAG; STAR is only ever optional. | `templates.py:12`; a branch in `generator.instantiate` (`generator.py:380-459`); `processing.evaluate_objectives` (`BE/rides/processing.py:56`); `service.record_progress:582`; reveal list `service.py:351`; `CORE/Models/Enums.swift:51`; `CORE/Navigation/ObjectiveTracker.swift:79`; `test_class_quests.py` plus the shared `rune_tracks.json`. M |
| `CARRY` | Yes, R2. The trace enters A, then later B. Gives givers errands. Shares the second-place work with the fork. Spoken: "You have it." / "Delivered." | Same seven places. M |
| `WOUND_BOSS` | Yes, R3. Done when the boss has lost N since the step opened, read from C's boss row so damage on any outing counts. | Same list, no generator geometry. S once C lands |
| `CLEAR_LAIR` | Not a type. A generator rule `regionLayout: "around_poi"`: the 7 cells round a park, visit 5, on the existing `VISIT_MULTIPLE_LOCATIONS`. Five of seven absorbs a lake or a locked gate. | `generator.py` only. S |
| `FOLLOW_WATER` | As a rule now: cells of three water-tagged places, R2. True "stay by the canal for 3 km" needs waterway geometry fetched at generation; R4 at most, measured with `min_distance_to_path_m` (`claims.py:38`). | S now, L later |
| `RIDE_THE_LINE` | Exists (`regionLayout: "line"`). | none |
| `VISIT_AT_DAWN` / `DUSK` | No. Verifiable from timestamps and a sun calculation, but it pays people to be on roads in poor light, and day length makes it unfair by season. The chronicle may remark on an early start; nothing is ever asked or paid. | none |

### 2.7 Regions as chapters

- **Names.** OSM `place=suburb|neighbourhood|quarter|village|town|hamlet` nodes, fetched as a fifth set in `overpass_query` (`BE/discoveries/osm_import.py:108`, bump `TILE_VERSION`) into a new global `regions` table. They do not go into `discoveries`, where they would become "?" markers.
- **Membership.** A cell belongs to the nearest place within 4 km (pure function). Beyond that it is unnamed open ground with no ledger.
- **Honest denominator.** The cells that contain a way.
  - One Overpass call per region, the first time the player enters it: ways with `highway` set, minus motorway, trunk and private, as `out ids center`. One point per way maps to its cell, cached on the region.
  - Long ways under-count, which errs towards a smaller denominator.
  - Until the fetch succeeds the ledger shows a count ("214 cells known"), never a percentage.
- **Completion** at 90% of way cells visited, paid once: sets `regions_completed` on `RideRewardInput` (`processing.py:184`), switching on the dormant 500 XP, plus a 150-coin purse.
- **Ledger** (new per-user `user_regions`, updated in `process_ride`): way cells, places found, things beaten, runes cut, notices done, first entered, last passed.
- **Held ground** stays, R3. It is the premise as a mechanic, and the only reason to revisit known ground.
  - Held means at least 50% and passed through in the last 30 days.
  - Pays 5 coins per held region, at most 10 regions, once per ISO week on the first outing.
  - Lapsing changes only a word ("going quiet") and, I assume, C's spawn weighting. Cell states never regress.
  - Copy: "{region} is held. Five coins a week for as long as you keep passing through."

### 2.8 Rhythm, with no scheduler

- **The week's notice.** One goal per ISO week, seeded by user and week: new ground km, days out, climb, places found, things seen off, or a held region revisited.
  - Target is the player's trailing four-week median times 1.1.
  - Paid by the outing that crosses it: 300 XP, 100 coins, once.
  - "The keeper pins one on a Monday and takes it down on a Sunday, done or not."
- **Bounty.** Unchanged; it gains the reeve as poster.
- **Streak with a rest day.** `update_streak` (`BE/economy/streaks.py`) continues when the gap is two days or less. "The road remembers you for a day after."
- **Quarter days.** A pure `season_for(date)` over Lady Day (25 Mar), Midsummer (24 Jun), Michaelmas (29 Sep) and Christmas (25 Dec).
  - Each quarter opens one SEASON arc of three steps through a `window` on the arc; a missed one returns next year.
  - Within three days of a quarter day, held-ground rent pays double.
  - "Michaelmas. Rents fall due and the roads get walked."

### 2.9 The Journal as a chronicle

**Composed entry, R1.** Built inside `process_ride` by a pure `chronicle.compose(facts, seed)` and stored at `processing_result["chronicle"]`: a lead from the most notable fact, a second fact, and a closer.

Pools: 12 leads, 10 seconds and 20 closers, three variants each, picked by ride id and never repeating the previous entry's variants.

- "Eleven kilometres, four of them new. The Fen Troll at the lock took what you gave it and stayed put. It has two days to think about that."
- "A short one, known ground all the way, and none the worse for it. Six days running."
- "You went out for the Gutter Drake and came back with a Groat. The Drake is still at the bins."

**Model entry, R2.**

- **Where the call goes.** After the summary is committed, in `process_ride_job` (`BE/jobs/handlers.py:15`), where the Strava upload already sits. The reckoning never waits for it; the Journal shows the model's entry when it lands.
- **Facts in.** Activity, distance, climb, new km, region names, up to three places, things beaten or missed, pieces, notice and giver, flags set, streak, and first-evers that are not speed.
- **Out.** Two or three sentences, 70 words at most, through `llm.extract` with schema `{"entry": string}`.
- **Guards.**
  - `asyncio.wait_for` at 8 seconds.
  - A `max_tokens` argument of 200 (`BE/core/llm.py:76` hard-codes 2048).
  - One attempt per ride, six model entries per user per day, and none for flagged rides or rides under 1 km.
  - Output is rejected for an exclamation mark, a capitalised name not in the facts, a number not in the facts, or a speed word.
- **Model.** `settings.anthropic_model` (default Haiku), with a new `anthropic_narrative_model` override so prose can move without moving request reading.
- **Cost.** About 700 tokens in and 120 out per ride; price it against current Haiku rates before switching on.
- **Eval.** `scripts/eval_chronicle.py` and `tests/test_chronicle.py`, on ten consecutive fact-sets.
  - No two entries share a first sentence.
  - Pairwise trigram overlap stays under 0.4.
  - The rejection rules above hold.
  - A second call must match shuffled entries to fact-sets at 9 of 10.
  - The composed path runs in every test run; the model path under the existing `llm` marker.
- **Name clash.** "Chronicler" is already a Scribe ability; A should rename one.

**Codex unlocks** are derived, with no table: `codex.json` entries carry `unlock: {step | flag | giver+rank | region | season}`, and `GET /codex` computes them. "New" is client-side seen state.

### 2.10 Fixes this depends on (all R1)

1. **Arc paid on every path.** Extract `story.settle_arc()` and call it from `process_ride` (`processing.py:363-414`), `complete_quest_with_ride` (`:499`) and `complete_quest_without_ride` (`:540`, reached from `on_object_claimed`, `service.py:667`).
   - Idempotent by a `RewardEvent` of type `STORY_ARC`.
   - `completion_payload` (`service.py:696`) stops hard-coding `storyProgress: None`.
   - The tap path also passes `is_story_quest`, so the 250 XP is not lost.
2. **Purses outside the cap.** Arc, region, weekly and standing purses go through `economy.credit` directly (`BE/economy/service.py:35`), not through `apply_cap` (`BE/economy/rules.py:85`).
3. **Completion text.** Steps author `completion`; `story.offer` (`story.py:341`) stores it, and `load_arcs` asserts it. Each of the 39 templates gets one `completion` line (`generator.py:489`).
4. **Riddle leak.** `objective_out` (`service.py:51-75`) drops `extra.poiName` and `discoveryId` while hidden; `narrative.enrich` (`BE/quests/narrative.py:86`) skips hidden names; `load_arcs` rejects `{poiName}` on a hidden template.
5. **Wording.** Rewrite 10 existing arc texts. Add a test: no ride, rider, pedal, saddle or wheel in a step whose template allows RUN or WALK. Fix "3 km" in `EXPLORER_WATERSIDE`.
6. **Party clone.** Copy `story_quest_id` (`BE/social/service.py:304`) only when that step is READY for the member.
7. **New, found while reading.** Story steps never expire, but chests and monsters go in three days, and `retire_orphaned` skips story quests (`service.py:409`). A chapter 2 step can point at a monster that has left, for ever. Re-target on board load.

### 2.11 Content budget

| Release | Authored | Generated |
|---|---|---|
| R1 | Act I: 3 chapters, 9 steps (36 lines); 3 templates; 39 completion lines; 30 giver lines; 126 chronicle lines; 10 rewrites | placement, line picks, chronicle |
| R2 | Act II: 5 chapters, 20 steps; 5 templates; 12 variants; 25 rank lines; 12 weekly lines | weekly targets; model chronicle |
| R3 | Acts III-IV: 8 chapters, 28 steps; 1 season arc (3 steps); 25 region lines | region names, denominators |
| R4 | Act V: 3 chapters, 12 steps; 3 season arcs (9 steps); 4 class arcs extended (12 steps) | none |

The model writes only chronicle entries and board-quest paragraphs. It never writes campaign steps, giver lines, codex or place facts.

## 3. How it attaches

- **Backend, no migration:** `story_arcs.json`, `templates.json`, `story.py`, `service.py`, `generator.py`, `narrative.py`, and new `BE/quests/campaign.py` (flags, standing, deed counts; pure, derived). Arc-level extras are read from `load_arcs()` by slug, as `arc_reward` does (`story.py:243`).
- **Backend, new modules:**
  - `BE/chronicle/` (`rules.py`, `config/chronicle.json`).
  - `BE/regions/` (models, rules, service, router).
  - `BE/quests/weekly.py`.
  - `BE/codex/` (loader only; A's content).
- **Tables:** `regions` (global) and `user_regions` (added to `reset_character`), one guarded migration, numbered in merge order.
- **Endpoints:**
  - `GET /quests/story` extended with optional fields.
  - `GET /campaign` (chapter, standing, flags, the week's notice, season).
  - `GET /regions` and `GET /regions/{id}`.
  - `GET /codex`.
  - `AdventureSummary` and `AdventureEntry` gain optional `chronicle`, `weeklyGoal`, `regions`, `standing`.
- **Flags:** `campaign`, `chronicle_llm`, `regions`, `weekly_notice`.
- **Switched on from dormant:** `StoryQuest.definition`, `narrative.completion`, `REGION_COMPLETED`, `RideRewardInput.regions_completed`.
- **iOS:**
  - Models and tracker: `CORE/Models/Quest.swift`, `Enums.swift`, `ObjectiveTracker.swift`.
  - `RideEvent.swift` gets three cases, each five words or fewer ("Raido is cut.", "Into {region}.").
  - Copy: `RewardCopy.swift` labels and a new `CORE/Formatting/CampaignCopy.swift`.
  - API: the protocol, `Endpoints`, `APIClient`, `MockAPI` and `SampleData` for three endpoints.
  - Screens: `IOS/Features/Quests/StoryArcsView.swift` (acts, then chapters), `QuestsView.swift` (giver line, campaign card, weekly card), `IOS/Features/Journal/JournalView.swift`, `IOS/Components/AdventureSummaryView.swift:365-381`.

## 4. Phasing

| Piece | Effort | Depends on | Release |
|---|---|---|---|
| Fixes 1-5 and 7 | M | none | R1 |
| Tracks, `WAITING` state, `requires` | S | fixes | R1 |
| Act I content and 3 templates | M | tracks | R1 |
| Givers on cards; standing count shown | S | none | R1 |
| Composed chronicle in reckoning and Journal | M | none | R1 |
| Campaign view (acts and chapters) | M | D | R1 |
| Fix 6 (party clone) | S | none | R2 |
| Second place slot, `ANY_FORK`, `CARRY` | M | none | R2 |
| `INSCRIBE_RUNE` | M | A's rune-to-shape table | R2 |
| Lair and waters generator rules | S | none | R2 |
| Flags and variants | S | tracks | R2 |
| Standing ranks and rewards | S | B's titles | R2 |
| Week's notice; rest-day streak | M | none | R2 |
| Model chronicle and eval | M | composed chronicle | R2 |
| Codex unlock engine | S | A's content | R2 |
| Act II content | M | `INSCRIBE_RUNE`, `CARRY` | R2 |
| Region names, membership, ledger | L | none | R3 |
| Honest percentage; region completion | M | regions | R3 |
| Held ground and rent | S | regions | R3 |
| `WOUND_BOSS`; Act III | M | C's bosses | R3 |
| Act IV | M | regions | R3 |
| First season arc | S | tracks | R3 |
| Act V; remaining seasons; class arcs extended | M | none | R4 |
| True `FOLLOW_WATER` | L | none | R4 |

**R1 must contain** the fixes, tracks, Act I, giver lines and the composed chronicle. That alone gives a beginning, a voice on every notice and a written entry per outing, and it is almost entirely JSON and text.

**Earlier roadmap.** Absorbed from 0.6: weekly goal, rest-day streak, named regions, held ground. Absorbed from 0.7: the Chronicler (pulled forward) and the Journal as atlas (as the region ledger). Records that are not speed survive only as chronicle first-evers. Untouched: fog and the frontier arrow, Live Activity, share card, shop.

## 5. Risks, cheap tests, and what not to build

| Risk | Cheap test |
|---|---|
| A template-built campaign reads as board quests with better text. | Ship Act I only and have the owner play it for three weeks before Act II is written. If it reads flat, put A's place lore into `{poiFact}` first. |
| A step cannot be placed (flat town, nothing spawned). | A script that instantiates all 69 steps at the owner's home and two other towns and prints the failures. |
| Required rune cuts cannot be traced on real streets. | The owner tries LOOP and TRIANGLE twice each. If it fails, required cuts use the 0.30 threshold or stay as out-and-back. |
| Region names are missing or odd; the percentage is unfair. | A script printing regions, denominators and the owner's percentage for their best-known district. Under 85% where they have "ridden everything" means the way filter needs tuning before any UI. |
| Chronicle entries repeat or invent. | The eval; the composed path ships first and stays the fallback. |
| Weekly targets are wrong. | Replay the owner's ride history through `weekly.py` offline. |
| A rest-day streak still breaks over a weekend at three outings a week. | Check against the owner's history; if so, the week's notice carries the rhythm and the streak stays minor. |
| Quarter-day names are northern and English. | Dates only in code; A decides the names. |
| The Anthropic key may not be set on Fly. | Log `llm.enabled` at start. |

Not building: dialogue trees or on-screen choices; branches that lock content; dawn or dusk objectives; anything timed; model-written steps or giver lines; factions at war; events needing a scheduler; story push notifications; per-city authored arcs; fog that regresses in data; quest failure; streak penalties.

### Critical Files for Implementation
- backend/app/quests/story.py
- backend/app/quests/config/story_arcs.json
- backend/app/rides/processing.py
- backend/app/quests/generator.py
- backend/app/quests/service.py
