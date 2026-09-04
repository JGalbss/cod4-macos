# Release

The release product is named exactly `jgalbs cod4`. The package script creates:

- `dist/jgalbs cod4.app`
- `dist/cod4-macos-arm64.dmg`
- `dist/cod4-macos-arm64.dmg.sha256`

A local ad-hoc package is useful for development. It is not a public release.
Public distribution is gated on Developer ID signing, Apple notarization and
stapling, final-artifact testing, and exact public GPL corresponding source.
Those credentialed public-release steps have not yet been completed.

## 1. Prepare a clean source revision

The exact release source must be committed and publicly reachable at
[`JGalbss/cod4-macos`](https://github.com/JGalbss/cod4-macos). Confirm that the
source revision contains all build and packaging scripts but no retail data,
profiles, logs, private signing material, app bundles, DMGs, or downloaded
vendor binaries.

The native build must use public OpenAssetTools revision
[`0ad64096aa6ee2874f835fff8a5c6dc4af8c7f77`](https://github.com/JGalbss/OpenAssetTools/commit/0ad64096aa6ee2874f835fff8a5c6dc4af8c7f77)
with its recursively pinned submodules. Review `LICENSE`, `NOTICE`, and
`THIRD_PARTY_NOTICES.txt` before each source release.

Do not package from a dirty worktree. Record the intended revision:

```zsh
git status --short
RELEASE_REVISION="$(git rev-parse HEAD)"
SOURCE_CODE_URL="https://github.com/JGalbss/cod4-macos/tree/${RELEASE_REVISION}"
```

## 2. Set versions and build

Increase both `CFBundleShortVersionString` and the numeric `CFBundleVersion` in
`mac/Info.plist`. Sparkle requires a greater `CFBundleVersion` to offer an
update.

Build the pinned SDL2 compatibility and SDL3 runtime artifacts, fetch the
pinned Sparkle distribution, configure the updater-enabled Metal build, and
build the CMake target. Follow [Development](DEVELOPMENT.md) first to build the
pinned OAT checkout, and see the
[pinned SDL runtime guide](../mac/sdl2/README.md) for the exact SDL2/SDL3 source,
hash, architecture, and deployment-target contract.

```zsh
mac/tools/fetch-build-sdl2-compat.zsh
mac/updater/fetch_sparkle.zsh
OAT_DIR="$(cd ../OpenAssetTools && pwd)"
cmake -S . -B build-metal -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.5 \
  -DKISAK_TARGET=posix \
  -DKISAK_METAL=ON \
  -DKISAK_SPARKLE_UPDATER=ON \
  -DOAT_ROOT="${OAT_DIR}"
cmake --build build-metal --target kisak_posix -j4
```

Before packaging, confirm the executable exists and is arm64:

```zsh
file 'bin/posix/jgalbs cod4'
```

## 3. Build a local package

With no signing variables, the script produces an ad-hoc-signed development
bundle. It embeds runtime libraries, removes build-machine Homebrew paths,
adds license/source notices, creates the DMG, and writes its checksum.
Development packages keep manual **Check for Updates…** available but disable
scheduled checks so they do not poll a production feed before one is live.
The public source export intentionally has no application mark: provide a
square PNG that you own or are authorized to redistribute. Setting the path
does not grant rights to the image.

```zsh
APP_ICON_SOURCE=/absolute/path/to/authorized-square-icon.png \
SOURCE_CODE_URL="${SOURCE_CODE_URL}" \
mac/package_native_app.sh
mac/tools/verify-bundled-sdl.zsh 'dist/jgalbs cod4.app'
mac/updater/verify_updater_bundle.zsh 'dist/jgalbs cod4.app'
(cd dist && shasum -a 256 -c cod4-macos-arm64.dmg.sha256)
hdiutil verify dist/cod4-macos-arm64.dmg
```

Mount the DMG, drag the app to `/Applications`, launch it from there, select a
legally owned data directory, and run the smoke/regression checks. Never test
only the app left in the build tree.

For a repeatable local install, validate the DMG first with a dry run and then
install it. The helper refuses to overwrite an existing app unless `--replace`
is explicit; replacement preserves the prior app as
`/Applications/jgalbs cod4.app.previous`. It never removes quarantine
attributes, and it leaves the Dock unchanged by default.

```zsh
mac/tools/install-local-app.zsh \
  --source dist/cod4-macos-arm64.dmg \
  --dry-run
mac/tools/install-local-app.zsh \
  --source dist/cod4-macos-arm64.dmg
```

Dock placement is a separate opt-in and uses `dockutil` for the current user:

```zsh
brew install dockutil
mac/tools/install-local-app.zsh \
  --source dist/cod4-macos-arm64.dmg \
  --replace \
  --add-to-dock
```

## 4. Developer ID and notarization gate

Store notarization credentials in the Keychain with `xcrun notarytool
store-credentials`; do not put credentials in scripts or environment files.
Then run publish mode with the real identity/profile and exact source URL:

```zsh
PUBLISH_RELEASE=1 \
CODE_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' \
NOTARYTOOL_PROFILE='jgalbs-cod4-notary' \
APP_ICON_SOURCE=/absolute/path/to/authorized-square-icon.png \
SOURCE_CODE_URL="${SOURCE_CODE_URL}" \
mac/package_native_app.sh
```

Publish mode fails closed if the identity, notary profile, or source URL is
missing. It notarizes and staples the final DMG before computing the checksum,
then runs code-signing and Gatekeeper checks. A successful command is still not
a substitute for installing and exercising the final artifact on another
supported Apple Silicon Mac.

## 5. Prepare a Homebrew cask

Only after publish mode succeeds, generate a cask from the exact notarized DMG:

```zsh
mac/tools/prepare-homebrew-cask.zsh \
  --tag v0.2.0 \
  --source-sha "${RELEASE_REVISION}"
```

The generator verifies the checksum, stapling, Gatekeeper acceptance,
Developer ID signature, hardened runtime, arm64 architecture, bundle metadata,
and source notices. It rejects the current ad-hoc development package and never
publishes anything. See the [Homebrew preparation guide](../mac/homebrew/README.md)
for the separate tap review workflow.

## 6. Prepare the signed Sparkle update

Sparkle's private Ed25519 seed belongs in the login Keychain or an encrypted
offline backup, never in Git or on the update host. The signed production feed
contains one full latest archive; GitHub Releases preserve older immutable
versions. The generic Homebrew DMG is staged separately under
`dist/release/TAG` so Sparkle never scans a duplicate bundle version.
After the notarized DMG exists:

```zsh
GITHUB_REPOSITORY=JGalbss/cod4-macos \
RELEASE_TAG=v0.2.0 \
RELEASE_SOURCE_SHA="${RELEASE_REVISION}" \
RELEASE_NOTES=docs/RELEASE_NOTES_v0.2.0.md \
mac/updater/prepare_update_release.zsh

RELEASE_SOURCE_SHA="${RELEASE_REVISION}" \
  mac/updater/publish_github_release.zsh JGalbss/cod4-macos v0.2.0
```

The publisher creates or updates a draft and verifies its assets. Draft assets
are not available through GitHub's `releases/latest` endpoint, so the exact
old-to-new update test must use a separate public staging feed/repository or a
notarized staging build pointed directly at the candidate appcast. Do not claim
that a production build discovered a draft through `releases/latest`. After the
staging update installs, relaunches, preserves external data/profile state, and
passes a multiplayer join/quit smoke test, promote the draft:

```zsh
gh release edit v0.2.0 \
  --repo JGalbss/cod4-macos \
  --draft=false \
  --latest
```

## Current public-binary blockers

- The exact exported source revision must pass public clean-clone arm64 CI
  before that revision is used for packaging.
- The final DMG must pass multiplayer smoke/regression testing on a clean,
  supported Apple Silicon Mac.
- The release must be signed with the owner's Developer ID Application identity.
- The final DMG must pass Apple notarization, stapling, and Gatekeeper assessment.
- The signed Sparkle old-to-new update flow must be exercised with final assets.
