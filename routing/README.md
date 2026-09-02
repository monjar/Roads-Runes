# Routing (GraphHopper + OpenStreetMap)

`config.yml` configures a GraphHopper 9/10 instance with four bike profiles
built from the custom models in `custom_models/`:

| profile | bike types | character |
|---|---|---|
| `road` | ROAD | blocks unpaved, strong cycleway preference |
| `gravel` | GRAVEL | boosts gravel/compacted tracks, penalises mud/sand |
| `mountain` | MOUNTAIN | tracks, bridleways and paths with `mtb_rating <= 2` |
| `hybrid` | HYBRID, FOLDING, OTHER | quiet roads and cycleways, light unpaved penalty |

All base models multiply `motorway`/`trunk` by 0 and honour `bike_access`, so
request-time preference overlays can only tighten routing, never re-enable
unsafe roads (spec §75).

## Importing a region

```bash
infra/scripts/download-osm.sh europe/great-britain/england/greater-london
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
  "custom_model": { "priority": [...], "speed": [...], "distance_influence": 70 },
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
