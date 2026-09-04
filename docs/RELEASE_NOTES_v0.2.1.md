# jgalbs cod4 0.2.1

This native Apple Silicon candidate focuses on custom-map compatibility,
browser reliability, and release-blocking rendering and LP64 correctness.

## Highlights

- Loads custom usermap IWDs before their fastfiles so authored loading screens,
  compass images, and other external assets are available during zone startup.
- Corrects mismatched custom IWI compression metadata by honoring the embedded
  IWI format and selecting the largest complete mip that can be uploaded.
- Provides safe custom-map team-model fallbacks when a map is not listed in the
  stock map table, while respecting authored urban, desert, and woodland teams.
- Treats absent optional custom vision and client-side FX files as optional
  instead of presenting a developer error overlay.
- Keeps saved Favorites visible even when the favorite server is empty, full,
  or reports a purity state hidden by Internet-browser filters.
- Fixes an active listen-server skeleton-memory alignment calculation that
  truncated a 64-bit pointer on arm64.
- Implements the CoD4x protocol-21 binary download path with bounded parsing,
  traversal-safe paths, checksummed range transfers, atomic installation, and
  protocol-6 browser joins for servers that advertise the legacy wire format.
- Fixes the arm64 `FS_SV_Rename` cross-array pointer arithmetic that prevented
  a verified custom-map download from being installed after transfer.
- Restores Metal film, glow, and depth-of-field view state without requiring the
  legacy D3D FLOAT_Z target; night vision now renders its authored green grade.
- Keeps normal multiplayer gameplay at the clean full-color countdown exposure
  instead of switching to the crushed, desaturated 2007 per-map film grade.
- Implements the missing flipped-ST UI command used by directional action-slot
  art and supplies a neutral pause-map overlay for custom maps absent from the
  stock map table.

## Validation scope

The exact raw arm64 executable SHA-256
`6b88b4ab056c4befd14d8327a658c8a565d22836dae46fdba581bad90fe8e306`
passed a five-map 600-frame stock fuzz run, clean Rust and Terminal gameplay,
the two-client bullet/death/score/killcam/respawn cycle, a stable full-color
countdown-to-gameplay transition, and both direct and stock night-vision input.
A separate clean-home live CoD4x test negotiated protocol 21, declined an HTTP
redirect, downloaded the 1,355,335-byte Highrise IWD with CRC verification,
installed it atomically, and advanced to the next file. The focused LP64 audit
also removed an active cross-array rename calculation in the download install
path.

See `docs/VALIDATION.md` for evidence paths and the distinction between tested
behavior and broader compatibility claims.

## Requirements and release status

- Apple Silicon and macOS 15.5 or newer.
- A legally owned compatible Call of Duty 4 installation is required; retail
  maps, textures, sounds, and other Activision data are not bundled.
- Windows-only mod DLLs cannot load in an arm64 macOS process.
- Third-party Rust and Terminal packages used in testing omit a small number of
  referenced texture payloads; the client reports those package defects rather
  than fabricating renderer data.
- Local DMGs are ad-hoc signed. A public binary still requires Developer ID
  signing, Apple notarization, stapling, Gatekeeper verification on a clean Mac,
  and an old-to-new Sparkle update test.
