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
(`project.yml`). Debug defaults to `http://localhost:8000`; on a physical
device replace it with your Mac's LAN address, e.g.
`API_BASE_URL=http://192.168.1.20:8000`. When the URL is not HTTPS the app
offers "Developer sign in" (backend `DEV_AUTH_ENABLED=true`) next to Sign in
with Apple.

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
xcodebuild -scheme RoadsAndRunes -destination 'platform=iOS Simulator,name=iPhone 15' test
```

## Status

Both app targets compile in CI (`xcodegen generate` + unsigned
`xcodebuild ... -destination 'generic/platform=iOS Simulator'`). They have
not been run on a simulator or device yet; the field tests listed in
`docs/PRODUCT_SPEC.md` §80 are still open.
