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
Watch ──► iPhone: pause / resume / end commands, heart-rate samples
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

## Always-On

`isLuminanceReduced` switches to simplified layouts: no map, larger next-turn
text, no animations, stats refresh every 5 s. The next turn must remain
readable in Always-On.

## Battery

Watch rendering is deliberately minimal; the phone owns GPS and route
matching. `BatteryPolicy` sets update intervals per mode; ENDURANCE relies
more on Watch turn cues and fewer phone screen wakes.

## Field tests

Required before beta: phone locked in pocket, Watch disconnect/reconnect,
tunnel, long ride > 3 h, rain glove use of pause/end. A ride is started on the
phone; the Watch follows it (it has no GPS of its own and cannot start one
yet). See protocol 5 in `docs/FIELD_TESTS.md`.
