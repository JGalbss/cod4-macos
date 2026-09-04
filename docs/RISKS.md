# Deferred risks and release limits

This file lists known limits of the native Apple Silicon client. It is not a
bootstrap plan: the multiplayer client, Metal renderer, OAT fastfile path,
Core Audio path, input, networking, and local server are linked and exercised.

## Release blockers

- The public DMG still needs final Apple Developer ID signing, notarization,
  stapling, Gatekeeper verification, and a clean-Mac install test.
- A production Sparkle update must be proven from an older signed build to the
  exact signed release bytes. Ad-hoc development builds intentionally do not
  poll a public feed.
- The final release needs corresponding source from the matching signed tag.
  Retail Call of Duty 4 data is never part of the source archive or DMG.

## Compatibility still to establish

- Search and Destroy/Sabotage objective pickup, plant, defuse, explosion,
  scoring, round transition, and killcam need an end-to-end two-client pass on
  the exact release artifact.
- Long public multiplayer sessions, more server configurations, every rank and
  challenge boundary, and multiple Apple Silicon generations are not yet a
  certified matrix.
- Script, IWD, fastfile, and asset mods can use the native `fs_game` path, but
  broad third-party compatibility is not guaranteed. OpenWarfare2 currently
  stalls during early renderer-zone startup. Windows-only native mod DLLs
  cannot load in an arm64 macOS process and require source ports.
- Visual and performance parity has broad automated coverage, not exhaustive
  review of every authored map, material, weapon, animation, and effect.

## Intentional technical boundaries

- Apple arm64 builds fail configuration when OpenAssetTools is unavailable.
  The excluded stock `db_load.cpp`/`db_stream_load.cpp` reader assumes x86
  layouts and low 32-bit addresses; it is not a fallback and must not be enabled
  on LP64. OAT translates the retail fastfile representation into native
  pointer-width objects.
- The database load runs synchronously in the current POSIX implementation.
  The OAT bridge now reports actual byte and registration progress and performs
  throttled loading-screen redraws, but a future worker implementation could
  improve responsiveness further.
- Dormant single-player-only and excluded recovered translation units may still
  contain Win32-size arithmetic. The active multiplayer source list is compiled
  with `-Wall -Werror` and has had a dedicated LP64 pointer/size audit; enabling
  new source files requires the same audit and runtime coverage.
- CoD4's original simulation and network tick behavior is distinct from render
  presentation rate. An uncapped renderer cannot make server-authoritative
  simulation update at the display FPS.

See [Validation](VALIDATION.md) for observed evidence and the precise claims we
do and do not make.
