# Routing

| Route alternatives | Navigation |
|---|---|
| ![](screenshots/05-routes.png) | ![](screenshots/06-navigation.png) |

## Pipeline

```
RouteGenerateRequest
  ├─ rider profile + bike → base RoutePreferences
  ├─ free text → parse_request (rules, or Claude when LLM_PROVIDER=anthropic) → preferences
  ├─ quest → target points, RETURN_TO_START, heading
  └─ for each label (3 from scoring.json bikeDefaultLabels, adjusted by preferences):
        overlay label preferences → custom model → GraphHopper request
        → analysis (elevation, climbs, surface, cycleway, traffic)
        → new-territory fraction (H3 vs user's cells)
        → quest objective coverage
        → POI corridor search
        → score → Route row
sorted by score; best becomes quest.suggested_route_id
```

Labels are never "Route 1/2/3": Relaxed, Adventure, Scenic, Direct, Gravel,
Challenge, chosen per bike type and adjusted when the request asks for
gravel, hills or a destination.

## Reading a request

A rider types one sentence, and it can name two different things:

| They wrote | Parses to | The ride |
|---|---|---|
| "a loop **in** Notting Hill with 5 pubs" | `area` | Moves there, wanders around it, comes home |
| "go **to** the Aragon Tower, 2 pubs on the way" | `destination` | Starts where they are, finishes at the tower |

`app/routing/preferences.py` finds both with the same trick: guess a phrase
loosely, then let `app/routing/geocode.py` decide whether it is a place. The
run-up is trimmed first, so "I want to **go to** the Aragon Tower" asks about
"aragon tower" and "I want to **go for** a 20 km ride" asks about nothing.

The two resolve differently, because a wrong answer costs differently:

* `area` searches Photon and Nominatim for ground — `place`, `boundary`,
  `leisure`, `natural`, `landuse`, `tourism`. The whole ride moves there, so a
  shop matching the phrase would waste the ride.
* `destination` (`kind="point"`) accepts nearly anything named: a building, a
  tower, a bridge, a pub, a station. The guard is the name instead — the answer
  has to be called what the rider called it, or a point search will happily
  return a bakery for "the way home".

A destination that resolves becomes a real waypoint: `loop` defaults off, the
stops are picked from the corridor along the way (`_pick_stops_between`, in the
order they are reached) rather than rung around the origin, and the target
distance comes from the trip rather than the app's slider. One that does not
resolve is said out loud in `parsedRequest.notes` — riding somewhere else
quietly is the worse answer.

The LLM (`LLM_PROVIDER=anthropic`) reads the same two fields and never returns
coordinates; the geocoder does that, so a hallucinated point cannot reach
navigation (spec §20, §31).

## Engine

`GraphHopperClient` posts to `/route` with `ch.disable=true`, a custom model,
elevation and details. Loops use `round_trip` with a user/origin-derived seed
per label; with a quest destination the loop is headed towards it and the
target is inserted as a via-point. Point-to-point uses `alternative_route`.

`SyntheticRouter` produces plausible loops for tests and for development when
GraphHopper is down. Routes carry `engine`; production refuses to boot on the
synthetic engine and clients should treat `engine == "synthetic"` as
non-navigable.

## Custom models

Base profiles (`routing/custom_models/*.json`) encode bike capability and
block motorway/trunk. `app/routing/custom_models.py` turns preferences into a
request-time overlay: traffic aversion penalises primary/secondary/tertiary,
cycleway preference lowers everything that is not cycling infrastructure,
gravel preference and bike capability adjust unpaved surfaces and tracks, low
hill tolerance penalises `average_slope >= 6`, scenic preference favours
non-road environments. Overlays multiply priorities and can only reduce them
for unsafe classes.

## Analysis

* Elevation samples every 100 m from the returned 3D coordinates; smoothing
  window 3; ascent/descent with 3 m hysteresis; max gradient over samples;
  climbs = rising stretches ≥ 30 m gain and ≥ 2 %, ended by a 15 m drop;
  longest climb and average climb gradient.
* Surface composition from `details.surface` buckets (paved, gravel, trail,
  unknown), cycleway fraction from `road_class == cycleway` or bike network,
  traffic exposure = length-weighted road-class score.

## Scoring

```
score = ( w1·preferenceFit + w2·questFit + w3·exploration + w4·poi + w5·scenic
        − w6·traffic − w7·difficulty − w8·surfaceMismatch ) / Σ positive weights
```

Weights in `backend/app/routing/config/scoring.json`. Difficulty penalty
compares distance, climbing and max gradient against the rider profile (never
the RPG level). Surface mismatch penalises gravel/trail on bikes that do not
allow them.

## POIs

Candidates come from `discoveries` within 60 % of the target distance
(PostGIS `ST_DWithin`); `attach_pois` keeps those within a 400 m corridor and
computes route position, detour distance/time, ETA and relevance (boosted for
the requested category near the requested position). Output: "The Crown ·
24.6 km into ride · +600 m · +3 min".

## Route package

`GET /routes/{id}/package` bundles route geometry, instructions, elevation,
climbs, POIs, the quest and a map region for offline use. The client stores
it before starting and navigates from it without network.

## Rerouting

The client detects off-route (> 40 m cross-track for 3 fixes), tries to rejoin
and, after 30 s (throttled to once a minute), requests a new route from the
current position with the same quest; quest objectives, not the original
polyline, decide completion.
