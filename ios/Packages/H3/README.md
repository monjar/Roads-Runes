# H3 (vendored)

uber/h3 v4.1.0 C library packaged as a SwiftPM C target so the app can
`import H3`. Upstream has no `Package.swift`. To update: copy
`src/h3lib/lib/*.c` and `src/h3lib/include/*.h` from the upstream tag into
`Sources/H3/`, regenerate `Sources/H3/include/h3api.h` from `h3api.h.in`
by substituting the version macros, and update this note. Licence: Apache 2.0
(see LICENSE).
