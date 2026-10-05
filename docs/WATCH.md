# Apple Watch

Target `RoadsAndRunesWatch` (watchOS 10). Responsibilities: turn navigation,
route map, quest objective, ride statistics, objective notifications,
pause/end, heart-rate workout. Works with the phone locked.

## Data flow

```
iPhone RideRecorder ──WCSession.sendMessage / updateApplicationContext──► Watch
   • RoutePackageSummary once at start (instructions, simplified geometry, objectives)
   • NavigationUpdate throttled (1 s FULL / 3 s BALANCED / 10 s ENDURANCE, `BatteryPolicy`):
       nextInstruction, distanceToTurn, streetName, objectiveTitle,
       objectiveDistance, stats snapshot, navigationState
   • ObjectiveCompleted events (haptic .success on watch), with an optional
       `outcome` for the overlay's heading: GONE, OPENED, FOUND or DONE
   • EncounterBeat (0.6.1): ENGAGED or LOOSENED, felt as one tap and never
       shown. Sent only while the Watch is reachable, never inside a turn's
       window and never while off route. A Watch build before 0.6.1 ignores it
   • 0.7.2, all optional both ways (an older Watch ignores them; a Watch with
       an older phone falls back to 0.7.1's screens):
       – RouteSummary.worldMarks: creatures, chests, rune stones, the bounty
         and the quarry within 1.5 km of the route (2 km of the start with no
         route), at most 30, plus each objective's place; stops carry a
         category so they draw as place marks
       – NavigationUpdate.fight: the quarry, else the nearest creature being
         fought, as its species, icon and health in tenths (0–10);
         goneMarkIds: things opened, defeated or done this journey
       – ObjectiveCompleted.icon and .rarity: the overlay shows the mark
       – JourneyEnd (new kind): after the phone gets the processed summary,
         creatures defeated, chests opened, coins, XP, a level reached and the
         finds (items, rune stones, new places); queued if the Watch is away
   • 0.7.3: Next up rides in the application context under its own `idleInfo`
       key beside the ride's last message (one context replaces the whole
       dictionary): the streak, the bounty (mark, how far, when it leaves), up
       to three quests the rider has taken, the activity and today's pledge.
       Sent when the World map loads its objects (quests fetched at most every
       5 minutes, and only to a paired Watch with the app)
Watch ──► iPhone: pause / resume / end commands, heart-rate samples, and
       (0.7.3) StartRequest {kind: LOOP|BOUNTY|QUEST|SEALED, minutes, questId,
       activity, id, requestedAt}: sent only while the phone is reachable; the
       phone ignores one older than 120 s, plans it through the
       QuickStartCoordinator and starts without a tap. A failure comes back as
       StartResult; success is the route summary arriving
```

Every tap the Watch gives is named in Core (`WristTap`). Turns own `click`,
`directionUp` and `directionDown`; a fight may only use `start`, `success` and
`failure`, and `WristTapTests` keeps the two sets apart.

The watch runs its own `HKWorkoutSession` (cycling, outdoor) so heart rate
streams and the workout continues if the phone connection drops. It keeps the
last received instruction on screen and logs `watch_disconnected`; it never
invents navigation.

## Screens (paged TabView)

| Navigation | Quest | Stats | Objective complete | Always-On |
|---|---|---|---|---|
| ![](screenshots/w1-watch-navigation.png) | ![](screenshots/w2-watch-quest.png) | ![](screenshots/w3-watch-stats.png) | ![](screenshots/w4-watch-objective-complete.png) | ![](screenshots/w5-watch-always-on.png) |


Five vertical pages (`App/ContentView.swift`, `RidePages`):

1. **Navigation** – arrow glyph, distance to turn, direction word, street
   name. Nothing else.
2. **Map** – the route, where you are on it and which way you face (0.7.1),
   and since 0.7.2 the game: creatures, chests and rune stones as small marks
   (the quarry larger with a terracotta ring, the bounty gold), stops as
   place marks, each gone from the map once opened or defeated. Hidden in
   Always-On.
3. **Quest** – quest title, current objective, distance to it, and the
   nearest thing on the route ("Bog Wraith · 120 m"). Since 0.7.2 the fight
   shows beside the title as the creature's mark inside its health ring,
   redrawn in tenths, with no numbers.
4. **Stats** – distance, duration, new ground, distance to go, climbed, heart
   rate. Speed is available but small.
5. **Controls** – pause/resume, end ride (confirm).

**Turn taps** are worked out on the Watch from the navigation updates
(`Core/Watch/TurnCue.swift`): two clicks as a turn comes up at 150 m, then at
35 m one tap for a right and two for a left. Any other tap the game adds must
use a different haptic, so nothing on the wrist can be mistaken for a turn.

A claim or a finished objective takes over the screen for about 4 s with a
success haptic (the heading, the thing's mark, the name, the coins, a set's
standing such as "Road Six, 3 of 6", and an item's rarity) and returns to
navigation. No interaction required.

After the journey is saved, **Journey's end** (0.7.2) takes the screen: a line
with a mark for each thing (creatures defeated, chests, coins, XP, a level,
up to six finds) and a Done button that returns to the idle screen. One that
arrives more than an hour late is dropped.

## Districts (0.9.0)

The phone sends the district the rider is in (`districtName`, "Rotherhithe,
the Riverlands" or "…, in the fog") with every update; it asks the server at
most once a minute and only after 300 m, never holding up the ride. The Watch
names a district once per journey, on the Navigation page's footer, and only
at a standstill (five seconds under 0.7 m/s, timed on the Watch's clock; an
unknown speed counts as moving); the line goes when the rider moves off, and
never shows in Always-On. Journey's end adds "District complete!" (or "2
districts complete!") with the names, and "Yours: Rotherhithe, Bermondsey".

## Legends (0.8.0)

While a legend is the quarry or the nearest foe, the Quest page draws its mark
inside three arcs, one per phase: broken ones filled gold, the current one
draining in tenths, the rest whole and dim; no numbers. A phase broken is one
success tap (a fight tap, never a turn tap) and the overlay: the legend's
mark in a gold ring, "PHASE BROKEN!", and how many phases are left. On the map
the legend is the largest mark, gold-ringed; a lair is one mark at its middle.
Journey's end on the wrist adds the legend's line, the lair's count or its
great chest, and buried treasure found. The complication shows the legend's
mark while it is the quarry. `WatchFight` gains optional `phase`/`phases`;
the overlay's outcome `PHASE`; marks of kind `LEGEND` and `LAIR`.

## Before a journey (0.7.3)

The idle screen is **Next up**: the streak, the bounty's mark and how far,
and buttons to go — "Ride to bounty" (Run/Walk for the rider's activity), up
to three "Start quest", and "Quick loop" for 20 or 40 minutes. Each sends a
start request; the Watch shows "Planning…" (75 s at most), then the ride, or
"Couldn't plan. Try on your iPhone." with a Done button. With no phone in
reach it says "Open the app on your iPhone to start." Without Next up (an
older phone) it shows 0.7.2's "Start on your iPhone" face.

**Complication** (`RoadsAndRunesWatchWidgets`, a watchOS widget extension
embedded in the Watch app): circular shows the quarry's or the bounty's mark,
else the streak; corner the streak; inline and rectangular the bounty and how
far. The Watch app writes Next up into the app group and reloads the
timelines when it changes.

Field protocol 5 (start from the Watch with the phone in a pocket) is
possible as written from 0.7.3; whether the phone plans and starts while
locked depends on location permission and is the thing to test.

## Always-On

`isLuminanceReduced` switches to simplified layouts: larger next-turn text,
no animations, stats refresh every 5 s. Since 0.7.3 the map page stays,
dimmed and muted, with the route, the rider's dot and a next-turn badge (no
creatures, chests or stops), following the rider at most every 15 s. The next turn must remain
readable in Always-On.

## Battery

Watch rendering is deliberately minimal; the phone owns GPS and route
matching. `BatteryPolicy` sets update intervals per mode; ENDURANCE relies
more on Watch turn cues and fewer phone screen wakes.

## Field tests

Required before beta: phone locked in pocket, Watch disconnect/reconnect,
tunnel, long ride > 3 h, rain glove use of pause/end. A ride can be started
on the phone or, since 0.7.3, from the Watch's Next up (the phone plans and
records it; the Watch has no GPS of its own). See protocol 5 in
`docs/FIELD_TESTS.md`.
