# jgalbs cod4 0.2.2

This native Apple Silicon candidate fixes four regressions found during live
multiplayer testing.

## Highlights

- Normal gameplay no longer enters the green night-vision grade unless the
  player actually toggles NVG. Turning NVG off restores the neutral authored
  color grade.
- Window and door brush surfaces no longer expose CoD4's red/yellow `Shadow`
  tool texture. Metal now submits the same base-world camera range as the
  original renderer and draws movable brush models in their dedicated pass.
- Live CoD4x protocol-21 client updates are parsed and acknowledged, preventing
  the packet loop that caused `Connection Interrupted` after joining a server.
- Native macOS full-screen mode works through the green window control and the
  in-game `r_fullscreen` setting. Fresh profiles default to full screen.

## Validation scope

The exact raw arm64 executable SHA-256
`de12fc7296197e0e03f1cdcf8601e079f3c76f717d70b77dce6fd69254cdf9bb`
passed neutral-color, NVG-on, and NVG-off frame captures; a live two-client
protocol-21 join that acknowledged a client-config update; the complete
two-client bullet/death/score/killcam/respawn test; five deterministic stock-map
fuzz cases; and a native macOS full-screen state check.

See `docs/VALIDATION.md` for artifact paths and the limits of these claims.

The verified local DMG SHA-256 is
`4cd7ddd387d59312ddcd396b130d65ea02de6ee73a8e7fc4da756969ba5e41c4`.
Its packaged executable SHA-256 is
`2b6b6c6b375a16c0f715cb6d36323161519072a9652b67dcd815729ef9fb6aa6`.
The package embeds corresponding source revision
`b1012a8238cb79a3d3db334f2292626dbff59e72`.

## Requirements and release status

- Apple Silicon and macOS 15.5 or newer.
- A legally owned compatible Call of Duty 4 installation is required. Retail
  maps, textures, sounds, and other Activision data are not bundled.
- Windows-only mod DLLs cannot load in an arm64 macOS process.
- This local DMG is ad-hoc signed. Public distribution still requires the
  owner's Developer ID signature, Apple notarization, stapling, Gatekeeper
  verification, and a signed Sparkle update test.
