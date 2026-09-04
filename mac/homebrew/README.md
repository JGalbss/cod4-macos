# Homebrew cask preparation

This directory contains a template for a future Homebrew tap. Release assets
remain in `JGalbss/cod4-macos`; Homebrew's tap naming convention maps the
shorthand `JGalbss/cod4-macos` to a separate
`JGalbss/homebrew-cod4-macos` repository. Neither this template nor the tap
contains a binary. The application still requires legally owned compatible
Call of Duty 4 data; retail data is never part of the cask or DMG.

## Prepare a cask

First complete the Developer ID, notarization, stapling, checksum, and final
artifact validation in [Release](../../docs/RELEASE.md). Then generate the
cask from the exact release DMG and matching tag:

```zsh
mac/tools/prepare-homebrew-cask.zsh --tag v0.1.0
```

The command fails closed unless all of the following are true:

- The DMG checksum matches `dist/cod4-macos-arm64.dmg.sha256`.
- Apple stapling and Gatekeeper checks accept the DMG.
- The app is an arm64, hardened-runtime Developer ID build accepted by
  Gatekeeper.
- The app identity, version, build number, minimum system version, and GPL
  notices match the release contract, including an exact corresponding-source
  revision in the release repository.

On success it writes `dist/homebrew/Casks/jgalbs-cod4.rb`. It never uploads a
release, creates a tap, commits, or pushes. A local ad-hoc package is expected
to be rejected.

## Review a future tap

After the matching GitHub release URL exists, create or update the tap in a
separate checkout and copy in the generated cask for review:

```zsh
brew tap-new JGalbss/cod4-macos
cp dist/homebrew/Casks/jgalbs-cod4.rb \
  "$(brew --repo JGalbss/cod4-macos)/Casks/jgalbs-cod4.rb"
brew style --cask JGalbss/cod4-macos/jgalbs-cod4
brew audit --cask --online JGalbss/cod4-macos/jgalbs-cod4
```

Publishing `JGalbss/homebrew-cod4-macos` remains a deliberate, credentialed
release action. Once a reviewed tap and notarized release exist, users can
install with:

```zsh
brew install --cask JGalbss/cod4-macos/jgalbs-cod4
```
