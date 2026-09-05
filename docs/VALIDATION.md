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
- The local 0.2.1/build-3 candidate DMG SHA-256 is
  `047240bcb288304c6db35f74ef268d80d05483376f64ba8478d0c9235416056d`;
  its packaged executable SHA-256 is
  `97d7381008ab607c56126767e4e7759537f2c75e0b9cc2d0172926fd4eba7f0c`.
  It passed checksum and disk-image verification, deep code-sign structure,
  bundled SDL and Sparkle verification, and a retail-asset exclusion scan. The
  installed app reached active `mp_vacant`, reported the updater available,
  created the `jgalbs` Favorite on a clean profile, and quit cleanly; evidence
  is in `/tmp/cod4-installed-0.2.1.U80TCW`. The same installed package passed
  Rust and Terminal gameplay smokes in `/tmp/cod4-installed-custom.2NSgpu`.
  A live protocol-21 connection followed by a local `mp_vacant` listen-server
  transition also reached active gameplay and exited cleanly; evidence is in
  `/tmp/cod4-protocol-handoff-auth.WQ1eoE`. The corresponding build source is
  public commit `3dfcd32be2175f7c53a6ca60cb18cc0a85ccda76`.
- The car-effect audit found no missing asset. The observed car debris and
  shellshock are authored effects, not a missing-resource fallback.
- The exact post-LP64-fix raw executable SHA-256 is
  `bd05e3552de2b5f43e1ca1628f8f61911a71dbe3cad9f46a10182528da5fa863`.
  It loaded the custom `mp_mw2_term` map into active gameplay for 600 frames,
  selected authored urban SAS/Russian teams, rendered the map compass from its
  usermap IWD, and quit normally with an empty fatal/error scan. Evidence is in
  `/tmp/cod4-terminal-exact.XtzFqV`.
- That same exact executable passed a 300-frame deterministic stock
  `mp_vacant` regression with seed `20260904`; evidence is in
  `/tmp/cod4-final-stock-regression`.
- A focused arm64 pointer-width audit found and fixed an active listen-server
  skeleton-memory alignment expression that narrowed an address through
  `unsigned int`. Remaining obvious pointer-to-32-bit conversions are confined
  to uncompiled single-player/debug code or the dormant legacy zone loader;
  the native multiplayer build uses the OAT loader and pointer-width storage.
- Custom-map startup now mounts the usermap IWD before fastfile loading, uses
  embedded IWI compression metadata when external metadata disagrees, and
  quietly defaults absent optional vision/FX files. The Terminal load and
  mini-map capture after those fixes is
  `/tmp/cod4-terminal-iwi-fix.03Myb8/terminal.png`.
- Favorites now bypass the Internet browser's empty/full/pure visibility
  filters. This preserves the user's filter choices while ensuring a persisted
  favorite remains listed and joinable from the Favorites source.
- The updater-enabled 0.2.1 raw arm64 release executable SHA-256 is
  `e6be6d01548eafd3c968614191c7e80d0006414ecc5b3ef246c1a9a502d88499`.
  A locked copy passed five 600-frame stock fuzz cases (`mp_vacant`, `mp_crash`,
  `mp_shipment`, `mp_backlot`, and `mp_strike`) with seed `20260904`; evidence
  is in `/tmp/kisak-native-fuzz.2UEs1F`.
- That exact locked executable also passed the two-client standard-combat gate:
  real bullet damage, authoritative deaths, attacker scoring, killcam
  entry/exit, and full-health respawns. Evidence is in
  `/tmp/kisak-native-combat.V76rh7`.
- On that exact executable, the normal `mpintro` and `mp_vacant` base grades
  remained neutral and full-color. Direct `+nightvision` entered the authored
  green `default_night` grade, and a second press restored the neutral grade.
  Evidence is in `/tmp/cod4-release-vision-roundtrip.WCHr6V`.
- The renderer-equivalent pre-updater-link executable passed clean-home
  movement, firing, reload, mouse-look, audio, capture, and clean-exit smokes on
  `mp_mw2_rust` and `mp_mw2_term`; evidence is in
  `/tmp/cod4-frozen-custom-smoke.oYXRPx`.
- A clean-profile startup created a cache with one Favorite named `jgalbs` at
  `159.65.37.227:28961` without touching the normal user profile. Evidence is
  in `/tmp/cod4-favorite-final.01xZqP`.
- A clean-home live CoD4x connection negotiated protocol 21/xproto18, safely
  declined the HTTP redirect, transferred `mp_highrise.iwd` through the binary
  checksummed server path, verified CRC `87388a09`, atomically installed
  1,355,335 bytes, and advanced to `mp_highrise.ff`. Local SHA-256
  `8faa87fe5db526f1d7b36ffddba7a2cbd30f652063c7fa1451414873b420457f`
  matched the server file. Evidence is in
  `/private/tmp/cod4-live-highrise-rename-audit.X4BxOb`.
- Clean-home Rust and Terminal pause-menu captures resolve their authored
  compass plus `compass_overlay_map_blank`, with no checker material. Evidence
  is in `/tmp/cod4-custom-map-validation.0KgWbR`.
- Shipment may log a nonfatal missing `fire/tire_fire_med` effect. A full OAT
  scan found that retail effect only in four single-player mission zones; no
  multiplayer-loaded zone packages it. The client keeps the standard missing-FX
  fallback and completes gameplay rather than loading unrelated SP content.
- The 0.2.2 raw arm64 executable SHA-256 is
  `de12fc7296197e0e03f1cdcf8601e079f3c76f717d70b77dce6fd69254cdf9bb`.
  Neutral gameplay, explicit NVG, and NVG-on-to-off captures are in
  `/tmp/cod4-normal-vacant.bUt9Kk`, `/tmp/cod4-nvg-vacant.HyPU4e`, and
  `/tmp/cod4-nvg-toggle.wT45PY`. The neutral captures contain no red/yellow
  `Shadow` tool surface, and the trace selects the night channel only while the
  authoritative NVG flag is set.
- Two clean native clients joined `159.65.37.227:28961` over protocol 21. The
  observer accepted client-config sequence 13; neither log contains an illegal
  server message, connection interruption, timeout, assertion, or fatal error.
  Evidence is in `/tmp/cod4-live-two-client.p65K5W`.
- That exact executable passed the full two-client combat lifecycle in
  `/tmp/kisak-native-combat.jj12Si` and five 1,200-frame deterministic fuzz
  cases on Vacant, Crash, Shipment, Backlot, and Strike in
  `/tmp/kisak-native-fuzz.6yHRN9`.
- A clean launch with `r_fullscreen=1` reported `AXFullScreen=true` through
  macOS accessibility state and reconfigured the renderer to the full-screen
  Space. Evidence is in `/tmp/cod4-fullscreen.9w59qY`.
- The local 0.2.2/build-4 DMG SHA-256 is
  `4cd7ddd387d59312ddcd396b130d65ea02de6ee73a8e7fc4da756969ba5e41c4`;
  its packaged executable SHA-256 is
  `2b6b6c6b375a16c0f715cb6d36323161519072a9652b67dcd815729ef9fb6aa6`.
  It passed checksum and disk-image verification, deep code-sign structure,
  bundled SDL and Sparkle checks, arm64/dependency inspection, and retail-asset
  exclusion. Two packaged clients then joined the live protocol-21 server,
  accepted config-client sequence 15, reached active gameplay, and exited with
  no parser, connection, assertion, or fatal error; evidence is in
  `/tmp/cod4-packaged-live.NgYSZ6`. The packaged neutral-color/window-surface
  capture is in `/tmp/cod4-packaged-visual.6GTJb5`.

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
- Complete texture payloads for the tested third-party Rust and Terminal map
  packages. Rust omits `watersetup0`; Terminal omits two referenced specular
  maps and two color maps. The stock `spotlight_beam.iwi` also uses legacy IWI6
  wavelet encoding that the native uploader does not yet decode.

Treat regressions, crashes, assertions, red-screen diagnostics, and rendering
artifacts as release blockers even if a narrower automated check passes.

## 0.2.7 release-candidate evidence

- Raw arm64 executable SHA-256:
  `18e62391b4cbbb41026e3fec86ecb0cb1cee42b5771b7f5c158b4b90c82faf8b`.
- Packaged arm64 executable SHA-256:
  `23124c0c93cfc4794c4943f58cbee6f3f2a34e419eec0bf578eb8c953dd6a29e`.
- Versioned DMG SHA-256:
  `e365c44c41b0275b3ae74b7bd4ca05f211c662e4a71b682ef493025194e49322`.
- The legacy warning used a 128-command ring as an implicit time threshold. On
  the 120 Hz test display that represented only about 1.06 seconds instead of
  the roughly two seconds it covered at the original 60 Hz target.
- A server-side capture of a healthy 158-second live protocol-21 session found
  a 1.000-second maximum server-to-client packet gap and a 0.832-second maximum
  client-to-server gap. The client stayed connected and exited cleanly. Capture
  evidence is `/tmp/jgalbs-cod4-live.pcap` on the test server and client evidence
  is in `/tmp/jgalbs-cod4-live-repro`.
- With the fixed millisecond threshold, a second live session completed without
  drawing a warning during normal network jitter and exited cleanly. Evidence is
  `/tmp/jgalbs-cod4-live-repro/time-threshold-clean.log`.
- A controlled three-second server-to-client outage then drew the warning at an
  observed command-ack delay of 2.002 seconds, recovered after packet delivery
  resumed, remained connected, and exited normally. Evidence is in
  `/tmp/jgalbs-cod4-drop-exact.XXXXXX.log`.
- The installed 0.2.7/build-9 package completed a separate deterministic
  `mp_vacant` load, active-play, and clean-shutdown smoke test. Its DMG passed
  SHA-256 and `hdiutil` verification, and the installed app passed deep strict
  code-sign validation. Evidence is in
  `/tmp/jgalbs-cod4-0.2.7-package-smoke.log`.
- The droplet remained healthy during diagnosis: no interface errors or drops,
  no resource pressure, and no server crash. The engine's hard-timeout path was
  not changed.

## 0.2.6 release-candidate evidence

- Raw arm64 executable SHA-256:
  `db429737f378dc4619f9c345354acbbc4d3d109eec7cd25e687e873e846fbcf7`.
- Packaged arm64 executable SHA-256:
  `e8e279e68bd0aa5fb4668fcb6744c1887ab2a7aa2f2fd2a7dc3ecb3b6bf7d313`.
- Versioned DMG SHA-256:
  `ba6f45100a1d18b47922a06cdb113371f47b36b6a77879861b9842b48a6a7a46`.
  The image passed checksum and `hdiutil` verification, and its app passed deep
  strict code-sign, bundled SDL, and Sparkle validation.
- A real local `mp_vacant` match with `com_maxfps 250` and VSync off held the
  120 Hz display rate at roughly 8.3 ms per normal frame. CPU encoding remained
  around 2.6-2.9 ms, GPU work around 4.9-5.8 ms, and no normal frame exceeded
  16.7 ms. Evidence is in `/tmp/cod4-perf-local250.XEnpUV`.
- A VSync-on comparison produced the same stable 120 Hz pacing without normal
  frames over 16.7 ms. Evidence is in `/tmp/cod4-perf-localvsync.yv0yWJ`.
- The installed, packaged 0.2.6 executable ran a timed match through the real
  outcome and map-vote transition while healthy snapshots continued. It
  identified `mpOutro`, suppressed the legacy false disconnect warning, and
  exited cleanly. Evidence is in `/tmp/jgalbs-cod4-0.2.6-transition`.
- The installed package also passed a separate cold-start, map-load, auto-join,
  active-play, and clean-shutdown smoke test. Evidence is in
  `/tmp/jgalbs-cod4-0.2.6-installed-smoke`.
- A live protocol-21 Scrapyard join rejected all eight remote developer film
  overrides and retained the neutral full-color map grade. Evidence is in
  `/tmp/cod4-vision-trace2.XSDgPP`.

## 0.2.5 release-candidate evidence

- Raw arm64 executable SHA-256:
  `13947f3e96413afca2b56b42abe18f7d4f1047e619ac63824019c122e3affa82`.
- Packaged arm64 executable SHA-256:
  `2df13c9c2465c1a3ac5df6193a865d82f31e4c9d4c20b9160290a9a563b328cd`.
- Versioned DMG SHA-256:
  `1cb0c62581874f670133227b31fbc4a978a7a6db3193841c887185f3399a949f`.
  The disk image passed checksum and `hdiutil` verification, and the app passed
  deep strict code-sign and bundled SDL/Sparkle validation.
- The live protocol-21 server reproduced the 0.2.4 regression by sending
  `r_filmUseTweaks` plus all seven `r_filmTweak*` values after spawn. The
  patched client rejected those remote developer controls while retaining the
  neutral map grade (`desaturation=1`, white light/dark tints, zero bias).
- The live join completed without a parser failure, connection loss, assertion,
  or crash. Logs are in `/tmp/cod4-film-policy.xz2Qjh`.
- A second independent live run captured a full-color post-spawn frame after
  the override commands. Evidence is in
  `/tmp/cod4-film-visual-final.G2fQgx`.
- The exact packaged 0.2.5/build-7 executable repeated the live protocol-21
  join on Rust, rejected every remote film override, retained neutral full
  saturation, captured a full-color post-spawn frame, and exited cleanly.
  Evidence is in `/tmp/cod4-film-package.2fGMfC`.

## 0.2.4 release-candidate evidence

- Raw arm64 executable SHA-256:
  `95724dfcdca82609a7f079229a296d0aae64db6912b76dae43561c58156bc067`.
- Packaged arm64 executable SHA-256:
  `4e6b094207d1f940d1c3d06c0c9a0bcbedcdd1c910bda640a6b2c99c935eed3b`.
- Versioned DMG SHA-256:
  `b077ec438899ab8a90650e929255f65f4eade9821e81d64fe2c4cfca5c6e4def`.
  The disk image passed `hdiutil verify`, deep strict code-sign verification,
  bundled SDL/Sparkle checks, and exact-byte comparison with the packaged
  release candidate.
- Two-client combat, killcam skip, respawn, and resolved player-name test:
  `/tmp/kisak-native-combat.gZ9IDU`.
- Live protocol-21 join, initial client-name cache, snapshot, and clean
  connection test: `/tmp/kisak-native-cod4x-join.EQFZbK`.
- Real score-limit end-state color and overlay test:
  `/tmp/cod4-outcome-hud-fixed.n2iyLq`.
- Real airstrike parent/impact FX test:
  `/tmp/kisak-native-airstrike.CCSJOv`.

## 0.2.1 focused regression evidence

- The exact post-LP64-fix raw executable SHA-256 is
  `bd05e3552de2b5f43e1ca1628f8f61911a71dbe3cad9f46a10182528da5fa863`.
  It loaded the custom `mp_mw2_term` map into active gameplay for 600 frames,
  selected authored urban SAS/Russian teams, rendered the map compass from its
  usermap IWD, and quit normally with an empty fatal/error scan. Evidence is in
  `/tmp/cod4-terminal-exact.XtzFqV`.
- That same exact executable passed a 300-frame deterministic stock
  `mp_vacant` regression with seed `20260904`; evidence is in
  `/tmp/cod4-final-stock-regression`.
- A focused arm64 pointer-width audit found and fixed an active listen-server
  skeleton-memory alignment expression that narrowed an address through
  `unsigned int`.
