# Bot Warfare: provenance and license notice

Files under this directory come from ineedbots' IW3 Bot Warfare, a GSC mod that adds
scripted bots to Call of Duty 4 servers running CoD4X.

| Field | Value |
| --- | --- |
| Repository | https://github.com/ineedbots/iw3_bot_warfare |
| Commit | `901895a10dee921142cf4228c467f99013b5b6c4` (master, 2025-05-21T18:24:17Z, "unused") |
| Version string | `level.bw_version = "2.3.0"` (unreleased master; the last tagged release is v2.2.0, commit `7b52b462e40fa68287b9e54602e52da83b17766c`, 2024-01-13) |
| Author | INeedGames / INeedBot(s), ineedbots@outlook.com |
| Credits named upstream | CoD4x Team, PeZBot team, Ability, Salvation |

## License

The repository has no LICENSE file and GitHub reports no detected license (checked
2026-09-20 through the repository API). The author's terms are in the README.txt of
the release archive `iw3bw220.zip` (v2.2.0, GitHub release of 2024-01-13), copied
verbatim to `UPSTREAM-RELEASE-README.txt` next to this file:

> Feel free to use code, host on other sites, host on servers, mod it and merge mods
> with it, just give credit where credit is due!
> -INeedGames/INeedBot(s) @ ineedbots@outlook.com

This grant covers using the code, running it on servers, modifying it and merging it
with other mods, with attribution. It is not an OSI-approved license text. Our use is
a private research server (the connected-learner duel arena) that runs the unmodified
scripts; the attribution above and the `opponent.source` block of the runtime's
`oracle-arena.json` carry the credit. Do not redistribute these files without this
notice.

## What is vendored

Only the files the server mod needs to run one bot on `mp_shipment`, byte-identical to
the commit (CRLF line endings preserved):

| File | Purpose |
| --- | --- |
| `maps/mp/bots/_bot.gsc` | Mod init, dvar defaults, connect hooks, management loops (pinned off by our fixture) |
| `maps/mp/bots/_bot_internal.gsc` | Per-bot movement, aim, trigger, stance and reaction logic |
| `maps/mp/bots/_bot_script.gsc` | Per-bot difficulty table, class and team choice, weapon and grenade behaviour, objectives |
| `maps/mp/bots/_bot_utility.gsc` | Waypoint loader, A* pathing, builtin wrappers, `BotFreezeControls` |
| `maps/mp/bots/_bot_chat.gsc` | Bot chatter (rate pinned to 0) |
| `maps/mp/bots/_menu.gsc` | In-game host menu (pinned off) |
| `maps/mp/bots/_wp_editor.gsc` | Waypoint editor (pinned off) |
| `maps/mp/bots/waypoints/_custom_map.gsc` | Fallback waypoint script (unused: the CSV loads) |
| `scripts/mp/bots_adapter_cod4x.gsc` | Maps the mod's builtin table to the CoD4X engine calls `botaction`, `botmoveto`, `botstop`, `setplayerangles`, `fs_fopen`, `fs_readline`, `fs_testfile` |
| `scriptdata/waypoints/mp_shipment_wp.csv` | 75 authored waypoints for mp_shipment |

Not vendored: `maps/mp/gametypes/_callbacksetup.gsx` (our mod has its own; the fixture
threads the Bot Warfare init functions itself), the `scripts/mp/bots*.gsc` one-line
shims, `scriptdata/botnames.txt` (the fixture adds its bot through `addTestClient`),
the other maps' waypoints, the editor assets and the README.

SHA-256 of every vendored file is pinned in `server/cod4-ai/cod4_ai/bot_warfare_opponent.py`
(`VENDOR_SHA256`); the composed runtime worker refuses to stage a file whose hash differs.
