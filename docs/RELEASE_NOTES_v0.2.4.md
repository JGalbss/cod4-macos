# jgalbs cod4 0.2.4

This Apple Silicon release candidate fixes the visual and multiplayer
regressions found while testing the 0.2.3 DMG.

## Fixed

- Keeps normal gameplay, countdowns, and match outcomes at a clean full-color
  exposure while preserving the intentional green night-vision channel.
- Clears obsolete objective, prompt, killed-by, killcam, and streak overlays
  as the authoritative end-of-match presentation begins.
- Reads CoD4x protocol-21 player names and clan tags from the server's client
  records, restoring names on the Tab scoreboard and in player-name HUD text.
- Preserves the stock `F`/`+activate` killcam-skip path and adds a real
  two-client regression test for damage, death, skip, and respawn.
- Supports protocol-21 joins and bounded custom-map downloads while rejecting
  traversal and unsafe download paths.
- Restores native fullscreen/window behavior, graphics option values, text
  editing, server-browser joins, default Favorites, and custom-map loading
  assets addressed during this release cycle.
- Corrects several arm64 pointer-width and renderer state issues that could
  produce crashes, missing materials, invalid fallback images, or bad effect
  colors.

## Verified

- A real two-client score-limit match ends in full color with only the intended
  result, reason, team icons, and score visible.
- A real two-client combat cycle passes bullet damage, death, score, killcam
  entry/exit, `F` skip, respawn, and player-name substitution.
- A live protocol-21 server join reaches active gameplay and populates the
  client-name cache without parser errors or connection loss.
- A real stock airstrike spawns its cluster-bomb parents and more than ten
  visible impact explosion effects.

This DMG is ad-hoc signed for private testing. A public release still requires
Developer ID signing, Apple notarization, and stapling. Players must provide a
legally owned Call of Duty 4 data directory; retail game data is not bundled.
