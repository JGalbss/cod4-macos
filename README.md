# jgalbs cod4

`jgalbs cod4` is an in-progress, native Apple Silicon port of the KisakCOD
multiplayer client. It runs as an arm64 macOS application and presents through
Metal directly—there is no Wine, DXVK, Vulkan, or MoltenVK layer in the native
build.

The public source repository is
[`JGalbss/cod4-macos`](https://github.com/JGalbss/cod4-macos). This project is
independent, unofficial, and not affiliated with the game's publisher.

## Current status

The tested native path can create a profile, render the multiplayer UI and 3D
maps, accept keyboard and mouse input, play audio, host or join multiplayer,
and exercise standard combat, killcam, respawn, bomb-mode, progression, and
Create-a-Class flows. A fresh profile receives a Favorite named
**New Experience**; an existing Favorites list is left unchanged.

The current updater-enabled Release arm64 build passed the integrated
two-client combat test, the five-map deterministic fuzz test, and a packaged
application smoke test. On the profiled Apple Silicon Mac's built-in 120 Hz
display, the tested scene held approximately 120 FPS; this is a measured result
for that setup, not a universal frame-rate claim.

This is still a development build. Rendering parity, long-session stability,
performance across Mac models, the full map/mode matrix, and broad mod
compatibility have not been established. A Windows-only mod DLL cannot load
inside an arm64 macOS process. See [validation status](docs/VALIDATION.md) for
the exact tested scope.

## Game data is not included

This repository and its application bundle do not contain Call of Duty 4 maps,
fastfiles, IWDs, textures, sounds, videos, or other retail data. You must own a
compatible Call of Duty 4 installation and point the client at its data
directory. Do not add retail data to issues, forks, source archives, or release
artifacts.

## Build on Apple Silicon

Requirements:

- Apple Silicon Mac running macOS 15.5 or newer
- Xcode Command Line Tools
- CMake, Ninja, Premake 5, SDL2 compatibility headers, and GLM
- The exact public OpenAssetTools revision used by the native fastfile bridge
- Pinned package runtimes built as described in the
  [SDL runtime guide](mac/sdl2/README.md)

Install the Homebrew prerequisites:

```zsh
brew install cmake ninja premake sdl2-compat glm
```

Clone and build OpenAssetTools at the pinned public revision:

```zsh
git clone --recurse-submodules https://github.com/JGalbss/OpenAssetTools.git ../OpenAssetTools
git -C ../OpenAssetTools checkout --detach 0ad64096aa6ee2874f835fff8a5c6dc4af8c7f77
git -C ../OpenAssetTools submodule update --init --recursive
../OpenAssetTools/mac-build.sh
```

Configure and build the CMake target `kisak_posix`. The produced executable is
`bin/posix/jgalbs cod4`.

```zsh
cmake -S . -B build-metal -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.5 \
  -DKISAK_TARGET=posix \
  -DKISAK_METAL=ON \
  -DOAT_ROOT="$(cd ../OpenAssetTools && pwd)"
cmake --build build-metal --target kisak_posix -j4
```

For data setup, direct execution, debugging, and test commands, continue with
[Development](docs/DEVELOPMENT.md).

## Packaging and releases

The packaged application name is exactly `jgalbs cod4`. Local ad-hoc packages
can be built for development, but no public binary should be treated as a
release until it is signed with Developer ID, notarized by Apple, stapled,
tested from the final DMG, and paired with the exact public GPL corresponding
source. The remaining public-release work is credentialed Developer ID and
notarization validation plus a production old-to-new Sparkle update test.

See [Release](docs/RELEASE.md) for packaging, signing, notarization, and Sparkle
update steps.

## License and attribution

Project code is distributed under GPLv3 except where individual files state
otherwise. See [LICENSE](LICENSE), [NOTICE](NOTICE), and
[THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt). This work is derived from
[KisakCOD](https://github.com/SwagSoftware/KisakCOD).
