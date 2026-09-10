# Roads & Runes — Product, Architecture and Implementation Specification

Platforms: iPhone + Apple Watch. Language: Swift. Backend: Python/FastAPI.
Database: PostgreSQL + PostGIS. Routing: GraphHopper + OpenStreetMap.
Maps: MapLibre (iPhone), MapKit where appropriate (Watch). Health: HealthKit.
Auth: Sign in with Apple.

Primary objective: encourage real-world exploration by bicycle through RPG
progression, quests, discovery and social interaction.

## 1. Product definition

A real-world cycling exploration RPG. Physical location is the player's
position in the game world; cycling is the movement mechanic.

Loop: create character → choose class → see nearby quests / unexplored areas →
select adventure → receive route → navigate (iPhone + Watch) → complete
objectives → discover locations and territory → earn XP → level → unlock
abilities → meet friends → explore further.

Not a training or racing app. Do not optimise for fastest rides, PRs,
segments, speed, watts, competitive leaderboards. Optimise for new territory,
exploration, quests, discoveries, story, adventure, cooperation.

## 2. Philosophy

Central question: does this feature give the user a reason to get on their
bike and go somewhere interesting? Exploration is rewarded more than
repetition. A slow 25 km through new territory beats a fast repeated loop.
Cycling stats stay available but never dominate.

## 3. Core loop

OPEN APP → VIEW WORLD → DISCOVER QUEST / UNEXPLORED AREA → SELECT ADVENTURE →
CUSTOMISE ROUTE → DOWNLOAD ROUTE → START RIDE → NAVIGATE → COMPLETE OBJECTIVES →
DISCOVER TERRITORY → FINISH → XP + ITEMS + QUEST PROGRESS → LEVELS / ABILITIES →
NEW QUESTS / REGIONS → REPEAT. Must work before social/monetisation.

## 4. App sections (iPhone)

- **World** (default): map, player position, fog of war, explored territory,
  quest markers, discoveries, nearby adventures, selected friends, current route.
- **Quests**: active, nearby, recommended, class, story, party, completed.
- **Journal**: adventures, ride history, discoveries, explored areas, stats,
  photos/notes, route history.
- **Character**: class, overall level, class level, XP, abilities, items,
  titles, bike profiles, friends, settings, integrations.

Active navigation is a temporary full-screen mode, not a tab.

## 5–9. Classes

Wizard, Explorer, Warrior, Scribe. MVP implements Explorer only; architecture
supports all from the start.

- **Explorer**: new roads, neighbourhoods, trails, parks, viewpoints,
  connecting regions. Abilities: Trail Sense, Cartographer, Pathfinder, Far Wanderer.
- **Wizard**: landmarks, strange architecture, ancient sites, puzzle chains,
  hidden destinations. Abilities: Arcane Sight, Foresight, Ley Finder, Second Chance.
- **Warrior**: climbing, distance, terrain, endurance, hilltops, multi-stage.
  Abilities: Second Wind, Mountainborn, Endurance, Vanguard.
- **Scribe**: photograph, notes, document trails, community knowledge.
  Abilities: Archivist, Rumour, Chronicler, Historian.

Abilities affect game systems only; never navigation or safety.

## 10–13. Progression

Two values: `overall_level`, `class_level`. Initial range 1–50; do not
hard-code 50. Level thresholds in backend config. XP originates from events
via a backend reward service; never from UI code. Event types:
QUEST_COMPLETED, QUEST_OBJECTIVE_COMPLETED, NEW_AREA_EXPLORED,
NEW_ROAD_EXPLORED, DISCOVERY_FOUND, LONG_DISTANCE_ADVENTURE, CLIMB_COMPLETED,
SOCIAL_QUEST_COMPLETED, STORY_QUEST_COMPLETED, CLASS_BONUS, REGION_COMPLETED.
Speed is never an XP source.

Total XP = quest base + exploration + discovery + class bonus + difficulty
modifier + social bonus, capped. All authoritative XP server-side.

Abilities: `{id, class, name, description, requiredClassLevel, maxRank}`.
They modify quest generation, discovery visibility, rewards, map information,
route options — not physical route safety.

## 14–16. Exploration

H3 grid. Cell states UNSEEN / DISCOVERED / VISITED / EXPLORED. During rides:
sample GPS → H3 cell → detect new cells → batch locally → server validates
after ride → store → XP. No network request per cell. Basic anti-cheat only:
impossible speeds, teleport jumps, malformed GPS, impossible routes,
unrealistic discovery counts, duplicate uploads. Flag, don't ban.

## 17–22. Quests

Quest `{id, type, class, title, description, difficulty,
recommendedDistanceKm, estimatedDurationMinutes, baseXP, status, expiresAt,
storyQuestId}` with objectives (VISIT_LOCATION, VISIT_REGION,
EXPLORE_DISTANCE, EXPLORE_NEW_ROADS, REACH_ELEVATION, COMPLETE_DISTANCE,
COMPLETE_CLIMB, VISIT_POI, PHOTO_LOCATION, WRITE_NOTE,
VISIT_MULTIPLE_LOCATIONS, RETURN_TO_START, COMPLETE_WITH_FRIEND,
COMPLETE_ROUTE).

State machine: AVAILABLE → ACCEPTED → ACTIVE → COMPLETED, plus ABANDONED,
FAILED, EXPIRED. Never AVAILABLE → COMPLETED outside admin/debug.

Generator inputs: location, class, levels, bike, preferred distance,
elevation comfort, surface preference, explored cells, completed quests,
POIs, cycling network, daylight, optional user request. Two stages:
deterministic geographic generation, then optional LLM narrative (names,
descriptions, flavour, lore). LLM never determines route safety.

Templates server-side, ~10–15 Explorer templates for first playable. Story
quests are authored chains (StoryArc, StoryQuest, Prerequisite) defined in
JSON/YAML initially.

## 23–24. Discoveries

Categories NATURE, HISTORICAL, CULTURAL, FOOD, PUB, CAFE, VIEWPOINT, CYCLING,
LANDMARK, TRAIL, CUSTOM. Users save notes, photos, rating, tags. No public
UGC without moderation.

## 25–32. Routing

GraphHopper + OSM with custom bike profiles. Bike types ROAD, GRAVEL,
MOUNTAIN, HYBRID, FOLDING, OTHER; bike affects routing not level. ~3 distinct
alternatives labelled Relaxed / Adventure / Scenic / Direct / Gravel /
Challenge, each with distance, duration, elevation gain, max gradient,
surface, cycleway %, traffic exposure, new territory %, objective coverage,
POIs. Route scoring service with configurable weights:
`score = preferenceFit + questFit + explorationPotential + POIValue +
scenicValue − trafficPenalty − difficultyPenalty − surfaceMismatchPenalty`.
Elevation samples stored per route; compute ascent, descent, highest point,
longest climb, max gradient, average climb gradient, significant climbs.
Separate rider difficulty profile (not the RPG character); never auto-raised
by level. Natural-language requests → LLM → structured preferences → routing
engine; LLM coordinates never go straight to navigation. POIs searched in a
route corridor with route position, detour distance/time, ETA, relevance.

## 33–40. Navigation and rides

Safety-first UI: next turn, distance, road name, map, objective, status.
Secondary: distance, time, speed, elevation, HR. No large XP animations while
moving. Navigation states PREPARING, READY, ACTIVE, PAUSED, OFF_ROUTE,
REROUTING, FINISHING, COMPLETED, CANCELLED, RECOVERY; persisted regularly.
Off-route: detect → OFF_ROUTE → rejoin → optional reroute → update
feasibility → ACTIVE; objectives, not polyline adherence, complete quests.
Tracking via CoreLocation + HealthKit, local session, sync after. Ride model
with geometry stored separately. HealthKit optional, never mandatory. Strava
optional (auto / ask / never; default never). Completion screen leads with
adventure progress.

## 41–48. Journal and Watch

Journal: Adventures, Discoveries, World, Statistics; exploration stats
primary, speed secondary. Separate watchOS target: turn navigation, route
map, objective, stats, objective notifications, pause/end, HR workout; works
with phone locked. Screens: navigation (arrow, distance, direction, street),
quest (title, objective, distance), stats (distance, duration, elevation,
HR), objective complete (haptic, auto-return). Always-On layouts simplified.

## 49–52. Battery, offline, map modes

Battery modes FULL / BALANCED (default) / ENDURANCE; navigation accuracy
never below safe level. RoutePackage stored locally (geometry, turns,
elevation, objectives, POIs, surface, map region). Map styles MINIMAL,
CYCLING, ADVENTURE, DETAILED.

## 53–60. Social and privacy

Profiles, friend requests (NONE, REQUEST_SENT, REQUEST_RECEIVED, FRIENDS,
BLOCKED), friends, activity visibility, quest invitations, parties (FORMING,
READY, ACTIVE, COMPLETED, CANCELLED; INDIVIDUAL / GROUP objective rules).
No stranger live-location. Small feed without performance comparison. Ride
visibility PRIVATE (default) / FRIENDS / PUBLIC; home masking later; never
expose precise current location publicly.

## 61–68. Backend

Sign in with Apple; identity = internal UUID + Apple subject. Modular
monolith: FastAPI, PostgreSQL, PostGIS, Redis, GraphHopper, object storage.
Modules: auth, users, characters, progression, quests, routing, exploration,
rides, discoveries, social, parties, integrations, notifications. PostGIS for
spatial queries; Redis for caching, rate limiting, party state, job queues.
Background jobs for post-ride work. API `/api/v1`, UUIDs, versioned,
consistent errors, pagination, ISO 8601, metres.

## 69–72. iOS

Swift, SwiftUI, async/await, CoreLocation, HealthKit, WatchConnectivity,
MapLibre. MVVM + service layer. Modules: App, World, Quests, Navigation,
Rides, Character, Journal, Social, Networking, Persistence, Location, Health,
Maps, Watch. SwiftData/SQLite local store; local-first ride recording; crash
recovery (Resume / Finish / Discard).

## 73–84. Cross-cutting

Notifications (few). Location permissions contextual. Safety constraints in
quest generator (no motorways, prohibited areas, private property, unsafe
classes, invalid trails). No interaction demands while moving. Reusable
design-system components (QuestCard, RouteCard, CharacterHeader, XPBar,
DiscoveryCard, RideMetric, ObjectiveRow, MapMarker, FogOverlay, POIMarker,
AdventureSummary, AbilityCard, FriendCard, PartyCard). Structured logging,
product analytics, test strategy (unit, integration, UI, field), three
environments, admin scripts, feature flags (wizard_class, warrior_class,
scribe_class, party_quests, fog_of_war, story_quests, strava). No
monetisation in MVP; never sell XP, levels, safety or navigation.

## 85–96. Phases

0 repo setup · 1 exploration prototype · 2 Explorer RPG · 3 routing ·
4 navigation · 5 Watch · 6 remaining classes · 7 social · 8 integrations ·
9 living world. MVP cut line: iPhone, Explorer, world map, fog, quest
generation, 10–15 templates, XP/levels, abilities, routes, elevation,
surface, navigation, ride recording, journal, HealthKit, basic Watch.

First playable journey: install → Sign in with Apple → character → Explorer →
gravel bike → world map → fog → three quests → "Beyond the River" → three
routes → Adventure → download → ride → fog clears → objective completes →
haptic → return → ride completes → server validates → XP → level up →
ability → journal → permanent explored territory.

## 97–100. Layout, standards, docs, success

Repository: `backend/app/{api,auth,users,characters,progression,quests,routing,
exploration,rides,discoveries,social,integrations,db,jobs,core}`,
`ios/RoadsAndRunes/{App,Features/*,Services/*,Models,Components}`,
`ios/RoadsAndRunesWatch/{Navigation,Quest,Ride,Workout,Connectivity}`.
Prefer small modules, explicit domain models, async/await, DI, typed
contracts, server-authoritative rewards, local-first rides. Avoid massive
view models, global mutable state, logic in Views, scattered SQL, hard-coded
XP or quest rules, LLM control of routes, network-dependent recording.
Docs: README, ARCHITECTURE, API, QUEST_SYSTEM, ROUTING, EXPLORATION, WATCH,
PRIVACY.

Success: users open the app because it gives them a reason to ride. "There's
a quest over there, and I've never ridden through that area."
