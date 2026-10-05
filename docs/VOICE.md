# Voice: how the app talks

Roads & Runes tells a simple fantasy story: dragons and wizards and bikes. The
words on buttons, labels, cards, errors, the Watch and the ride's voice are
**simple to read and ring of fantasy**. This page wins over `docs/WORLD.md`
wherever the two disagree (it replaced that page's dry, understated voice and
its lexicon on 2026-10-04, after the first rides of 0.7.0).

Quest descriptions, quest stories and world lore are not covered here. They are
the game's author's to write; until they are, leave the existing quest text
alone and invent no new lore, cast lines or mysteries for it.

## Rules

1. **Buttons are a verb and a noun**, three words at most: "Open chest", "Plan a
   ride", "Light a lamp", "Learn skill". No metaphors on anything you tap.
2. **One word per idea**, from the glossary below, everywhere: phone, Watch,
   spoken lines and the server's messages.
3. **Fantasy lives in nouns and names** (creatures, dragons, runes, the bounty,
   the Codex, guilds). Instructions are plain.
4. **Say what it does and what it costs first**, flavour second: "Calls a
   creature to this place. 50 coins, only if one comes."
5. **Warm and light**, a little playful. Never ominous, never a riddle, never
   creepy. An exclamation mark is fine for a celebration (a level, a creature
   defeated, a quest done) and nowhere else.
6. **Numbers carry a label**: "Health 260 / 400", "Wizard level 3",
   "3 / 5 rune stones".
7. **Errors say what happened and what to do**, in two short sentences at most.
   No codes, no enum names, and never anything that contradicts what the player
   just did.
8. **Empty states say how to fill them**: "No creatures met yet. Ride near one
   to add it."
9. **The cast** (Ada Pym, Tam Hurdle, Enid Sallow, Walter Garth, Nell Foss)
   speak only on quest cards, notices and Codex pages: never in menus, settings
   or errors.
10. **Still true from the product spec**: never praise speed; nothing to read
    while moving; a spoken line on the ride is five words or fewer.

## Glossary

| Idea | Say | Not |
|---|---|---|
| A monster | **creature**; a named stronger one is an **elder** | thing, monster, it |
| Beaten / partly beaten | **defeated** / **weakened** | seen off, gone, beaten, loosened |
| Its hit points | **health** ("Health 260 / 400") | its hold, HP |
| Weak to / resists | **Weak to** / **Resists** | wants / does not mind |
| The five kinds of effort | **distance**, **exploring**, **climbing**, **rune shape**, **a note** | the road, new ground, height, a rune, the word |
| The map you have and have not covered | **explored** / **unexplored**, counted in **tiles**; the unexplored is **the fog** | read / unread ground, cells, patches, areas, territory |
| A chest | **chest** | box |
| A rune piece | **rune stone** | stone of it, shard |
| Money | **coins**; your balance is your **purse**; extra pay is a **bonus** | AC, the book, a purse of 100 |
| Your type of character | **class** (Explorer, Wizard, Warrior, Scribe); guild names only in the Codex | trade |
| An ability / a point to spend | **skill** / **skill point** | knack, ability point |
| Days in a row | **streak** | days kept |
| A recorded activity | **ride**, **run** or **walk** when known; **journey** when it could be any | outing, adventure |
| The summary after a journey | **Journey's end**; its button is **Done** | the reckoning, Close the book |
| Levels | **Level up!**; "Wizard level 3" for a class level | the roads count again, bare "Explorer 8" |
| The lure | **lamp**; the button is **Light a lamp** | leave a lamp out, lure |
| A place on the map | **place**; one not found yet is a **hidden place** | discovery, a mystery, "?" |
| Riding a rune's shape | **rune ride**; the button is **Ride its shape** | cut it |
| What you wear | **gear**, in five **slots** (Bell, Lantern, Bag, Map case, Keepsake); one piece is an **item** | equipment, kit, loadout |
| How rare an item is | **Common**, **Rare**, **Legendary** | Plain, Good, Storied |
| What you carry and don't wear | your **bag** (gear and consumables) | inventory, stash |
| The shop | **the stall** (opens at level 3) | market, store |
| The wallet ledger | **coin history** | the book |
| The map fragment | **map piece** | fragment |
| Other consumables | **lamp**, **rest token**, **sealed chest** | — |
| A creature with a twist | **Stubborn**, **Skittish** or **Mossy** before its name | variant, mutation |
| One that got away twice and came back | a **grudge**: "Fen Troll the Grumpy" | nemesis, revenant |
| A quest whose goal you learn on the way | **sealed quest** ("The board picked the way. Your goal opens halfway.") | fate's errand, mystery quest |
| A promise to go out for something | **pledge**; the button is **Pledge it**; kept: "You said you would. You did." | vow, oath |
| A note to your future self at a place | **letter**; the button is **Leave a letter** | message, cairn |
| A real reward set against coins | **savings goal** | treasury |
| The picture of a journey to send someone | **share card** | — |
| A great creature that takes several journeys | a **legend** ("A legend has woken: the Fog Dragon"); its health comes in three **phases**, and breaking one is "**Phase broken!**" | boss, old one, raid |
| Seven tiles round a park to visit | a **lair** ("Visit 5 of its 7 tiles in 14 days") | dungeon |
| A map with no marker, only a clue | **treasure map**, its **clue**, the **buried treasure** | riddle, fragment |
| A lair's reward | a **great chest** | strongbox |

Keep as they are: XP, level, runes, **inscribe**, rank, bounty, quest, quest
board, Codex, Journal, deeds, titles, the fog, lamp, gear, bag.

## Checks

- `backend/app/lore/voice.py` and `tests/test_voice.py` hold the server's
  config labels to the glossary.
- UI tests find controls by accessibility identifier, not by their words, so a
  rewrite does not break them.
