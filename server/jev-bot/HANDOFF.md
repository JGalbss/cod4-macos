# Jev bot: handoff

State of `server/jev-bot` on 2026-09-21. Read `DESIGN.md` for the architecture and
`PROTOCOL.md` for the wire contract; this note records what was verified live and what to
watch.

## Verified live (Shipment free-for-all, 2 Jev bots against 2 Bot Warfare bots, 300 s)

Kills/deaths per match. `medium` is bots_skill 4, `hardest` is bots_skill 7.

| brain | opponents | match 1 | match 2 | match 3 | pooled | K/D |
| --- | --- | --- | --- | --- | --- | --- |
| scripted control (`eval1-scripted-*`) | medium | 52/14 | 56/12 | 48/7 | 156/33 | 4.73 |
| Jev v1, chased forgotten enemies (`eval1-jev-*`) | medium | 36/7 | 45/8 | 41/15 | 122/30 | 4.07 |
| Jev v2, current code (`eval2-jev-*`) | medium | 50/19 | 57/9 | 55/13 | 162/41 | 3.95 |
| Jev v2 (`hard1-jev-02`) | hardest | 34/14 | | | 34/14 | 2.43 |
| scripted control (`hard1-scripted-01`, link lag up to 220 s) | hardest | 28/6 | | | 28/6 | 4.67 |
| scripted control (`hard1-scripted-03`, cut at 165 s by an SSH reset) | hardest | 18/6 | | | 18/6 | 3.00 |

Jev v2 request health over the medium round: 4,144 requests, 2 errors (0.05%), p50 latency
about 215 ms, p95 about 305 ms, mean 1,140 input tokens per decision, 2.1 to 2.4 decisions
per second per bot, no command refused by the worker, under 1% rejected as stale.

Honest reading: against medium bots Jev v2 out-kills the scripted control by a little and dies
a little more, so the two brains are close. The executor (aim, fire control, navigation,
auto-target) carries most of the result on a map this small; Jev's value shows in kill volume
and in behaviours the scripted brain cannot express (cover, flank, grenade choices), not yet in
kill/death ratio. Match-to-match variance is large (K/D 2.6 to 6.9 for the same brain), so
differences under about 20% need more than three matches to trust.

The hardest-skill rows carry a caveat: the SSH link from the Mac to the host stalled for tens
of seconds several times that night (observation lag up to 67 s, decision cadence down to
1.1 per second, 4 request timeouts), so Jev's choices reached the bots late and the executor's
auto-target did much of the fighting. Three of the four hardest-skill attempts were cut or lagged by SSH resets and stalls
(`ssh-ended-without-cleanup-receipt`, `Connection reset by peer`); `lab/lab.py` now uses
`ServerAliveInterval=15` with `ServerAliveCountMax=8` so a stall under two minutes no longer
ends a match. Repeat `hard1` on a quiet link before quoting it; a controller running on the
host itself would remove the link from the loop entirely.

All `combat-metrics.json` checks pass on every completed medium run above: every bot moved, saw an
enemy, fired, scored, kept a positive kill/death ratio, held cadence, and no command was
refused by the worker. `hard1-jev-01` stopped at 175 s when the SSH session to the host timed
out (network, not the bot); it stood at 31/11 at that point and was rerun as `hard1-jev-02`.

## How the bot works, in one paragraph

The fixture (`game/jev_bot.gsx`) runs perception, memory, Dijkstra navigation, aim tracking
with lead, burst fire control and stance every 50 ms. Its default target is `auto`, so a bot
returns fire at the nearest visible enemy within one tick even before Jev has spoken. Jev is
asked every 400 ms of game time per bot: `move` (cover, toward enemy, unexplored, flank,
chase, hold), `posture`, `weapon` (keep, reload, frag), and `engage` only while an enemy is
visible. Answers become one command line that the fixture holds until the next one. The
state Jev reads is about 250 tokens; the questions carry the option semantics.

## Map knowledge (added after the first evaluation)

The fixture traces eye-height sightlines between every pair of waypoints at match start
(`mapSightDump`, 75 `map_sight` events in the first second). `src/map.ts` turns them into
place words with exposure ("north lane (open)", "south-west corner (enclosed)"), real cover
(nodes the enemy's expected node cannot see), real flanks (nodes that see the enemy's node
from a new side), per-option "sees / hidden from the enemy's expected position", and the
threat lines `enemies_seen_at` and `you_died_at`. The task text describes Shipment's layout.
Measured in `eval3-jev-*` (see the table above once filled in). To port another map: compile
its Bot Warfare waypoints with `tools/compile_waypoints.py`, change `map mp_shipment` in the
worker config, and rewrite the layout sentence in `taskDescription` (`src/run.ts`); the
sightline dump and place words need no per-map work.

## Search and Destroy on Nuketown

`--game-mode sd --map mp_nuketown` runs a full multi-round match (`scr_sd_roundlimit 0`,
`scr_sd_scorelimit 5`, `scr_sd_roundswitch 3`, 2.5 min rounds). The mod fast-restarts the
map between rounds; the fixture survives it by keeping ids, lives, sequence counters and the
match clock in `pers[]` and `game[]` and re-adopting its bots from the connected replay
(`adoptAsJevBot`). Verified in `artifacts/jev-bot/sd-09`: four rounds, bots re-adopted each
time, sequences monotonic, bomb planted and detonated in two rounds.

Planting for a test client needs three things the stock code does not give it: the gameobject's
use trigger event never fires for bots, so the fixture runs `_gameobjects::useHoldThink`
itself with the briefcase weapon blanked (bots never complete a weapon switch); every attack
button must be released first or the hold loop rejects it at once; and the hold must be
committed for its 5 s regardless of Jev's next decision. Defusing uses `level.sdDefuseObject`,
which the worker patches into the private `sd.gsx`.

Strategy layer: `src/rounds.ts` keeps per-round history (sites tried, planted, won) that the
state shows as `objective.history`; teammates appear with their goal and whether they are
planting; `approach_<L>` (a node the site cannot see) and `overwatch_<L>` (a node that sees it)
join `site_<L>` in the move question; the instructions push variety and pairing. Jev bots take the attacking side the map defines;
Bot Warfare bots defend. The fixture emits an `objective` observation part (role, sites with
distance, bearing, planted, occupied, touching; bomb and round clocks), accepts `g=site<L>` and
`w=plant|defuse`, and reports `plant_start`, `plant_done`, `bomb_planted`, `bomb_defused`,
`bomb_exploded` events; metrics count `plants` per bot. Waypoints for a new map come from
`tools/compile_waypoints.py <map>` after vendoring Bot Warfare's `<map>_wp.csv` and pinning
its sha in `EXTRA_WAYPOINT_SHA256`. Results of the first Search and Destroy runs are in
`artifacts/jev-bot/sd-0*` (see the end of this note).

## Bigger maps and navigation

Highrise (`--map mp_highrise`, 237 waypoints) exposed two faults that Shipment hid. A waypoint
link that needs a mantle stalled a bot for two thirds of a match; links that stall are now
blocked for the rest of the match (`link_blocked` event, honoured by both path searches). With
no enemy known the bots only had "unexplored" options within 400 units and orbited spawn; the
move question now also offers far regions (one per compass sector, at least 30% of the map
span away) and the state carries `map_coverage` with the unvisited regions.

## Playing against the bot

`tools/play.sh [seconds] [bots]` (free-for-all, `LOADOUT=sniper|assault|...`) and
`tools/play_sd.sh` (Search and Destroy on Nuketown) start a match on UDP 28990 with game
password `rogo`; `ufw allow 28990/udp` must exist on the host. The client joins with
`open -a "/Applications/jgalbs cod4.app" --args +set password rogo +connect 159.65.37.227:28990`.
Kill cams are on for joinable matches only. Stop a match with `pkill -TERM -f "src/run.ts --brain jev"`
and check the host for a leftover server holding the port before starting another.

## Live server: Josh bots from the web panel

The same fixture ships inside the live mod (`tools/deploy_live.py` installs `code/jev_bot.gsx`,
the CSV waypoint loader, the init/_teams/player/sd hooks and all 360 Bot Warfare waypoint
files under `scriptdata/waypoints/`). It sleeps until the panel sets `jev_enabled 1`. The
controller runs as the `jev-bots` systemd service (`src/run.ts --live`), tails
`jev_telemetry.jsonl` in the mod directory through `lab/live_worker.py`, and sends commands
by rcon on 127.0.0.1:28961. The API key comes from `/etc/cod4-control/jev-bots.env`
(root, 0600). Logs: `/var/log/jev-bots.log`; runs: `/var/lib/jev-bots/run-*/events.jsonl`.

The panel's "Josh bots" section talks to the fixture through dvars: `jev_request`
(`add|<allies|axis|autoassign>|<name>` or `remove|<name|all>`), `jev_request_result`,
`jev_roster` (`id:name:team,...`). The wanted roster persists in `jev_roster_wanted`, because
the engine drops test clients on every map change and the next map's `main()` adds them back.
Disable removes every bot and clears the wanted list. Unsupported maps or modes (no waypoint
file, Gun Game, ...) keep the fixture idle but answering: the panel shows the reason. Bots
hold ids 0..7 on a live server and every other player gets 8 and up, because ids ride the
wire (`t`, `chase<id>`, `e<id>` accept two digits). Domination and Hardpoint run as team
deathmatch for now; flags and hills are not yet in the objective view.

Rehearse on the mod copy before touching the live mod: `/opt/cod4/mods/jev_live_test` with a
private server on 127.0.0.1:28985 (`developer 1` makes script errors fatal, which is what
you want there), `/tmp/jevrc.py <port> <password-file> <command>` for rcon.

## Traps that cost a run each

- Every wire value must pass three whitelists: `src/command.ts`, `lab/remote_worker.py
  FIELD_FORMS`, and the fixture's `readCommand`. Adding a value to one and not the others
  refuses every command silently; the `noWorkerRejections` check now catches it.
- The observation parser drops any record it cannot validate. If `invalid_observation`
  counts appear in `events.jsonl`, the fixture emitted a field the parser does not accept;
  `tools/probe_state.ts` reproduces the failure offline from `stream.jsonl`.
- Kills, deaths and damage are counted from `[jev-event]` game events, never from
  observation parts, because observations can be dropped or coalesced.
- Chase goals follow a prediction of at most 1.5 s of velocity, and the final leg of a path
  stops at the goal node when the goal point is behind a wall. Longer horizons walked bots
  into container walls for tens of seconds.
- A dead enemy is forgotten at once on both sides; they respawn elsewhere.
- CoD4x script file calls need the `scriptdata/` prefix spelled out for both `fs_testfile`
  and `fs_fopen`; the waypoint loader returned nothing for hours without it.
- A `thread` started on a fresh test client before it has `pers["team"]` dies in
  `verifyTeam` and, with `developer 1`, takes the server down. Start `controls()` and
  `observations()` only after `joinTeam` succeeds.
- The engine log clock counts from server start, not map start; only the InitGame line's
  `g_mapStartTime` pins it to wall time.
- `nohup ... &` inside an ssh command needs `< /dev/null` and `ssh -n`, and `$!` must be
  captured from the process itself; a stale server keeps the UDP port and the new one dies
  with "Could not bind".

## Cost

One 300 s match with two Jev bots is about 1,500 requests at 1.3k input tokens, about 2M
input tokens. The key is read from `TYPESAFE_API_KEY` only; a 402 stops decisions and the
executor finishes the match on the last commands.

## Next steps worth taking

1. Watch a match with a real client on the private port and note behaviours the metrics
   miss (staring, edge hugging, over-chasing).
2. Tune `MOVE_INSTRUCTIONS` in `src/questions.ts` with `tools/probe_state.ts --ask` on
   recorded states before spending matches; Jev picked chase in about half of all decisions.
3. Try `hard` (bots_skill 5) opponents and 3 to 4 Jev bots; the host holds one server at a
   time and has about 2 GB of RAM free.
4. Compose the native observation plugin block in the worker if eye-height accuracy
   matters (`--native-plugin` is not wired in v1).
