> **Superseded where it disagrees with [docs/ROADMAP.md](../../../ROADMAP.md).** This is one of five design drafts written independently on 2026-10-01, before an adversarial review. Known differences: coins, not pence; Hollow Sentry, not Hollow Knight; five cast (Ada Pym, Tam Hurdle, Enid Sallow, Walter Garth, Nell Foss), not six quest-givers; "the road", not "passage"; the old ones are the Blank, the Drowned Lane, the Long Drag, the Slow Coach and the Worn Stone, not the Bailiff; the build is runes, gear and abilities, not attributes plus fifteen systems. Read it for the written lines and the reasoning, not as the specification.

# D. PRESENTATION: the woodcut plan

Prefixes: `APP` = `ios/RoadsAndRunes`, `PKG` = `ios/Packages/RoadsAndRunesCore`, `WATCH` = `ios/RoadsAndRunesWatch`.

Assumed of neighbours:
- **A** names things and picks each creature's sigil parts.
- **B** defines attributes, gear slots, rarity names, and the inventory, runes, titles and shop endpoints.
- **C** puts `hpMax`/`hpNow` on monsters and a `fights` array in the summary.
- **E** supplies the first-outing quest.

Everything below degrades to today's look when those fields are absent. MapLibre API names are from memory of the 6.x SDK, not compiled here.

## 1. The idea in five lines

1. Everything with a name gets a face drawn in code: Raido is its real glyph, and a Fen Troll is a hunched ink shape under a bridge arch, not `flame.fill`.
2. The map becomes an inked parchment sheet; ground you have not ridden is unpainted paper with a soft edge, not hexagons.
3. The Character tab becomes a sheet you can read: crest, worn title, attributes, cut runes, gear, and abilities with their numbers.
4. The reckoning tells the fight, turns over the loot and stamps new codex entries; one tap still skips all of it.
5. One woodcut language serves phone and Watch, and every face is a slot an illustration can replace later.

## 2. The design

### 2.1 The woodcut language

- **Grid:** every mark is drawn on a 24-unit square (runes on 4×6); `u = side/24`.
- **Line:** outline 2u, inner line 1.25u, hatch 0.6u at 2u pitch and 45°. Caps are butt and joins mitre (limit 3), so marks look carved, not rounded like SF Symbols.
- **Three tones only:** paper, hatch, cross-hatch or solid.
- **Two blocks per plate:** an ink block (`ink` 201E1D, `inkSoft` 474238 for hatch) and at most one spot colour, offset 1 pt as if misregistered. Spot colours are terracotta, sage, wizard violet, scribe blue and gold.
- **Gold:** becomes `Theme.Colors.gold`; it is hard-coded three times today (`BountyCard.swift:27`, `EncounterCard.swift:139`, `MapLibreView.swift:520`).
- **Dormant tokens switched on:** `Theme.Colors.hatch` (`Theme.swift:20`) and the unused aliases `parchment`, `rune`, `moss`, `river`, `ember` (`:51-56`) become the palette's names.
- **Wobble:** each vertex is jittered ±0.25u, seeded by an FNV hash of the glyph id. It is stable between renders and never sterile.
- **Paper grain:** a seeded Canvas of short fibres (6–14 pt, ink at 3–5%) plus speckle. It is rendered once into a 256 pt tile and tiled, so there is no per-frame cost.
- **Palette as a parameter:** an `InkPalette` (paper, ink, hatch, spot) is passed in. The Watch passes cream line on black, which is the same art inverted.

### 2.2 How a glyph is authored

Glyphs are Swift literals, not JSON: they are compile-checked, need no bundle loading on the Watch, and cannot fail to decode. The path is an SVG subset (`M L H V Q C Z`, absolute) on the grid:

```swift
public struct Glyph: Sendable { let id: String; let grid: CGSize; let ink: String; var spot: String?; var hatch: String? }
```

- **Where it lives:** a new target `RoadsAndRunesArt` in the same package (`PKG/Sources/RoadsAndRunesArt`, imports SwiftUI, depends on Core), linked by the app, the Watch and later widgets. Core is Foundation-only today and stays so.
- **CI:** SwiftUI and Canvas compile on macOS 14, so `swift test` in CI keeps working.
- **Unknown ids:** an id with no glyph draws a worn stone, in the spirit of `SafeEnum`, so the server can ship a creature before the app has art.

The 24 Elder Futhark runes are straight strokes on a 4×6 grid, y down:

| Rune | Path | Rune | Path |
|---|---|---|---|
| Fehu | `M1 0V6M1 2L3 0M1 4L3 2` | Eihwaz | `M2 0V6M2 0L3.2 1.2M2 6L.8 4.8` |
| Uruz | `M1 6V0L3 2V6` | Perthro | `M3 0L2 1L1 0V6L2 5L3 6` |
| Thurisaz | `M1 0V6M1 1.5L3 3L1 4.5` | Algiz | `M2 6V0M.5 0L2 2.5L3.5 0` |
| Ansuz | `M1 0V6M1 0L3 1.5M1 2L3 3.5` | Sowilo | `M3 0L1 2L3 4L1 6` |
| Raido | `M1 6V0L3 1.5L1 3L3 6` | Tiwaz | `M2 6V0M.5 1.5L2 0L3.5 1.5` |
| Kenaz | `M3 1L1 3L3 5` | Berkano | `M1 6V0L3 1.5L1 3L3 4.5L1 6` |
| Gebo | `M.5 .5L3.5 5.5M3.5 .5L.5 5.5` | Ehwaz | `M1 6V0L2 1.5L3 0V6` |
| Wunjo | `M1 6V0L3 1.5L1 3` | Mannaz | `M1 6V0L3 2.5M3 6V0L1 2.5` |
| Hagalaz | `M1 0V6M3 0V6M1 2.5L3 3.5` | Laguz | `M1 6V0L3 2` |
| Nauthiz | `M2 0V6M1 2.5L3 3.5` | Ingwaz | `M2 1L3.5 3L2 5L.5 3Z` |
| Isa | `M2 0V6` | Dagaz | `M.5 1V5L3.5 1V5Z` |
| Jera | `M2 .5L.5 2L2 3.5M2 2.5L3.5 4L2 5.5` | Othala | `M.5 6L3.5 2.5L2 .5L.5 2.5L3.5 6` |

The renderer adds a chisel wedge at each stroke end and sets the rune on a stone plate.

### 2.3 Catalogue

| Family | Count | Approach | Effort |
|---|---|---|---|
| Engine: parser, `InkShape`, hatch clip, wobble, paper tile, `Plate`, `MarkView`, gallery | n/a | n/a | M (3 d) |
| Runes | 24 | table above | S (½ d) |
| Class crests | 4 | shield plate, today's motif (compass star, arcane ring, shield, ink drop), class spot colour | S (1 d) |
| Creature sigils | 25 parts | composable, see below | M (3 d) |
| Chests | 3 | one chest path; banding and lock vary for Old, Iron, Gilded | S (½ d) |
| Coins | 4 + purse mark | ring plus denomination device; replaces `circlebadge.2.fill` | S (½ d) |
| What-hurts-it marks | 6 | distance, climb, new ground, rune, stop, note | S (½ d) |
| Item marks | about 15 | 5 slots × 3 silhouettes (slots are B's; placeholder) | M (2 d) |
| Rarity frames | 5 | plain rule, double rule, notched, hatched corner, gold cartouche | S |
| Frame kit | 6 | plate, cartouche, title ribbon (3 ends), ink rule, corner, HP ring | S (1½ d) |
| Place marks | 11 | one per discovery category | S (1 d) |
| Region seals | procedural | ring, radial ticks, one of 8 devices (river, hill, bridge, tree, tower, gate, mill, well) chosen by A or by id hash | S (1 d) |

**Creatures are composed from parts**, so a new one is a JSON line on the server:

- **7 bodies:** shade, hulk, beast, wyrm, armour, wisp, bird.
- **10 features:** antlers, horns, crown, hood, hook, empty visor, ember eyes, wings, moss, fins.
- **8 habitat marks under the figure:** water, reeds, bridge arch, wall, lamp, ash, mist, tree.
- **Tier frames:** plain ring for tier 1, double for 2, notched for 3; a boss gets the cartouche; a bounty swaps the spot colour to gold.
- **Examples for the 12 (A may re-map):** Fen Troll is hulk + horns + bridge. Rook Lord is bird + crown + tree. Hollow Knight is armour + empty visor + wall.
- **Unmet:** the body alone, solid ink.
- **Small sizes:** under 28 pt the hatch drops out and only the silhouette draws, for markers, Always-On and complications.

### 2.4 Swap points

One type carries every face: `enum Mark: Hashable { rune, crest, creature(SigilSpec), item, chest(tier), coin, place, seal, method }`. `MarkView(mark:size:palette:)` first asks `ArtSlots.illustration(mark) -> Image?` (nil today, an asset later), then draws code.

| Today | Becomes |
|---|---|
| `EncounterGlyph` switch (`APP/Features/World/EncounterCard.swift:127-162`); 6 call sites pass only `kind` | `init(object:)` → `MarkView`; the `kind:` init stays as fallback |
| `MarkerAnnotationView` object case (`APP/Services/Maps/MapLibreView.swift:544-571`) | `MapMarker.mark: Mark?`; a `UIImageView` fed by `MarkImageCache`; the reuse identifier at `:454` gains the mark key |
| `ClassStyle.symbol` and `ClassEmblem` (`APP/Components/Theme.swift:225-232`, `:434-448`) | `ClassEmblem` draws `.crest`; `symbol` stays for the three raw `Image(systemName:)` uses |
| `DiscoveryIcon.symbol` (`APP/Components/DiscoveryCard.swift:4-19`) | `.place(category)` in cards and tiles; route-stop map markers keep SF Symbols (they are utilities) |
| `EncounterCard.symbol(for:)` (`:114-123`), `CoinPill` (`CharacterHeader.swift:174`), the Watch sparkle (`ObjectiveCompleteOverlay.swift:17`) | method marks, the coin mark, the sigil |

### 2.5 The map

**Skin.** Use a bundled style JSON, not runtime tinting. Tinting an OpenFreeMap style after load depends on remote layer ids we do not control.

- **Fork:** positron has 55 layers and is the base (26 line, 19 symbol, 9 fill, 1 background; checked against the live style). The fork lives at `APP/Resources/MapStyles/parchment.json`.
- **Keep the source id `openmaptiles`**, so `applyEmphasis` (`MapLibreView.swift:196-240`) and POI taps (`:154-157`) keep working. Positron has no `poi` source layer, so copy bright's POI symbol layers in.
- **Colours:**
  - background is cream;
  - water is a pale scribe tint, with an ink shoreline and a second faint line offset 3 px;
  - parks are sage tint;
  - minor roads are `inkSoft`;
  - major roads are an ink casing with a cream centre;
  - paths are dashed ink;
  - labels are Noto Sans from OpenFreeMap's glyph server, in ink with a cream halo.
- **Patterns:** paper grain and tree stipple are fill and background patterns whose images are drawn at runtime and registered with `style.setImage(_:forName:)` in `didFinishLoading` (`:152`).
- **Config:** `Config.mapStyleURL` (`APP/App/Config.swift:31-35`) returns the bundle URL for `.adventure`, the default (`AppContainer.swift:156`), when flag `parchment_map` is on. This needs no server enum change. `project.yml:84-87` is untouched; "Detailed" stays as the escape hatch.
- **Route casing:** changes from white to cream (`:331-336`).
- **Ride screen:** stays on `.minimal` until the skin has been ridden with.

**Fog as an unpainted wash.** This replaces `applyFog` (`:273-309`).

1. Union the visited and explored cells with H3's `cellsToLinkedMultiPolygon`, already in the vendored library (`ios/Packages/H3/Sources/H3/include/h3api.h:293`) and unused.
2. Smooth each ring with two Chaikin passes, so hexagon edges become a wavering coastline.
3. Build one `MLNPolygonFeature`: a padded rectangle with the rings as interior polygons.
4. Draw four layers:
   - a parchment fill at 0.86, so roads still ghost through;
   - a stipple fill pattern at 0.3;
   - a feather, which is a cream line 12–40 px wide by zoom with `lineBlur` at half its width;
   - the frontier, a dotted `inkSoft` line 1.2 px wide.

Cost: a 6 km radius is at most about 1,070 cells. The union is linear and should take a few milliseconds, and it runs only when the existing cell hash changes (`:274`). The GPU draws one polygon instead of a thousand. One caveat: fill patterns rescale at integer zooms and shift slightly.

Flag: a new `ink_fog`, so 0.5.0 never redraws hexes (`fog_of_war` stays off in `backend/fly.toml:25`).

**Markers, frontier, seals.**
- World objects become sigils on a cream disc with the tier frame. A reachable one or a bounty takes the gold ring, as now.
- On the ride map there is never a wash; later, only the frontier line and one off-screen chevron towards the nearest ring vertex.
- Region seals are point annotations at the centroid below zoom 12.

### 2.6 The character sheet

Top to bottom, replacing `CharacterView.sheet` (`APP/Features/Character/CharacterView.swift:92-134`) and `CharacterHeader`:

1. **Header plate:** class ground with grain; a 96 pt crest; the name; a `TitleRibbon` with the worn title (tap → Titles); "Explorer · Level 7"; the purse pill (tap → the stall); the streak pill. Identifiers `character.coins` and `character.streak` are kept.
2. **Two XP rules:** the same `XPBar` API, drawn as an inked rule with a notch per level.
3. **Attributes:** a row of `StatPlate`s (B's names). A tap shows one line on what it changes.
4. **Cut runes:** `RuneStone` slots; an empty one is a dashed stone reading "Uncut". A tap opens the Rune table.
5. **Gear:** five `GearSlot` plates in a rarity frame. An empty slot shows the slot silhouette and "Nothing worn here."
6. **Abilities as rows, not pills:** mark, name, rank pips, the description and the effect in numbers. The description is only a VoiceOver label today (`CharacterHeader.swift:162`). An ability that can be learnt gets a "Learn" button.
7. **Doors:** a 2×2 grid of `DoorTile`s for Pack, Runes, Titles and Codex.
8. **Ground:** the three existing `FactTile`s.
9. **An ink rule, "The rider":** the cycling profile and bikes, unchanged and visibly below the line. This keeps "Levelling up never changes these" and the UI test that scrolls to the bike row.
10. **More.**

**Codex placement: not a fifth tab.**
- `FloatingTabBar` gives four tabs about 83 pt each on a 393 pt screen, and the selected "Character" pill already needs about 88. Five would mean a new bar.
- The Codex would be mostly silhouettes for weeks.
- It lives in the Journal: segments become Adventures, **Codex**, Map, Stats (`JournalSection`, `JournalView.swift:95-106`). Today's Discoveries grid becomes its Places chapter, and there is a door from the sheet.
- `AppTab` is `CaseIterable`; promote it later if it earns it.

### 2.7 New screens

| Screen | Purpose and layout | Empty state | API |
|---|---|---|---|
| **Codex** | Chapters as an ink-pill row: Creatures, Runes, Places, People, Regions. A three-column grid of plates; unmet ones are silhouettes with a habitat hint. An entry has the sigil at 160 pt, a cartouche, flavour, times met and beaten, and first-met place and date. | Creatures: "Nothing met yet. They keep to places nobody passes." Runes: "No runes yet. They are where two ways meet, mostly worn smooth." People: "Nobody yet. People turn up once you have somewhere to be." Regions: "No ground of your own. Ride a district until it stops being news." | new `GET /codex` (A, C); Places reuse `myDiscoveries` |
| **Pack and loadout** | Slots across the top; below, a grid filtered by the tapped slot. An item sheet has the mark, a rarity frame, two lines of text, numbers and "Wear". | "An empty pack. Chests help. So does finishing things." | `GET /inventory`, `PUT /character/loadout` (B) |
| **Rune table** | The stones you hold, with glyph, name and one line of meaning, over the sheet's slots. Tap a stone, then a slot. | "Nothing to cut. Find one first." | `GET /runes`, `PUT /character/runes` (B) |
| **Titles** | Ribbons in a list, earned ones first with where they came from; locked ones are faint with their condition. Tap to wear. | "No titles. You are whoever turns up." | `GET /character/titles`, `PUT /character/title` (B); the server already logs `RewardEvent TITLE` |
| **The stall** | The keeper's plate and one dry line (A). Stock is two columns with prices in coin marks; hold 0.6 s to buy. The ledger sits below. | Stock: "Bare till dawn." Cannot afford: "Your purse says not today." Ledger: "Nothing in, nothing out." | `GET /shop`, `POST /shop/buy` (B); `wallet()` and `walletTransactions()` exist with no caller |
| **Boss page** | The sigil in a cartouche. HP is an inked tally with one notch per outing. A what-hurts-it row with numbers, the outings so far ("Tuesday · 142 off it · the climbing"), a lair map thumbnail and "Plan a route here". | "It has not noticed you. That can be arranged." | `worldObject(id:)` exists with no caller; C adds `hpMax`, `hpNow`, `history` |

### 2.8 Ceremony in the reckoning

`Stage` (`APP/Components/AdventureSummaryView.swift:36-40`) becomes `trace, fight, xp, lines, coins, loot, levels, codex, world, quest, rest`. Each new stage is an `arrive(at:)` in `playReveal` (`:133-171`). `showEverything()` (`:181-189`) already skips on one tap, and "Collect rewards" stays present from the start.

- **fight:** at most three monsters, about 2.5 s each.
  - The map camera moves to the lair (existing `MapCamera`).
  - The sigil sits in an `HPRing`; each hit lands as a line ("The climbing · 42") and the ring ticks down.
  - Fallen: an ink cut draws across the sigil and the plate tilts 4°, with the `.win` chime.
  - Standing: "Still standing. 180 of 400 left. It keeps what you took."
- **loot:** plates face down, turned one by one, with the `.piece` chime and the `.chest` chime for a chest. The rarity frame is drawn last.
- **levels:** today's card (`:295-319`), plus what the level gave as rows with marks. A title arrives as a ribbon unrolling: "You are Edgewalker now."
- **codex:** a first-time-seen card. The sigil is stamped (scale 1.15 → 1, ink bleeding in), with the eyebrow "New in the codex", the name and one line. The same card appears on the World when an unmet creature's `EncounterCard` opens.
- **Haptics:** a small `Ceremony` wrapper over CoreHaptics (not used anywhere today). A blow is a sharp transient with a short decay; a stamp is two transients; a level is a swell. It falls back to the existing `UIImpactFeedbackGenerator` calls.
- **Chimes:** one new `RideChime.blow` (a single 147 Hz note of 0.12 s, which passes `testEveryChimeIsShortAndAudible`).
- **Reduce Motion:** everything shows at once.

### 2.9 Onboarding as a prologue

A new `Step.prologue` in `OnboardingFlow` (`APP/Features/Onboarding/OnboardingFlow.swift:11`), shown before `CharacterCreationView` in `.needsCharacter` and skipped when `AppContainer.isUITesting`. Four paged plates, skippable (text is A's; these use the approved lines):

1. "Every road was written once." The plate is a crossroads with Raido cutting itself in.
2. "Nobody reads them now. So the land forgets itself." The wash creeps over a small map.
3. "Things settle where nobody passes." A silhouette under a bridge arch.
4. "You pass. The way remembers." Button: "Choose a trade".

Class choice becomes "What is your trade?": `ClassCard` (`:169-197`) with crest plates. The button keeps the label "Ride as …", because the UI tests match on it.

First outing: a `FirstOutingCard` takes `TodayStrip`'s place until the first ride ends. It shows a glyph, one line and "Start" (the quest is E's). That ride's reckoning shows the first rune stamp.

### 2.10 At a standstill and on the Watch

**Phone.** `EncounterBanner` (`APP/Features/Navigation/NavigationScreen.swift:473-522`):
- Moving, it shows only a 44 pt sigil inside the `HPRing`, the name and the distance. No sentence.
- Below 0.7 m/s for 5 s it expands to the flavour line, the what-hurts-it marks and the note button.
- The note button shows while moving today; gating it on stillness also fixes that.

**Watch.**
- `WatchNavigationUpdate` gains an optional `encounter` (sigil spec, name, HP fraction, metres).
- `QuestScreen` (`WATCH/Quest/QuestScreen.swift:28-35`) swaps its 12 pt text line for a 36 pt sigil and ring.
- `WatchObjectiveCompleted` gains an optional `sigil`, replacing the sparkle.
- Always-On (`AlwaysOnNavigationScreen.swift`): a 20 pt stroke-only sigil and arc at half opacity, with no fills and no animation.
- A complication needs a WidgetKit target, which does not exist; it is R4. The under-28 pt silhouette rule is what makes it possible.

### 2.11 Engineering

- **Files:**
  - `PKG/Sources/RoadsAndRunesArt/{InkPath, InkShape, Hatch, PaperGrain, Plate, MarkView, HPRing, Runes, Crests, CreatureParts, Items, Frames, Seals}.swift`
  - `APP/Services/Maps/{MarkImageCache, FogWash}.swift`
  - `APP/Features/Codex/`, `APP/Features/Character/{Pack, RuneTable, Titles, Stall}View.swift`
  - `APP/Services/Haptics/Ceremony.swift`
- **Previews and tests:** there are no `#Preview`s today. Add an `ArtGallery` showing every mark at 20, 34, 48 and 96 pt in both palettes, with a DEBUG row in Settings. Core tests (run in CI):
  - every path parses and stays inside its grid;
  - there are 24 runes;
  - every id in a fixture copied from the backend catalogues resolves, as `rune_tracks.json` already does;
  - a digest of element counts catches accidental edits.
- **Performance:** a mark is 10–40 path elements. Draw it live in lists, and use `drawingGroup()` only on hatched plates. For map annotations, render once with `ImageRenderer` into an `NSCache` keyed by mark, size and palette.
- **Accessibility:**
  - marks beside a name are hidden;
  - standalone marks carry the name ("Raido, the road-rune");
  - the `HPRing` has a value;
  - mark sizes use `@ScaledMetric`;
  - the attribute grid reflows with `ViewThatFits`.
- **Dark mode:** there is none. Colours are fixed hex and nothing sets a colour scheme, so stock `Form`s follow the system. Pin `.preferredColorScheme(.light)` at `RootView` in R1; a "lamplight" palette is R4 and costs little because the palette is a parameter.
- **UI tests:** they run against the local API with `RR_UI_TEST=1`, not the mock; MockAPI serves previews and `RR_MOCK_API=1`. Keep every existing identifier, the labels ("Collect rewards", "Ride as", "Allow location", tab titles) and the bike row on the Character tab. New endpoints go through the protocol, `Endpoints`, `APIClient`, `MockAPI` and `SampleData`, with optional fields. Doors hide when their flag is off.

## 3. How it attaches

- **Backend, presentation-only:**
  - flags `parchment_map`, `ink_fog`, `codex` in `DEFAULT_FLAGS`;
  - `sigil: {body, feature, habitat}` per monster in `world_objects.json`, with a pytest that every part id is known;
  - optional `sigil` on `WorldObject` and `ClaimedObject`.
- **No new tables from this area.**
- **Dormant things switched on:**
  - `MonsterInfo.hp` and `WorldObject.tier`, decoded and never shown;
  - `Ability.description` and `effects`;
  - `wallet()`, `walletTransactions()` and `worldObject(id:)`;
  - H3 `cellsToLinkedMultiPolygon`;
  - the unused Theme aliases.
- **Old roadmap:**
  - 0.6 "fog and a frontier arrow" is absorbed (wash in R2, chevron in R3);
  - "abilities that do something" gets its surface in the R1 sheet;
  - "named regions" gets seals in R3;
  - 0.7 "Journal as an atlas" is superseded by the Codex segment plus the parchment Journal map;
  - "ride card to share" reuses the plate kit and `ImageRenderer` (R3);
  - "Live Activity/widget" reuses `MarkView` (R4).

## 4. Phasing

| Piece | Effort | Depends on | Release |
|---|---|---|---|
| Art engine and gallery | M | none | R1 |
| 24 runes; 4 crests | S + S | engine | R1 |
| Creature parts (25) and tier frames | M | engine; A's part map | R1 |
| Chests, coins, purse mark, method marks | S | engine | R1 |
| Frame kit (plate, cartouche, ribbon, rule, HP ring) | S | engine | R1 |
| Four swap points, gold token, light-mode pin | S | the marks | R1 |
| Parchment style and Config hook | M | none | R1 |
| Sigil map markers and image cache | S | creature parts | R1 |
| Reckoning: fight, loot, codex stages; level payoffs; CoreHaptics | M | C `fights`, B `loot` (each stage hides without its data) | R1 |
| Character sheet v1: header, ribbon, readable abilities, doors | M | crests | R1 |
| Codex in Journal: creatures, runes, places | M | `GET /codex` | R1 |
| Prologue and crest class cards | S | crests | R1 |
| Ride banner HP ring; Watch sigil, ring, Always-On | M | C's HP | R1 |
| Ink wash and frontier line | M | H3 union | R2 |
| Pack and loadout, item marks, rarity frames | M | B | R2 |
| Rune table; Titles | S + S | B | R2 |
| The stall and ledger | M | B | R2 |
| Place marks (11) | S | engine | R2 |
| Boss page | M | C | R3 |
| Region seals; Codex people and regions | M | A, E | R3 |
| Frontier chevron on the ride map | S | wash, ridden once | R3 |
| Share card | S | frame kit | R3 |
| Watch complication target; iOS widget marks | M | new targets | R4 |
| Lamplight palette; Caprasimo map glyphs; first illustrations in slots | L | all | R4 |

**R1 must contain:** the engine, runes, crests, creature sigils, the swap points, the parchment skin, sigil markers, the three reckoning stages, sheet v1, the Codex with creatures and runes, and the prologue. That is roughly four weeks of the letters above.

## 5. Risks, cheap tests, and what not to build

| Risk | Cheap test |
|---|---|
| Code-drawn creatures read as clip art | An afternoon: Fen Troll, Rook Lord, Lamp Sprite, Raido and the Explorer crest in one preview at 28, 48 and 96 pt, plus one map screenshot. If a creature is not recognisable at 34 pt, drop bodies for single bold heraldic devices. Do this before anything else. |
| Parchment hurts legibility outdoors | World tab only behind the flag; compare screenshots at zoom 16.5 in daylight before the ride screen adopts it. |
| The wash is as purposeless as hexes were | Render it from the owner's real cells on the Journal map card only (`JournalView.swift:268-286`, non-interactive). If the edge does not invite riding, stop there. |
| Ceremony drags | A 12 s budget, one-tap skip, instant under Reduce Motion; time it on three real rides. |
| Marker rendering hitches | One Instruments pass on device with 55 markers; the fallback is a symbol layer with registered images. |
| Style fork drifts from the tile schema | A test that the bundled JSON parses and names the source `openmaptiles`; "Detailed" remains. |
| Server sigil spec and client parts diverge | Unknown part falls back to the worn stone; the fixture test covers it. |
| watchOS type-checker timeouts on path maths (already noted in `RuneMatcher.resample`) | Keep path builders in small steps; build the Watch scheme in the first art PR. |

**Not building:**
- image assets, Lottie or Rive;
- an avatar or appearance editor;
- a fifth tab;
- animated creatures on the map;
- anything animated or worded on the ride screen while moving;
- particle effects;
- dark mode before R4;
- a custom map label font before R4;
- per-creature one-off drawings;
- runic Unicode from system fonts (unreliable look).

### Critical Files for Implementation
- ios/RoadsAndRunes/Components/Theme.swift
- ios/RoadsAndRunes/Services/Maps/MapLibreView.swift
- ios/RoadsAndRunes/Components/AdventureSummaryView.swift
- ios/RoadsAndRunes/Features/Character/CharacterView.swift
- ios/Packages/RoadsAndRunesCore/Package.swift
