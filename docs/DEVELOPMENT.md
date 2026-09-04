# Development

This guide covers the native arm64 macOS and Metal configuration. The CMake
target remains `kisak_posix`; its packaged product and executable name are
`jgalbs cod4`.

## Prerequisites

Use an Apple Silicon Mac with macOS 15.5 or newer and install Xcode Command
Line Tools. The currently exercised dependency set is CMake, Ninja, Premake 5,
SDL2 compatibility headers, and GLM:

```zsh
xcode-select --install
brew install cmake ninja premake sdl2-compat glm
```

You also need a legally owned Call of Duty 4 data directory. Retail files are
runtime inputs and must stay outside this repository.

## Build the pinned fastfile dependency

The native LP64 fastfile path uses this public OpenAssetTools commit:

[`0ad64096aa6ee2874f835fff8a5c6dc4af8c7f77`](https://github.com/JGalbss/OpenAssetTools/commit/0ad64096aa6ee2874f835fff8a5c6dc4af8c7f77)

Keep its submodules pinned and build it natively:

```zsh
git clone --recurse-submodules https://github.com/JGalbss/OpenAssetTools.git ../OpenAssetTools
git -C ../OpenAssetTools checkout --detach 0ad64096aa6ee2874f835fff8a5c6dc4af8c7f77
git -C ../OpenAssetTools submodule update --init --recursive
../OpenAssetTools/mac-build.sh
```

Do not substitute prebuilt OAT archives when producing a release. The pinned
source, submodules, and build script are part of the corresponding source for
a client that links those archives.

## Configure and build

From the `cod4-macos` checkout:

```zsh
OAT_DIR="$(cd ../OpenAssetTools && pwd)"
cmake -S . -B build-metal -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.5 \
  -DKISAK_TARGET=posix \
  -DKISAK_METAL=ON \
  -DOAT_ROOT="${OAT_DIR}"
cmake --build build-metal --target kisak_posix -j4
```

CMake must report that OpenAssetTools zone loading is enabled. A warning that
OAT was not built produces an executable that cannot load normal game zones;
do not treat that configuration as a successful client build.

Metal is the native renderer. `KISAK_COD4X` defaults to `ON` for the portable
discovery and protocol work currently integrated into the source client. That
does not imply compatibility with every CoD4x server or mod.

To build the optional Sparkle updater, fetch the pinned official distribution
and reconfigure with the opt-in enabled:

```zsh
mac/updater/fetch_sparkle.zsh
cmake -S . -B build-metal -DKISAK_SPARKLE_UPDATER=ON
cmake --build build-metal --target kisak_posix -j4
```

## Run against owned data

The data directory must contain `main/iw_00.iwd`. One direct development run
looks like this:

```zsh
export COD4_DATA='/absolute/path/to/Call of Duty 4'
export COD4_HOME="${HOME}/Library/Application Support/jgalbs cod4"
mkdir -p "${COD4_HOME}"
CLIENT="$(pwd)/bin/posix/jgalbs cod4"
(cd "${COD4_DATA}" && "${CLIENT}" \
  +set fs_basepath "${COD4_DATA}" \
  +set fs_homepath "${COD4_HOME}")
```

Use an isolated home path for automated or destructive testing so your normal
profile is untouched:

```zsh
TEST_HOME="$(mktemp -d /tmp/jgalbs-cod4-home.XXXXXX)"
"${CLIENT}" \
  +set fs_basepath "${COD4_DATA}" \
  +set fs_homepath "${TEST_HOME}" \
  +set developer 1 \
  +devmap mp_vacant
```

A new profile gets **New Experience** as a default Favorite. Loading an
existing server cache does not overwrite or re-add a Favorite the player has
removed. The remote server was reachable during development, but external
availability is not guaranteed by the client.

## Focused regression tools

The native scripts isolate profile state under a temporary `fs_homepath` and
retain logs/screenshots in the printed artifact directory:

```zsh
COD4_DATA="${COD4_DATA}" mac/tools/test-native-combat.zsh
COD4_DATA="${COD4_DATA}" \
  KISAK_FUZZ_CASES=5 KISAK_FUZZ_FRAMES=1200 KISAK_FUZZ_SEED=1337 \
  mac/tools/test-native-fuzz.zsh
```

These are targeted checks, not a complete certification suite. Review the
artifact logs and [Validation](VALIDATION.md), especially after renderer,
lifecycle, networking, game-mode, progression, or packaging changes.

## Source hygiene

Never commit retail game data, player profiles, logs, signing keys, notarization
credentials, Sparkle private keys, downloaded frameworks, app bundles, DMGs,
or build directories. Preserve the license and modification notices in
[NOTICE](../NOTICE) and [THIRD_PARTY_NOTICES.txt](../THIRD_PARTY_NOTICES.txt).
