# Quest system

## Objects

* **Template** (`backend/app/quests/config/templates.json`) – class, type,
  minimum class level, weight, objective rules and objective specs, narrative
  variants. 13 Explorer templates plus one each for Wizard/Warrior/Scribe.
* **QuestInstance** – a template instantiated for one user at one origin, with
  concrete objectives, difficulty, XP, expiry (14 days) and a status.
* **QuestObjective** – typed objective with location/radius, target metres,
  target cells, target elevation, progress and `provisional` flag.
* **StoryArc / StoryQuest** – authored chains (schema present, flag-gated,
  loaded from JSON under `app/quests/story/` in a later phase).

## State machine

```
AVAILABLE → ACCEPTED → ACTIVE → COMPLETED
    │           │         ├──→ ABANDONED
    │           ├──→ ABANDONED
    ├──→ EXPIRED (also from ACCEPTED)
    └──────────────────── ACTIVE → FAILED
```

`assert_transition` raises `QUEST_INVALID_TRANSITION` (HTTP 409) for anything
else. AVAILABLE → COMPLETED is impossible outside `admin_override`.

Starting a quest demotes any other ACTIVE quest to ACCEPTED: one active quest
keeps navigation and the Watch screen unambiguous.

## Generation

Inputs (`GenerationContext`): origin, class and levels, rider profile
(comfortable distance/elevation, gravel comfort), bike capabilities, explored
and visited H3 cells, recently completed templates, nearby POIs (radius grows
with the Trail Sense ability), unlocked templates from abilities, seed.

Stage 1 (`generator.py`, deterministic):

1. Filter templates by class, level and ability unlocks; weight by template
   weight, down-weight recently completed templates.
2. For each pick, `instantiate()` resolves rules:
   * `distanceKm` / `newTerritoryKm` / `elevationMeters` ranges scaled by
     the rider's comfortable distance (0.5×–2×);
   * `poiCategory` (+ `poiTagAny`, `requireUnexplored`, `requiresGravel`) →
     choose a POI in the distance band; missing POI → template skipped;
   * `regionCount` → unexplored cells at random bearings/distances, or
     frontier cells (unexplored cells bordering explored ones) when
     `frontier` is set.
3. Objectives get coordinates (POI, cell centre with a 250 m radius, or the
   origin for RETURN_TO_START) and targets.
4. Difficulty = distance vs comfortable distance (EASY < 0.7×, MODERATE
   < 1.15×, HARD < 1.7×, else EPIC), nudged by elevation. Base XP comes from
   `xp_rules.json` `questBase[difficulty]`.
5. A second pass re-rolls region templates with new seeds if sparse POI data
   left fewer than the requested count.

Stage 2 (`narrative.py`): if `llm_narrative` is on, Claude rewrites title,
hook and completion text from the facts. Objectives and coordinates are never
touched. Any failure falls back to the template narrative.

After persisting, target cells/POIs are marked `DISCOVERED` on the user's map
so the fog shows where to go.

## Progress and completion

* The client reports objective events (`POST /quests/{id}/progress`) as it
  observes them; the server marks them `provisional`.
* Post-ride processing re-evaluates every objective from the validated trace:
  visit objectives need a point within 1.25× radius (or a target cell in the
  trace), distance/elevation/new-roads objectives compare against computed
  metrics, RETURN_TO_START needs the last point near the first after ≥ 1 km,
  photo/note objectives require a client event at the location.
* Provisional completions the trace does not support are reverted.
* When all required objectives are complete the quest becomes COMPLETED and
  the reward service grants XP (`QUEST_COMPLETED` with difficulty modifier,
  objective XP, exploration, discoveries, class bonus, capped per ride).
* `POST /quests/{id}/complete` is an explicit path for the client after
  processing; it refuses while the ride is still processing.

## Safety rules

Objectives never require interaction while moving. Photo/note objectives carry
`extra.safety = "Stop safely before completing this objective."` and the
client only enables them when stationary. POIs must be `cycling_accessible`.
Regions are cell centres with a generous radius so the rider never has to hit
an exact point.

## Adding a template

Add an entry to `templates.json` with an existing objective type set; unit
tests assert every objective type is known. Keep `minLevel` honest and add a
narrative variant or two. If the template needs new rules, extend
`instantiate()` and the post-ride `evaluate_objectives()` together.
