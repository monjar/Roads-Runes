# Plan: Roads & Runes, the whole road to 1.0

## Where it stands (2026-10-04)

Built on the `feat/old-roads` branch, not merged to master. 0.7.0 went to TestFlight (internal) and its backend to Fly on 2026-10-04:

| Release | Built | Still yours |
|---|---|---|
| Ground truth | the PostGIS deploy gate, `app/jobs/reprocess.py`, `scripts/play_report.py`, `scripts/replay_fights.py` (run on made-up outings only: 13 short rides on the hosted backend), the source documents | ride 0.5.0 (protocols 1 to 3, sound in a pocket, a shape on real streets); art sign-off |
| 0.6.0 Words and faces | everything listed below | the gate outing (protocol 4); art sign-off; a read-through of the new lines |
| 0.6.1 Hold | server, phone and wrist; `effort_combat` off | the replay with real outings; protocols 3 and 5 with a fight; then the flag on |
| 0.6.2 The Board | titles (migration 0009), working knacks, arcs settled once, Act I, posters, the entry, the week's notice | the gate outing on an Act I step; a snapshot before 0009 runs on Fly; `story_quests` on |
| 0.7.0 Runes and the fog | runes held, ranked, inscribed and woken (migration 0010), deeds, rune rides, `INSCRIBE_RUNE` and `CARRY`, Act II, the ink fog on the Journal map and behind `ink_fog` on the World tab | a rune ride planned, ridden and woken; the wash seen over your own cells |
| 0.7.1 Plain sight | the lamp (server on Fly, phone in the build), one icon set (game-icons.net) across the app and the Watch, docs/VOICE.md and the wording pass on server, phone and Watch, how to play, Next up, the map legend, a labelled Plan a ride, markers that answer a tap, the Watch map's dot pointing the way you face, Settings and story where they can be found; CI on every branch push and `make backend-test-pg` | read the new words in one sitting; hand the phone to someone new; quest text and lore in your own words |
| 0.7.2 What you carry | gear in five slots (15 items, Common/Rare/Legendary, migration 0011), drops with pity and a full bag sold on the spot, the lamp, map piece, rest token and sealed chest, the stall, selling, coin history, every level pays (past levels paid once), 12 more creatures with variants and grudges, the model-written entry behind `chronicle_llm`, the last world cached for offline starts; the Watch catches up (the game on its map, the fight in its health ring, Journey's end on the wrist, finds in the overlay) | protocol 6 (battery); the stall's prices against a real week's coins (`scripts/price_check.py`); the new creatures' pages in your own words |

Not built from 0.7.0's list: the World tab's ink fog is behind its flag and unseen on a device; the
phone folds neither waking nor Wunjo's stops (the server does, and the reckoning says so).

## Context

You asked for the RPG plan to be continued and expanded into one full plan that takes in the existing roadmaps. There are six of them, and they no longer agree:

| Roadmap | Where it lives | State today |
|---|---|---|
| The product spec's ten phases | `docs/PRODUCT_SPEC.md`, the README status table | 0 to 3, 6 and 8 live. 4 (navigation) and 5 (Watch) written, never ridden. 7 (social) built on the server and switched off. 9 (living world) has creatures, chests and five arcs; regional events not started |
| "A planner that answers" (M0 to M5, September) | an earlier plan file | All built: coins, change of trade, run and walk, quests for anyone, creatures and chests, bounty and days kept |
| "The ride talks back" (0.5.0, agreed 2026-10-01) | an earlier plan file and project memory | Built and on master; **never ridden**, so its sound is unproven |
| "Home ground" (0.6) and "Between rides" (0.7) | same plan, plus a menu of about 50 ideas | Not started |
| The field tests | `docs/FIELD_TESTS.md` | Protocols 3 to 8 not ridden (off-route, crash recovery, Watch, battery, typed request, somewhere new) |
| Promises made in other docs | `docs/PRIVACY.md`, the design canvas | Home masking, account deletion and a purge job "before beta"; a dozen design-only screens |

This plan replaces all of them. It keeps the RPG work you asked for at its centre: there is no world, "runes" is six nouns, a character is a name and two bars, a fight is a pass/fail check, every face is an SF Symbol, and quests go nowhere. Around that it places everything else still open: field tests, the ride's sound, things between rides, the long game, and what would have to be true before anyone else plays. Appendix K traces every idea from every earlier roadmap to the release that now carries it, or to the reason it was dropped.

Your decisions so far: **dry folk-fantasy** in today's voice, **art drawn in code**, **effort is damage**, and **sound unproven on the road** (so story sits before and after the ride; mid-ride additions are a few chimes, taps and at most five spoken words).

How it was made: a seven-part audit of the code; five designers (world, character, combat, presentation, campaign); five adversarial reviewers, each checked by a verifier against the code. The review changed the first release into three, fixed the fight maths (weaknesses did nothing on foot, a typed note beat everything, any city block counted as a rune), and made the combat flag a real way back.

Standing rules (`docs/PRODUCT_SPEC.md`): never reward speed; nothing to read or tap while moving; rewards are server-authoritative through the single writers; RPG stats never touch routing or safety; few notifications; nothing invents facts about real places.

## The game in one page

**The premise.** Every road was written once, by people who cut a rune where two ways met. People still use the roads. Nobody reads them. A road that is used and not read goes vague: that is the fog. Things settle in the vague parts. You read.

| Today | In the world |
|---|---|
| Fog, unexplored cells | Ground you have not read. "Plenty of people have passed it. That is not the same thing." Read ground stays read: "The book does not forget; that is what it is for." |
| Monsters | Things that settle where nobody is paying attention. Not evil; in the way |
| HP | "Its hold." Effort loosens it; enough and it is seen off |
| Kill methods | What it wants: the road used, new ground, height, a rune cut with your track, a word written down |
| Chests | A waywright's box, buried when the gate closed |
| Coins ("AC") | Old coin. "The roads pay in old coin. Nobody will change it for you." |
| The board, the bounty, the summary | Pinned by Ada Pym, reported by Nell Foss, counted by Walter Garth |
| The four classes | Four trades of road-people, with a guild each: Wayfinders, Cutters, Menders, Clerks |
| Levels | How well the roads know you, from Passer-by to Known to the Roads |

**Seven pillars**, and the release that delivers each:

1. **A world.** A world bible with one lexicon, five people who post notices and sign the codex, a bestiary, 24 runes with meanings. *0.6.0*
2. **Faces.** A woodcut art system drawn in SwiftUI; later an ink-and-parchment map and fog as unpainted paper. *0.6.0, 0.7.0, 0.7.3*
3. **Fights.** Every creature has hold, a habitat, two wants and one thing it does not mind; effort near it and on the way loosens it; later, persistent old ones that take several outings. *0.6.1, 0.8.0*
4. **A character.** Titles, working abilities, then runes inscribed as a build, deeds, gear, and something at every level. *0.6.2, 0.7.0, 0.7.2*
5. **A campaign.** "The Old Roads": five acts and an ending on the existing arc machinery, so it works in any city. *0.6.2 to 1.0*
6. **A rhythm and a record.** A codex, a written entry per outing, a weekly notice, seasons, named districts and ground you keep, an atlas of everything. *0.6.2, 0.9.0*
7. **Reach.** The game on the lock screen, the wrist and the home screen; quick starts; a card to share; later, other people. *0.7.3, Beyond 1.0*

## Decisions

Yours (taken): folk-fantasy in the current voice; code-drawn art; effort is damage with no on-screen choice encounters; spoken lore stays optional.

Mine. Change any.

| Decision | Why |
|---|---|
| **1.0 means the game is whole for one player**: a campaign with an ending, a build, bosses, districts, seasons. Other players, the App Store and social come after, and only if you open it up | Every earlier roadmap deferred social until there is a second player; the spec says the core loop must work first |
| **Each release is gated on one real outing** with the build before it, not on a date | Field testing is the scarce thing; every first-week bug was in code the suite marked green |
| The premise turns on **reading**, not passing | "Nobody passes" is false on a real street, and fog that never returns cannot be "forgetting" |
| Currency is **"coins"** with a coin mark; "AC" goes; code names stay | "Pence" on a stall reads as sterling; today's spoken lines already say coins |
| On screen: **hold, loosened, seen off, wants, does not mind** | The no-gore voice. Blow, wound, kill and fight stay in code |
| **The speed test is retired**: PACE goes, the Tempo quest and its arc step are replaced | The two places the app rewards speed today |
| Five kinds of effort: `ROAD, GROUND, CLIMB, RUNE, WORD`; on screen "the road, new ground, height, a rune, the word" | One vocabulary on server, phone and copy |
| **The runes you hold are the runes you cut.** Road forms: loop Raido, zigzag Sowilo, triangle Kenaz, square Dagaz; Ansuz by a note, Wunjo by a stop | The first draft had you holding six runes and tracing five others |
| **The build is three things, not fifteen**: runes (rules), gear (yields and rules), abilities (the only percentages). Deeds are a record, not points to spend | The review counted fifteen systems summing into one capped number |
| Classes stay Explorer, Wizard, Warrior, Scribe; the noun in copy is "trade" | Renaming the classes is more than this needs |
| One `CharacterSheet`, built on the server and frozen onto the ride, is all the fight maths reads | Phone and server cannot disagree |
| The bounty lives 36 to 48 hours, not until midnight | Midnight pays for riding after dark, and the server's midnight is UTC |
| The Codex is a segment of the Journal, not a fifth tab | No room in the tab bar |
| No server push. No notification is added beyond today's two reminders and an opt-in pledge (0.7.3) | "Few notifications"; everything else can be found on opening the app |
| Voice-dependent ideas (a familiar that speaks, audio adventures, hot and cold) wait for the road test of 0.5.0's voice | Memory and the review both say: do not build on unproven sound |
| Nothing before 0.7.2 needs a language model; when one is used it gets categories, never place names, and never overwrites an authored line | The key may not be set on Fly; privacy |

## The roadmap

Sizes are relative to 0.5.0, which was 3,126 lines in 53 files. Each release is one TestFlight build tagged `vX.Y.Z`.

| # | Release | What the player notices | Size | Migration | Gate outing |
|---|---|---|---|---|---|
| 0 | **Ground truth** | Nothing new; 0.5.0 is ridden and the risky ideas are proven or dropped | M | none | 0.5.0's sound and protocols 1 to 3 |
| 1 | **0.6.0 Words and faces** | A premise, people, a codex; every creature has a face; the sheet can be read | L | none | protocol 4 (crash recovery) |
| 2 | **0.6.1 Hold** | Fights over an outing, habitats, a lamp to summon, a quarry to go out for | L | `0008` | protocol 3 again with a fight; protocol 5 (Watch) |
| 3 | **0.6.2 The Board** | Titles, working abilities, Act I with a finale, a poster on every notice, a written entry, a weekly notice | L | `0009` | protocol 2 on an Act I step |
| 4 | **0.7.0 Runes and the fog** | Runes inscribed and woken, rune rides, deeds, the fog back as ink, Act II | XL | `0010` | a rune ride |
| 5 | **0.7.1 Plain sight** | One look (an open fantasy icon set everywhere), plain words (docs/VOICE.md), a lamp that says what it will do, a "Next up" card, a map legend, how to play | L | none | someone new plays without asking |
| 6 | **0.7.2 What you carry** | Gear, loot, a stall and the book, every level pays, grudges, twelve more creatures; the Watch catches up (the game on its map, fights, Journey's end) | L | `0011` | protocol 6 (battery) |
| 7 | **0.7.3 Between rides** | Lock screen, wrist and home screen; quick starts; a sealed notice; the pledge; letters to yourself; a card to share | L | `0012` | a quick-started outing |
| 8 | **0.8.0 The old ones** | Bosses that take weeks, lairs, treasure maps, Act III | XL | `0013` | protocol 8 (somewhere new) |
| 9 | **0.9.0 The parish** | Named districts, kept ground, an atlas, seasons, Act IV, cosmetics | XL | `0014` | protocol 7 (typed request) |
| 10 | **1.0 The long way round** | Act V and an ending, a familiar, the board after the ending, a dark palette | L | `0015` | a full season |
| 11 | **Beyond 1.0** | Only if you open it up: other players, the App Store, history import | — | — | — |

Releases 4 to 10 are written here in enough detail to build. Each still starts with a short design check against what the release before taught, because several of their numbers depend on what you do on the road.

## What gets built on approval

Ground truth, then 0.6.0, then each release in order after its gate outing. At the start, project memory is updated to point at this plan, since it replaces the 2026-10-01 roadmap.

---

## 0. Ground truth (about a week, alongside your first outings)

Three kinds of work, all done before 0.6.0 ships.

**Ride what exists** (yours). 0.5.0 has never been on a road.
1. Protocols 1 to 3 from `docs/FIELD_TESTS.md`, phone in a pocket, sound on. On one of them, play a scripted fight from a debug button (item 6). Write down whether traffic could be heard, how many sounds a minute, whether any wrist tap felt like a turn, and whether the voice should stay off.
2. On the same outing, ride a loop and a triangle on real streets and note any turn that felt wrong. If one did, runes are cut on foot only.
3. Fix `docs/FIELD_TESTS.md` §5, which says to start from the Watch (impossible today), and add a sound protocol.

**Prove the risky RPG ideas** (built while you ride).

4. **Art contact sheet.** The path parser and renderer, and a test that draws marks to PNG with CoreGraphics under `swift test`, so they can be inspected without a simulator. First sheet: all 24 runes, the Explorer crest, all seven creature bodies as silhouettes, Fen Troll and Rook Lord in full, at 20, 34, 48 and 96 pt in phone and Watch palettes. You sign off. If a creature cannot be recognised at 34 pt, creatures become twelve fixed heraldic devices.
5. **Fight replay.** Write the pure `world_objects/fight.py` and its tests now. Add `replay_fights.py`, which runs your real traces through it in date order with creatures placed by the new habitat rules. Traces come from GPX exports or a read-only proxy to the database. It prints, per outing: the share of effort that landed on anything; what was seen off, and how much of that was by accident; rune matches by shape; and how often a habitat was found near home. **Pass marks:** a 25 km outing does more than a 5 km one; at least a third of effort lands; at most one outing in five sees something off by accident. If fewer than about ten real traces exist, the numbers stay provisional.
6. **Things to judge by eye and ear**, from sample data: a static mock of the fight card, the sheet and a Codex page; thirty journal entries composed from your real outings, read in a row; the scripted fight played through the ride's audio.
7. **Read every place line.** Compose creature and place lines over every anchor in your home tile (about 250), printed with their map tags, and read them all for a joke at a sensitive place or a claim about a real one.
8. **The source documents.** `docs/WORLD.md` (premise, cast, trades, lexicon, voice sheet); the five drafts under `docs/design/rpg/drafts/`, each headed as superseded by this plan; this plan beside them; the content manifest (Appendix G).

**Make the ground safe to build on.**

9. The PostGIS migration job becomes a `needs` of the Fly deploy (`.github/workflows/fly-deploy.yml`). Today a missing migration passes the unit tests and still deploys.
10. `app/jobs/reprocess.py`, run with `fly ssh console`, reruns a ride whose processing failed. Today such a ride is lost for good.
11. A timing baseline for `process_ride` on your longest stored trace. A check of whether `ANTHROPIC_API_KEY` is set on Fly, and a log line saying whether the model is in use. The known-flaky board test run 40 times.
12. Docs that drifted: `docs/WATCH.md`, `docs/ARCHITECTURE.md` (classes ship on, not off), `docs/API.md`, and the backend README layout. `/health` reports `0.1.0`; it should report the app's version.
13. A read-only `scripts/play_report.py` answering each release's "it worked if" question from your own data: outings a week, effort landed, codex filled, coins in and out, steps done.

---

## 0.6.0 Words and faces

No migration. No change to how a ride is judged or paid.

**Backend**
- New pure `backend/app/lore/`: `config/{codex,runes,cast}.json` behind an asserting `lru_cache` loader (the pattern of `load_arcs`, `quests/story.py:54`). `GET /codex` returns the static entries plus what the player has met, derived from their `world_objects` rows the way `pieces_owned` does (`world_objects/service.py:131`), with a name-to-id alias table for rows spawned before now. `runes.json` carries each rune's `roadForm`. The router is registered in `api/v1/router.py`.
- `world_objects/config/world_objects.json`: each creature gains `id`, `family`, `habitat`, `wants`, `minds`, `leaves`, `elders`, `sigil` (Appendix B). Hollow Knight becomes Hollow Sentry. The spawner writes `speciesId` into every new payload.
- `characters/config/classes.json`: trade text, with optional `guild`, `saying`, `crest`. `quests/narrative.py`: `CLASS_LINES` rewritten; `SYSTEM` given the premise and register. `enrich` **merges** into the narrative dict, never touches an authored line, and falls back to composed text if the model's output trips the lint.
- `tests/test_lore_catalog.py`: every species has a codex entry and a sigil; there are 24 runes; each shape maps to at most one rune; every species wants a rune or the word; height is wanted only where the habitat implies it.
- **Voice lint** over prose fields only, whole words, with a short mechanical list (exclamation marks, AC, HP, loot, buff, spawn, tier, sprint, race, the lexicon's forbidden synonyms) and an allowlist. A matching Core test covers the Swift copy files.

**iOS and Watch**
- New SwiftUI target `RoadsAndRunesArt` in the existing package, with its own tests and palette type; `product:` lines in `ios/project.yml` for app and Watch. Core stays Foundation-only; the UIKit image cache lives in the app.
- One `Mark` enum drawn by `MarkView`, which first asks an `ArtSlots.illustration(mark)` hook (nil today), so an illustration can replace any face later. An unknown id draws a worn stone.
- Marks: 24 runes, 4 crests, twelve creatures (per Ground Truth item 4), 3 chests, coins, 5 kind marks, the frame kit.
- Swap points that switch on SF Symbol names today: `EncounterGlyph` (`Features/World/EncounterCard.swift:127`), `MarkerAnnotationView` (`Services/Maps/MapLibreView.swift:544`), `ClassEmblem` (`Components/Theme.swift:434`), `CoinPill`. Gold becomes a Theme token. Light mode is pinned at `RootView`.
- **Character sheet v1:** crest; title on a plain ribbon; abilities as rows with descriptions, each plainly marked working or "not yet"; a door to the Codex. Cycling profile and bikes stay below a rule.
- **Codex** as a Journal segment (`Features/Journal/JournalView.swift:95`):
  - Creatures: silhouettes for the unmet, a habitat hint, what each leaves, "seen off 7 of 12".
  - Runes: in futhark order; rows not yet obtainable show as "not yet found".
  - Places.
- **Prologue:** four plates before choosing a trade, replayable from codex entry 1, plus a one-screen "what the board is" card for a player who already has a character.
- New `Core/Formatting/LoreCopy.swift` with `purse(_:)` for every amount. First half of the rename sweep, only what is true today: coins, the reckoning, a knack, days kept, trades, "Go out as", loading and empty states (Appendix F). String-asserting tests change in the same commit.

**Done when:**
- the lint is green and no "AC" is left on any screen;
- you have signed off each art sheet;
- your past kills show as met in the Codex;
- a 0.5.0 build still works against the server;
- the gate outing is done.

**It worked if** you open the Codex between outings.

---

## 0.6.1 Hold

Migration `0008`: `rides.loadout_snapshot`. The whole vertical sits behind one flag, `effort_combat`: spawner payload, resolver, the Tempo offer and the phone's fold.

**The model** (Appendix C)
- New pure `world_objects/fight.py`: a per-fix fold over positions and altitude, never a timestamp. A test resamples one path at the fix spacings of the three battery modes and asserts the same result.
- `world_objects/service.py`: `claim_from_ride` (:457) calls it in place of `_fight` (:621).
  - Each creature is resolved in its own guard: an exception becomes a miss with a `FIGHT_ERROR` flag, never a lost outing.
  - Creatures are chosen by the ride's own window, whatever their status now.
  - Wounds are written by **reassigning** `payload` (the JSON column does not track in-place edits) and keyed by ride id, so a rerun replaces rather than adds.
- **The way back:**
  - The spawner always writes both the new `species` block and legacy `killMethods` (never PACE).
  - With the flag on, the API sends `killMethods: []` plus the new optional fields, so a 0.5.0 phone can never call a win. With it off, it sends today's payload.
  - Deploy with the flag off; turn it on once the new build is on your phone.
- **Placement**, so effort lands on something:
  - Creature rings scale with the declared activity.
  - The nearest-300 cut-off at `service.py:341` is fixed.
  - A planned route places one creature along its far half.
  - Anchors nobody has passed in 30 days are favoured, and the card says so: "You have not passed here in 41 days."
- **Habitat and sensitive places.** `Anchor` gains the place's tags, and species is chosen after the anchor. One predicate, `discoveries.is_sensitive()`, applied where anchors are built, covers creatures, chests, pieces and quest targets: memorials, monuments, graves, places of worship, hospitals and anything tagged private. `KEEP_TAGS` is widened and the tile version bumped so stored places gain the tags; until then every memorial and monument counts as sensitive.
- **The bounty** lives 36 to 48 hours. A loosened bounty stays on as an ordinary creature at the ordinary purse, and its linked quest stays with it.
- **Pay:**
  - Coins only when it is seen off.
  - Half its XP by share of hold removed (new source `BLOWS_LANDED`), half on the finish, through `grant()`.
  - Tap-claimed coins come off that day's cap.
- **The lamp.** The lure has an endpoint and no button. It is fixed to place one creature at a place you pick, refuses without charge if it cannot, and gets a button. It is the first thing coins buy.
- New `characters/sheet.py` with `CharacterSheet` (Appendix D), carrying only the trade's base for now.
  - `rides/service.py:65 create_ride` freezes it onto the ride.
  - The ride and character responses both carry it, so an outing started offline uses the last one seen.
  - Combat constants reach the phone through `GET /config`.
- PACE leaves the offers; the Tempo template is marked `retired`.
  - The Iron Hours' first step points at the long-haul template, with its slug kept and its text rewritten.
  - A Tempo step already issued is retired at deploy.
  - `load_arcs` asserts no step uses a speed objective.

**The phone and the wrist**
- New `Core/Encounters/FightResolver.swift`, held to the server by shared fixtures (`tests/fixtures/fight_tracks.json`, copied like `rune_tracks.json`). The phone under-claims by 5%.
- Known cells are fetched at ride start from `GET /world/exploration` (not gated on the fog flag) and cached with the route. Without them, or without a sheet, the phone says nothing about fights.
- **Small on purpose while moving.** Three sounds: it has noticed you; a rune or word landed; it is gone, or got away. A fight sound is dropped, never queued, if anything is playing. It never plays inside the turn-cue window, and off-route always wins. Only the quarry, or else the nearest creature, makes a sound.
- **Wrist taps** come from a Core vocabulary that a test keeps disjoint from the turn taps: start, success, failure.
- **Ride screen:**
  - a sigil in a ring of hold that redraws in tenths, with no animation and no numbers;
  - no new pills;
  - words only at a standstill, defined once in Core (valid speed under 0.7 m/s for five seconds; unknown speed counts as moving). The note button follows the same rule; today it shows while moving.
- **A quarry.** "Plan a route here" on a creature marks it as what the outing is for. It is the one that speaks, and the reckoning leads with it.
- **Encounter card:** what it wants and does not mind, its hold, its rune and road form ("Raido. On the road, a loop."), and how many of the cells round it are new to you.
- **Reckoning:** a `fight` stage (`Components/AdventureSummaryView.swift:36`). "Grey Stag got away at 31 of 400. Another 13 m of height would have done it. It is there three more days." An ink mark stays on the map where something was seen off. The reckoning gets CoreHaptics patterns (no wrist taps).
- Second half of the rename sweep: the road, seen off, loosened, hold, wants, rune names, spoken lines. The Watch overlay needs an optional kind on its message.

**Done when:**
- the replay meets its pass marks;
- the flag works both ways with new creatures live;
- a 0.5.0 phone never announces a win;
- a failed ride can be rerun;
- timing is within budget;
- on the gate outing a fight could be followed by ear and wrist, and nothing was taken for a turn.

**It worked if** at least once a week you choose where to go because of something on the map.

---

## 0.6.2 The Board

Migration `0009`: `character_titles`, `characters.title_pinned`. Two separate pieces of work.

**(a) Titles and abilities**
- `character_titles`, written only by a new `progression.service.award_title()` (called from `grant()`, character creation and arc completion). A title is worn automatically only until you choose one.
  - The backfill maps the seven old level titles to new ones and renames the stored title.
  - It is tested on a copy of production, after a database snapshot.
  - Endpoints: `GET /character/titles`, `PUT /character/title`.
- Level titles become degrees of being known: Passer-by, Familiar Face, Roadwise, Journeyman, Waywright, Old Hand, Known to the Roads. Every other level pays a line or a deed title.
- Abilities:
  - only the current trade's count (`characters/service.py:61`);
  - points are derived per trade, ending the farmable shared pool (your balance before and after is noted);
  - each description states its numbers.
  - Thirteen work (Appendix D); Cartographer, Arcane Sight and Second Chance say "not yet".
- Caps: arc, set and streak purses are exempt from the 800-coin cap; the never-enforced daily XP cap applies to tap claims.
- **Welcome back:** the first outing after fourteen days or more pays double XP for its first kilometre. "The roads kept your place."

**(b) The campaign, the entry and the week**
- Fixes first:
  - `story.settle_arc()` on every completion path, keyed so it pays once (a tap-completed step ends an arc unpaid today);
  - story steps get an authored `completion`;
  - a hidden riddle stops leaking its place name;
  - a creature a live step points at does not leave.
- **Tracks:** one live step per track (MAIN, SIDE), made per-track in the board loop and `offer` as well as `story.due`. An unplaceable step reports `WAITING` with a reason authored on its template.
- **Act I, "The Board":** What Settles and The Rune at the Crossing after First Light (you start at chapter 2 if First Light is done).
  - Finale: a named elder bound to its step, 400 hold, placed beyond the near ring, wanting Raido without requiring it; about two outings.
  - Reward: a title and coins.
  - The draft's six role names are re-voiced to the five cast; "three crossings" becomes "three patches".
- **A poster on every notice:** a cast member and one of their lines, attached after the narrative step so nothing drops it. A `completion` line for each of the 39 templates.
- **The entry:** a pure `chronicle.compose(facts, seed)` in `process_ride`, in its own guard, stored on the ride and shown in the reckoning and the Journal. Slots are sized by how often the replay says each fires; at most one dry turn per entry.
- **The week's notice:** one goal per ISO week, fixed target, paid once through the single writers.
- iOS:
  - acts then chapters in `Features/Quests/StoryArcsView.swift`;
  - the poster's line on quest cards;
  - a `codex` stage that stamps first meetings;
  - UI tests for the Codex, the sheet, Titles, and one launch that does not skip the prologue.

**Done when:**
- every step of Act I can be placed at home and in two other towns;
- thirty entries read in a row do not read alike;
- the title backfill has run on a copy of production.

**It worked if** Act I is finished within three weeks and you read the entries.

---

## 0.7.0 Runes and the fog

Migration `0010`: `rune_holdings`, `character_deeds`, `loadouts` (inscriptions now, gear in 0.7.2). The release where the title is earned: runes become the build, and the roads become something you cut them into.

**Runes as the build** (Appendix H)
- **Holdings and ranks:**
  - Finding a rune you hold adds a shard; two shards and some coins raise it a rank.
  - Ranks I to III improve reach and size, never a percentage.
  - The Road Six come from finds and from Act II; the Ground Six only on their own kind of ground (water, green places, old ground).
  - A pity rule: after four repeats, the next stone is one you do not hold.
- **Slots:** three, opening at levels 1, 10 and 25.
  - Only inscribed runes act. Each changes a rule; for example, Wunjo makes a five-minute stop at a café or green place count as the word, and Sowilo lets a cut reach 2 km.
  - Changing them is free, and refused while recording.
- **Waking:** cutting an inscribed rune's road form anywhere on an outing wakes it. It counts one rank higher for that outing and lands a rune blow on every creature within reach. Once per outing.
- **Rune rides.** The planner offers a route in a road form: "Cut Raido here: a 2.4 km loop." Waypoints on the road network make the shape, so the rider never improvises a U-turn. Loops, triangles and squares only on a bike; zigzags on foot.
- The cut leaves a mark: each rune cut is drawn where it was cut on the World and Journal maps ("Raido, cut by the pond, the fourth"), and the sheet counts them.
- Single writer `inventory/service.py` with an `item_events` ledger. Every row is idempotent by ride and object.

**Deeds**, a record rather than points
- Five lifetime counters from the trace: Legs (distance), Lungs (height), Eyes (new ground), Hand (runes cut), Ink (words written). Each has its mark on the sheet.
- They change no numbers. Each has five thresholds that award a deed title and a crest frame. "Records that are not speed" live here: furthest from where you usually start, most new ground in one outing, highest point reached.

**The fog, back as ink**
- First on the Journal map card, then on the World tab behind `ink_fog`.
- It replaces the old hexagon layer. H3 cells are joined with `cellsToLinkedMultiPolygon` (already in `ios/Packages/H3`), the edges are softened, and the result is drawn as one paper-coloured wash with a feathered edge and a dotted frontier.
- The ride screen never shows it. The World tab gets a frontier chevron toward the nearest unread ground.
- With the fog visible, the last three abilities work: Cartographer (one more reveal ring), Arcane Sight (stones more likely), Second Chance (one missed optional objective counts).

**Act II, "Five More Cuts"**
- Kenaz, Ansuz, Wunjo, Sowilo, Dagaz: four steps each (learn, fetch, prove, cut). Each chapter's reward is the rune's first rank and a line in the codex.
- New objective `INSCRIBE_RUNE`: cut a named road form round a place (a park or landmark, never a junction). It reuses the shared matcher.
- New objective `CARRY`: the trace reaches place A, then later place B. It shares a second-place slot in the generator with `ANY_FORK`.
- Consequences without choices: an optional objective you did sets a flag that changes a later notice ("Posted for whoever came back by the far gate"). Nothing is ever locked out.
- Standing with the cast is folded into titles: finishing their notices earns their titles, and nothing else is tracked.

**Done when:**
- a rune ride is planned, ridden and woken on the gate outing;
- the replay over stored traces shows accidental wakes at most one outing in five;
- the wash has been seen from your real cells and does not read as hexagons.

**It worked if** you plan an outing to cut a rune.

---

## 0.7.1 Plain sight

Added on 2026-10-04 after the first rides of 0.7.0, which found three things no
release had planned for: the art came from two worlds (woodcut marks beside
SF Symbols in coloured discs, and two symbols for each class), the words were
jargon and often eerie ("the reckoning", "a knack", "loosened", "read ground"),
and nothing said what to do (the lamp refused almost everywhere, and its
refusal named the wrong reason). No migration.

**The lamp** (already fixed). The server refused any named place with a chest
or piece on it, which on a normal day is nearly all of them near the player;
two lamps a second apart took coins for nothing. Now only a creature at the
place stops it, and says so by name; coins go only after it comes; a free check
(`GET /world/objects/lure`) lets the place card say what will happen before
anything is spent.

**One look.** The user chose an open icon set over redrawing in code:
game-icons.net (CC BY 3.0, credited in Settings and `GAME_ICONS.md`), converted
to paths the art package already draws, so the Watch and the contact sheets get
them too. A thing in the world is a paper token with an ink ring and its icon;
a class is its icon on a shield in the class colour; system actions stay SF
Symbols. Every map marker, class tile, place icon, streak, reckoning line, the
tab bar and the Watch.

**Plain words.** `docs/VOICE.md` replaces the dry voice and lexicon for
everything but quest text and lore, which the game's author will write: one
word per idea (creature, defeated, health, weak to / resists, class, skill,
streak, journey), buttons a verb and a noun, errors that say what to do. The
server's messages and labels and the voice check follow it.

**Knowing what to do.**
- A "Next up" card on the World map: one sentence, one button (your first ride;
  a chest in reach; a skill point; the nearest creature or chest; the board).
- The main button says "Plan a ride".
- A map legend drawn with the real marks, from a "?" among the map's buttons.
- Every marker does something when tapped.
- How to play, in five pages, in place of the premise plates; shown once to
  players who already have a character.
- Settings, the Codex and story arcs where they can be found.

**On the Watch.** The same marks and words, and the map's dot now points the
way the rider is heading (a Core `CourseTracker`; the phone sends the course
with each update, and a Watch with an older phone works it out from the
positions). The rest of the Watch's catching up is in 0.7.2.

**Done when** someone who has never seen the app plays an outing without asking
what anything is, and the user has read the new words in one sitting.

## 0.7.2 What you carry

Migration `0011`: `inventory_items`, gear in `loadouts`.

**Gear** (Appendix H)
- Five slots, opening at levels 1, 3, 5, 13 and 21: Bell (creatures), Lamp (fog and sight), Bag (coins), Map case (the board), Keepsake (runes).
- Fifteen written items in three rarities: Plain, Good and Storied (one of each Storied, ever).
- Each item is a yield or a rule, never a damage percentage. No secondary rolls, re-forging, durability or set bonuses. A full bag sells the newest drop on the spot and says so.
- Items never raise a server cap.

**Loot**
- Drops by source and tier, seeded from the object so a rerun drops the same thing.
- Pity: five finishes without a Good item forces one.
- Items bypass the coin and XP caps; leavings are trophies counted on the codex page.
- Quest rewards finally fill their empty `items` arrays: Good on hard, Storied chance on epic.

**Consumables**
- the lamp (existing);
- a map fragment, which reveals ground round the nearest unread place through `exploration.reveal(via="ITEM")`;
- a rest token, which keeps days kept over one missed day;
- a sealed chest, opened at a standstill, which holds an item of stated rarity.

**The stall and the book**
- Walter Garth's stall: four offers per ISO week, seeded and computed on read (no scheduler).
- Prices come from the real sum of your coin ledger before this release, not from estimates.
- The book is the wallet history, which has an endpoint today and no screen.

**Every level pays.** A table (Appendix H) so each of 50 levels gives a slot, a consumable, a line, a deed frame or a title. Levels gained before this release are paid on first launch.

**The world grows**
- Twelve more creatures (Culvert Imp, Stile Boggart, Milestone Wight, Gate Grim and others).
- Variants: stubborn, skittish, mossed-over.
- Grudges: something that leaves loosened twice returns once to the same place, with an epithet from what failed ("Fen Troll the Unimpressed").

**The model-written entry**
- Behind `chronicle_llm`, written after the summary is committed so the reckoning never waits. Eight-second timeout, 200 tokens, six a day, categories rather than names.
- An eval: read ten in a row; no two share a first sentence; a second call can match entries to facts at 9 of 10.
- The composed entry stays the fallback.

**Offline and recovery.** The last world loaded is cached beside the route package, and crash recovery replays the game layer as well as the ride.

**On the Watch: catching up with the phone.** The Watch was built for 0.5.0's
ride and has had only words and marks since. In this release it gets the game:
- **The game on the Watch map.** Creatures, chests, rune stones, the bounty
  and the quarry near the route drawn as their marks, and each objective's
  place as a flag (sent with the route summary, changes with the updates;
  optional fields, so an older Watch ignores them). Stops drawn as their place
  marks, not dots.
- **A fight on the wrist.** The quarry, or else the nearest creature, as its
  mark in its health ring on the Quest page, redrawn in tenths with no numbers
  (the phone already folds the fight; it sends the species and the tenths), with
  the fight taps Core already keeps apart from the turn taps.
- **Journey's end on the wrist.** After Save, one card: creatures defeated,
  coins, XP, a level, anything found or dropped. Then back to the idle screen.
- **Drops** in the objective overlay with their mark.
- `RideStoreTests` for every new field; a Watch-palette sheet for every new
  mark in the contact-sheet test.

**It worked if** a drop changes what you wear, and coins run low at least once,
and the Watch alone is enough to follow a fight.

---

## 0.7.3 Between rides

Migration `0012`: `pledges`, `letters`. The 2026-10-01 "Between rides" release, rebuilt on the art and the world.

**On the lock screen, the wrist and the home screen**
- **Live Activity and Dynamic Island**, in a new ActivityKit target that reuses `MarkView`. It shows what navigation shows: next turn and distance, plus the quarry's sigil and ring with no words.
- **Home-screen and lock-screen widget:** days kept, the bounty, the week's notice, a codex count. Fed from the app group's snapshot; no network in the widget.
- **Watch complication:** the quarry's or the bounty's sigil, drawn by the under-28 pt silhouette rule.

**Quick starts**
- App Intents for Siri, Shortcuts and the Action Button: "Start an outing", "Go out for the bounty", "Give me something for forty minutes".
- **A start command from the Watch**, which asks the phone to start when it is reachable. This makes field protocol 5 possible as written.
- **Next up on the Watch's idle screen**, in place of "Start a ride on your iPhone": the streak, the bounty and how far, and a quest to start from the wrist.
- **Always-On** keeps the map's dot and the next turn, dimmed, not only the turn.

**A sealed notice** (the menu's "fate's errand"): choose 20, 40 or 90 minutes. Ada Pym's notice picks the direction and keeps the objective hidden until halfway, using the existing hidden-objective machinery.

**The pledge**
- Opt-in. The evening before, you pledge a creature or a notice for tomorrow. It sends one local reminder at a time you choose.
- Done, it says "You said you would. You did." Missed, it costs nothing and is never mentioned.

**Letters to yourself**
- At a standstill, leave a line at a place.
- Pass within 60 m a season or more later, and the reckoning (never the ride screen) shows it: "You wrote this here in October." It is never sent anywhere.

**Your own treasury**
- Set real-world rewards against coins: "New bar tape at 5,000."
- It is a bar on the book page and nothing more.

**A card to share**
- Built with the frame kit and `ImageRenderer`.
- By default it carries the creature, the fight line, the entry's first sentence, deeds and title.
- It carries no map, trace, district or "home ground" unless you add the trace, and an added trace is masked for its first and last kilometre (the home masking promised in `docs/PRIVACY.md`).
- No rune glyph on the card.

**The parchment map.** The ADVENTURE style becomes a bundled style forked from OpenFreeMap's positron, keeping the `openmaptiles` source id so POI taps work. It is World tab only, behind `parchment_map`, swapped at `WorldView.swift:76`.

**It worked if** at least one outing a week starts from a widget, a shortcut or the Watch.

---

## 0.8.0 The old ones

Migration `0013`: `old_ones`. The living-world phase of the spec, for one player.

**The old ones** (Appendix I)
- Persistent personal bosses, one at a time, found about once a week with no scheduler: a rumour appears when you have seen off three things since the last one.
- Each has three phases with different wants. At most one phase breaks per outing and per day, so three phases means at least three outings.
- Left alone, one regains a tenth of its hold a week and goes dormant after four weeks. It never takes anything from you.
- Each drops a Hard Six rune and a Storied item.
- **Five of them:**
  - **The Blank:** the largest connected block of unread cells that contain a way. It falls to new ground and works in any town.
  - **The Drowned Lane:** water with a path beside it. Falls to the word and stops.
  - **The Long Drag:** the highest point the router can reach. Falls to height.
  - **The Slow Coach:** a long named trail. Falls to the road.
  - **The Worn Stone:** a place where the mark has gone smooth. Falls only to its rune.
- Anchors are only where the routing engine can reach for your activity, with one free move: "It is somewhere you cannot go. Ask again."
- **The boss page:** the sigil in a cartouche; hold as an inked tally with a notch per outing; what it wants, with numbers; the outings so far; "Plan a route here".

**Lairs.** Five of the seven way-cells round a park, visited (not metres inside), over at most 14 days. Foot only unless the cells hold ways a bike may use. The reward is a strongbox.

**Treasure maps**
- A map fragment with a riddle and no marker. The box is found by reading the ground: the riddle names what is there (water, a hill, a green place), and the generator's hidden-objective rules keep it fair.
- **Hot and cold**, a tick that quickens as you near the box, is added only if the road test passed sound.

**Act III, "What Holds the Ground":** Habits, The Lair, The One That Stayed (a new objective, `WOUND_BOSS`: take N hold off the old one on any outing), Double Pay.

**Also in this release**
- **Signature haptics** at rest (a box is two knocks and a rattle, a phase break a swell).
- **Capstone abilities**, one per trade at trade level 20.
- **The Hard Six** in the codex.

**On the Watch:** an old one's phase ring and mark on the Quest page while it is
the quarry; a phase broken is one tap and its mark in the overlay. Hot and cold,
if built, is wrist taps only.

**It worked if** an old one changes where you go for more than one week.

---

## 0.9.0 The parish

Migration `0014`: `regions`, `user_regions`. The 0.6 "Home ground" ideas that were not yet built, and the atlas from 0.7.

**Districts** (Appendix J)
- Real names come from OpenStreetMap place nodes (suburb, neighbourhood, village), with a cell joining the nearest within 4 km. They are a fifth set in the importer, kept out of the "?" places.
- An epithet is computed from what is there: "Rotherhithe, the wet side". It is always after a comma, never fused into a fake place name.
- **An honest percentage.** The denominator is only cells that contain a way: highway ways, minus motorway, trunk and private, fetched once per district. Until that fetch succeeds, the page shows a count, never a percentage.
- Completion at 90% pays the dormant `REGION_COMPLETED` XP and a purse, once.
- **Kept ground:**
  - A district is kept at 50% or more and passed through in the last 30 days.
  - It pays a little rent once a week on your first outing, at most ten districts: "Rotherhithe is kept. Five coins a week for as long as you keep passing through."
  - Lapsing changes a word, nothing else. Cells never regress.
- **A district's page:** its ledger of places found, things seen off, runes cut, notices done, first and last passed.

**The atlas** (the Journal's Map segment grown up)
- every trace you have made on one parchment map;
- a calendar of outings;
- a year page with deeds and firsts.

**Seasons**
- Quarter days (Lady Day, Midsummer, Michaelmas, Christmas), worked out from the date, with no scheduler.
- Each opens one SEASON-track arc of three steps; a missed one returns next year. Rent doubles in the three days round a quarter day.
- Names are configurable and flip by hemisphere (the locale rule in Appendix A).

**Act IV, "The Parish":** Home Ground, Beating the Bounds, The Next Parish, Going Quiet.

**Also**
- **Cosmetics at the stall:** route ink, marker frames, crest frames.
- **Place lore from Wikidata:** fetched once per tile at import, never per ride. A line is used only if it passes the validator: no capital word or number not in the facts. The Trade Six complete in this release.

**On the Watch:** a district entered is named on the next standstill, never while
moving; Journey's end on the wrist says which districts were kept.

**It worked if** you ride a known district on purpose to keep it.

---

## 1.0 The long way round

Migration `0015`: `familiars`. The game is whole for one player.

**Act V and the ending:** The Far Board, The Line, The Last Cut. The closing line: "Somebody has to keep the board. It has been you for a while."

**After the ending, the board keeps going**
- Seasons recur, old ones return stronger, and the week's notice continues.
- **A second board:** elders appear more often, and the campaign's places are drawn from farther out.

**The familiar**
- Chosen at the end of Act I in 0.6.2 terms, but delivered here with its full role: a hare, a crow, a dog or a cat.
- It grows with distance, has a sigil on the sheet and the map marker, and writes the first line of each reckoning in its own grammar.
- **If the road test passed voice:** the familiar becomes the voice of the ride, a persona phrasebook over the same five-word rule, with short spoken beats for a quest's route (start, the place, the way home) cached in the route package for offline use. If voice failed, it stays written.

**Runes as their real glyphs**
- Trace templates for each rune's actual shape, on foot only, as an alternative road form.
- Sowilo, Othala, Tiwaz and Algiz are never offered as templates.

**The look**
- the lamplight palette (dark mode), possible because the palette is a parameter;
- the first illustrations in the art slots, if you want them.

**A balance pass** over a year of `play_report.py`, with every constant still in config.

**On the Watch:** the familiar's mark on the idle screen and the complication.

**It worked if** you finish the campaign and keep going out anyway.

---

## Beyond 1.0: only if you open it up

None of this is planned in detail; it is listed so nothing is lost.

**Before anyone else plays**
- account deletion and the purge job (`docs/PRIVACY.md`; the App Store requires both);
- crash reporting;
- a cost guard on the model;
- privacy labels;
- external TestFlight;
- a decision on English-only or localisation.

**History import.** Past rides from Strava or GPX become read ground, so a new player does not start from a blank map.

**Fellowship**, from spec phase 7, the design canvas and the menu:
- friends see each other's codex and titles;
- cairns, a mark left at a place for a friend to find;
- crossing paths ("You crossed paths with Maya");
- parties where "Start" starts it for everyone;
- an old one a district's friends wear down together.

Nothing in it compares speed or performance, and nothing exposes live location.

---

## Rules every release keeps

- **Contract.**
  - Every new field is optional and every new enum decodes unknown values.
  - Each release lists, per field or endpoint: the server file, the Swift model, what a 0.5.0 client does with it, and the decoding test.
  - Each endpoint goes through the protocol, `Endpoints`, `APIClient`, `MockAPI`, `SampleData` and a `docs/API.md` sample.
- **Single writers.**
  - XP and titles through `progression.service`.
  - Coins through `economy.service`.
  - Runes and items through `inventory.service`.
  - Each writer is idempotent by ride and object.
  - New per-user tables join the delete list in `reset_character` (`characters/service.py:238`).
- **Flags.** Every release's new behaviour sits behind a flag that isolates it on both server and phone, with a written way back.
- **The Watch.** Every release says what changes on the wrist, or says "nothing on the Watch" and why.
  - A new field between phone and Watch is optional both ways: an older phone or Watch ignores it, and the Watch has a fallback when it is missing.
  - `RideStoreTests` cover each new message; the Watch scheme builds and its tests run with every release.
  - Nothing to read while moving still holds on the wrist: a mark, a ring, a tap, a word at a standstill.
- **Runes on screen.**
  - Plain Elder Futhark forms only: never doubled, never beside themselves.
  - Never on a share card, widget, icon, crest or ribbon.
  - Othala means what is kept, not home or heritage.
- **Real places.**
  - Creature lore describes the creature, never the place's history.
  - A landscape word comes from the place's tags, or is generic.
  - Nothing is asked for at a road junction.
  - Nothing stands at a sensitive place.
- **Privacy.**
  - "Home ground" is a display label only.
  - The model gets categories, not names.
  - Notes never leave the server.
  - `docs/PRIVACY.md` is updated with each release that touches this.
- **Your time is the critical path.** Each release needs one gate outing, one art sign-off and one read-through of its new copy.

## Verification

- **Backend:** `cd backend && .venv/bin/pytest -m "not integration" -q` (never piped) and `make lint`. Flags are switched in tests the way `test_story_arcs.py:23` does.
- **Migrations:** the PostGIS job gates the deploy. Locally, run upgrade, `downgrade -1`, upgrade on a scratch database. Take a volume snapshot before any data migration.
- **Core:** `cd ios/Packages/RoadsAndRunesCore && swift test`. It checks:
  - fight fixtures agree with the server;
  - every glyph parses and the contact sheets render;
  - turn taps and fight taps are disjoint;
  - summaries from older servers still decode.
- **App and Watch:** `xcodebuild test` for both schemes; `swiftlint --config ios/.swiftlint.yml ios`; `make ios-ui-test` with the stack up and idle.
- **Old client:** `git worktree add ../rr-050 84ca905`, then run its UI suite against the new API.
- **Accessibility:** labels on standalone marks, a value on the ring of hold, Dynamic Type on the sheet.
- **Simulator:** a walk-through with screenshots per release, including a `simctl location` outing past a seeded creature.
- **Road:** each release's gate outing, written up as in `docs/FIELD_TESTS.md`, plus the `play_report.py` question.

## Not building

| Idea | Why not |
|---|---|
| A named realm, an antagonist, factions at war, a chosen one | Breaks the voice you chose |
| Dialogue trees, on-screen choices, branches that lock content, quest failure | You chose no choice encounters; consequences come from what you did |
| Player HP, monsters that chase, timers, damage per minute, heart-rate damage | Punishment, or speed by another name |
| Anything that reads a clock to judge effort; dawn, dusk, night or weather bonuses; "weather is a monster"; midnight deadlines | Pays for riding in the dark, in ice, or fast |
| The Cartographer rival who maps your roads while you stay in | Turns a rest day into a loss |
| Pocket notifications mid-ride | The Live Activity shows the same thing without a buzz |
| Crafting, a second currency, durability, trading, paid currency, coins for XP | Scope; the spec forbids selling progress |
| Image assets before 1.0, an avatar editor, a fifth tab, animation or words on the ride screen while moving | Scope and safety |
| Model-written steps, cast lines, bestiary or place facts | The voice and the facts must be authored |
| Leaderboards, segments, speed records, server push | The spec, and few notifications |

## Most likely to be wrong, and the cheap test

| Idea | Why it might fail | Test |
|---|---|---|
| Composed creature sigils | Clip art at marker size | Ground truth 4; fallback is twelve fixed devices |
| The fight numbers | Things seen off by accident, or effort that lands on nothing | Ground truth 5 pass marks |
| The on-foot scale | Walking wins everything | The replay on walks alone |
| Fights followable by ear | Chimes are unproven on a road | Ground truth 1 |
| Runes on real streets | Shapes need turns that feel wrong | Ground truth 2; rune rides in 0.7.0 plan the shape for you |
| A template-built campaign | Reads as board quests with better text | Play Act I before Act II is written |
| The dry voice | One joke on every surface | One turn per screen; flag any line or ending seen three times in ten outings |
| Place and creature lines | A joke at the wrong place | Ground truth 7 |
| The ink wash | As purposeless as the hexagons were | The Journal map card first |
| Gear | Bookkeeping, not play | If most drops are sold unworn after three weeks, cut slots |
| The old ones | Seated where nothing can reach them | Routable anchors only, plus the free move |
| District percentages | Unfair denominators, odd names | A script printing your best-known district before any UI |
| The familiar's voice | It grates | Only if the 0.5.0 voice passed; ten scripted lines heard first |

---

## Appendix A. The world

**Premise at three lengths.** One line: "Every road was written once. Go out and read it back." The paragraph is under "The game in one page". The one-page codex entry is in the world draft, revised to the reading premise.

**The trades** (ids and class names stay):

| Class | Guild | Saying | Crest | Poster |
|---|---|---|---|---|
| Explorer | the Wayfinders | "The edge moves." | A compass star whose north-east point runs long | Nell Foss |
| Wizard | the Cutters | "Look twice, then once more." | A rough standing stone, one stave cut down its face | Enid Sallow |
| Warrior | the Menders | "The hill does not negotiate." | A mattock upright over a hill line | Tam Hurdle |
| Scribe | the Clerks | "It may as well be you." | An open book, a road drawn off the edge | Walter Garth |

**The cast.** They write; they are never described and never answer. One name per card.

| Who | Role | How they write | Sample |
|---|---|---|---|
| Ada Pym | keeps the board; posts for anyone | Notices. No "I", fragments, a day of the week | "Wanted: somebody. The park, north side. Up since Tuesday." |
| Tam Hurdle | roadmender | The shortest. Weather and gradient, no joke | "Hill. Wet. It will keep." |
| Enid Sallow | hedge-scholar; writes the codex | The only one who hedges and writes long sentences; carries the wit | "Fen Troll. I have the habits down; the reasons I am still guessing at." |
| Walter Garth | toll-keeper; the reckoning, the book, the stall | Always a figure, never an adjective | "Troll, sixty. Chest, twenty-five. Eighty-five in the book." |
| Nell Foss | lamplighter; the bounty | A place and a time of day, reported plain | "By the pond. Not there at lamp-lighting." |

**Lexicon.** One on-screen word per concept; the lint checks the forbidden column.

| Concept | On screen | Never |
|---|---|---|
| HP | its hold; numbers bare ("31 of 400") | HP, health, hit points |
| Partial / finished | loosened / seen off ("GONE" on the Watch) | wounded, beaten, slain, killed |
| Weak to / resists | wants / does not mind | weakness, resistance |
| The five kinds | the road, new ground, height, a rune, the word | passage, pace, the record, the cut as a noun |
| Currency | coins, with the coin mark | AC, pence |
| Set | a six ("the Road Six") | row |
| Class | trade | class, order |
| Ability / unspent point | a knack / a knack to choose | ability point |
| Streak | days kept | streak |
| Journal text | the entry | chronicle |
| A creature, generically | a thing, something | the settled, monster, mob |
| Boss | an old one | boss, raid |
| District held | kept ground | held ground, territory |

**Voice.**
- Plain declaratives and short words; second person, present tense; British spelling; understatement. Things want, charge, keep and remember.
- The dry two-beat turn is allowed, not required: one per screen, and never on a rule, a number, a price, an error, a safety line or a sensitive place.
- Mid-ride: one sentence of five words, name first ("Fen Troll. Wants a climb.").
- Never: exclamation marks, archaic diction, invented place names or facts, speed as praise, gore, other players, emoji, cheerleading.

**Locale.** The narrator may be British. The ground may only be what the tags say. Seasons flip by hemisphere and their names are configurable.

## Appendix B. Creatures and runes

**The twelve.** This is the starting table: the catalogue test enforces the rules below it, and the replay tunes the values.

| Species | Family | Lives at | Wants | Does not mind | Leaves | Elders (tier 2 / 3) |
|---|---|---|---|---|---|---|
| Bog Wraith | water | water, trails by water | new ground, the word | height | a cold button | Lock Wraith / the Long Cold |
| Fen Troll | water | water, ponds | the road, a rune (square) | the word | a bridge nail | Culvert Troll / Old Arch |
| Tide Serpent | water | beaches, rivers | the road, a rune (loop) | the word | a scale | Ebb Serpent / the Spring Tide |
| Mire Hag | water | ponds, reserves | the word, new ground | the road | a hagstone | Mill-Pond Hag / the One Who Waited |
| Rook Lord | green | parks, gardens | new ground, the word | height | a black feather | Rook Baron / the Parliament |
| Grey Stag | green | viewpoints, peaks | height, a rune (triangle) | the word | a tine | Grey Hart / the Grey Royal |
| Moss Golem | stone | ruins, old gardens | the word, new ground | the road | a chip of capstone | Lichen Golem / the Garden Wall |
| Hollow Sentry | stone | castles, forts, manors | the word, a rune (square) | the road | a buckle | Hollow Serjeant / the Empty Captain |
| Ash Warden | stone | ruins | the word, a rune (triangle) | height | a charred key | Ember Warden / the Last Watchman |
| Gutter Drake | street | food, cafés, pubs | new ground, a rune (loop) | the word | a bottle-top | Skip Drake / the Drake of the Back Lane |
| Lamp Sprite | street | cafés, pubs, artworks | a rune (triangle), new ground | the word | a wick | Lantern Sprite / the Last Lamp |
| Cinder Hound | street | trails, cycling places | the road, the word | a rune | a clinker | Clinker Hound / Old Smoke |

Rules the catalogue test enforces:
- every species wants a rune or the word;
- height is wanted only where the habitat implies it;
- no species shrugs off the road while both its wants depend on terrain;
- on a ride, a wanted rune is a loop, square or triangle.

The twelve added in 0.7.2 are in the world draft. The Churchyard Grim becomes the Gate Grim, and none of them is placed at a sensitive place.

**The 24 runes in four sixes,** shown in the Codex in futhark order, each with one fixed gloss:

| Six | How met | Runes |
|---|---|---|
| Road | found anywhere; taught in Act II | Raido (loop) · Sowilo (zigzag) · Kenaz (triangle) · Dagaz (square) · Ansuz (a note) · Wunjo (a stop) |
| Ground | only on their own kind of ground (0.7.0) | Laguz water · Berkano green places · Eihwaz old ground · Jera what comes due · Ehwaz riding · Algiz a ward |
| Trade | given by the cast at chapter ends (0.7.0 to 0.9.0) | Fehu coin · Gebo finds · Mannaz on foot · Tiwaz bearing · Perthro what a box holds · Othala what is kept |
| Hard | taken from the old ones and elders (0.8.0) | Uruz height · Isa standing still · Nauthiz near misses · Hagalaz unread ground · Thurisaz against elders · Ingwaz collecting |

A star is "a bind", several runes cut as one: always optional, never required. "A stave cannot be ridden. Each rune has a road form: what it comes out as when the knife is a road."

## Appendix C. The fight model (starting values, tuned by Ground Truth 5)

`hold removed = units × rate[kind] × footScale × affinity × sheet[kind]`

| Kind | Units | Rate | Limits |
|---|---|---|---|
| ROAD | metres made good inside its ground | 0.01 per m | Up to one out-and-back per creature per outing, so laps pay nothing. Cannot finish a creature unless it wants the road |
| GROUND | new cells first entered inside its ground | 15 per cell | |
| CLIMB | metres of new height inside its ground | 1.25 per m | Height already climbed that outing pays nothing, so hill repeats equal one climb |
| RUNE | the species' own road form matched nearby | 100 | Once per creature per day. Any other shape does nothing |
| WORD | a note of a few words, placed by the server on the trace within 120 m | 60 | Once per creature per day. No photo bonus until photos are stored |

- **Hold** by tier is 100 / 220 / 400. **Affinity:** wants ×2, does not mind ×0.5, otherwise ×1.
- **Its ground** is 1,000 m round it, ending at 1,300 m. An outing counts only if it comes within 150 m.
- **The carried blow.** Effort since the start of the outing lands at contact as an opening blow, at a fraction of the local rate and at most half the creature's hold. The fraction is set by the replay; zero switches it off.
- **On foot.** One scale for running and walking (starting at ×2), outside the clamp. The server decides the band from the trace and only ever lowers it.
- **The clamp** (0.25 to 3) applies to `sheet[kind]` alone. Property tests check that wants > neutral > does not mind for every kind and activity, and that a 10% bonus changes the result.
- **Fixes.** Only fixes accurate to 30 m or better count. A segment over the activity's speed cap, or a jump over 250 m, does nothing.
- **Outings that loosen nothing:** under 500 m made good, or overlapping another of your outings.
- **Loosened creatures stay.** `expires_at = max(expires_at, loosened_at + 2 days)`, capped at 7 days from when it appeared. Nothing heals. Nothing hurts the player.
- **Design target:** a tier-1 falls to one deliberate act it wants, or two it does not, and never to the road alone unless it wants the road.

## Appendix D. Character

```python
@dataclass(frozen=True)
class CharacterSheet:
    version: int
    character_class: str
    overall_level: int
    class_level: int
    damage_pct: dict[str, float]      # ROAD GROUND CLIMB RUNE WORD: trade base + abilities only
    rune_threshold: float             # 0.22; Wizard 0.30 as today
    rune_reach_m: float
    coin_pct: dict[str, float]
    xp_pct: dict[str, float]
    rules: list[str]                  # 0.7.0: rule ids from inscribed runes and gear
    reveal_rings: int                 # 0.7.0
    loot_find_pct: float              # 0.7.2
```

Trade bases keep today's eases:
- Warrior: height ×1.3, the road ×1.15
- Explorer: new ground ×1.3
- Wizard: rune threshold 0.30
- Scribe: the word ×1.3

**Abilities.** R means redefined, because the old promise touched routing or needed other players.

| Ability | Effect per rank | Where | From |
|---|---|---|---|
| Trail Sense | POI radius +15% (kept); new ground +5% | existing; sheet | 0.6.2 |
| Pathfinder R | the first 10 / 20 new cells of an outing count double | sheet | 0.6.2 |
| Far Wanderer | +10% XP on new cells over 5 km from the start | `progression/engine.py` | 0.6.2 |
| Foresight R | a rune +6% | sheet | 0.6.2 |
| Ley Finder R | a rune reaches 1.5 / 2 km | sheet | 0.6.2 |
| Second Wind R | the road +10% beyond the tenth kilometre (scaled on foot) | sheet | 0.6.2 |
| Mountainborn | template unlock (kept); height +10% | existing; sheet | 0.6.2 |
| Endurance | +10% on the long-distance XP line | `progression/engine.py:183` | 0.6.2 |
| Vanguard R | +10% against elders and bounties | sheet | 0.6.2 |
| Archivist R | the word +8% | sheet | 0.6.2 |
| Rumour R | +5% box coins; better finds in 0.7.2 | sheet | 0.6.2 |
| Footnote R (was Chronicler) | discovery XP +20% on an outing with a note | `progression/engine.py` | 0.6.2 |
| Historian | the word +15% at historical and cultural places that are not sensitive | sheet | 0.6.2 |
| Cartographer | one more reveal ring round new cells | `rides/processing.py` → `exploration.reveal` | 0.7.0 |
| Arcane Sight R | +20% chance a placed piece is a rune stone | spawner, via a small `spawn_mods` | 0.7.0 |
| Second Chance | one missed optional objective counts | `rides/processing.py` | 0.7.0 |
| One capstone per trade | at trade level 20 | sheet | 0.8.0 |

## Appendix E. Campaign

| Act | Chapters | Release |
|---|---|---|
| I The Board | First Light · What Settles · The Rune at the Crossing (finale: a named elder) | 0.6.2 |
| II Five More Cuts | Kenaz · Ansuz · Wunjo · Sowilo · Dagaz | 0.7.0 |
| III What Holds the Ground | Habits · The Lair · The One That Stayed · Double Pay | 0.8.0 |
| IV The Parish | Home Ground · Beating the Bounds · The Next Parish · Going Quiet | 0.9.0 |
| V The Long Way Round | The Far Board · The Line · The Last Cut | 1.0 |
| Seasons | one three-step arc per quarter day | 0.9.0 onward |

Chapters are gated by level and by deeds the database already counts. All text is activity-neutral ("outing"; never ride, pedals or wheel on a run or walk). New objective types arrive in this order:
- `INSCRIBE_RUNE` and `CARRY` in 0.7.0;
- `WOUND_BOSS` in 0.8.0;
- lairs as a generator rule on `VISIT_MULTIPLE_LOCATIONS` in 0.8.0.

`VISIT_AT_DAWN` and `VISIT_AT_DUSK` are never built.

## Appendix F. Renames

| Now | Becomes | With |
|---|---|---|
| Active Coins, AC | coins, with the mark | 0.6.0 |
| "Adventure complete" / "Collect rewards" | "The reckoning" / "Close the book" | 0.6.0 |
| ability point / "{name} available" | a knack / "A new knack: {name}" | 0.6.0 |
| streak, "Days in a row" | days kept | 0.6.0 |
| class change / "Ride as" | change of trade / "Go out as" | 0.6.0 |
| "Loading your world…" | "Unfolding the map." | 0.6.0 |
| Old Runes / Milled Coins | the Road Six / Odd Coins | 0.6.0 |
| Hollow Knight | Hollow Sentry | 0.6.0 |
| "a fast kilometre"; "How to beat it" | "It wants the road used."; "What it wants" | 0.6.1 |
| beaten / "Monsters" | seen off, loosened / "Things seen off" | 0.6.1 |
| triangle, square, loop, zigzag | Kenaz, Dagaz, Raido, Sowilo, each with its road form | 0.6.1 |
| lure | a lamp left out | 0.6.1 |
| "YOURS" / "OBJECTIVE COMPLETE" (Watch) | "GONE", "OPENED", "FOUND" / "DONE" | 0.6.1 |
| "today's bounty … gone at midnight" | no deadline wording | 0.6.1 |
| "Level up"; titles Novice … Legend of the Roads | "The roads count again"; Passer-by … Known to the Roads | 0.6.2 |
| Chronicler (ability) | Footnote | 0.6.2 |

## Appendix G. Content to write

| Release | What | About |
|---|---|---|
| 0.6.0 | `docs/WORLD.md`; codex "how it works" entries; elder lines (24); habitat hints (12); trade text and `CLASS_LINES`; the model's `SYSTEM`; pickup lines | 110 lines |
| 0.6.1 | fight-card phrases; wants and does-not-mind hints; five spoken lines; lamp and quarry copy; the rewritten Iron Hours step | 45 |
| 0.6.2 | template completion lines (39); cast pools (30); entry pools (sized by the replay); ability texts (16); title sources (14); arc rewrites (10); level lines | 175 |
| 0.7.0 | rune glosses and rule texts (24); deed titles (25); Act II (20 steps); rune-ride copy | 150 |
| 0.7.2 | 15 items; 4 consumables; 12 creatures and their elders; variants; grudge epithets; stall lines; 50 level lines | 160 |
| 0.7.3 | sealed notices; pledge lines; letter framing; widget and Live Activity text; share-card lines | 60 |
| 0.8.0 | five old ones (rumour, three phases, quiet week, seen off); lair lines; treasure-map riddles; Act III | 140 |
| 0.9.0 | epithet alternates; district page lines; four season arcs; Act IV; cosmetics | 120 |
| 1.0 | Act V and the ending; four familiars' grammars; second-board lines | 90 |

Each release ends with you reading its new lines in one sitting.

## Appendix H. The build in 0.7.0 and 0.7.2

**Road Six rules when inscribed.** Ranks widen the numbers; they never add a damage percentage.

| Rune | Rule |
|---|---|
| Raido | the carried blow counts double at contact |
| Sowilo | a cut reaches 2 km (2.5 / 3 at ranks II / III) |
| Kenaz | one reveal ring round each place found; things are sighted 600 m out |
| Dagaz | on your first outing of the day, "does not mind" counts as neutral |
| Ansuz | a word lands on every creature within 1 km, not one |
| Wunjo | a five-minute stop at a café, pub or green place counts as the word |

Ground Six rules follow the same pattern, for example Laguz: things at water count your road effort along water as wanted.

**Gear: fifteen items.** Effects are yields or rules only.

| Slot (opens at level) | Plain | Good | Storied |
|---|---|---|---|
| Bell (1) | Tin Bell: things sighted 500 m out | Drover's Bell: the carried blow +25% | The Bell That Was Not Rung: something left under a tenth of its hold is seen off |
| Lamp (3) | Stub of Candle: one more reveal ring | Bull's-eye Lantern: map fragments reveal half as much again | Wrecker's Light: boxes open from 150 m of the track |
| Bag (5) | Saddle Roll: +10% coins per km | Tinker's Satchel: +20% box coins, sells for more | Poacher's Pocket: better finds +10% |
| Map case (13) | Folded Sheet: one more notice on the board | Pedlar's Road-book: optional objectives pay double XP | The Blank Quarter: each new cell counts 1.25 for new ground |
| Keepsake (21) | Hagstone: rune match as forgiving as a Wizard's | Rowan Twig: a rune reaches 1.5 km | Toll-gate Nail: a woken rune counts one more rank |

**Every level pays.**
- Rune slots open at 1, 10 and 25; gear slots at 1, 3, 5, 13 and 21.
- The stall opens at 3.
- A consumable every fourth level.
- A deed frame every fifth.
- Titles at 1, 5, 10, 20, 30, 40 and 50.
- A written line on every other level.

The full table is in the character draft, adjusted to the three-system build.

## Appendix I. The old ones (0.8.0)

| Old one | Where | Wants, by phase | Leaves |
|---|---|---|---|
| The Blank | the largest connected block of unread way-cells, anchored at its edge | new ground · new ground and the road · a rune | Hagalaz |
| The Drowned Lane | water with a path beside it | the word · a stop · the road along the water | Isa |
| The Long Drag | the highest point the router reaches | height · height and the road · the word at the top | Uruz |
| The Slow Coach | a long named trail | the road · new ground · the road again | Nauthiz |
| The Worn Stone | a place where the mark has gone smooth | a rune · its rune · its rune woken | Thurisaz |

Rules:
- Lore describes the creature's belief, never the place's history. "By its own account, a road. By the map's account, {name}."
- Hold is 1,500 in three phases.
- Each phase break pays coins, XP and a Good item; the finish pays a Storied item and the rune.
- The purse is exempt from the per-outing caps; the one-phase-a-day rule is the limit.

## Appendix J. Districts (0.9.0)

Epithet rules, by the share of a district's places. The first that applies wins:

| Rule | Epithet |
|---|---|
| water tags 30% or more | the wet side |
| two or more viewpoints or peaks | the high ground |
| historical 25% or more (not sensitive) | the old stones |
| nature 40% or more | the green quarter |
| pubs the top category | the thirsty end |
| cafés and food on top | the fed quarter |
| trails 20% or more | the back ways |
| cultural 15% or more | the kept things |
| fewer than five places | the quiet end |

Overrides:
- The district you start from most is shown to you alone as "home ground", and never stored or shared.
- A district under 10% read is "past the last lamp".

## Appendix K. Every earlier idea, and where it went

**From the spec and the README**

| Item | Now |
|---|---|
| Phase 4 navigation and 5 Watch, written but never ridden | Ground truth and the gate outings (protocols 3 to 8) |
| Phase 7 social (backend done, flag off) | Beyond 1.0, Fellowship |
| Phase 9 regional events | Seasons in 0.9.0; shared events beyond 1.0 |
| Map modes MINIMAL / CYCLING / ADVENTURE / DETAILED | ADVENTURE becomes the parchment style in 0.7.3 |
| Push notifications (APNs stub) | Not building |
| Home masking, purge job, account deletion | Home masking in 0.7.3; the rest before anyone else |
| Product analytics | `play_report.py` in Ground truth |

**From "the ride talks back" menu (2026-10-01)**

| Item | Now |
|---|---|
| Counting the spoils, the reckoning, the near-miss, sets that count, honest pay, progress and milestones, what's on the way, nudges that name things, story arcs on, Watch catches up | Built in 0.5.0; ridden in Ground truth |
| Sound, then voice; new ground sings; finds and hills said aloud | Built; voice stays off until the road test |
| Pocket notifications | Not building (the Live Activity instead) |
| Abilities you can read | 0.6.0 |
| Welcome back | 0.6.2 |
| Signature haptics | Reckoning in 0.6.1; full set in 0.8.0 |
| Fog on the map, frontier arrow | 0.7.0 (World tab; never the ride map) |
| The Week | 0.6.2, the week's notice |
| A streak that allows a rest day | 0.7.2, the rest token |
| Records that are not speed | Deeds in 0.7.0, the atlas year page in 0.9.0 |
| A ride card to share | 0.7.3, with home masking |
| Things to buy | The lamp in 0.6.1, the stall in 0.7.2 |
| Abilities that do something | 0.6.2 and 0.7.0 |
| Live Activity, widget, complication; quick start | 0.7.3 |
| The Chronicler | Composed in 0.6.2, model-written in 0.7.2 |
| Audio adventure | 1.0, with the familiar, only if voice passed |
| Named regions, held ground, the Journal as an atlas | 0.9.0 |
| A world that changes | Grudges and variants in 0.7.2; dawn chests and dusk creatures not built |
| Bosses with real HP | The old ones, 0.8.0 |
| Items | 0.7.2 |
| Parties that work | Beyond 1.0 |
| Weather is a monster | Not building |
| Hot and cold | 0.8.0, only if sound passed |
| Fate's errand | 0.7.3, the sealed notice |
| The sealed chest | 0.7.2 consumable |
| Treasure maps | 0.8.0 |
| Letters to yourself | 0.7.3 |
| The Cartographer rival | Not building |
| A familiar | 1.0 |
| Dungeons | Lairs, 0.8.0 |
| Rune rides | 0.7.0 |
| The pledge | 0.7.3 |
| Your own treasury | 0.7.3 |
| Cairns | Beyond 1.0 |
| Seasons | 0.9.0, quarter days |

**From the design canvas**

| Item | Now |
|---|---|
| "31% of Southwark explored" | 0.9.0 district percentage |
| Rune Fragment, Map Fragment rewards | Rune shards in 0.7.0; map fragment in 0.7.2 |
| "Keeper of the South" | 0.9.0 district titles, with no real place names in titles |
| "Traveller encounter, +10 XP each"; a friend's marker on the map | Beyond 1.0, crossing paths |
| "Riddles, ruins, ley lines" | 0.6.0 trade text |
| "5 mysteries"; "weekly challenge" | Treasure maps in 0.8.0; the week's notice in 0.6.2 |
| Hand-authored quests (The Forgotten Railway, The Seven Bridges…) | Not building as written: quests cannot be written for one city. Their feel goes into the old ones and Act V |
| "Rumours speak of an old trail…" | The old ones' rumour lines, 0.8.0 |

## Source drafts

The five designers' drafts are in [`docs/design/rpg/drafts/`](design/rpg/drafts/): `world.md`, `character.md`, `combat.md`, `presentation.md`, `campaign.md`. Where a draft and this plan disagree, this plan wins: the drafts were written before the review, and still say pence, Hollow Knight, six quest-givers, "passage", "the Bailiff" and fifteen-system builds.
