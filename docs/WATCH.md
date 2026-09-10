# Apple Watch

Target `RoadsAndRunesWatch` (watchOS 10). Responsibilities: turn navigation,
route map, quest objective, ride statistics, objective notifications,
pause/end, heart-rate workout. Works with the phone locked.

## Data flow

```
iPhone RideRecorder ──WCSession.sendMessage / updateApplicationContext──► Watch
   • RoutePackageSummary once at start (instructions, simplified geometry, objectives)
   • NavigationUpdate throttled (1 s FULL / 2 s BALANCED / 5 s ENDURANCE):
       nextInstruction, distanceToTurn, streetName, objectiveTitle,
       objectiveDistance, stats snapshot, navigationState
   • ObjectiveCompleted events (haptic .success on watch)
Watch ──► iPhone: pause / resume / end commands, heart-rate samples
```

The watch runs its own `HKWorkoutSession` (cycling, outdoor) so heart rate
streams and the workout continues if the phone connection drops. It keeps the
last received instruction on screen and logs `watch_disconnected`; it never
invents navigation.

## Screens (paged TabView)

| Navigation | Quest | Stats | Objective complete | Always-On |
|---|---|---|---|---|
| ![](screenshots/w1-watch-navigation.png) | ![](screenshots/w2-watch-quest.png) | ![](screenshots/w3-watch-stats.png) | ![](screenshots/w4-watch-objective-complete.png) | ![](screenshots/w5-watch-always-on.png) |


1. **Navigation** – arrow glyph, distance to turn, direction word, street
   name. Nothing else.
2. **Quest** – quest title, current objective, distance to it.
3. **Stats** – distance, duration, elevation gained, heart rate. Speed is
   available but small.
4. **Controls** – pause/resume, end ride (confirm).

Objective completion shows a full-screen overlay ("OBJECTIVE COMPLETE · Old
Station discovered · +50 XP") with a success haptic and auto-dismisses after
3 s back to navigation. No interaction required.

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
tunnel, long ride > 3 h, rain glove use of pause/end.
