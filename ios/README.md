# Roads & Runes — iPhone and Apple Watch

```
ios/
  project.yml                 XcodeGen spec (targets, plist, entitlements, SPM deps)
  Packages/RoadsAndRunesCore  pure Swift: models, API client, navigation logic,
                              exploration recorder, persistence formats, tests
  RoadsAndRunes/              iPhone app (SwiftUI, MVVM + services)
  RoadsAndRunesWatch/         watchOS app (navigation, quest, stats, workout)
  RoadsAndRunesTests/         app unit tests
```

## Design

The UI implements the Claude Design project in `../docs/design` ("Cycling
Companion"). Tokens live in `RoadsAndRunes/Components/Theme.swift`
(`Theme.Colors`, `Theme.Typography`, button styles, `ClassStyle`) and, for
the Watch, `WatchTheme` in `RoadsAndRunesWatch/App/ContentView.swift`.
Caprasimo (titles, quest and route names, primary buttons) and Figtree
(body, every number) are bundled in `RoadsAndRunes/Resources/Fonts` under the
SIL Open Font License and registered through `UIAppFonts` in `project.yml`.
`../docs/SCREENS.md` maps each screen to its design option.

## Generate the project

```bash
brew install xcodegen swiftlint
cd ios
xcodegen generate
open RoadsAndRunes.xcodeproj
```

Set your development team in Xcode (Signing & Capabilities) for both app
targets. Capabilities used: Sign in with Apple, HealthKit, App Groups
(`group.com.roadsandrunes.app`), background location.

## Pointing at a backend

`API_BASE_URL` is an Info.plist key fed from the build configuration
(`project.yml`). Debug defaults to `http://localhost:8000`; Release points at the
hosted development backend `https://roadsandrunes.fly.dev` (`infra/README.md`).
On a physical device pass whichever you want on the command line: your Mac's LAN
address (`API_BASE_URL=http://192.168.1.20:8000`) or the hosted URL.

Debug builds, and any non-HTTPS backend, offer "Developer sign in" (backend
`DEV_AUTH_ENABLED=true`) next to Sign in with Apple; a Release build against an
HTTPS backend offers Apple only.

### On an iPhone

`make ios-device` (set `DEVICE=` to your device id from `xcrun devicectl list devices`)
builds against the hosted backend and installs. Signing is automatic against team
`7WBQP62F6Z`, and `-allowProvisioningUpdates` lets Xcode register the App IDs
(`com.roadsandrunes.app`, `…app.watchkitapp`) with Sign in with Apple, HealthKit and the
App Group `group.com.roadsandrunes.app` the first time. Sign in with Apple on a native app
needs no Service ID or key — only the entitlement and a backend whose `APPLE_CLIENT_ID`
matches the bundle id (it does).

Do not pass `CODE_SIGN_ENTITLEMENTS` on the command line: it applies to *every* target,
including the test bundles, whose App IDs have no HealthKit, and the build then fails.

### Running against the local backend in the simulator

```bash
make up && make migrate && make seed && make api      # from the repo root
xcrun simctl location booted set 51.49,-0.04          # the seeded area (Rotherhithe)
```

Run the app, tap "Developer sign in" with subject `rider-1` and the World tab
shows the seeded quests and discoveries. `make seed` is safe to re-run when
quests run out. On the World, search or tap a place (long-press drops a pin)
and "Ride here" plans A → B routes; the terracotta button plans a ride from
here. Quests open on their fixed route (`GET /quests/{id}/route`), tweakable
in the planner. Place search uses MapKit (`MKLocalSearch`), so it needs no key.

### Mock data (no backend)

Launch with `RR_MOCK_API=1` in the environment (Scheme → Run → Arguments, or
`SIMCTL_CHILD_RR_MOCK_API=1 xcrun simctl launch ...`) to run on `MockAPI`
with the sample London data; previews use it automatically.

Map styles are Info.plist keys (`MAP_STYLE_*`) pointing at MapLibre style
JSON; the defaults use OpenFreeMap public styles. Replace them with your own
tile server before beta.

## Dependencies (SPM, resolved by Xcode)

* `RoadsAndRunesCore` (local)
* MapLibre Native iOS (`maplibre-gl-native-distribution`)
* `H3` (local package vendoring the uber/h3 v4.1.0 C library, since upstream has no SwiftPM manifest) — wrapped by `Services/Location/H3CellIndexing.swift`

## Tests

```bash
cd Packages/RoadsAndRunesCore && swift test      # no Xcode needed
xcodebuild -scheme RoadsAndRunes -destination 'platform=iOS Simulator,name=iPhone 17' test   # any installed iPhone simulator
xcodebuild -scheme RoadsAndRunesUITests -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test   # UI tests, needs `make api`
```

The UI tests (`RoadsAndRunesUITests`, `make ios-ui-test`) run against the local
API. Each signs in as a new developer rider (`RR_UI_TEST=1` clears the session
and turns Health off) and drives onboarding, quests (accept, the current
quest's Details and Continue, Begin quest into a ride and its end), place
search and a ride to the place, a custom adventure, and quests and routes in
Paris, outside the GraphHopper graph. Taps land off-centre on purpose: a
button that only answers on its label's glyphs fails them. CI does not run them.

## Status

Both app targets compile in CI (`xcodegen generate` + unsigned
`xcodebuild ... -destination 'generic/platform=iOS Simulator'`) and run on the
paired iPhone + Watch simulators against the local backend (dev sign-in,
seeded quests, route planning, ride start and recovery). The field tests
listed in `docs/PRODUCT_SPEC.md` §80 are still open.
