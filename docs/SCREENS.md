# Screens

The images below are design renders of the app screens as specified
(`PRODUCT_SPEC.md` §4, §33, §40–48), produced from HTML/CSS with the app's
theme tokens (`ios/RoadsAndRunes/Components/Theme.swift`). They are not
device captures: no Xcode or simulator was available when this repository
was assembled. Regenerate with `node docs/screenshots/render.js`; replace
them with real simulator screenshots once the app builds.

## iPhone

| Onboarding · class | World · fog of war | Quests |
|---|---|---|
| ![Choose class](screenshots/01-onboarding-class.png) | ![World map](screenshots/02-world.png) | ![Quests](screenshots/03-quests.png) |
| Explorer only in MVP; other classes are visible but locked behind feature flags. | Default tab. H3 fog, explored cells outlined, quest markers, discoveries, nearby-quest sheet. | Active quest with progress, nearby and recommended quests, difficulty chips. |

| Quest detail | Route alternatives | Navigation |
|---|---|---|
| ![Quest detail](screenshots/04-quest-detail.png) | ![Routes](screenshots/05-routes.png) | ![Navigation](screenshots/06-navigation.png) |
| Objectives (required / optional), rewards, accept and plan route. | Three labelled options (never "Route 1/2/3"): elevation, distance, time, climb, new territory, cycleways, traffic, surface bar, POIs with position and detour. | Full-screen mode: next turn, distance, street; map; quest objective; secondary metrics; pause / end. No XP animations while moving. |

| Adventure complete | Journal | Character |
|---|---|---|
| ![Adventure complete](screenshots/07-adventure-complete.png) | ![Journal](screenshots/08-journal.png) | ![Character](screenshots/09-character.png) |
| Adventure progress first, XP breakdown, cycling stats last (§40). | Adventures with route thumbnails, exploration-first statistics (§41–42). | Overall and class XP bars, abilities with unlock, bikes and rider profile. |

## Apple Watch

| Navigation (§44) | Quest (§45) | Stats (§46) | Objective complete (§47) | Always-On (§48) |
|---|---|---|---|---|
| ![Watch navigation](screenshots/w1-watch-navigation.png) | ![Watch quest](screenshots/w2-watch-quest.png) | ![Watch stats](screenshots/w3-watch-stats.png) | ![Watch objective](screenshots/w4-watch-objective-complete.png) | ![Watch always-on](screenshots/w5-watch-always-on.png) |
