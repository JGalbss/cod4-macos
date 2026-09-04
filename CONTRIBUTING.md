# Contributing to jgalbs cod4

This repository develops a native Apple Silicon macOS multiplayer client from
the GPLv3 KisakCOD source. The supported development target is arm64 macOS
15.5 or newer; Wine, DXVK, and Intel builds are outside this project's scope.

## Before opening a pull request

1. Read [Development](docs/DEVELOPMENT.md) for the build setup and
   [Validation](docs/VALIDATION.md) for the currently tested behavior.
2. Keep the change focused on one subsystem. Renderer, input, audio,
   networking, asset loading, gameplay, and release engineering are easier to
   review and bisect independently.
3. Do not commit or attach retail game data, including IWDs, fastfiles, maps,
   textures, sounds, videos, profiles, configuration files, or screenshots
   extracted from a game installation. Never include credentials or keys.
4. Do not add downloaded binaries or package-manager output. A required
   dependency needs a reproducible source build, a pinned revision or digest,
   and its license recorded in `THIRD_PARTY_NOTICES.txt`.
5. Preserve behavior on the native macOS path and explain any intentional
   divergence from the upstream KisakCOD implementation.

## Build and validation

Build the `kisak_posix` target on Apple Silicon using the configuration in
[Development](docs/DEVELOPMENT.md). Run the narrowest relevant checks and list
their exact commands in the pull request. Rendering changes should include the
affected map/material scenario; gameplay changes should include the applicable
host/client or deterministic test.

The public-source safety check is:

```zsh
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/cod4-public-review.XXXXXX")"
mac/tools/export-public-source.zsh "$staging_dir"
```

The exporter must pass before source is published. Its output is source-only
and is not a playable game or a signed binary release.

## Commit conventions

Conventional Commit subjects are encouraged:

```text
fix(metal): preserve projective distortion coordinates
perf(audio): reduce mixer contention
test(combat): cover grenade damage and respawn
```

Use English for repository content and follow the surrounding upstream style.
Avoid unrelated formatting changes. Update `CHANGELOG.md` under `Unreleased`
for user-visible changes.

## Pull request checklist

- The arm64 native target builds without retail data in the repository.
- Relevant automated and manual validation is documented.
- No proprietary assets, generated binaries, secrets, or local paths were
  added.
- New third-party code has a pinned source and complete license notice.
- The public-source exporter still passes.

## Releases and licensing

Pull requests must not publish ad-hoc-signed applications or disk images.
Public binaries require the maintainer's Developer ID signature, Apple
notarization and stapling, final-DMG validation, and matching GPL corresponding
source. Contributions are licensed under GPLv3 unless an individual file
states another compatible license; contributors must have the right to submit
their work.
