# Jev bot

A Jev-driven bot for private CoD4 Shipment matches. Jev (TypeSafe's decision model)
chooses targets, movement goals, posture and weapon actions a few times a second; a
server-side executor tracks, aims, fires and walks the waypoint graph at 20 Hz between
decisions. Design: `DESIGN.md`. Wire contract: `PROTOCOL.md`. Verified results and traps:
`HANDOFF.md`.

## Layout

- `game/jev_bot.gsx` executor fixture, inserted into a private copy of the mod.
- `game/jev_bot_waypoints.gsx` Shipment waypoint graph compiled by
  `tools/compile_waypoints.py` from Bot Warfare's data (credit: INeedGames / INeedBots,
  see `../vendor/bot-warfare/LICENSE-NOTICE.md`).
- `lab/lab.py`, `lab/remote_worker.py` match launcher and host worker.
- `src/` controller: state builder, questions, Jev brain, scripted control brain, metrics.
- `test/` unit tests for the controller (`npm test`) and the worker
  (`python3 -m unittest discover -s test -p 'test_*.py'`).

## Requirements

- Node 22.6+, npm, Python 3, SSH access to the match host (default
  `root@159.65.37.227`) which already holds `/opt/cod4/cod4x18_dedrun`, the base assets
  and `/opt/cod4/mods/new_experience`.
- `TYPESAFE_API_KEY` in the controller's environment. Set it without echoing:

```zsh
read -rs 'TYPESAFE_API_KEY?TypeSafe API key: '
export TYPESAFE_API_KEY
```

The key never leaves the controller process; it is removed from the worker environment
and never written to disk.

## Run

```sh
npm ci --ignore-scripts
npm test && npm run check
# control brain, no Jev calls, 2 Jev bots versus 2 Bot Warfare bots on medium
npm start -- --seconds 120 --bots 2 --opponents bot_warfare:medium:2 --brain scripted --output /abs/new/dir
# Jev brain
npm start -- --seconds 300 --bots 2 --opponents bot_warfare:medium:2 --brain jev --output /abs/new/dir
# Search and Destroy on Nuketown: Jev bots attack, Bot Warfare defends, one round per match
npm start -- --seconds 300 --bots 2 --game-mode sd --map mp_nuketown --opponents bot_warfare:hardest:4 --brain jev --output /abs/new/dir
```

Another map needs its Bot Warfare waypoints: copy `<map>_wp.csv` into
`../vendor/bot-warfare/scriptdata/waypoints/`, pin its sha256 in `EXTRA_WAYPOINT_SHA256`
(`lab/remote_worker.py`), run `python3 tools/compile_waypoints.py <map>`, and pass `--map <map>`.

Every run writes `events.jsonl`, `report.json` and `combat-metrics.json` into the output
directory, and leaves the private server root on the host for inspection.

## Live server

`tools/deploy_live.py --mod /opt/cod4/mods/new_experience --vendor /opt/jev-bots-vendor --service --key-file /etc/cod4-control/jev-bots.env`
installs the fixture, hooks and waypoints into the live mod and writes the `jev-bots` service
(`src/run.ts --live`), which stays attached across map changes and rebriefs the brain for each
map and mode. Scripts load on the next map; the panel's "Josh bots" section enables the bots
and adds or removes them by name and team. See `HANDOFF.md` for the dvar protocol.

## Inspect a run

```sh
# combat per bot, choice distribution per question, latency, tokens, errors
python3 tools/decision_summary.py /abs/run/dir
# replay a recorded bot through the controller and print the state Jev would see;
# --ask sends it to Jev (key from the environment) and prints the answers
node --experimental-strip-types tools/probe_state.ts /abs/run/dir/events.jsonl --bot 1 --pick visible --count 2 --ask
```

`--pick` is one of `visible`, `remembered`, `hurt`, `idle`. Use the probe to tune
wording in `src/questions.ts` and `src/state.ts` before spending a live match.

## Safety

The live server under `/opt/cod4` is never modified. Each run copies the binary and mod
into a fresh `/tmp/cod4-jev-*` root, verifies the binary hash, starts an owned server on
a spare port, and kills it at exit. Match duration is the only run limit.
