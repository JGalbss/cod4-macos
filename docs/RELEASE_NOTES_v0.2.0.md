# jgalbs cod4 0.2.0

This developer preview is the first binary release candidate for the native
Apple Silicon multiplayer client. It runs directly on arm64 macOS and presents
through Metal without Wine, DXVK, Vulkan, or MoltenVK.

## Highlights

- Native Metal rendering, Cocoa input, networking, and Core Audio-backed sound.
- Corrected smoke, debris, fire, explosion, distortion, depth, alpha-test,
  culling, and tangent behavior in the native renderer.
- High-refresh presentation with Metal vsync disabled by default and a
  user-configurable 250 FPS default cap.
- A first-launch retail-data chooser; no Call of Duty 4 retail assets are
  bundled or downloaded.
- A default New Experience favorite for fresh profiles while preserving
  existing Favorites lists.
- A self-contained app bundle with pinned SDL runtimes and signed Sparkle
  update support.

## Validation scope

The release-candidate source passed clean arm64 CI, integrated two-client
combat cycles, deterministic 21-map fuzz coverage, focused graphics/FX stress,
and installed-app map-load smoke tests. See `docs/VALIDATION.md` for the exact
commands, evidence, and limitations.

## Requirements and known limitations

- Apple Silicon and macOS 15.5 or newer.
- A legally owned compatible Call of Duty 4 installation is required.
- Script, IWD, fastfile, and asset mods use the native `fs_game` paths, but
  broad third-party mod compatibility is not guaranteed.
- Windows-only mod DLLs cannot load in an arm64 macOS process and require a
  native source port.
- This candidate must not be published until its final DMG is Developer-ID
  signed, notarized, stapled, accepted by Gatekeeper, tested on a clean Mac,
  and proven through an old-to-new Sparkle update.
