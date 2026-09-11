# Routing (GraphHopper + Valhalla + OpenStreetMap)

## Coverage: GraphHopper where it has a graph, Valhalla everywhere else

GraphHopper routes only inside the extract it imported (Greater London by
default). With `ROUTING_ENGINE=auto` (the default) the API builds a
`RegionalRouter` (`app/routing/engine.py`): a request goes to GraphHopper when
all its points, and for a loop the circle it may sweep, lie inside the graph's
bounding box (`GET /info`), and to Valhalla (`app/routing/valhalla.py`)
otherwise, or when GraphHopper fails. Valhalla defaults to the public FOSSGIS
server (`https://valhalla1.openstreetmap.de`: no key, fair use, development
only); production points `VALHALLA_URL` at a self-hosted Valhalla built from
planet tiles (`VALHALLA_API_KEY` is sent as `api_key` if the host needs one).

| `ROUTING_ENGINE` | behaviour |
|---|---|
| `auto` | GraphHopper inside its graph, Valhalla elsewhere; Valhalla alone if GraphHopper is down |
| `graphhopper` | GraphHopper only (synthetic fallback in development) |
| `valhalla` | Valhalla only |
| `synthetic` | geometric test routes |

The rider's preferences drive both engines: GraphHopper gets the custom-model
overlay below, Valhalla the bicycle costing from `valhalla_costing()` (bike
type Road/Cross/Mountain/Hybrid; `use_roads` from traffic and cycleway
preference; `use_hills` from hill tolerance; `avoid_bad_surfaces` from gravel
appetite and what the bike can ride). Valhalla has no round-trip algorithm, so
a loop runs through three waypoints on a circle through the origin (the seed
picks its side and direction) and is rescaled once toward the target
distance. Surface, road class and cycle network come from a
`trace_attributes` call over the route (exact walk, or map matching when a
loop doubles back), laid onto the route by distance and translated into
GraphHopper's detail format, so the analysis and scoring below do not care
which engine answered. `RouteOption.engine` records which one did.

Google's Routes API was considered and rejected: its terms do not allow its
results on a non-Google map (the apps draw MapLibre with OpenFreeMap tiles),
and its cycling mode has no bike types, surfaces or round trips.

## GraphHopper profiles

`config.yml` configures a GraphHopper 10 instance (image pinned to
`israelhikingmap/graphhopper:10.2` in `infra/docker-compose.yml`) with four
bike profiles. Each is GraphHopper's bundled base model (`bike.json`,
`racingbike.json` or `mtb.json`: access, priority and average speed from OSM
tags) followed by our overlay from `custom_models/`, which only multiplies
priority and caps speed — the overlays set no base speed of their own:

| profile | bike types | character |
|---|---|---|
| `road` | ROAD | blocks unpaved, strong cycleway preference |
| `gravel` | GRAVEL | boosts gravel/compacted tracks, penalises mud/sand |
| `mountain` | MOUNTAIN | tracks, bridleways and paths with `mtb_rating <= 2` |
| `hybrid` | HYBRID, FOLDING, OTHER | quiet roads and cycleways, light unpaved penalty |

All base models multiply `motorway`/`trunk` by 0 and honour `bike_access`, so
request-time preference overlays can only tighten routing, never re-enable
unsafe roads (spec §75).

## Importing a region (GraphHopper only; everywhere else routes through Valhalla)

```bash
infra/scripts/download-osm.sh europe/united-kingdom/england/greater-london
docker compose -f infra/docker-compose.yml --profile routing up graphhopper
```

The first start imports the extract and builds `data/graph-cache` plus SRTM
elevation tiles under `data/elevation-cache`. Both are git-ignored.

## What the backend sends

`app/routing/engine.py` posts to `POST /route`:

```json
{
  "profile": "gravel",
  "points": [[lon, lat], ...],
  "elevation": true,
  "points_encoded": false,
  "instructions": true,
  "details": ["surface", "road_class", "road_environment", "bike_network", "average_slope"],
  "ch.disable": true,
  "custom_model": { "priority": [...], "speed": [...], "distance_influence": 100 },
  "algorithm": "round_trip",
  "round_trip.distance": 30000,
  "round_trip.seed": 42,
  "heading": 135
}
```

* **Loops** use `algorithm=round_trip` with `round_trip.distance` and a seed
  derived from the user and origin, so the three alternatives (Relaxed,
  Adventure, Gravel/Scenic/Challenge) differ in shape and preference overlay.
  When a quest has a destination, `heading` points the loop towards it and the
  destination is added as a via-point instead.
* **Point-to-point** requests use `algorithm=alternative_route` with
  `alternative_route.max_paths=3`.
* The request-time `custom_model` is generated from the rider's preferences
  (`app/routing/custom_models.py`); the JSON files in
  `custom_models/preferences/` document the same overlays in GraphHopper form.
* With LM, GraphHopper only accepts a request-time `distance_influence` at
  or above the profile's base (road 90, hybrid 80, gravel 70, mountain 60), and
  request-time priorities may only lower weights. The backend therefore sends
  `distance_influence: 100` for riders who want directness and omits it
  otherwise; quiet-road preference is expressed through priority.
* Enum values in custom models must exist in GraphHopper 10 (e.g. there is no
  `surface == MUD`); an unknown value stops the server at startup.

## How the backend uses the response

* `points.coordinates` (with elevation) → resampled every 100 m into
  `elevationSamples`; ascent/descent, highest point, max gradient, climbs
  (`app/routing/analysis.py`).
* `details.surface` → surface composition buckets (paved / gravel / trail).
* `details.road_class` + `details.bike_network` → cycleway fraction and
  traffic exposure (weighted by road class).
* `instructions` → turn-by-turn with GraphHopper `sign` mapped to
  `LEFT/RIGHT/...` (`SIGN_MAP`).

Route scoring weights live in `backend/app/routing/config/scoring.json`.
