# Exploration and fog of war

## Grid

H3 at resolution 9 (`H3_RESOLUTION`, 6–11 allowed). Each user has rows in
`user_exploration_cells` only for cells that are not UNSEEN.

| state | meaning | set by |
|---|---|---|
| UNSEEN | never entered; drawn as fog | absence of a row |
| DISCOVERED | revealed by a quest target or ability, not visited | quest generation, abilities |
| VISITED | rider passed through | post-ride processing |
| EXPLORED | ≥ `EXPLORED_DISTANCE_THRESHOLD_METERS` (400 m) ridden inside the cell, cumulative | post-ride processing |

States only move upward (`merge_state`).

## Recording during a ride (client)

1. Each accepted GPS fix is mapped to a cell (`CellIndexing`, backed by the
   uber/h3 C library on device).
2. `ExplorationRecorder` dedupes cells, accumulates distance per cell, and
   batches new cells for upload every 50 cells or 60 s. No network call per
   cell.
3. The fog overlay updates immediately from local state so the map visibly
   clears while riding.
4. Batches go to `POST /rides/{id}/exploration`; anything unsent is included
   in `POST /rides/{id}/complete`.

## Validation (server)

`process_ride` derives the authoritative cell set from the validated trace
(`cells.traverse`): distance is attributed to the cell of each segment's start
point and gaps between non-adjacent cells are bridged with `grid_path_cells`
so a short GPS outage does not leave holes. Client cells are accepted only if
they, or a neighbour, appear in the trace (`reconcile_client_cells`); the rest
are rejected and the ride flagged `REJECTED_CLIENT_CELLS`.

Anti-cheat (`rides/validation.py`) flags impossible speeds (> 25 m/s
sustained), teleports (> 500 m in < 10 s), malformed or inaccurate points,
client/server distance mismatch, and implausible cell counts per km.
Suspicious rides are stored as FLAGGED and earn no exploration or XP. Nobody is
banned automatically.

## Rewards

Per `xp_rules.json`: 12 XP per new cell (+6 if EXPLORED on first visit),
20 XP per km of new roads, Explorer class bonus 25% on both, capped at 400 new
cells per ride. New territory in km/roads km appears in the journal and
`GET /world/exploration/stats`.

## Map queries

* `GET /world` – cells within a radius (computed as an H3 disk), discoveries,
  quest markers, feature flags.
* `GET /world/exploration` – cells in a bounding box for map panning.
* `GET /world/exploration/stats` – exploration-first statistics; speed stats
  are present but secondary.

## Regions

"Regions visited" counts distinct parent cells three resolutions up
(resolution 6, ~36 km²), a neighbourhood-scale unit for region completion
rewards in a later phase.
