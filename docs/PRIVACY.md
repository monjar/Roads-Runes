# Privacy

Location privacy is a first-class system.

## Identity

Sign in with Apple only. The backend stores the Apple subject and an internal
UUID; email is optional and never a primary key.

## What is public

`GET /users/{id}` exposes display name, avatar, class, level, title, quest
and discovery counts, favourite terrain and recent adventures (title,
distance, new territory, XP). It never includes home location, ride start or
end points, live location or private routes. Ride geometry and points are only
readable by the owner.

## Ride visibility

`PRIVATE` (default) / `FRIENDS` / `PUBLIC`, set per ride and defaulted from
the user's settings. Feed events carry no coordinates. Home-area masking of
the first/last kilometre of shared rides is planned before public rides ship.

## Live location

No stranger location. Party members receive only what the shared quest needs;
exact location sharing requires mutual friendship and explicit opt-in and is
not implemented in MVP.

## User content

Notes, photos and custom discoveries stay private (`PUBLIC` is downgraded to
`PRIVATE` server-side) until moderation infrastructure exists. Custom
discoveries are `PENDING` moderation and visible only to their creator.

## Analytics

Product events only (`docs/PRODUCT_SPEC.md` §79). No precise location in
analytics; exploration metrics are aggregated counts.

## Data retention

Rides, points and cells persist for the account's life. Account deletion
(`deleted_at`) revokes tokens and is followed by a purge job (to add before
beta). Strava tokens are stored server-side, encrypted at rest by the database
provider, and deleted on disconnect.

## Permissions

Location "while using" for the map; "always" is requested only when starting
a ride, with an explanation. HealthKit is optional and the app works without
it. Motion and notifications are optional.
