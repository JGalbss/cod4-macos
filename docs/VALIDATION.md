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
- The **jgalbs** default Favorite was added to an exact copy of a user's valid
  zero-Favorites cache and persisted to disk. A cache created by an earlier
  build with the same address named **New Experience** was upgraded in place to
  **jgalbs**, without a duplicate or changes to other Favorites. A remote
  connection to that server also completed during testing.
- The current integrated two-client standard-combat test exercised real bullet
  damage, authoritative death, score update, killcam entry/exit, and full-health
  respawn. Binary SHA-256
  `d1d67065f2c735d1c37e169cc5ee25d755ff1736693f7cf706713a83b16bb14b`
  passed the final exact-binary cycle with artifacts in
  `/tmp/kisak-native-combat.6mtC5X`.
- The exact installed 0.1.0/build-1 baseline entered active FFA, Team
  Deathmatch, Domination, Headquarters, Search and Destroy, and Sabotage states
  on `mp_vacant`. Each mode rendered 3D gameplay, accepted scripted input, and
  shut down cleanly. This verifies mode startup, not every objective transition.
- A focused Search and Destroy probe found the authored A/B sites, entered an
  attacker round, and displayed the real `Hold F to plant` prompt. The requested
  `scr_sd_planttime=2`, `scr_sd_defusetime=2`, and `scr_sd_bombtimer=5` values
  were registered exactly. Team-selection races prevented the harness from
  completing a plant, so plant duration, countdown/explosion, two-client defuse,
  scoring, and round transition are not claimed as validated.
- One real kill moved XP from 0 to 10 and persisted through a cold restart in
  the encrypted 8,476-byte `mpdata` file.
- Controlled additive-XP checks observed XP 100 to 200 with rank 1 to 2, then
  XP 200 to 300 with rank reaching 3.
- A level-9 progression test exposed all five Create-a-Class slots, and the
  level/loadout state persisted across restart. This verifies the tested
  Create-a-Class path, not the complete unlock matrix at every rank.
- Installed-app first-run probes verified explicit, saved, and `$HOME/Games/cod4`
  data discovery plus presentation of the retail-data chooser when no compatible
  directory existed. Fresh profiles received one jgalbs Favorite.
- The installed client loaded ModWarfare's IWD, fastfile, and 115 scripts into
  active `mp_vacant` gameplay. The custom `mp_mw2_rust` load/main zones also
  reached active 3D gameplay. OpenWarfare2 discovered its five IWDs but did not
  finish early renderer-zone startup in repeated 35–90 second probes, so it is
  explicitly unsupported pending focused loader profiling.
- Renderer/game binary SHA-256 `7f40b89e89f7ded2fa2fddfe88c83875f8f8fc374e51c426402471af1797a563`
  passed all 21 maps in the deterministic matrix for 1,200 frames each with
  seed `20260904`. Artifacts are in `/tmp/kisak-native-fuzz.RKET7T`.
- The final exact binary above also passed a post-relink regression gate on
  `mp_vacant`, `mp_crash`, and `mp_shipment` for 600 frames each. Its independent
  fatal scan was empty and its hash was unchanged after the run. Evidence is in
  `/tmp/kisak-native-fuzz-clean-rebuild.VPK7Mg`.
- A real synchronous `mp_vacant` load capture showed the loading bar advancing
  to an intermediate value while OAT decoded and registered assets, rather than
  remaining empty until completion. The captured frame is
  `/tmp/cod4-loading-frame-v2-converted.png`.
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
  structure, removal of runtime and compiler build-machine paths, the DMG
  checksum, and `hdiutil verify`. The pinned runtime build is documented in the
  [SDL runtime guide](../mac/sdl2/README.md).
- The final local 0.2.0/build-2 candidate DMG SHA-256 is
  `7d02fb8b218e4a8ae2c991ebdb87ac7360a048674de588cf46a21d1986aeba4c`.
  Its packaged executable SHA-256 is
  `7542986855cb7dcbba8b9189d9ec41c399f5765651b0c7b36dc6f2853364d6a0`;
  the difference from the raw tested binary is expected from install-name
  rewriting and app-bundle signing. This candidate remains a local ad-hoc build,
  not a public release.
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
- Completed Search and Destroy/Sabotage pickup, plant, defuse, explosion,
  scoring, and round-transition semantics on the exact release artifact
- Compatibility with all script, IWD, fastfile, and asset mods
- Compatibility with Windows-only native mod DLLs
- Coverage across multiple Apple Silicon generations and all supported macOS
  point releases
- A complete Developer-ID-signed, notarized, Gatekeeper-approved public binary
- A production Sparkle update from an older signed build to the final release

Treat regressions, crashes, assertions, red-screen diagnostics, and rendering
artifacts as release blockers even if a narrower automated check passes.
