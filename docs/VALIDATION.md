# Validation status

This is an evidence ledger for the native Apple Silicon client, not a claim of
complete compatibility. Results below were observed during development through
2026-09-04.

## Observed working paths

- The built client is a native arm64 Mach-O with a macOS 15.5 deployment target.
- The native renderer presents through Metal without Wine, DXVK, Vulkan, or
  MoltenVK.
- Profile creation, menus, textured UI, map loading, keyboard/mouse input,
  audio, local hosting, and remote joining have run on Apple Silicon.
- The **New Experience** default Favorite was added for a fresh profile, and a
  remote connection to that server completed during testing. Existing Favorites
  remain untouched.
- The current integrated two-client standard-combat test exercised real bullet
  damage, authoritative death, score update, killcam entry/exit, and full-health
  respawn. A final three-cycle run passed every check with artifacts in
  `/tmp/kisak-native-combat.G0p9Nw`.
- Search and Destroy and Sabotage tests exercised their plant and defuse paths.
  This is not a comprehensive certification of every timing or balance setting.
- One real kill moved XP from 0 to 10 and persisted through a cold restart in
  the encrypted 8,476-byte `mpdata` file.
- Controlled additive-XP checks observed XP 100 to 200 with rank 1 to 2, then
  XP 200 to 300 with rank reaching 3.
- A level-9 progression test exposed all five Create-a-Class slots, and the
  level/loadout state persisted across restart. This verifies the tested
  Create-a-Class path, not the complete unlock matrix at every rank.
- Renderer/game binary SHA-256 `7f40b89e89f7ded2fa2fddfe88c83875f8f8fc374e51c426402471af1797a563`
  passed all 21 maps in the deterministic matrix for 1,200 frames each with
  seed `20260904`. Artifacts are in `/tmp/kisak-native-fuzz.RKET7T`.
- Focused vehicle-explosion captures at early and late effect lifetimes show
  authored orange fire, smoke, debris, and localized heat distortion without
  the previous gray cards, colored wedges, or full-screen corruption. Their
  fatal scans are empty. Evidence is in
  `/tmp/cod4-final-graphics-stress/final-v2-plus35` and
  `/tmp/cod4-final-graphics-stress/final-v2-plus130`.
- A moving/camera graphics stress run had no fatal frames and no sampled frame
  over 16.7 ms while capped near 120 FPS. Evidence is in
  `/tmp/cod4-final-graphics-stress/final-motion-stress`.
- The updater-enabled Release arm64 configuration built successfully. A packaged
  app smoke test launched the final app layout, reported Sparkle enabled, loaded
  `mp_vacant`, joined a team/loadout, and quit normally. Its artifacts are in
  `/tmp/cod4-packaged-smoke.3EJMt5`.
- Package validation passed for the embedded Sparkle updater, the pinned SDL2
  compatibility library loading the app-local SDL3 runtime, ad-hoc code-signing
  structure, the DMG checksum, and `hdiutil verify`. The pinned runtime build is
  documented in the [SDL runtime guide](../mac/sdl2/README.md).
- The car-effect audit found no missing asset. The observed car debris and
  shellshock are authored effects, not a missing-resource fallback.

Progression and automated gameplay tests used isolated `fs_homepath`
directories so normal user profile data was not read or modified.

## Performance sample

The profile in `/tmp/cod4-metal-profile.Acu4bb` measured a stable approximately
120 FPS on the tested Mac's built-in 120 Hz display. Across the sampled windows,
Metal command encoding used about 1.9–2.5 ms of CPU time, GPU work used about
4.4–5.7 ms, and drawable acquisition used about 5–6 ms. These measurements
describe one machine, scene, resolution, and display mode; they are neither a
claim of a higher unlocked frame rate nor a guarantee for other hardware, maps,
or effects.

## Reproducible focused checks

Build the client according to [Development](DEVELOPMENT.md), then provide an
absolute path to legally owned retail data:

```zsh
export COD4_DATA='/absolute/path/to/Call of Duty 4'

COD4_DATA="${COD4_DATA}" mac/tools/test-native-combat.zsh

COD4_DATA="${COD4_DATA}" \
  KISAK_FUZZ_CASES=5 \
  KISAK_FUZZ_FRAMES=1200 \
  KISAK_FUZZ_SEED=1337 \
  mac/tools/test-native-fuzz.zsh
```

Each script prints its isolated artifact directory. Preserve the logs and any
captured frame when reporting a failure. A pass from an older binary is not
evidence for a changed build.

For package structure and dependency checks:

```zsh
file 'dist/jgalbs cod4.app/Contents/MacOS/jgalbs cod4'
otool -L 'dist/jgalbs cod4.app/Contents/MacOS/jgalbs cod4'
codesign --verify --deep --strict --verbose=2 'dist/jgalbs cod4.app'
mac/tools/verify-bundled-sdl.zsh 'dist/jgalbs cod4.app'
mac/updater/verify_updater_bundle.zsh 'dist/jgalbs cod4.app'
(cd dist && shasum -a 256 -c cod4-macos-arm64.dmg.sha256)
hdiutil verify dist/cod4-macos-arm64.dmg
```

A public release additionally requires `spctl` success on the notarized,
stapled DMG and an install/update test from the downloaded final bytes.

## Not yet established

- Visual and performance parity across every map, effect, material, and scene
- Long multiplayer sessions and a broad sample of public servers
- Every stock game mode, rank boundary, challenge, attachment, perk, and unlock
- Compatibility with all script, IWD, fastfile, and asset mods
- Compatibility with Windows-only native mod DLLs
- Coverage across multiple Apple Silicon generations and all supported macOS
  point releases
- A complete Developer-ID-signed, notarized, Gatekeeper-approved public binary
- A production Sparkle update from an older signed build to the final release

Treat regressions, crashes, assertions, red-screen diagnostics, and rendering
artifacts as release blockers even if a narrower automated check passes.
