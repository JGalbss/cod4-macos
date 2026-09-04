<!--
Thanks for contributing to the native Apple Silicon client.
Read CONTRIBUTING.md and keep the change focused on one subsystem.
Never attach retail game data, credentials, generated binaries, apps, or DMGs.
-->

## Summary

<!-- What changed, and what user-visible problem does it solve? -->

## Affected subsystem

<!-- Metal / input / audio / network / gameplay / assets / performance /
packaging / build / tests / docs -->

## Validation

<!-- List exact build/test commands, Mac model/chip, macOS version, and the
map/material/gameplay scenario used. Do not include private data paths. -->

## Compatibility and risk

<!-- Note upstream behavior, data-format impact, new dependencies, performance
tradeoffs, and known gaps. -->

## Checklist

- [ ] The native arm64 target builds.
- [ ] Relevant automated or manual checks pass and are listed above.
- [ ] `CHANGELOG.md` is updated under `Unreleased` for a user-visible change.
- [ ] No retail assets, profiles, secrets, local paths, or generated binaries are included.
- [ ] New third-party code has a pinned source and complete license notice.
- [ ] `mac/tools/export-public-source.zsh` still passes.
- [ ] No app or DMG is presented as a release without Developer ID signing,
      Apple notarization, final-DMG validation, and matching GPL source.
