# Garmin

A study, 2026-10-08. Nothing here is built. Two questions:

- **A. Routes on the Garmin.** A rider plans a route in the app and follows it on a Garmin Edge or watch.
- **B. Journeys into Garmin Connect.** A journey recorded by the app shows up in the rider's Garmin Connect account.

## The short answer

**A is possible today without Garmin's permission. B is not possible automatically, for us or for almost anyone.**

- **Garmin's own route sync is closed to newcomers.** komoot, Strava, Ride with GPS and AllTrails send routes through the **Courses API**. That API sits inside the Garmin Connect Developer Program, which has taken **no new applications since spring 2026**. Garmin says the program is being redesigned ("Stay tuned"), gives no date, and existing partners keep working ([the5krunner](https://the5krunner.com/2026/09/14/garmin-developer-api-access-paused/), [Garmin forum](https://forums.garmin.com/developer/connect-iq/f/discussion/434798/cannot-access-developer-program-application-form-under-construction)).
- **Two ways around it are open.** One is a **FIT course file** the rider opens in the Garmin Connect app. The other is **our own Connect IQ app** on the device, which downloads the route into the device's own Courses list and starts Garmin's navigation. Connect IQ is a separate, open program and is not affected by the pause.
- **No public API writes activities into Garmin Connect.** The program's user permissions are `ACTIVITY_EXPORT`, `WORKOUT_IMPORT`, `HEALTH_EXPORT`, `COURSE_IMPORT` and `MCT_EXPORT`, with no activity import. Activity push exists only as private deals: Zwift, TrainerRoad, ROUVY and Tacx, and Peloton since March 2026 ([DC Rainmaker](https://www.dcrainmaker.com/2026/03/peloton-garmin-workout.html)). Garmin has told developers it is "not accepting any new requests (partners) to push activities" ([TrainerDay, quoting Garmin](https://forums.trainerday.com/t/official-word-from-garmin-on-activities/218)).
- **What we can offer for B** is a **FIT activity file** the rider imports at connect.garmin.com. Longer term, the journey could be recorded *on* the Garmin, so it is a Garmin activity from the start (see B3).

Recommended order: FIT export for routes and journeys first (small, needs nobody's approval), then a Connect IQ app, then the Courses API once Garmin reopens. Details are under [Plan](#plan).

---

## What we already have

The data is all there. Only the delivery is missing.

| We need | We have | Where |
|---|---|---|
| A course: the line, height, turns, stops | `Route.coordinates` as `[lon, lat, ele]` at the engine's full resolution; `instructions` with `sign`, `text`, `streetName` and `coordinateIndex`; `pois` with name, category and position | `backend/app/routing/models.py`, `routing/schemas.py:45-54` |
| An activity: timestamped points | `ride_points` keeps every raw fix with timestamp, altitude, speed and heart rate (Watch or HealthKit), never thinned | `backend/app/rides/models.py:65-77` |
| Account linking | The Strava integration: OAuth, a connection row, upload modes `NEVER/ASK/AUTO`, a per-ride upload status and retry | `backend/app/integrations/strava.py`, `SettingsView.swift`, `JournalView.swift:441-487` |
| File export | `GET /rides/{id}/export?format=gpx\|tcx` | `backend/app/rides/export.py` |
| A device that follows the phone | The Watch app, a remote display that "never invents navigation" | `docs/WATCH.md` |

Gaps to fix whatever we choose:

- **"Export GPX" in the Journal shares a link, not a file.** `ShareLink(item: container.api.rideExportURL(...))` (`JournalView.swift:583`) hands the share sheet the authenticated API URL. Any app that receives it, Garmin Connect included, fetches it with no token and gets refused. The file has to be downloaded first and the local file shared.
- **Exports say everything is cycling.** GPX writes `<type>cycling</type>` and TCX writes `Sport="Biking"` for runs and walks too (`export.py:22, 42`). Exports also include the points validation dropped.
- **Routes cannot be exported at all.** There is no course export of any kind.
- **The Strava callback never checks the OAuth `state`.** `StravaCallback` carries only `code` (`integrations/router.py:27`). A Garmin link must check it, and Strava's should too.
- **Turn detail is lossy.** Keep-left/right collapse to `CONTINUE`, and roundabout exits to `ROUNDABOUT`. That is fine for the phone's voice, and it is the same detail a Garmin would get.
- **A sealed quest's route gives the goal away.** Its point is a destination kept hidden until halfway, so it must never be exported or sent.

---

## A. Routes on the Garmin

### A1. A FIT course through the share sheet (no approval needed)

The rider taps **Send to Garmin** on a planned route. The share sheet opens with `Old Mill loop.fit`, they pick **Connect**, choose a course type, and the course syncs to the device on its next sync. Footpath documents the same flow ([Footpath](https://footpathapp.com/user-guide/exporting-routes/exporting-to-garmin/)). Recent forum reports say the Garmin Connect iOS app accepts both GPX and FIT this way.

- **What it costs:** an encoder and an endpoint. Garmin's official FIT SDKs now include a **Python encoder** (`garmin-fit-sdk`, since 21.200.0, April 2026) and a **Swift package** (`fit-swift-sdk`, iOS 14+). Encode on the **backend**: one encoder serves the share sheet, a Connect IQ app (A2) and journeys (B1), and is tested in pytest beside `export.py`.
- **The file** ([FIT course file](https://developer.garmin.com/fit/file-types/course/)):
  - The structure is `file_id` (type course), `course` (name; sport from the activity), one `lap`, a timer start `event`, then `record`s from `coordinates` with cumulative distance and timestamps paced by `estimated_duration_seconds`, then `course_point`s and a closing timer `event`.
  - **Turns become course points.** `LEFT`→left (6), `RIGHT`→right (7), `SLIGHT_LEFT`→slight_left (19), `SHARP_LEFT`→sharp_left (20), `SLIGHT_RIGHT`→21, `SHARP_RIGHT`→22, `U_TURN`→u_turn (23) and `CONTINUE`→straight (8). FIT has no roundabout type, so a roundabout becomes generic (0) named with its instruction.
  - **Places become course points too.** Requested pubs, cafés and quest objectives become food, water, checkpoint or generic points. Names are short on a device screen, so "Chest" and "The Moby Dick" work and sentences don't.
- **Friction:** about six taps, then a sync. Garmin support once called share-sheet import "not an intended feature". It has worked for years, but it could change without notice.
- **To test before building on it:**
  - Does Garmin Connect iOS still accept a `.fit` course from the share sheet?
  - Do our course points survive the import?
  - On an Edge with maps, does the rider see our turns, Garmin's own, or both?

### A2. Our own Connect IQ app (no approval needed beyond store review)

This is what komoot (Connect IQ App of the Year 2023) and Ride with GPS do alongside the Courses API.

- **On the device:** the app lists the rider's planned routes from our API. Picking one downloads it as FIT straight into the device's **native Courses list** (`Communications.makeWebRequest` with `HTTP_RESPONSE_CONTENT_TYPE_FIT`) and starts Garmin's own navigation (`PersistedContent.getCourses()`, then `System.exitTo(course.toIntent())`, API 2.2.0+). Garmin does the navigating; we only deliver.
- **Linking:** the device can't do Sign in with Apple. The iPhone app gives the Garmin a device token over Garmin's **Connect IQ Mobile SDK for iOS** (SPM, v1.8.0 January 2026, still maintained). That same channel lets the phone say "this route, now". A short pairing code typed into the phone is the fallback. The token can only read routes.
- **Requests** go through the phone's Garmin Connect app over Bluetooth and must be HTTPS. `roadsandrunes.fly.dev` already is.
- **Costs:**
  - A new language (Monkey C) and a device matrix.
  - Memory is 768 KB–1 MB for a device app on current Edge, Forerunner and fēnix models.
  - Some older devices take only FIT or only GPX for downloads, with no way to ask first. Test each target.
  - Store review takes up to 72 h and a free app costs nothing.
- **Later, maybe:** game marks drawn on the course with `MapView` (3.0.0+, map devices only), and creatures and chests as course points. That is how a Garmin could carry the game the way the Watch does.

### A3. The Courses API (the komoot/Strava way, closed for now)

This is the best experience: link Garmin once in Settings next to Strava, and every **Send to Garmin** appears in the device's Courses menu on the next sync.

- **How it works:**
  - A server-side JSON `POST /training-api/courses/v1/course` with `geoPoints` (at most about 10,000, no more than 100 m apart), `activityType`, and POI-only course points.
  - There are **no turn cues through the API**: Garmin works them out on its side.
  - OAuth 2.0 PKCE, with the token exchange on our backend because it needs the client secret.
  - Rate limits of 200 calls per user per day on evaluation keys.
  - These details come from an unofficial copy of the partner spec, so check them against the portal if we ever get in.
- **Blocked:** no applications are taken today. The program is free but "only for business use", and approval for a studio of one was never certain. Before production, Garmin reviews the integration and may review it for brand.
- **Terms to read before applying** ([agreement, March 2026](https://www8.garmin.com/en-US/GARMINCONNECTDEVELOPERPROGRAMAGREEMENT/GARMINCONNECTDEVELOPERPROGRAMAGREEMENT_EN.pdf)):
  - a ban on using the API "to compete with Garmin";
  - an AI-transparency statement if user data is processed by AI;
  - 30 days' notice before new screens show Garmin data.
  - Pushing courses alone shows no Garmin data, so the attribution rules in the [brand guidelines](https://developer.garmin.com/downloads/brand/Garmin-Developer-API-Brand-Guidelines.pdf) barely apply.

### A4. Through an aggregator (Terra)

[Terra's Routes API](https://tryterra.co/blog/routes-api) (launched 2026-09-06) uses Terra's own Garmin access and also reaches **COROS and Wahoo**: one route, three brands. It is reported at a few hundred dollars a month plus a write add-on; I have not checked the price myself. That is too much before 1.0 with internal testers. Worth pricing at App Store launch if the Courses API is still closed.

---

## B. Journeys into Garmin Connect

### B1. A FIT activity the rider imports (the only route open)

**Save for Garmin** on Journey's end and in the Journal writes a FIT activity file ([FIT activity file](https://developer.garmin.com/fit/file-types/activity/)):

- **Contents:** `file_id` (type activity), `activity`, one `session` and one `lap` from the ride's totals, then a `record` per kept point with timestamp, position, altitude, speed and heart rate. The sport comes from `Ride.activity`.
- **Importing:** the rider opens connect.garmin.com → **Import Data**. The Garmin Connect phone app cannot import activities.
- **To be honest in the app about:**
  - iOS Safari has long refused to pick `.fit` files on that page. Re-test it; if it still does, the honest instruction is "on a computer".
  - Imported third-party activities probably don't count toward Training Status (unverified).
  - A rider who also recorded on their Garmin gets the journey twice. "Only if you didn't record it on your Garmin" belongs in the how-to.
- **Effort:** small once the encoder exists. GPX would work too, but FIT keeps heart rate and the sport without guesswork.

### B2. Bridges that don't exist

- **Apple Health:** Garmin writes into Health. Nothing shows that Health workouts become Garmin activities.
- **Strava:** sends *routes* to Garmin but never activities.

Neither is a path.

### B3. Record on the Garmin instead (the long way round)

If the Connect IQ app from A2 grows a recording mode (`ActivityRecording`), the journey is a Garmin activity from its first second and lands in Garmin Connect by itself, Training Status included. The app would then send the track to us for the game. That reverses who records: the Garmin owns GPS, and the phone stops being the source of truth. It is a second client for the whole game, not an integration, so it isn't worth doing unless Garmin riders become a large share.

### B4. A partner deal

Peloton got one in 2026, so deals still happen, but for companies with leverage. Not a plan.

---

## Privacy

- **Export:** the rider starts it and it goes to their own account, like GPX and Strava today, and `docs/PRIVACY.md` promises nothing that forbids it.
- **The trace is not masked.** A file carries the whole route from the doorstep; the share card's `TraceMask` does not apply. That is right for the rider's own Garmin, but the button must not appear to share publicly.
- **A Garmin link (A3):** its tokens go in the account-deletion purge alongside Strava's.

---

## Plan

| Step | What | Size | Needs |
|---|---|---|---|
| 1 | FIT encoder on the backend; `GET /routes/{id}/export?format=fit\|gpx` and `GET /rides/{id}/export?format=fit`; sport per activity; dropped points left out | S | `garmin-fit-sdk` ≥ 21.200.0 |
| 2 | The phone downloads, then shares a file: **Send to Garmin** on a planned route (never a sealed quest), **Save for Garmin** on a journey, each with a short how-to sheet. Fixes the Journal's GPX button on the way | S | step 1 |
| 3 | The test list from A1 and B1 on a real Edge or watch and the current Garmin Connect app | S | your Garmin |
| 4 | Connect IQ app: list routes, download into Courses, start navigation; device token through the Mobile SDK | M–L | steps 1 and 3; Connect IQ developer account |
| 5 | Courses API: **Send to Garmin** without the share sheet, linked in Settings next to Strava, built on its patterns with `state` checked | M | Garmin reopening and accepting us |

Steps 1 to 3 are a sensible small release. Step 4 is a release of its own. Step 5 waits on Garmin, so watch the [developer program page](https://developer.garmin.com/gc-developer-program/overview/).

## Open questions

- **Which Garmin do you ride with?** Edge or watch, and which model, decides the Connect IQ targets and the test device.
- **Before or after 1.0?** The roadmap's "Beyond 1.0" lists only other players, the App Store and history import. Steps 1 and 2 are small enough to fit beside a release. Step 4 is not.
- **Is "Send to Garmin" for every route, or only some?** A rune ride's line is its whole point and shows well on a Garmin map. A quest route also shows the objective's place, which is fine for every quest except a sealed one.
