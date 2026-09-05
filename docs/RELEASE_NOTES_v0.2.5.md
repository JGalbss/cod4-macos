# jgalbs cod4 0.2.5

This Apple Silicon release candidate supersedes 0.2.4, which allowed a remote
server script to replace the active map vision with developer film settings.

## Fixed

- Prevents servers from enabling `r_filmUseTweaks` or changing the associated
  `r_filmTweak*` developer controls.
- Keeps the map's authored full-color vision active after spawn while retaining
  local developer controls and the intentional night-vision effect.
- Prevents remote film settings from leaking into the player's saved renderer
  preferences.

## Verified

- The live jgalbs protocol-21 server attempted all eight film overrides that
  previously made the picture monochrome; the client rejected each one.
- A post-spawn frame retained neutral saturation and tint after the server's
  override commands.
- The same run reached active multiplayer, received snapshots, and exited
  without a parser error, connection loss, assertion, or crash.

This DMG is ad-hoc signed for private testing. A public release still requires
Developer ID signing, Apple notarization, and stapling. Players must provide a
legally owned Call of Duty 4 data directory; retail game data is not bundled.
