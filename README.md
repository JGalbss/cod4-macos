# jgalbs cod4

`jgalbs cod4` is an open-source Apple Silicon port of the
[KisakCOD](https://github.com/SwagSoftware/KisakCOD) multiplayer client for
macOS, featuring a native Metal renderer.

## Related repositories

| Repository | Purpose |
| --- | --- |
| [`cod4-macos`](https://github.com/JGalbss/cod4-macos) | Client source, macOS build, and renderer |
| [`homebrew-cod4-macos`](https://github.com/JGalbss/homebrew-cod4-macos) | Homebrew installation metadata for released builds |
| [`OpenAssetTools`](https://github.com/JGalbss/OpenAssetTools) | Asset tooling used by the client to load game data |

## Current status

The client supports profiles, multiplayer menus and maps, keyboard and mouse
input, audio, hosting, and joining matches. Core gameplay includes combat,
killcams, respawning, progression, Create-a-Class, and the stock bomb modes.
Fresh and upgraded profiles receive a
Favorite named **jgalbs**; other saved Favorites are preserved and its address
is not duplicated.

Development is ongoing. See [Validation](docs/VALIDATION.md) for tested features
and known limitations.

## Game data

Game assets are not included. Point the client to the data directory of a
compatible Call of Duty 4 installation.

## Build

Building requires an Apple Silicon Mac with macOS 15.5 or later, the Xcode
Command Line Tools, and [Homebrew](https://brew.sh). From the repository root,
run:

```zsh
./mac/build.zsh
```

The script installs the build dependencies, downloads the pinned
OpenAssetTools source, and builds the client. The executable is written to
`bin/posix/jgalbs cod4`. See [Development](docs/DEVELOPMENT.md) for data setup,
debugging, and testing.

## Releases

See the [release guide](docs/RELEASE.md) for packaging, code signing,
notarization, and updates.

## License and attribution

Project code is distributed under GPLv3 except where individual files state
otherwise. See [LICENSE](LICENSE), [NOTICE](NOTICE), and
[THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt). This work is derived from
[KisakCOD](https://github.com/SwagSoftware/KisakCOD).
