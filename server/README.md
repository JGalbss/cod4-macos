# Dedicated server and control plane

This directory contains the public, credential-free deployment source for the
household CoD4X server and its private control plane. It does not contain game
data, player profiles, passwords, SSH keys, or RCON credentials.

The server runs CoD4X with the New Experience mod under systemd. The control
plane is one standard-library Python program that provides:

- a loopback-only web interface;
- an SSH-friendly `cod4ctl` command;
- map, mode, rules, player administration, progression and RCON controls;
- RCON-only per-player god mode, ADS aim lock and through-wall enemy markers.

## Install

Copy legally owned dedicated-server data into `/opt/cod4/main` and
`/opt/cod4/zone/english`. On a new Ubuntu host, review the scripts and run:

```bash
sudo server/provision.sh
sudo COD4_PASSWORD='set-at-deploy-time' \
  COD4_RCON='set-at-deploy-time' \
  server/configure.sh
sudo server/maps.sh
sudo server/control.sh
sudo server/harden.sh
```

Secrets are accepted only at deployment time. `control.sh` installs the RCON
value into `/etc/cod4-control/rcon_password` with mode `0640`; the web service
runs as the unprivileged `cod4` account and never sends that value to a browser.
The web listener is fixed to `127.0.0.1:8787`, so no public admin port is opened.

From a packaged native client, simply run:

```bash
cod4 menu
```

The launcher creates the SSH tunnel and opens the browser. `cod4 menu stop`
closes it; `cod4 server status` and `cod4 server console` expose the same
backend without the website.

The panel's map selector uses the shared `community-maps.json` catalog: 17 MW2
remakes, Nuketown, and retail Crash. Display names remain readable while
commands use the exact installed map IDs. `control.sh` copies the configured rotation into the panel's
`COD4_MAPS` environment setting at installation. After changing that setting,
restart only `cod4-control.service` and refresh the browser panel; restarting
the panel does not restart the game server.

Team moves are RCON-only: `cod4ctl raw 'cmd adminteam:SLOT:allies'` or
`cod4ctl raw 'cmd adminteam:SLOT:axis'`. Switched players choose a class again;
saved loadouts and progression are untouched. To verify current teams, send
`cod4ctl raw 'cmd adminteams:SLOT'` using any connected slot, then query
`cod4ctl raw admin_team_roster`. Newly installed script commands require one
map reload; subsequent team moves do not restart the match.

The same player powers are available over SSH as
`cod4ctl power SLOT {godmode,aimbot,wallhack} {on,off}`. They apply only to the
target's current server session and can always be revoked from the dashboard.

Unused killstreak rewards stack in LIFO order, newest first. Using one restores the next
reward on the same action key, including duplicate rewards earned on later
lives. Cancelled or rejected requests keep the reward. Choose **Killstreaks** in
the in-game pause menu while alive to choose three personal rewards. Use forward/back to move,
Use to toggle or save, and Esc or Melee to cancel. The list scrolls to show every
reward plus Save and Cancel. Saved choices apply on the next
life and persist across reconnects, without removing banked rewards. The pause
button requires the updated native client; `$killstreaks` remains a chat fallback. See
[`KILLSTREAKS.md`](KILLSTREAKS.md) for installation and engine tests.
Comparable rewards use classic MW2 base costs, with the VIP discount disabled;
[`CLASSIC_KILLSTREAKS.md`](CLASSIC_KILLSTREAKS.md) lists costs and custom exceptions.

Headquarters is replaced by **Hardpoint** in the `koth` slot.
The dashboard and CLI accept `hardpoint` / `hp`, with fixed hill rotation,
contested scoring and unlimited respawns. Native client **0.2.14+** renders the
server-authoritative, team-coloured ground boundary; update all players.
See [`HARDPOINT.md`](HARDPOINT.md)
for map compatibility, settings, isolated testing, and rollback.

Sabotage is replaced by **Gun Game** in the `sab` slot. The dashboard accepts
Gun Game and CLI aliases `gg` / `gungame`. Its 20 stock-weapon tiers use normal
animated swaps; melee sets the victim back one tier, with a final knife kill
to win. The dedicated panel configures kills per gun, setbacks and match time
for the next map without restarting a match. See [`GUNGAME.md`](GUNGAME.md).

`maps.sh` installs the 18 checksum-pinned CoD4/IW3 maps in
`community-maps.json`. Keep that catalog and `install-community-map.py` beside
the installer when provisioning. See [`MAPS.md`](MAPS.md) for the full map list,
compatibility rules and unverified requests.

New Experience references three shellshock definitions that only ship in a
single-player zone. `configure.sh` patches its nuke to use the stock multiplayer
`default` shellshock instead. Do not install a private `mod.ff` as a workaround:
CoD4X advertises it as a required client file, so every player must download it
before joining.

## Leaderboard

`/leaderboard` on the panel ranks every player who ever fought on the server. `leaderboard.py`
builds it from the engine log (`games_mp.log`: matches, kills, deaths, headshots, streaks,
weapons, joins and quits) and the mod's journal (`ne_db/leaderboard/events.log`: match wins and
participation) into `/var/lib/cod4-control/leaderboard.sqlite`, incrementally, so history
survives restarts. Identity is the player name: this server has no GUIDs and every install
shares one installation key, so anything keyed by GUID merges everyone into one player.
`code/leaderboard.gsx` in the mod writes the journal with the same name key (`nm_<name>`);
`leaderboard_count_bots 1` lets test clients count during rehearsals.

Filters: time window, mode, map, name search, minimum matches, bots and test clients hidden by
default (and hideable per player). Wins and losses count completed matches with a recorded
winner; in team modes one recorded winner settles the whole team. The API is
`/api/leaderboard`, `/api/leaderboard/filters`, `/api/leaderboard/player?key=` and
`POST /api/leaderboard/hide`.

## Josh bots

The "Josh bots" section adds Jev-driven bots to the live server by name and team; it drives
the fixture in `cod4/server/jev-bot` through the `jev_request` dvars. See `jev-bot/HANDOFF.md`.

## Test

`patch-progression-repair.py` installs an earned Create-a-Class reconciliation
on reconnect. It derives eligibility from saved XP and the mod's rank table,
then repairs the menu feature flag and first-slot access separately. It never
resets rank, replays promotions, or overwrites loadouts. Deploy the helper and
rank hook together, then reload the map when no players are connected. Client
0.2.13 also remembers the mod at startup so the main menu reads that save.

```bash
python3 -m unittest server/test_cod4ctl.py server/test_patch_progression.py \
  server/test_patch_runtime_assets.py server/test_patch_progression_repair.py \
  server/test_patch_hardpoint.py server/test_patch_killstreak_stack.py \
  server/test_patch_killstreak_loadout.py
bash -n server/*.sh
```

CoD4X probes for `steam_api.so` during startup even when this private server
uses no Steam identity features. Its "Steam is not going to work" line is
expected with `sv_authorizemode -1` and does not affect protocol-21 clients,
RCON, progression, or matches. Do not silence it with an untrusted replacement
library; install an authentic compatible Steam API only if Steam identity is
made an explicit server requirement.
