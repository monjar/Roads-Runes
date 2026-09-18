# Field tests

The spec (§80) makes these mandatory before beta and says they cannot be
automated. It is right: every bug found in the first week of TestFlight — a
76 km/h top speed, the same quest dealt twice, a "line" quest drawn as a
triangle, no way to delete a ride — was in code the suite marked green. The
suite checks what the planner does with a reading; only a ride checks the
reading, the GPS, the battery, the road.

Each protocol below is one ride with one question. Ride it with the phone
where it lives on a ride (pocket, bar mount), not in your hand. Afterwards,
export the ride's GPX from its page in the Journal (Export GPX) and keep the
screenshots — the GPX carries every fix the phone kept, which is what a
speed, distance or route bug is diagnosed from.

## What to record, every ride

* Phone model and iOS version; watch model if worn; battery mode (Settings).
* Where the phone was (pocket / mount) and the weather (rain kills touch).
* Distance and moving time from another source when there is one — the
  Watch's own workout, a bike computer, Strava.
* Anything that surprised you, with the time it happened. A note typed at the
  next stop is worth more than a memory at home.

## Protocols

### 1. A plain ride, start to finish
**Question:** does recording round-trip cleanly?
Start a free ride, ride 20–40 minutes with at least one stop of 2+ minutes,
end it. Check: distance within 3% of the other source; moving time excludes
the stop; top speed is a speed you actually did; elevation plausible; the
adventure appears in the Journal with the right title and date; XP awarded.

### 2. A quest to completion
**Question:** do objectives complete on the road, not just in a test?
Accept a quest with a visit objective, ride its route. Check: the objective
ticks off when you arrive (note how far from the marker you were); a haptic
fires; the quest reads COMPLETED after the ride processes; the summary names
the quest and its XP. Then a quest with a hidden (puzzle) target: did the app
withhold the location until you found it?

### 3. Going off route on purpose
**Question:** does navigation notice, and does it recover?
Follow a planned route, then leave it for two blocks. Check: how long until
the app says you are off route (it waits 30 s and three fixes past 40 m);
whether it offers a reroute; whether rejoining is recognised (within 20 m);
whether the turn list resumes at the right turn. Do this once at walking
pace and once at speed.

### 4. Killing the app mid-ride
**Question:** does crash recovery keep the ride?
Ten minutes in, swipe the app away. Wait a minute. Reopen. Check: the
recovery sheet appears; resuming keeps distance and time (no bridging of the
gap — the missing minute should be missing); the final ride uploads as one.
Then the harder version: let the phone die (or airplane mode for five
minutes) and see what the ride looks like afterwards.

### 5. The Watch on its own
**Question:** does the Watch do its job without looking at the phone?
Start from the Watch, phone in a pocket. Check: distance and time keep pace
with the phone; the turn haptic arrives before the turn, not at it; the
objective haptic fires; Always-On shows the stat you want at a glance;
heart rate is present in the summary; ending from the Watch ends the ride.

### 6. Battery, three modes
**Question:** what does a two-hour ride cost?
Same route (or as near as you get), one ride per mode: FULL, BALANCED,
ENDURANCE. Record battery % at start and end for phone and Watch. Compare
the three GPX traces for track quality — ENDURANCE should still hold a
navigable line, never a scribble.

### 7. A typed request, on the road it planned
**Question:** does the plan survive contact with the ground?
Type a request that names a place and a stop — "to the Aragon Tower via the
Moby Dick" — and ride what it plans. Check: the understood line matched what
you meant; the route passed the named stop; the finish was the finish; the
stop count and kind were right; the distance shown was the distance ridden.

### 8. Somewhere new
**Question:** does the world fill in when you leave the seeded area?
Ride somewhere the app has never been (another borough, another town).
Check: quests appear for the new place within a minute of opening the
Quests tab; discoveries import; the fog and the cell count make sense; the
board does not repeat quests from home.

## Handing it over

A report is: the protocol number, the GPX, the screenshots, and the notes.
Numbers without the GPX ("it said 76 km/h") take a fix from a screenshot to
a guess; the GPX makes it a test case.
