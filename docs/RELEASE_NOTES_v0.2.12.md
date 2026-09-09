# jgalbs cod4 0.2.12 release candidate

Fixes progression resetting after leaving and rejoining the mod server.

- XP, rank, unlocks, and challenges save to the correct profile and mod.
- Progression autosaves during play and flushes before stats/profile reloads.
- Atomic saves preserve the previous good file if a write fails.

Everyone needs this client update; the server does not need a restart.
Quit the old app, open the DMG, replace **jgalbs cod4.app** in Applications,
then launch that copy. Keep using the same player profile. Existing saves,
settings, and maps are preserved outside the app. Progress already lost by an
older build cannot be reconstructed automatically; the server's level control
can restore a known level.

Verified with server-awarded stats in the native client and a separate player
on the live mod server: level 10 / 2,430 XP survived leaving, quitting, and
rejoining in a new client process.
The regression test also reproduces the reset in 0.2.11: earned XP is lost
after a stats reload, and the next session starts at zero. It passes in 0.2.12.

Rust, Terminal, and Scrapyard are bundled; retail CoD4 data is not included.
Requires Apple Silicon and macOS 15.5+. This is an ad-hoc-signed test build,
not Apple-notarized. For a trusted download blocked by Gatekeeper, attempt
to open it, then use System Settings → Privacy & Security → Open Anyway.

Developer regression check:

```sh
COD4_DATA=/path/to/cod4 mac/tools/test-native-stats-persistence.zsh
mac/tools/check-native-regressions.zsh
```
