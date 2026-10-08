> **Superseded where it disagrees with [docs/ROADMAP.md](../../../ROADMAP.md).** This is one of five design drafts written independently on 2026-10-01, before an adversarial review. Known differences: coins, not pence; Hollow Sentry, not Hollow Knight; five cast (Ada Pym, Tam Hurdle, Enid Sallow, Walter Garth, Nell Foss), not six quest-givers; "the road", not "passage"; the old ones are the Blank, the Drowned Lane, the Long Drag, the Slow Coach and the Worn Stone, not the Bailiff; the build is runes, gear and abilities, not attributes plus fifteen systems. Read it for the written lines and the reasoning, not as the specification.

# A. WORLD: the bible for "The Old Roads"

## 1. The idea in five lines

- Every mechanic gets a reason in one fiction: roads were written in runes, nobody reads them, the land forgets (fog), and things settle where nobody passes.
- The four classes become four old trades of road-people. A cast of five plain people post the board, pay the purse and write the codex. No dialogue, no choices.
- "Runes" stops being six nouns: 24 named runes in four rows, each with a meaning and a kind of power. The five GPS shapes become five named cuts.
- Every monster gets a habitat, a want, a leaving, two elders and a codex entry. There are twelve new creatures and four "old ones".
- Real ground gets identity without invented names: a real district plus a computed epithet, and one honest line per place.

**Assumed of neighbours.** B owns rune numbers, items, titles as a collection and level payoffs. C owns hold (HP) maths, the PACE replacement maths, habitat weighting and loot tables. D draws glyphs and crests, and renders fog as the map going blank rather than hexagons. E decides which cast member posts which quest.

**Earlier roadmap.** This absorbs 0.6 "named regions" and the fog fiction. It gives the 0.7 Chronicler its voice (Enid Sallow), but E builds it.

## 2. The design

### 2.1 The premise at three lengths

**One line (store, welcome; replaces `OnboardingFlow.swift:55`):**
"Every road was written once. Go out and read it back."

**One paragraph (prologue):**
"Every road was written once, by people who cut a rune where two ways met. The rune said what the road was for, and the land kept to it. Nobody reads them now, so the land forgets itself: that is the fog. Things settle where nobody passes. None of this is urgent; it has been going on for a long time. It needs somebody to go out, by bike or on foot, and pass. The road remembers whoever does."

**One page (codex entry 1, "The Old Roads"):**
"Every road was written once. The people who made them cut a rune where two ways met, and the rune said what the road was for: this one to water, this one to market, this one home. The land read the runes and kept to them. That was the arrangement.

The people were waywrights, and there were four trades of them. They are covered elsewhere and would want it noted that they got on.

Nobody reads the runes now. Signposts do the work, and a signpost says where a road goes without saying what it is for. So the land forgets itself, a field at a time. That is the fog. It is not weather and it is not dangerous. It is ground that has stopped being sure.

Things settle where nobody passes. They are small and local and have habits. None of them is in charge.

The cure is not complicated. Go out, and pass. A road that is used is a road that is read. Cut a rune again and the way remembers you.

E. Sallow, who was asked to keep this short."

### 2.2 Every mechanic, in-world

| Mechanic | Game name | Finished copy |
|---|---|---|
| Fog | the fog | "Ground nobody has passed lately. It has not gone anywhere. It has stopped being sure of itself." |
| Road-makers | the waywrights | "They cut the roads and then cut what the roads were for. Four trades. No kings." |
| A rune | rune | "A mark cut where two ways meet, saying what the road is for. The land reads it even when nobody else does." |
| Stray runes | piece (kept) | "Rune-stones work loose. Frost, roadworks, a council with a budget." |
| Old coins | Old Money (was Milled Coins) | "Every old road charged at the gate. The gates moved; the coins did not." |
| Monsters | the settled / a settled thing | "Where a rune wears smooth, something moves in. It is not evil. It is in the way." |
| HP (for C) | hold | "How firmly it has settled. Effort loosens it." |
| CLIMB | height | "It sits low. Anybody who has been higher than it today has the better of it." |
| EXPLORE | new ground | "It stands on what is forgotten. Remember the ground round it and it has less to stand on." |
| RUNE | the cut | "Draw the rune it wore smooth. The road is the knife." |
| LORE | the record | "A thing written down is not a rumour any more. It cannot stay where it has been noted." |
| PACE | passage, "a steady kilometre" | "It wants passing, not visiting. Keep going past it, at any pace, and do not stop." |
| Three-day expiry | (none) | "Settled things do not care for weather. Three days and it finds somewhere quieter. It is not beaten. It is elsewhere." |
| The board | the board | "Ada Pym pins what needs looking at. She does not say who told her." |
| Daily bounty | today's bounty | "Nell Foss lights the lamps and reports what was not there yesterday. Double, because it is on a road people use." |
| Chests | waywright's box | "A chisel, chalk, the day's tolls. Buried when the gate closed, on the understanding somebody would come back." |
| Coins | pence (code stays `ac`, `activeCoins`, `rewardAC`) | "Every old road paid its menders out of the tolls. The roads still pay. Nobody has found out who signs it off." |
| XP | XP | "Pence is what the road pays you. XP is what it remembers." |
| Level | level | "The roads count who passes. A level is their count of you." |
| Title | title | "What the board calls you. Earned, never chosen; worn, your choice." |
| Streak | keeping the way / days kept | "A road walked daily stays open. So, it turns out, does a person." |
| Set | a row / a full row | "One rune is a word. A full row is a sentence, and the land can read a sentence." |
| Class change | change of trade | "Taking up another trade. The old one keeps your place. They share a shed." |
| The reckoning | the reckoning | "Walter Garth's count at the end of the day. Nothing is yours until it is in the book." |
| Lure | a lamp left out | "Leave a lamp at a junction and something comes to see who is passing." |
| Ability point | a knack | "Something the trade teaches you once it trusts you with it." |
| Discovery | a place found | "Named places hold their own. They are the last thing the fog takes." |

**PACE.** Retire the speed test and keep the slot. Passage means keeping moving for the existing `windowMeters` (600/1000/1500) within 1 km, with no stop and no pace target. C owns the maths. The `paceSecPerKm` block and the pace near-miss copy go.

**The five cuts.** The RUNE shapes take real rune names; the matcher is unchanged.

| Shape | Rune |
|---|---|
| ZIGZAG | Sowilo |
| SQUARE | Ingwaz |
| TRIANGLE | Thurisaz |
| LOOP | Othala |
| STAR | Hagalaz ("in the later rows it is cut as a star") |

"You can cut a rune you do not own. You cannot carry one you have not found."

### 2.3 The four trades

Code ids and display names stay. Each gains an order name: "Explorer, of the Wayfinders".

| Class | Order | Believes | Reads a road by | Founder and saying | Crest (woodcut) |
|---|---|---|---|---|---|
| Explorer | the Wayfinders | A road nobody has taken is a rumour. | Its edges: where it stops, and what is past that. | Agnes Fell, who walked off the county map and sent back a corrected one. "The edge moves." | A ring broken at upper right, one arrow leaving through the gap, three hatch-strokes beyond. |
| Wizard | the Readers | Every straight line was somebody's idea. | What was cut into it: markers, alignments, old ground under new tarmac. | Tobias Marrow, who could read a milestone by hand in the dark and was wrong about most other things. "Look twice, then once more." | A standing stone, one stave cut down its face, three short rays. |
| Warrior | the Menders | A road is kept with the legs. | What it costs: length and gradient. | Hester Cragg, who carried the same stone up the same hill until it stayed. "The hill does not negotiate." | A mattock upright over a single hill line, a notch cut in the slope. |
| Scribe | the Clerks | What is not written down was never there. | What happened on it: stop, look, record. | Edmund Pell, who wrote down the weather for forty years and is the only reason anybody knows it rained. "It may as well be you." | An open book, a road drawn across both pages and off the edge. |

**`classes.json` rewrites:**

| Class | tagline | description |
|---|---|---|
| EXPLORER | "Goes first. Moves the edge of the map." | "The Wayfinders walked ahead and decided where the road would go. New roads, new ground and places nobody pointed you at pay best. A road you have not taken is only a rumour." |
| WIZARD | "Reads what was cut. Looks twice." | "The Readers kept the runes legible. Old stones, odd markers and shapes drawn with your own track pay best. There is more to a place than the map admits." |
| WARRIOR | "Keeps the road with the legs. Pays the hill." | "The Menders carried the stone. Distance, climbing and long hours out pay best, measured against yourself and nobody else. The hill charges everyone the same." |
| SCRIBE | "Stops, looks, writes it down." | "The Clerks kept the toll-book and everything else. Notes, photographs and places looked at properly pay best. A thing in the record is harder to forget." |

### 2.4 The cast

They appear as bylines only: a name under a notice, a codex entry or the reckoning. At most one cast line per screen.

- **Ada Pym, keeper of the board.**
  - "Three on the board. One has been there since Tuesday and is starting to curl."
  - "I only pin them. What you do about it is between you and your legs."
  - "Somebody has to go and look. I have written 'somebody' and left a gap."
- **Walter Garth, toll-keeper.** He runs the reckoning, the purse, anything sold and the change of trade.
  - "Sixty pence for the troll. I have counted it twice and it is still sixty."
  - "Nothing is yours until it is in the book. Then it is yours and I have a copy."
  - "The roads pay. I do not ask where they get it."
- **Enid Sallow, hedge-scholar.** She writes the codex and place lore.
  - "Fen Troll. I have the habits down. The reasons I am still guessing at."
  - "The map files it as a ruin. The map is being polite."
  - "Three theories about the fog. I hold all of them, on different days."
- **Tam Hurdle, roadmender.** Hills, distance, weather.
  - "It is a hill. It was a hill yesterday."
  - "Wet out. The road will not mind, and nor will you after the first bit."
  - "Mended the gap by the bridge. Something had been sitting in it."
- **Nell Foss, lamplighter.** The bounty, sightings, dusk.
  - "Something by the pond again. It was not there when I lit the lamps."
  - "One for today. Double, because it is on a road people use."
  - "Gone by midnight. They do not like being talked about."

### 2.5 The 24 runes

Four rows of six.

- **Road Row.** Today's `RUNES` set, found lying anywhere. These are the six met first.
- **Ground Row.** Strays found only on their own kind of ground.
- **Trade Row.** Given by the cast and orders at arc ends (E).
- **Hard Row.** Taken from the old ones and elders (C).

| Rune | Row | Meaning here | Lends |
|---|---|---|---|
| ᚨ Ansuz | Road | "The word-rune. A place named is a place kept." | the record: notes |
| ᚱ Raido | Road | "The road-rune. Cut it again and the way remembers you." | distance |
| ᚲ Kenaz | Road | "The lamp. It shows what is there, which is not always welcome." | sight: reveal, sighting range |
| ᚹ Wunjo | Road | "The good day. Nobody cut it for a reason, which is the reason." | stops: cafés, pubs |
| ᛋ Sowilo | Road | "The sun. A road goes somewhere; this is the somewhere." | arriving, viewpoints |
| ᛞ Dagaz | Road | "The day-rune. Dawn and dusk are the same mark seen from each side." | dawn and dusk outings, the bounty |
| ᛚ Laguz | Ground: water | "The water-rune. Water remembers every route that crossed it." | waterside ground |
| ᛒ Berkano | Ground: parks | "The birch. First tree back on cleared ground." | green places |
| ᛇ Eihwaz | Ground: historic | "The yew. Older than the churchyard it stands in." | old ground |
| ᛃ Jera | Ground: food, pub, café | "The year. What you did last season, coming due." | known ground, repeat custom |
| ᛖ Ehwaz | Ground: trail, cycling | "The mount. Two going as one: you, and whatever you are on." | bike, run and walk parity |
| ᛉ Algiz | Ground: viewpoint, reserve | "The sedge. Grab it and it cuts; follow it and it marks the dry way." | a ward: keeps a missed day |
| ᚠ Fehu | Trade: Garth | "The toll-rune. What a road is owed." | pence |
| ᚷ Gebo | Trade: Pym | "The crossing. Two ways meet and each gives the other somewhere to go." | boxes and finds |
| ᛗ Mannaz | Trade: Sallow | "The passer-by. A road with nobody on it is a ditch." | places found |
| ᛏ Tiwaz | Trade: Menders | "The pole. It points one way and has never been asked why." | bearing: far from home, out-and-back |
| ᛈ Perthro | Trade: Readers | "The cup. Nobody agrees what it means, which is taken as proof." | luck: what a box holds |
| ᛟ Othala | Trade: first arc | "The home-rune. Out, round, and back to where you keep your things." | home ground |
| ᚢ Uruz | Hard: the Long Drag | "The ox. A hill is a thing you lean on." | climbing |
| ᛁ Isa | Hard: the Drowned Lane | "The still-rune. Stopping is also a way of being somewhere." | standing still |
| ᚾ Nauthiz | Hard: the Night Mail | "The need-rune. Cut it when short of something. It does not say what." | near misses carry over |
| ᚺ Hagalaz | Hard: the Blank | "The hailstone. What comes down on ground nobody is minding." | foul weather, new ground |
| ᚦ Thurisaz | Hard: first tier-3 elder | "The thorn. A hedge is a wall that grows back." | against elders |
| ᛜ Ingwaz | Hard: first full row | "The seed. A small closed shape with something kept in it." | rows and collecting |

### 2.6 The bestiary: the existing twelve

Habitat uses the OSM categories and the `Discovery.tags` already stored. No settled thing anchors at `historic=memorial`, graves or places of worship.

| Monster | Habitat | Wants | Leaves | Tier 2 / tier 3 |
|---|---|---|---|---|
| Bog Wraith | any `waterway`; TRAIL by water | passage, new ground | a cold penny | Lock Wraith / the Long Cold |
| Fen Troll | `waterway`, `natural=water`; NATURE by water | height, passage | a bridge nail | Culvert Troll / Old Arch |
| Gutter Drake | FOOD, CAFE, PUB | new ground, the cut | a bottle-top | Skip Drake / the Drake of the Back Lane |
| Hollow Sentry (was Hollow Knight) | HISTORICAL `castle|fort|manor`; LANDMARK | the record, the cut | a buckle | Hollow Serjeant / the Empty Captain |
| Mire Hag | `natural=water`, `water=pond`; NATURE | the record, new ground | a hagstone | Mill-Pond Hag / the One Who Waited |
| Lamp Sprite | CAFE, PUB, CULTURAL; dusk | the cut, passage | a wick | Lantern Sprite / the Last Lamp |
| Rook Lord | NATURE `leisure=park|garden` | new ground, height | a black feather | Rook Baron / the Parliament |
| Cinder Hound | TRAIL, CYCLING | passage, height | a clinker | Clinker Hound / Old Smoke |
| Moss Golem | HISTORICAL `ruins`; NATURE `garden` | height, the record | a chip of capstone | Lichen Golem / the Garden Wall |
| Tide Serpent | `natural=beach`, `waterway=river`; VIEWPOINT by water | passage, the cut | a scale | Ebb Serpent / the Spring Tide |
| Grey Stag | VIEWPOINT, `natural=peak`, `nature_reserve` | height, new ground | a tine | Grey Hart / the Grey Royal |
| Ash Warden | HISTORICAL `ruins`; LANDMARK | the record, the cut | a charred key | Ember Warden / the Last Watchman |

**Codex entries:**

- **Bog Wraith.** "A cold patch of air that follows the towpath. It keeps up with whoever is passing and falls behind only when they do not stop. Nobody has seen it, and several people have worn a second jumper because of it."
- **Fen Troll.** "Sleeps under the bridge; wakes for footsteps. It has held the towpath since the rune at the lock wore smooth. It sits low and dislikes anyone who has been higher than it today."
- **Gutter Drake.** "Small, quick, and fond of bins. It hoards anything that shines and has no idea what any of it is worth. Draw a line round it and it assumes it has been caught."
- **Hollow Sentry.** "Armour with nobody in it, still patrolling. It was given a post and never given leave. Write down that the watch is over and it will take your word for it."
- **Mire Hag.** "Has been waiting by this pond a very long time. She will not say for whom, and may have forgotten. She goes when somebody finally makes a note of her."
- **Lamp Sprite.** "Flickers when you look straight at it. It lives in the one street light that never quite comes on. It follows a shape drawn on the ground the way a moth follows anything."
- **Rook Lord.** "Holds the park by the sheer number of rooks. There is no lord as such; there are the rooks, and an agreement. They lose interest in ground somebody else plainly knows better."
- **Cinder Hound.** "Faster than it looks, and it looks fast. You will not outrun it and it is not asking you to. It tires of anyone who simply keeps going."
- **Moss Golem.** "Mostly wall. The moss is the dangerous part. It moves about a stride a year, always towards the path."
- **Tide Serpent.** "Only ever seen at the water's edge. It comes in with the tide and takes the bank for its own until shown otherwise. A loop drawn along the shore is a line it will not cross."
- **Grey Stag.** "Stands in the mist and dares you. It is always one contour higher than you are. Come up level and it finds it has somewhere else to be."
- **Ash Warden.** "Guards a place that burned down long ago. Nobody has told it, and it would not thank them. It stands down for anyone who writes what is there now."

### 2.7 Twelve more creatures

| Name | Flavour | Habitat |
|---|---|---|
| Culvert Imp | "Lives where the stream goes under the road. Collects single gloves." | `waterway` |
| Stile Boggart | "Sits on the stile and makes it one step higher than it was." | TRAIL |
| Milestone Wight | "Stands by the stone and reads the wrong distance aloud." | LANDMARK |
| Churchyard Grim | "A black dog that minds the yew. Mostly it minds its own business." | HISTORICAL, never at graves |
| Hedge Hob | "Keeps the gap in the hedge. Charges for it in blackberries." | NATURE, TRAIL |
| Bandstand Ghost | "Still waiting for the second half." | NATURE `leisure=park` |
| Kiln Wyrm | "Asleep in the bakery wall since the ovens went electric." | FOOD |
| Cellar Nixie | "Came up with the beer one evening and liked the company." | PUB |
| Steam Familiar | "Hangs over the counter and reads the orders back wrong." | CAFE |
| Gallery Shade | "Stands very still in front of one picture. It is not on the list." | CULTURAL |
| Cairn Crow | "Adds a stone when nobody is looking. Takes one when they are." | VIEWPOINT |
| Spoke Gremlin | "Responsible for the noise you cannot find." | CYCLING |

### 2.8 The old ones

- **The Night Mail.** "Runs on a line that was lifted before you were born. It keeps to the timetable, which is all that is left of the railway. It cannot be stopped and does not need to be. It needs somebody to cover the whole line, over as many outings as that takes, so the line can be marked closed." Habitat: long named TRAIL routes (`route=bicycle|hiking`). Falls to distance. Leaves Nauthiz.
- **The Long Drag.** "A hill with no top to speak of. It has charged everyone the same since before the road and has never once been paid in full. It keeps a tally. Every metre climbed in sight of it comes off, and it remembers what you paid last week." Habitat: the highest VIEWPOINT or peak in reach. Falls to climbing. Leaves Uruz.
- **The Drowned Lane.** "A road that went under when the water was let in, and still thinks it is a road. On still days you can follow it from the bank. It wants what any road wants, which is to be on a map. Stop along the water, write down what is there, and it surfaces a length at a time." Habitat: the largest water in reach. Falls to stops and records. Leaves Isa.
- **The Blank.** "The piece of the map nearest you with the most nothing in it. It is not a creature. It is what the fog becomes when left alone long enough to have opinions. It gives way only to new ground, and what you take from it, it does not get back." Habitat: the largest block of unseen cells in reach. Falls to exploration. Leaves Hagalaz.

### 2.9 Regions

A region is a res-6 parent cell, the unit already counted at `exploration/service.py:247-256`.

- **Name.** The real district from one reverse-geocode per cell, cached for ever.
- **Epithet.** Computed from the `Discovery` rows inside the cell.
- **Form.** Always "{Real name}, {epithet}". The epithet is lower-case, after a comma, and never fused to the name. "Old Deptford" would read as a real place.
- **No district found.** Use a bearing: "North-east of home, the wet side".

| # | Rule (share of the cell's discoveries) | Epithet | Example |
|---|---|---|---|
| 1 | water tags at 30% or more | the wet side | Rotherhithe, the wet side |
| 2 | two or more VIEWPOINT or peak | the high ground | Greenwich, the high ground |
| 3 | rail present (needs a new import tag) | the far side of the line | Deptford, the far side of the line |
| 4 | HISTORICAL at 25% or more | the old stones | Nunhead, the old stones |
| 5 | NATURE at 40% or more | the green quarter | Dulwich, the green quarter |
| 6 | PUB is the top category | the thirsty end | Bermondsey, the thirsty end |
| 7 | CAFE and FOOD on top | the fed quarter | Peckham, the fed quarter |
| 8 | TRAIL at 20% or more | the back ways | Blackheath, the back ways |
| 9 | CULTURAL at 15% or more | the kept things | South Bank, the kept things |
| 10 | fewer than five discoveries | the quiet end | Surrey Quays, the quiet end |

Two overrides sit above the table:

- The player's most-ridden cell is always "home ground".
- A cell under 10% seen is "past the last lamp" until entered.

### 2.10 Place lore

One line per real place, built in layers. The first layer that produces a line wins.

1. **The OSM `description` tag**, verbatim, trimmed to 140 characters.
2. **A tag fact.** This is a widened `_fact_for` (`quests/generator.py:264`), written as "{what}, by the map's account." About 40 tag values need a phrase.
3. **Wikidata, optional.** One batched `wbgetentities` call (labels, description, P31, P571) for places the player found on that ride, at most 12, with a two-second timeout. It states only what is returned.
4. **A composed fallback**, chosen by `hash(osm_id) % 3`.
5. **An LLM rewrite, optional**, of layers 2 and 3 into one line of 22 words or fewer, passed through a validator.

**What the LLM may do:**
- Rephrase supplied facts.
- Add one clause about the game's own layer: fog, a rune, a settled thing, the board.

**What it may not invent:**
- names, dates, numbers, people, events or architecture;
- opening hours, quality, directions, safety or speed;
- other players.

**Validator.** Reject any digit or capitalised word not in the supplied facts, any banned word, or any line over 22 words. On rejection, use the composed line.

**Sensitive places.** Memorials, graves and places of worship get layers 1 to 3 only: no joke, no settled thing.

**Composed fallbacks:**

- **NATURE**
  - "{name} keeps its own hours. The fog has never got far past the gate."
  - "Green on the map and greener in person. Something has been using the benches."
  - "The trees were not consulted about the road. They have not forgotten."
- **HISTORICAL**
  - "{name} was here before the road and expects to be here after."
  - "Somebody built this to last and it took them at their word."
  - "Old enough that the rune beside it has worn smooth. It manages without."
- **CULTURAL**
  - "{name} keeps things so that nobody has to remember them personally."
  - "What somebody thought worth keeping. The fog stops at the door."
  - "Somebody made this on purpose. That is rarer than it sounds."
- **FOOD**
  - "{name} feeds people on their way somewhere. That makes it a road business."
  - "Something is cooked here most days. The settled do not care for the smell."
  - "Open, by the map's account. The map does not vouch for the menu."
- **PUB**
  - "{name} has been giving directions for longer than the signposts."
  - "Every road used to end at one of these. Some still do."
  - "The oldest reliable landmark is a pub. Ask anyone who has given directions."
- **CAFE**
  - "Out, a cup at {name}, and home. The oldest quest there is."
  - "A warm room with a window. Half the roads round here were planned in one."
  - "It does cups. The fog has never yet crossed a queue."
- **VIEWPOINT**
  - "From {name} you can see how much is left. It is always more than expected."
  - "Ground looks different from above it. So does the fog."
  - "The waywrights came up here to check their spelling."
- **CYCLING**
  - "{name} mends what the road breaks. The road keeps them busy."
  - "Somebody in here knows what that noise is."
  - "A shed with the right tools in it. The Menders would approve, and say nothing."
- **LANDMARK**
  - "{name} is what people mean by 'you cannot miss it'."
  - "Directions round here start or end with it."
  - "Big enough to hold its own name. The fog goes round."
- **TRAIL**
  - "{name} is not a road. That is the point."
  - "A way that stayed a way without anybody surfacing it."
  - "Older than the tarmac it avoids. The rune at its start is still legible."
- **CUSTOM**
  - "Not on anybody's map but yours. That counts."
  - "You put this here. The road will take your word for it."
  - "A place because somebody said so, which is how all of them started."

### 2.11 Voice sheet

**Twelve rules**

1. Plain declaratives, short words, under twenty words a sentence.
2. Two beats: a flat statement, then one turn.
3. Things want, charge, keep, remember and wait. People mostly do not.
4. Second person, present tense.
5. British spelling and furniture: towpath, verge, stile, kerb, bins.
6. Understate. The biggest thing in the game is "a long way".
7. Spell numbers under thirteen in prose; use digits in tallies.
8. Real things keep their real names. The rest is "the pond", "the bridge".
9. The joke is in the facts, never in the wording.
10. Settled things are nuisances with habits: loosened, seen off, got away.
11. The scholar admits doubt: "the map says", "nobody is sure".
12. Mid-ride lines are five words, noun first.

**Twelve banned moves**

1. Exclamation marks.
2. Archaic diction: thou, hark, behold, realm, destiny, hero, chosen, "traveller".
3. Invented place names, or an epithet fused to a real name.
4. Invented facts about real places.
5. Speed words: fast, pace, sprint, race, record, beat.
6. Gore and death (slay, kill, blood), and jokes at memorials.
7. Other players, ranks, comparison.
8. Emoji and decorative symbols.
9. Ancient, mystic, arcane, epic or legendary used as praise.
10. Surface jargon: AC, HP, loot, buff, spawn, tier, mob.
11. Cheerleading: "Great job", "Amazing".
12. Lore dumps: more than three sentences on a card.

**The hardest five**

| | Right | Wrong |
|---|---|---|
| The turn | "Mostly wall. The moss is the dangerous part." | "A fearsome golem of living stone, cloaked in deadly moss." |
| Understating a win | "Level nine. The roads know you a little better." | "LEVEL UP! You are becoming a legend." |
| Effort, not speed | "It wants a steady kilometre. Any pace; no stopping." | "Outrun it: hold 24 km/h for a kilometre." |
| Lore without invention | "A ruin, by the map's account. Something has been keeping the nettles down." | "Built in 1140 by a forgotten baron, the abbey fell to fire." |
| Mid-ride | "Fen Troll. It wants a climb." | "A Fen Troll stirs beneath the old bridge ahead, traveller." |

### 2.12 Flat surfaces, rewritten

- **Level-up card** (`AdventureSummaryView.swift:305`)
  - Eyebrow: "The roads count again".
  - Title: "Level nine".
  - Rotating line: "The roads know you a little better than they did this morning." / "Counted again. It comes out higher." / "Nothing feels different. It is, slightly."
  - Class level: "Explorer, level six. The Wayfinders have moved your name up the list."
- **Ability unlock** (`:317`): "A new knack: Trail Sense. It is on your sheet when you want it."
- **Chests**
  - Old: "Old chest. A chisel, some chalk and 25 pence. Somebody meant to come back."
  - Iron: "Iron chest. Locked once; the lock gave up first. 60 pence."
  - Gilded: "Gilded chest. Somebody important hid this and told nobody. 150 pence."
  - Spoken: "Chest opened. Sixty pence."
- **Piece pickup**
  - New: "Raido, the road-rune. Three of six."
  - Duplicate: "Raido again. The road has plenty. Ten pence."
  - Coin: "A groat. Somebody paid a toll here, and the gate has gone."
- **Loading** (`RootView.swift:14`): "Unfolding the map." Alternates: "Asking the roads." / "Checking the board."
- **Watch overlay** (`ObjectiveCompleteOverlay.swift:21,44`)
  - "SEEN OFF" / "OPENED" / "FOUND" by kind, replacing "YOURS". This needs an optional kind on `WatchObjectiveCompleted`.
  - "DONE" replaces "OBJECTIVE COMPLETE".
  - "+60" with the coin mark replaces "+60 AC".
- **Class change** (`ClassChangeSheet.swift:88,95`)
  - Free: "The first change of trade is free. People are allowed to be wrong once."
  - Paid: "Walter Garth wants 150 pence for the paperwork. Your purse has 320."
  - Button: "Take up reading · 150 pence".
  - Kept line: "The Wayfinders keep your place."
- **Empty Journal** (`JournalView.swift:197`): "Nothing written yet" / "The journal fills itself. It only needs you to go out."
- **Streak**
  - "The way kept three days."
  - Day 7: "Seven days kept. The road has stopped being surprised to see you."
  - Day 30: "Thirty days kept. The fog has started going round."
  - Nudge: "The way goes unkept tonight" / "One kilometre keeps it. A short walk will do."
- **Spoken wants** (`RideEvent.swift:183-187`)
  - "It wants a steady kilometre."
  - "It wants a climb."
  - "It wants its rune cut."
  - "It wants writing down."
  - "It wants new ground."

### 2.13 Renaming table

| Now | Becomes |
|---|---|
| Active Coins, AC (every surface) | pence; "+60 pence"; never abbreviated |
| Milled Coins | Old Money |
| Old Runes | the Road Row |
| "Adventure complete" | "The reckoning" |
| "Collect rewards" | "Close the book" (the UI never grants) |
| "Level up" | "The roads count again" |
| "{name} available" | "A new knack: {name}" |
| ability point | a knack |
| "Monsters" (XP and coin labels) | "Things seen off" |
| "beaten" | "seen off"; a partial is "loosened" |
| "a fast kilometre" (also `ActivitySetupView.swift:53`) | "a steady kilometre" |
| "a shape drawn round it" | "its rune cut" |
| triangle, square, star, loop, zigzag | Thurisaz, Ingwaz, Hagalaz, Othala, Sowilo |
| "new areas" | "new ground"; one cell is "a patch" |
| hp | hold |
| tiers 2 and 3 | the elder names |
| streak | days kept / keeping the way |
| lure | a lamp left out |
| class change | change of trade |
| Hollow Knight | Hollow Sentry (another game's title) |
| "Adventurer" (unknown class) | Passer-by |
| Level titles: Novice, Wanderer, Pathfinder, Far Wanderer, Cartographer, Worldwalker, Legend of the Roads | Passer-by, Regular, Road Hand, Time-Served, Waywright, Old Hand, Known to the Roads. This frees the three ability names. |
| Quest title "Far Wanderer" | "The Far End" |
| "Loading your world…" | "Unfolding the map." |
| "No adventures yet" | "Nothing written yet" |
| "YOURS" / "OBJECTIVE COMPLETE" | "SEEN OFF", "OPENED", "FOUND" / "DONE" |

### 2.14 Still to write

- Codex "how it works" entries from §2.2: 27, at three sentences each.
- Codex entries for the 12 new creatures and 24 elders.
- About 20 rotating lines per cast member.
- Six level-up lines per ten-level band.
- About 40 tag-fact phrases.
- Two more chest lines per tier.
- One pickup line per rune (24) and per coin (4).
- Epithet alternates, two per pattern.
- Ability flavour for 16 abilities (with B).
- An almanac of season and weather lines, about 24.

## 3. How it attaches

**Backend**

- **New module `backend/app/lore/`.**
  - Config: `codex.json`, `runes.json`, `bestiary.json`, `cast.json`, `place_lore.json`, `regions.json`.
  - `catalog.py` loads them with `lru_cache` and asserts at import. The pattern is `load_arcs` (`quests/story.py:54-83`) and `characters/catalog.py:14-21`.
  - It is pure, with no I/O beyond the file read.
- **`world_objects/config/world_objects.json:15-26`.** Each monster gains `habitat`, `wants`, `leaves`, `elders`. `payload` is JSON, so no migration. C consumes them at `spawner.py:163` (species pick), `:170` (`hp`) and `_appeal` (`:225`).
- **Hints** at `spawner.py:74,88,96,104,112` and chest names at `:178` take the copy above.
- **`quests/narrative.py`.**
  - `SYSTEM` (`:13`) gets a 150-word digest: premise, voice rules, banned list.
  - `CLASS_LINES` (`:28`) is rewritten to the trades.
  - `enrich(..., locality=)` (`:75`) already takes a locality that no caller supplies. Feed it the region name.
- **`quests/generator.py:264`.** `_fact_for` delegates to `lore.place_line(poi)`, with the same "never invented" contract.
- **`characters/config/classes.json`.** New text, plus optional `order`, `saying` and `crest` keys.
- **`progression/config/levels.json:7`.** New titles.
- **Endpoint.** `GET /codex` serves static content plus which entries the player has met, derived from CLAIMED `world_objects` rows in the manner of `pieces_owned` (`world_objects/service.py:131`). New fields are optional.
- **Tables.** None needed for R1. R2 adds, in migration 0008:
  - a nullable `discoveries.lore` JSON column;
  - a small shared `region_names` table (cell, name, epithet).
  
  Neither is per-user, so neither joins `reset_character`'s delete list (`characters/service.py:238`).
- **Reverse geocoding.** `routing/geocode.py` is forward-only. Add one `reverse()` beside `_photon` (`:140`), with the same User-Agent and cache.
- **Tests.**
  - `tests/test_lore_catalog.py`: every monster has a bestiary entry; all 24 runes are present; every category has three fallbacks.
  - A voice lint over all `config/*.json` strings: no "!", no banned words, no "AC".

**iOS**

- New `Core/Formatting/LoreCopy.swift` beside `RewardCopy` and `NudgeCopy`, shared with the Watch, with tests.
- Strings change at:
  - `OnboardingFlow.swift:55,123,159`
  - `RootView.swift:14`
  - `JournalView.swift:197`
  - `ClassChangeSheet.swift:88,95`
  - `CharacterHeader.swift:175,180`
  - `AdventureSummaryView.swift:97,201,271,305,317,341,345,473,492`
  - `BountyCard.swift:37`, `EncounterCard.swift:108`, `TodayStrip.swift:73`
  - `NavigationScreen.swift:453`
  - `SettingsView.swift:76,102`
  - `MockAPI.swift:184,253`
  - `RideEvent.swift:90-91,183-187`
  - `RewardCopy.swift` labels and near-miss copy

**Switched on**

- The unused `hp` field, as "hold".
- The never-fed `locality` argument.
- Stored but unfetched `wikidata` tags.
- The empty region concept.

## 4. Phasing

| Piece | Effort | Depends on | Release |
|---|---|---|---|
| Renaming sweep (pence, reckoning, knack, seen off, steady kilometre) | S | nothing | R1 |
| Premise at three lengths, in welcome and codex entry 1 | S | D's prologue screen | R1 |
| `classes.json`, `CLASS_LINES`, level titles | S | nothing | R1 |
| `bestiary.json` for the twelve, and the Hollow Sentry rename | S | nothing | R1 |
| `runes.json` (24), and shape names as runes | S | D's glyphs | R1 |
| Flat-surface rewrites and `LoreCopy.swift` | M | renaming sweep | R1 |
| `lore/` loader, `GET /codex`, lint test | M | nothing | R1 |
| Cast bylines on board, bounty and reckoning | S | E's board | R1 |
| LLM `SYSTEM` digest | S | nothing | R1 |
| Composed place lines and tag-fact table | M | `lore/` | R2 |
| Region names and epithets | M | reverse geocode, migration 0008 | R2 |
| Twelve new creatures (content) | S | C's habitat spawn | R2 |
| Mechanic codex entries and cast line pools | M | codex screen (D) | R2 |
| Ground Row found on its own ground | S | C's spawner | R2 |
| Wikidata fetch | M | `discoveries.lore` | R3 |
| LLM place line and validator | M | wikidata, API key set | R3 |
| The old ones (lore; build is C's) | S | C's bosses | R3 |
| Trade and Hard Rows | S | E's arcs, C's bosses | R3 |
| Almanac of season and weather lines | S | C's weather | R4 |
| Rail epithet (import tag, `TILE_VERSION` bump) | M | re-import | R4 |

**R1 must contain** the first nine rows. With only those, every word on screen belongs to one world, and "AC" and "fast kilometre" are gone.

## 5. Risks, cheap tests, and what not to build

- **"Pence" reads as real money.** Test: show one reckoning screenshot to someone who has not played. Fallback: "coins".
- **Rune names on geometric shapes.** A drawn square is not a textbook Ingwaz. Test: show the glyph beside the traced shape on one encounter card and see if it reads as the same thing.
- **Rune imagery.** Some forms carry extremist associations: doubled Sowilo, serifed or winged Othala, and Algiz as a "life rune". D draws plain Elder forms only, never doubled, never as an insignia.
- **Dry jokes repeating.** Frequent surfaces need five or more variants. Test: the owner rides ten times and flags any line seen three times.
- **Place lines landing wrong.** Test: run the composer read-only over every imported discovery in the home tile (about 250) and read them all before shipping.
- **District names.** Photon may return a borough or a street. Test: 20 cells around home by hand before building.
- **Cast creep into dialogue.** Rule: bylines only, one per screen, never a reply.
- **LLM drift.** The validator rejects on any unknown capitalised word or digit. Test: 50 generations against fixtures, counting rejections.

**Not to build**

- A named realm or map overlay.
- An antagonist.
- Dialogue trees.
- Voiced lore while moving.
- A rune cipher to decode.
- City-specific hand-written lore.
- An LLM-written bestiary.
- Lore that mentions other players.

### Critical Files for Implementation

- backend/app/world_objects/config/world_objects.json
- backend/app/world_objects/spawner.py
- backend/app/quests/narrative.py
- backend/app/characters/config/classes.json
- ios/Packages/RoadsAndRunesCore/Sources/RoadsAndRunesCore/Formatting/RewardCopy.swift
