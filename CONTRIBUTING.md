# Contributing to KisakCOD-Switch

This fork ports [KisakCOD](https://github.com/SwagSoftware/KisakCOD) — a
decompilation of Call of Duty 4: Modern Warfare — to the Nintendo Switch via
homebrew (devkitPro + libnx + Atmosphere CFW).

## Before opening a PR

1. **Read [`docs/SWITCH_PORT.md`](docs/SWITCH_PORT.md)** — it describes the
   three port phases and which one we are in. Changes that skip phases tend
   to break things.
2. **Keep PRs focused on one subsystem.** Upstream is divided into
   `gfx_d3d`, `sound`, `win32`, etc. Each PR should touch **one** of these.
3. **Do not distribute CoD4 assets.** This fork is source only. `.iwd`/`.ff`
   files live on the user's SD card, never in the repo.
4. **Preserve upstream compatibility.** When possible, land changes on the
   upstream `master` and keep port-specific work on `port/switch`. Avoids
   drift.

## Commit conventions

[Conventional Commits](https://www.conventionalcommits.org/) is encouraged,
not mandatory:

```
<type>(<scope>): <short description>

[optional body]

[optional footer]
```

Common types: `feat`, `fix`, `refactor`, `perf`, `build`, `ci`, `docs`,
`chore`, `port`. Scopes: subsystems (`gfx`, `sound`, `net`, `posix`,
`switch`, `cmake`, `deps`, etc.).

Example:

```
port(gfx): replace D3DXMatrixIdentity with glm::mat4(1.0f)

The D3DX layer does not exist outside Windows. glm is header-only and
already available via switch-glm on devkitPro.
```

All repo-tracked content (code, comments, docs, commit messages) is written
in **English**.

## Syncing with upstream

The `upstream` remote points to `SwagSoftware/KisakCOD`. To pull changes:

```bash
git fetch upstream
git checkout master
git merge upstream/master
git push origin master
# then rebase port/switch onto the updated master:
git checkout port/switch
git rebase master
```

## Code style

- Follow upstream style (Allman braces, snake_case variables, etc.). Do not
  reformat existing files in feature PRs — open a separate formatting PR if
  needed.
- `.editorconfig` defines baseline EOL/indent rules.

## Changelog

Every user-visible change (non-chore) adds an entry to `CHANGELOG.md` under
`[Unreleased]`, in the appropriate section (Added/Changed/Fixed/Removed/
Security). Releases promote `[Unreleased]` into a versioned section.

## License

This project is GPL-3.0, inherited from upstream. Any contribution is
automatically licensed under the same terms. You must have the right to
contribute the code you submit.
