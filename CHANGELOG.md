# Changelog

This file tracks notable changes to the native Apple Silicon macOS client.
The project uses semantic versioning while the port is under active development.

## Unreleased

No user-facing changes yet.

## 0.2.9 release candidate - 2026-09-06

### Fixed

- Restored the configured expiry time for level-up, kill-streak, and other
  `iPrintLn`/`iPrintLnBold` notifications instead of misreading the message
  window's integer line-count setting as a floating-point duration.
- Made smoke visibility blockers occupy the same zero-based slots consumed by
  friendly-name and aim-assist visibility checks, so gameplay overlays and
  targeting no longer remain active through the first smoke cloud.
- Repaired the leaked `NativeInputCheck` diagnostic player name back to the
  active profile name without changing legitimate custom multiplayer names.

## 0.2.8 release candidate - 2026-09-05

### Fixed

- Disabled the renderer's missing-light-grid visualization in normal builds.
  First-person weapons and sleeves now use the map's fallback lighting outside
  authored light-grid coverage instead of flashing rainbow debug colors.

## 0.2.7 release candidate - 2026-09-05

### Fixed

- Made the active-play connection warning use a fixed two-second command-stall
  threshold instead of the legacy 128-command history. At 120+ FPS the old
  history covered roughly one second and treated normal Internet jitter as a
  connection interruption.
- Kept genuine stalls visible and left the engine's authoritative network
  timeout handling unchanged.

## 0.2.6 release candidate - 2026-09-05

### Fixed

- Prevented the client from showing a false `Connection Interrupted` warning
  while a healthy server is presenting the final scoreboard or map vote.

### Verified

- Real local multiplayer holds the display's 120 Hz presentation rate with the
  existing 250 FPS cap, clean normal-frame pacing, and CPU/GPU headroom.
- A timed match completed through the real outcome and intermission sequence
  without displaying the disconnect warning.

## 0.2.2 release candidate - 2026-09-04

### Changed

- New Apple Silicon profiles start in native macOS full-screen mode, while the
  archived graphics option stays synchronized with the macOS full-screen Space.
- Deterministic combat and fuzz harnesses explicitly remain windowed so the new
  user-facing default cannot hide or throttle parallel test clients.

### Fixed

- Prevented transient weapon animation states from enabling night vision unless
  the authoritative NVG flag is set, eliminating surprise neon-green gameplay.
- Stopped the Metal base-world pass from drawing shadow-only brush faces as the
  stock red/yellow `Shadow` texture on windows and doors.
- Parsed and acknowledged live CoD4x protocol-21 client configuration packets,
  removing the `Illegible server message 11`/`Connection Interrupted` loop.
- Allowed the native protocol-21 runtime to coexist with server-side
  `cod4x_patchv2` and `cod4x_ambfix` revisions without weakening stock-protocol
  fastfile checks.

## 0.2.1 release candidate - 2026-09-04

### Changed

- Existing profiles now receive the jgalbs default Favorite without
  duplicating its address or disturbing other saved servers. Profiles seeded
  by earlier builds migrate the old label to jgalbs in place.
- Native OAT fastfile loading reports real decode and asset-registration
  progress and repaints the map loading screen while synchronous work runs.
- Native app icons use a transparent macOS-style rounded tile instead of a
  square black image in the Dock.
- Normal Metal gameplay keeps a clean full-color base grade across the
  countdown-to-match transition while preserving authored scripted effects.

### Fixed

- Hardened active arm64 code against dozens of Win32-size allocations, copies,
  pointer strides, pointer comparisons, and delayed-render-command truncations
  across scripts, UI, assets, snapshots, FX, sound, physics, and rendering.
- Restored Metal film, glow, depth-of-field, night vision, flipped HUD art,
  custom-map loading images, protocol-21 map downloads, and protocol-6 joins.
- Fixed an arm64 cross-array rename calculation that prevented a verified
  downloaded map from being installed atomically.

## 0.2.0 release candidate - 2026-09-04

### Added

- A safe local `/Applications` installer with dry-run, explicit replacement,
  rollback, validation, and optional Dock placement.
- Fail-closed Homebrew cask preparation that requires the final DMG to pass
  Developer ID, hardened-runtime, notarization, Gatekeeper, checksum, bundle,
  architecture, and corresponding-source checks.
- Signed Sparkle feed tooling with exact source/tag/version validation and
  complete generic, versioned, and checksum asset manifests.

### Changed

- Replaced legacy Switch/Windows contribution templates with native Apple
  Silicon issue, pull-request, and source-safety guidance.
- CI now audits the sanitized source manifest and builds the Metal client on a
  GitHub-hosted arm64 macOS runner without uploading unsigned binaries.
- Ad-hoc development packages keep manual update checks but disable scheduled
  polling until a signed public feed exists.
- Native renderer restarts now apply latched graphics choices. Legacy D3D MSAA
  and multi-GPU toggles are pinned off instead of presenting nonfunctional values.

### Fixed

- Corrected the IWI diagnostic decoder's format mapping: format `0xC` is BC2
  and format `0xD` is BC3. The tool now accepts BC1, BC2, and BC3 inputs.
- Resolved late-loaded FX materials against the canonical sorted material table
  so smoke, debris, fire, and distortion no longer inherit material slot zero.
- Corrected native Metal FX sampling, depth, alpha-test, culling, and tangent
  semantics used by explosions and other translucent effects.
- Enabled the standard macOS full-screen control and made live window/full-screen
  transitions rebuild viewport, projection, HUD, menu, console, and mouse geometry.
- Restored native Video Mode and Screen Refresh Rate enum registration for the
  retail Graphics menu, and made applied windowed modes resize the AppKit window.
- Made Auto, 4:3, 16:10, and 16:9 aspect selections update the native projection
  and pixel-aspect configuration after Apply.
- Removed absolute build-machine runtime paths from packaged applications and
  made DMG installation verify its SHA-256 sidecar before mounting.
- Normalized compiler source/debug paths and made packaging reject embedded
  checkout or temporary-build paths in every bundled Mach-O.

## 0.1.0 source baseline - 2026-09-04

### Added

- Native arm64 macOS client path with direct Metal presentation, Cocoa input,
  Core Audio-backed sound, networking, and multiplayer engine integration.
- Source-only support for user-owned Call of Duty 4 data. Retail maps,
  fastfiles, IWDs, media, and credentials are excluded from this repository.
- Deterministic combat/fuzz validation tools and documented test scope.
- Reproducible, checksum-pinned SDL2 compatibility and SDL3 runtime builds.
- Self-contained app/DMG packaging with dependency audits, license notices,
  code-signing hooks, notarization gates, and Sparkle update integration.
- A fail-closed public-source exporter with secret scanning and a SHA-256
  manifest.

## Version plan

- `0.1.x`: source previews while renderer parity, compatibility, and packaging
  continue to stabilize. No public binary is implied by a source commit.
- `0.2.x`: signed and notarized developer previews after final-DMG multiplayer,
  update, crash/fuzz, and clean-Mac installation gates pass.
- `1.0.0`: stable native multiplayer release after the supported map/mode
  matrix, long-session stability, performance targets, and documented data
  compatibility have been validated on multiple Apple Silicon Macs.

Public binary versions must also increment `CFBundleShortVersionString` and
`CFBundleVersion`, publish matching GPL corresponding source, and use a signed
`vX.Y.Z` Git tag. Source-only snapshots remain untagged until those release
requirements are satisfied.
