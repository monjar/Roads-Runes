# Design source

The Claude Design export of *Cycling Companion*, the UI this app follows.

| File | What it is |
|---|---|
| `Cycling Companion.dc.html` | The design canvas: turn 0 (assumptions and system), turn 1 (plan, route comparison, route detail, navigation, elevation and surface, the 10-screen Watch MVP, haptics, product states 8a–8g) and turn 2 (the RPG direction: World 9a/9b, quest detail 10a/10b, class pick and character sheet 11a/11b, navigation with quest 12a/12b, adventure complete 13a/13b, journal 14a/14b, friends 15a/15b, Watch 16a). |
| `support.js` | The Claude Design runtime that renders the canvas. |
| `ios-frame.jsx` | The iPhone device frame component used by the canvas. |
| `thumbnail.webp` | Preview of the canvas. |

Open the `.dc.html` file in a browser next to `support.js`. The canvas links
Google Fonts, Leaflet map tiles and the design-system bundle
(`_ds/organic-…`) from the network, so it renders fully only online; the
layout, copy and inline styles are all in the file and readable offline.

## Options carried into the code

The design offers two or three options per screen. The app implements the
"prototype the loop" set the design proposes: **9a → 10a → 12a → 12b →
13b**, plus 11a/11b, 14a/14b, 15a/15b, 1a/2a/3a for planning, 4c/8a–8g
for states, and 7a/16a on the Watch. `docs/SCREENS.md` shows each screen
next to its option id.

## Tokens

The palette, type and radii are transcribed into
`ios/RoadsAndRunes/Components/Theme.swift` (iPhone) and
`ios/RoadsAndRunesWatch/App/ContentView.swift` (`WatchTheme`). The fonts
Caprasimo and Figtree are bundled under the SIL Open Font License in
`ios/RoadsAndRunes/Resources/Fonts`.
