# Fights: effort is damage

Behind the `effort_combat` flag (0.6.1). With the flag off the old pass/fail
check stands, so the flag is a real way back. The plan and its reasons are in
`docs/ROADMAP.md` (0.6.1 and Appendix C); the world's words for all of this are
in `docs/WORLD.md`.

## What a fight is

Every creature has a **hold** (100 / 220 / 400 by tier). Effort near it takes
some off, judged after the outing from the trace alone
(`backend/app/world_objects/fight.py`). There is no clock in the fight: a point
carries a position, an altitude and whether it can be trusted, and going faster
can only ever lose effect. Nothing hurts the player, and nothing heals.

| Kind | On screen | What counts | Rate |
|---|---|---|---|
| `ROAD` | the road | metres made good inside its ground, on 15 m stride anchors. Ground covered twice on one outing pays once, and at most 4 km a ride | 0.01 per m |
| `GROUND` | new ground | new cells first entered inside its ground | 15 per cell |
| `CLIMB` | height | metres of new height inside its ground; height already climbed that outing pays nothing | 1.25 per m |
| `RUNE` | a rune | its own rune's road form, cut nearby (the shared rune matcher). Once a day | 100 |
| `WORD` | the word | a note of a few words written within 120 m of it, placed by the server on the trace. Once a day | 60 |

* **Its ground** is 1,000 m round it (left at 1,300 m). An outing counts only
  if it comes within 150 m.
* **Wants ×2, does not mind ×0.5.** Each species wants two kinds and shrugs at
  one (`world_objects.json`, `monsters[]`).
* **The carried blow.** What the outing did before contact lands as one opening
  blow at a fifth of its local worth, at most a third of the hold.
* **A thing goes when it gets what it wants.** Effort it does not want (the
  road, new ground, height, the opening blow) loosens it down to its last point
  of hold; only a kind it wants, or a deliberate act (a rune, the word), sees it
  off. Passing by never finishes anything that was not asking for it.
* **On foot** the road and new ground count double and height a quarter more,
  outside the build's clamp; the build (`CharacterSheet.damage_pct`) is clamped
  to 0.25–3.
* Only fixes accurate to 30 m count. A jump over 250 m counts nothing. An
  outing under 500 m, or one that overlaps another of the player's, loosens
  nothing.

All of these numbers are in `world_objects.json` under `combat`, reach the
phone on `GET /config`, and are **provisional**: the hosted backend held 13
short test rides on 2026-10-04, too few to tune against. The replay
(`backend/scripts/replay_fights.py --synthetic`, or `--gpx` with exported
outings, or `--rides` against a database) over five made-up outings round
Rotherhithe found that before "a thing goes when it gets what it wants" three
outings in five saw something off by chance; after it, one in five. Outings
that wander without aiming at anything meet few creatures (one or two of five
placed round home), which is what the quarry and placing a creature on a
planned route are for. Rerun it with real outings before trusting a number.

## Runes inscribed (0.7.0)

Inscribed runes change the fight's rules, never its percentages
(`backend/app/inventory/config/runes.json`; the sheet's `rules`):

| Rune | Rule (rank I) |
|---|---|
| Raido | the opening blow counts double |
| Sowilo | a rune cut reaches 2 km |
| Kenaz | a ring of ground read round each place found; things sighted 600 m out |
| Dagaz | on the first outing of the day, "does not mind" counts as neither |
| Ansuz | the word lands on everything within 1 km |
| Wunjo | a five-minute stop at a café, a pub or a green place is the word |
| Laguz, Berkano, Eihwaz, Ehwaz | the first thing of their family met counts the road, new ground, the word, or (on a bike) the road as wanted |
| Jera | the week's notice pays half again |
| Algiz | a loosened bounty keeps its double purse, a day longer |

**Waking.** Cutting an inscribed rune's road form on an outing planned as that
rune's rune ride (`POST /routes/rune`) wakes it, once: it counts a rank deeper
for that outing and lands a rune blow on every creature within reach of where
it was cut (`fight.WOKEN`), as well as on those whose own form it is. A shape
an ordinary outing happens to make wakes nothing: the replay found three
ordinary outings in five cut a square by chance (street grids turn at right
angles), against the plan's mark of one in five. It still lands on a creature
whose own rune it is. The phone does not fold waking, Wunjo's stops,
Dagaz or the Ground Six, so it is early, never late.

## Afterwards

* **Seen off**: claimed; coins pay now (the bounty's purse if it was one). XP:
  half by share of hold taken (`BLOWS_LANDED`, on every outing that takes
  some), half on the finish (`MONSTER_BEATEN`).
* **Loosened**: the wound is written onto the object, keyed by ride (a rerun
  replaces, never adds), and it stays two days from this outing, at most a week
  from when it appeared. A loosened bounty carries on as an ordinary creature
  at the ordinary purse.
* Creatures are chosen by the ride's own window (placed before it ended, not
  gone before it began), whatever their status now, so a late upload is judged
  against the world it rode through.
* A fight that throws becomes a miss and a `FIGHT_ERROR` flag on the ride,
  never a lost outing. A ride whose processing failed entirely can be run again
  with `python -m app.jobs.reprocess <ride-id>`.

The summary carries `worldObjects.fights[]` (one report per creature met:
`outcome`, `holdBefore`, `holdAfter`, `damage` by kind, `finisher`,
`wouldHaveDone`) and `quarryId`, the creature the outing was planned for.

## Where things are

* Species are chosen after the place, by habitat: a tag match weighs 6, a kind
  of place 3, anything else 0.2.
* Nothing is placed at a memorial, grave, place of worship, hospital or
  anywhere private (`backend/app/discoveries/sensitivity.py`).
* Creature rings widen for riders (×1.6) and runners (×1.25).
* The route chosen to ride has one creature waiting beside its far half, unless
  one is already there (`place_on_route`, when the package is fetched).
* Places not passed in 30 days are favoured, and the card says so.
* The bounty lives 36 to 48 hours, not until midnight.
* A lamp left out (`POST /world/objects/lure`) brings one creature to the
  nearest named place within 250 m of the spot picked, and costs 50 coins only
  if something comes.

## The way back

1. `FEATURE_FLAGS` without `effort_combat` (in `backend/fly.toml`, or
   `fly secrets set`). The API then sends the old payload (`killMethods` with
   real params), and judges by the old check. New creatures always carry both
   their species block and old-style methods (never PACE), so either way has
   something true to judge.
2. Wounds already written stay on their objects and do nothing with the flag
   off; they lapse with the objects.
3. A ride that failed while the flag was on: `fly ssh console -C "python -m
   app.jobs.reprocess <ride-id>"`.

## The phone

With the flag on, the API sends a 0.5.0 phone `killMethods: []`, so it can
never announce a win the server will not give. A phone that understands effort
gets `holdMax`, `holdLeft`, `wants`, `minds`, `rune` and `roadForm` on each
monster, the frozen sheet on the ride (`loadout`) and on the character
(`sheet`), and the constants on `/config`. It folds the same fight for
provisional feedback (`Core/Encounters/FightTracker.swift`), under-claiming by
5%, and the reckoning tells the server's verdict.

The phone follows a fight only when it has the constants, a sheet and the
ground already read round the route (`GET /world/exploration`, fetched at the
start whether or not the fog is drawn). Missing any, it says nothing of
fights. It does not know about a rune or word that landed on an earlier
outing the same day, so on a second outing it can be early by that much.

While moving it is small on purpose:

* **Three sounds.** It has noticed you; a rune or the word landed; it is gone
  (or, leaving its ground loosened, it got away). Only the quarry speaks, or
  else the nearest thing being fought.
* **Never over the road.** A fight sound is dropped, not queued, if anything
  is playing, inside a turn's cue window (150 m) or while off the route.
* **Two wrist taps**, `start` when it notices you and `failure` when it gets
  away, from a vocabulary kept apart from the turn taps by test. Seen off
  shows the Watch's GONE card.
* **The ride screen** shows its sigil in a ring of hold, redrawn in tenths,
  with no numbers and no animation. What it wants, and the button to write the
  word, show only at a standstill (under 0.7 m/s for five seconds; an unknown
  speed counts as moving).

"Plan a route here" on a creature makes it the outing's quarry
(`RideCreate.quarryId`); the reckoning's fight stage leads with it.
