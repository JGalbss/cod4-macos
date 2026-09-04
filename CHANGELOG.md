# Changelog

This file tracks notable changes to the native Apple Silicon macOS client.
The project uses semantic versioning while the port is under active development.

## Unreleased

No changes are currently queued beyond the 0.2.0 release candidate.

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
