# Native macOS updates

The native client uses [Sparkle 2](https://sparkle-project.org/) for secure,
in-place application updates. Sparkle provides the macOS-native update UI,
atomic bundle replacement, permission handling, scheduled background checks,
Developer ID validation, and Ed25519 archive verification. The integration is
disabled by default and fails closed until the release identity is configured.

The pinned distribution is Sparkle **2.9.6** (released 2026-08-17). Its archive
URL and GitHub-published SHA-256 digest are recorded in
`sparkle-release.conf`. The official release is:

<https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6>

The design follows Sparkle's official
[setup](https://sparkle-project.org/documentation/),
[programmatic API](https://sparkle-project.org/documentation/programmatic-setup/),
[publishing](https://sparkle-project.org/documentation/publishing/), and
[manual signing](https://sparkle-project.org/documentation/sandboxing/#code-signing)
guides.

## Behavior and security gate

`src/posix/posix_updater.mm` retains one `SPUStandardUpdaterController`, adds a
native **Check for Updates…** item to the application menu, and lets Sparkle own
its normal check schedule. It does not implement another timer or silently
override user preferences.

The updater remains inert unless all of these are true:

- the executable is running from an `.app` bundle;
- `SUFeedURL` is HTTPS and has no embedded credentials;
- `SUPublicEDKey` decodes to a 32-byte Ed25519 public key;
- `SURequireSignedFeed` is true;
- `SUVerifyUpdateBeforeExtraction` is true.

This protects both the executable archive and appcast/release-note metadata.
The recommended defaults enable automatic discovery while keeping installation
user-confirmed (`SUEnableAutomaticChecks=true`, `SUAutomaticallyUpdate=false`).
Local ad-hoc packages override scheduled checks to false so they do not poll a
feed before the first signed public release; their manual menu item remains.

## One-time release-owner inputs

These values cannot safely be invented or committed:

1. The public release repository is
   [`JGalbss/cod4-macos`](https://github.com/JGalbss/cod4-macos). It was
   created empty on 2026-09-04; source and release publication are separate,
   explicit steps because the current working tree contains uncommitted port
   work and its existing remotes point at upstream projects.
2. A Sparkle signing key. After fetching Sparkle, run this once:

   ```zsh
   mac/updater/fetch_sparkle.zsh
   mac/vendor/Sparkle/bin/generate_keys --account jgalbs-cod4
   ```

   The private seed stays in the login Keychain. Put only the printed public
   key in the application plist. Export one encrypted/offline recovery copy
   with `generate_keys --account jgalbs-cod4 -x /secure/offline/path`; never
   put that file in this repository or on the update web host.
3. The plist feed URL is
   `https://github.com/JGalbss/cod4-macos/releases/latest/download/appcast.xml`.
   Merge the keys from `Updater-Info.plist`, replacing the public-key
   placeholder.
4. A Developer ID Application signing identity and the existing notarytool
   Keychain profile for public packages.

GitHub Releases is sufficient for both immutable versioned DMGs and the stable
signed appcast URL. DigitalOcean/CDN hosting is optional, not required. If the
feed later moves, publish a signed app update containing the new HTTPS URL
before removing the old endpoint.

## Build hooks

The updater files are intentionally separate from the branding/package files.
The main build needs these two hooks.

After `kisak_posix` is created in `scripts/posix/CMakeLists.txt`:

```cmake
include("${CMAKE_SOURCE_DIR}/mac/updater/SparkleUpdater.cmake")
kisak_enable_sparkle_updater(kisak_posix)
```

In `src/posix/posix_gl_main.cpp`, include the header under the feature define:

```cpp
#if defined(__APPLE__) && defined(KISAK_SPARKLE_UPDATER)
#include "posix/posix_updater.h"
#endif
```

Immediately after the successful `posix_gl::CreateWindow(...)` call, while
still on the macOS main thread:

```cpp
#if defined(__APPLE__) && defined(KISAK_SPARKLE_UPDATER)
    posix_updater::Initialize();
#endif
```

Fetch and build with the opt-in enabled:

```zsh
mac/updater/fetch_sparkle.zsh
cmake -S . -B build-metal -G Ninja \
  -DKISAK_TARGET=posix -DKISAK_METAL=ON -DKISAK_SPARKLE_UPDATER=ON
cmake --build build-metal --target kisak_posix
```

## Packaging hooks

The framework is a versioned bundle with nested executables and symlinks. Copy
it with `ditto`, then sign its nested helpers in Sparkle's documented order.
Do not use `codesign --deep` for signing.

In `mac/package_native_app.sh`, after creating the staging app directories and
before dependency validation:

```zsh
"${repo_dir}/mac/updater/stage_sparkle.zsh" "${stage_app}"
```

After `sign_identity` and `sign_options` are established, but before signing
the containing application:

```zsh
"${repo_dir}/mac/updater/resign_sparkle.zsh" \
  "${stage_app}/Contents/Frameworks/Sparkle.framework" "${sign_identity}"
```

`resign_sparkle.zsh` retains the official ad-hoc signatures for local builds.
For Developer ID builds it signs Installer.xpc, Downloader.xpc (preserving its
entitlements), Autoupdate, Updater.app, and finally Sparkle.framework.

Validate a packaged bundle with:

```zsh
mac/updater/verify_updater_bundle.zsh 'dist/jgalbs cod4.app'
```

## Prepare a signed GitHub release

Package, Developer-ID sign, notarize, and staple the DMG first. Sparkle must
sign the exact final bytes users download. Keep `dist/updates` (or another
protected update archive directory) between releases so `generate_appcast`
can preserve old feed entries and produce binary deltas.

```zsh
GITHUB_REPOSITORY=JGalbss/cod4-macos \
RELEASE_TAG=v0.2.0 \
RELEASE_SOURCE_SHA="$(git rev-parse HEAD)" \
RELEASE_NOTES=/absolute/path/to/notes.md \
mac/updater/prepare_update_release.zsh
```

The preparation tool verifies the mounted app, framework link, signing keys,
feed URL, bundle versions, and signed-feed policy; creates a versioned DMG copy
and checksum; invokes Sparkle's `generate_appcast`; and verifies that the feed
is signed and points at the matching GitHub Release asset.

By default signing uses the `jgalbs-cod4` Keychain account. In non-interactive
CI, pass the private seed only over standard input instead of writing it into
the workspace:

```zsh
printf '%s' "${SPARKLE_PRIVATE_KEY_SECRET}" | \
  SPARKLE_ED_KEY_FILE=- GITHUB_REPOSITORY=JGalbss/cod4-macos \
  RELEASE_TAG=v0.2.0 RELEASE_SOURCE_SHA="$(git rev-parse HEAD)" \
  mac/updater/prepare_update_release.zsh
```

Create or update a verified **draft** GitHub Release:

```zsh
RELEASE_SOURCE_SHA="$(git rev-parse HEAD)" \
  mac/updater/publish_github_release.zsh JGalbss/cod4-macos v0.2.0
```

The script refuses private repositories, non-draft existing releases, and any
DMG that fails Developer ID, notarization, stapling, or Gatekeeper checks. It
uploads the generic Homebrew DMG, versioned update archive, generated deltas,
checksums, and signed appcast while the release is hidden, then verifies the
remote asset list. Final promotion is intentionally separate so a partially
uploaded feed is never exposed at `releases/latest/download/appcast.xml`.

GitHub draft assets are not available through `releases/latest`. Exercise the
candidate with a separate public staging feed/repository or a notarized staging
build pointed directly at the candidate appcast; never report a draft as having
passed production-feed discovery.

## End-to-end release test

Use two real Developer-ID-signed/notarized builds with increasing numeric
`CFBundleVersion` values; changing only `CFBundleShortVersionString` is not
enough. Before promoting a production release, exercise the same artifacts on
a public test feed/repository:

1. Install the older build in `/Applications` (not from the mounted DMG).
2. Launch twice and choose automatic checks when prompted, or use **Check for
   Updates…** immediately.
3. Verify the update is offered, release notes render, and installation
   relaunches the new bundle without losing the external CoD4 data/profile.
4. Confirm the new bundle version and run one multiplayer join/quit smoke test.
5. Inspect Console.app for the app's Sparkle logs and run
   `codesign --verify --deep --strict` plus Gatekeeper assessment on the result.
6. Clear `SULastCheckTime` only for scheduler testing; Sparkle's default check
   cadence is 24 hours and should not be replaced by an application timer.

Keep Sparkle dSYMs from the official distribution with release symbols for
post-release crash diagnosis.
