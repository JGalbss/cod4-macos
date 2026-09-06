# jgalbs cod4 0.2.8

This Apple Silicon release candidate fixes intermittent rainbow coloring on the
first-person weapon and sleeves.

## Fixed

- Disables the missing-light-grid debug visualization by default.
- Uses the map's normal fallback lighting when the player moves outside authored
  light-grid coverage.
- Retains `r_showMissingLightGrid` as an explicit renderer diagnostic for
  developers.

This DMG is ad-hoc signed for private testing. A public release still requires
Developer ID signing, Apple notarization, and stapling. Players must provide a
legally owned Call of Duty 4 data directory; retail game data is not bundled.
