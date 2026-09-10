# RoadsAndRunesCore

Platform-independent Swift package shared by the Roads & Runes iPhone app
(`ios/RoadsAndRunes`) and the watchOS app (`ios/RoadsAndRunesWatch`). It
contains everything that does not need UIKit, SwiftUI, CoreLocation, HealthKit
or MapLibre, so it builds and tests on macOS and Linux CI with plain `swift test`.

## What is inside

| Directory | Contents |
| --- | --- |
| `Models/` | `Codable` structs mirroring `docs/API.md` field-for-field (camelCase, UUID ids, `Date` timestamps, metres/seconds). String enums adopt `SafeEnum`, so unknown server values decode as `.unknown` instead of failing. `JSONValue` covers loosely typed fields (`extra`, `payload`, `details`). `JSONCoding` provides the shared ISO 8601 coder (fractional seconds optional). |
| `API/` | `RoadsAndRunesAPI` protocol (one method per endpoint), `Endpoints` builders, `APIClient` (URLSession actor: bearer injection, single refresh-and-retry on 401, error envelope mapping, `nil` on 202 for ride summaries), `TokenStore`, and `MockAPI` + `SampleData` for previews and tests. |
| `Navigation/` | `NavigationStateMachine`, `GeoMath` (haversine, bearing, destination, segment projection), `Polyline` (Google polyline5), `RouteProgressTracker` (map matching with search window + off-route hysteresis), `ObjectiveTracker` (client-side objective completion), `RideStatistics` (distance / moving time / elevation with noise filtering), `BatteryPolicy`, `RerouteAdvisor`. |
| `Exploration/` | `CellIndexing` protocol (the app injects an H3 implementation), `ExplorationRecorder` (cells entered, distance per cell, upload batching, new-territory metres), `FogGrid` (merges server + local cell state into renderable polygons). |
| `Persistence/` | `RoutePackageStore` / `FileRoutePackageStore` for offline route packages and `ActiveRideState` / `FileActiveRideStore` for crash recovery (Resume / Finish / Discard). |
| `Analytics/` | `AnalyticsEvent` names from the product spec, `AnalyticsSink`, `NoopAnalytics`. |
| `Formatting/` | `UnitFormatter`: metres, seconds and m/s to metric or imperial strings. |

Design rules:

- No CoreLocation / UIKit / MapLibre types in public API. Positions are
  `Coordinate { latitude, longitude }`; GPS samples are `LocationFix`.
- Everything is a value type or a `final class` with documented isolation.
  `APIClient` is an actor; `ExplorationRecorder` is deliberately not thread safe
  and must be driven from one queue/actor by its owner.
- No third-party dependencies. H3 is injected through `CellIndexing`.
- The server is authoritative for XP, levels and quest completion. Client
  trackers only produce *provisional* objective events that the backend
  re-validates in post-processing.

## How the apps use it

**iPhone app**

```swift
import RoadsAndRunesCore

let api = APIClient(baseURL: URL(string: "https://api.roadsandrunes.example")!, tokenStore: KeychainTokenStore())
let world = try await api.world(center: here, radiusMeters: 5000)

var tracker = RouteProgressTracker(route: package.route)
var objectives = ObjectiveTracker(objectives: package.quest?.objectives ?? [], start: here)
var stats = RideStatistics()
let recorder = ExplorationRecorder(indexing: H3CellIndexing(), knownCells: knownCells)

// On every CLLocation:
let fix = LocationFix(coordinate: ..., timestamp: ..., altitude: ..., horizontalAccuracy: ..., speed: ...)
stats.add(fix: fix)
let progress = tracker.update(position: fix.coordinate)
recorder.record(fix: fix)
let events = objectives.update(position: fix.coordinate, distanceMeters: stats.distanceMeters,
                               elevationGainMeters: stats.elevationGainMeters,
                               newTerritoryMeters: recorder.newTerritoryMeters, timestamp: fix.timestamp)
if let batch = recorder.takePendingBatch(now: fix.timestamp) { /* POST /rides/{id}/exploration */ }
try activeRideStore.save(ActiveRideState(...))   // for crash recovery
```

`RouteProgressTracker`, `ObjectiveTracker` and `RideStatistics` are structs so
the ride service can snapshot them into `ActiveRideState` at any time. SwiftUI
previews use `MockAPI()` and `SampleData.*`.

**Watch app** uses the same models for `WatchConnectivity` payloads (`RideSnapshot`,
`ProgressUpdate`, `Instruction`, `Objective`), `UnitFormatter` for display, and
`BatteryPolicy.watchUpdateInterval` to pace updates.

## Running the tests

The package has no network or platform dependencies:

```sh
cd ios/Packages/RoadsAndRunesCore
swift test
```

On macOS you can also open the package in Xcode and run the `RoadsAndRunesCoreTests`
scheme. The tests cover model decoding of the JSON samples in `docs/API.md`,
the navigation state machine, polyline round trips, route matching on a
synthetic loop, objective detection, ride statistics, exploration batching,
formatting, persistence round trips, and the mock API's quest/ride flows.

## Conventions when adding endpoints

1. Add or update the model in `Models/` (keep property names identical to the JSON).
2. Add a builder to `Endpoints`, a requirement to `RoadsAndRunesAPI`, and the
   implementations in `APIClient` and `MockAPI`.
3. Add a decoding test using the sample from `docs/API.md`.
