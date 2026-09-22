# Jev bot: design

A CoD4 bot for private Shipment matches whose tactical decisions come from the TypeSafe
Jev decision model and whose moment-to-moment execution runs inside the game server.
It replaces `server/jev-agent`, which asked Jev eight low-level questions every 250 ms,
froze each answer for a second, and never tracked a target. That bot stalled, stared at
walls, and shot at where enemies had been half a second earlier.

## What "good" means here

Success criteria for the first release:

- Positive kill/death ratio against Bot Warfare `medium` (bots_skill 4) in a 300 s
  Shipment free-for-all, measured over at least three matches.
- Clearly better than a scripted brain on the same executor (the scripted brain is the
  control: it proves the executor, Jev must add value on top).
- Sustained tactical decisions at 2 to 3 per second per bot with under 2% failed requests.
- Under 2,500 input tokens per decision.

## Architecture

```
game server (GSC fixture, 50 ms)          host worker (python)          controller (TypeScript)
perception, memory, navigation,   --obs-->  tail telemetry, join   --ssh-->  build state, ask Jev,
aim tracking, fire control,       <--cmd--  records, validate,     <------   choose command, log,
command application                          rcon set dvar                    metrics
```

Three layers, one contract each.

### 1. Executor (`game/jev_bot.gsx`)

Runs on the private server copy. Every 50 ms per bot:

- **Perception.** Visible enemies: 100 degree cone plus a bullet trace to the eye, with
  a second trace to the chest so partial exposure is known. Teammates. Damage taken in
  the last two seconds with attacker bearing. Gunfire heard: any other player's shots
  within 1,400 units, reported as bearing, distance, age.
- **Memory.** Per enemy: last seen position, velocity, time, and whether the loss of
  sight was ours (we turned) or theirs (they left). Predicted position from velocity for
  up to three seconds.
- **Navigation.** Bot Warfare's 75 Shipment waypoints compiled into
  `game/jev_bot_waypoints.gsx` (credit retained). A* over the graph to the commanded
  goal. `botMoveTo` toward the next node with a 40 unit arrival radius. Stuck detection:
  under 24 units of progress in one second triggers jump, then sidestep, then replan
  through a different neighbour.
- **Aim.** When a target is commanded and visible, aim at its head if exposed, else the
  chest, with lead equal to target velocity times 100 ms. Turn rate: up to 24 degrees
  per tick far from alignment, tapering to 6 degrees inside 10 degrees of error, applied
  with `botLookAt` over one tick. When no target: the commanded look bearing, else the
  predicted position of the freshest remembered enemy, else along the path.
- **Fire control.** Fire only when the angular error is inside the target's apparent
  half-width plus 1 degree and the trace is clear. M16: press 70 ms, release 180 ms
  (one burst per press). ADS when the target is over 260 units away and the weapon is
  ready; hip fire inside that. Reload automatically at 9 rounds or fewer with no target
  visible, or when commanded.
- **Command application.** Commands are held until replaced or until death. Every
  command is admitted against sequence, life, and age (under 1,200 ms) exactly like the
  old fixture, so stale decisions are rejected and logged. The default command after
  a spawn is `t=auto`, so a bot defends itself before its first decision.

### 2. Worker (`lab/remote_worker.py`)

Derived from `jev-agent/remote_lab.py`. Same private copy discipline: temporary root
under `/tmp/cod4-jev-*`, binary hash check, only `.ff`/`.iwd`/`code`/`maps` copied,
fixture inserted after `code\player::init();`, owned server killed at exit. Changes:

- Generic command wire. A command is `sequence life observed key=value ...` with keys
  from a fixed whitelist and values matching `[A-Za-z0-9_.:-]{1,24}`; the worker checks
  the whitelist, the fixture re-validates.
- Observation records `[jev-observation]` carry `part` and are joined per
  `botId, sequence` into one observation before forwarding.
- Optional Bot Warfare opponents: vendored scripts copied into the private mod, the
  opt-out patch applied to the copy so Bot Warfare never adopts Jev-controlled bots, and
  `bots_skill` pinned.

### 3. Controller (`src/`)

- `jev.ts` is the existing client (bearer key from `TYPESAFE_API_KEY`, 900 ms timeout,
  validated answers).
- `state.ts` turns an observation plus memory into the compact state described below.
- `questions.ts` builds the question set from the state; every option is legal by
  construction.
- `brain.ts` runs one decision per bot every 400 ms with one request in flight, maps
  answers to a command, and never blocks the executor: if a request fails the previous
  command stands.
- `scripted.ts` is the control brain: attack the nearest visible enemy, otherwise walk to
  the nearest unexplored node, retreat to cover when health is under 40. Same executor,
  no Jev.
- `metrics.ts` writes `report.json` and `combat-metrics.json`: kills, deaths, damage,
  time to kill, shots per kill, decision cadence, request latency, tokens, errors.

## What Jev sees

One JSON object, about 1,200 to 2,000 tokens. Short keys, plain numbers, no grids.

```json
{
  "task": "Free-for-all on Shipment against 3 bots. Win fights, keep moving, avoid dying.",
  "you": {"hp": 100, "pos": [-120, 340], "facing": 90, "moving": "north 180u/s",
          "weapon": "M16 burst", "clip": 24, "reserve": 90, "ready": true, "stance": "stand",
          "node": 27, "area": "east containers"},
  "enemies_visible": [
    {"id": 2, "name": "bot2", "dist": 310, "bearing": -12, "elev": 0, "exposed": "head_and_body",
     "moving": "toward you", "aim_error": 13, "seen_for": 0.8, "hp_known": false}
  ],
  "enemies_remembered": [
    {"id": 1, "last_seen_s": 4.5, "last_pos": [220, 610], "bearing": 40, "dist": 480,
     "was_moving": "west", "predicted": [80, 610]}
  ],
  "threats": {"damage_taken_2s": 35, "from_bearing": 150, "gunfire_heard": [{"bearing": 150, "dist": 400, "age_s": 0.5}]},
  "movement": {"goal": "node 41 (center crates)", "remaining": 220, "progress_ok": true,
               "options": {"n41": "center crates, 220u, unexplored", "n12": "cover NW corner, 160u",
                           "n33": "toward enemy 1 last seen, 480u", "hold": "stay, cover left"}},
  "recent": {"kills": 1, "deaths": 0, "hits_landed_10s": 4, "shots_10s": 9}
}
```

Wording rules: bearings are degrees relative to the current facing, negative is right.
Distances in game units (about 1 unit = 1 inch). Everything time-based is in seconds.
Nothing is repeated across sections. The map grid is never sent; navigation options carry
their own semantics.

## What Jev knows about the map

The waypoint graph alone cannot say what a place is like, so the fixture traces eye-height
sightlines between every pair of waypoints at match start and emits one `map_sight` event per
node. The controller's `MapKnowledge` turns them into:

- Place words for every node: position (`center`, `north lane`, `east edge`, `south-west
  corner`) plus exposure from how many nodes see it (`open`, `covered`, `enclosed`).
- Real cover: the nearest node the enemy's expected node cannot see, least exposed first.
- Real flanks: nodes that see the enemy's node from at least 50 degrees off the bot's own
  approach.
- Per-option relations: "sees the enemy's expected position" or "hidden from it".
- Threat memory in place words: where enemies were seen in the last 15 s and where the bot
  died in the last minute.

Until all nodes are known, everything falls back to compass words and distance heuristics.
The task text carries a one-paragraph description of Shipment's layout.

## What Jev is asked

Four `choice` questions per decision, all options legal:

1. `engage`, only while an enemy is visible: `attack_<id>` per visible enemy (criteria:
   distance, exposure, current aim error, whether it is shooting us), or `hold_fire`
   (criteria: reloading, or ambush). The executor tracks and fires for the chosen
   target. With nothing visible the question is skipped and the target stays `auto`:
   the executor fires back at the nearest enemy that appears within one 50 ms tick, so
   reaction time never waits on a decision.
2. `move`: `advance_<node>` for up to five candidate nodes with semantics, `chase_<id>`
   toward an enemy seen within the last 6 s, `retreat_<node>` toward cover when an enemy
   is known, and `hold` only while an enemy is visible. Standing still with nothing in
   sight never scores, so it is never offered. Controller memory mirrors the fixture's
   visible and remembered lists every observation, so an enemy the server has forgotten
   (dead, respawned elsewhere) is never offered as a chase.
3. `posture`: `stand` or `crouch`.
4. `weapon`: `keep`, `reload`, `grenade_<id>` (only with ammo and a remembered enemy
   position within 900 units).

Candidate nodes are chosen by the controller from the graph: nearest cover node not
visible from the freshest known enemy position, the node nearest the freshest enemy
prediction, the least recently visited node within 400 units, a flanking node roughly
90 degrees off the enemy bearing, and the current node.

## Cadence and latency

Executor tick 50 ms. Observation 200 ms. Decision 400 ms per bot, one request in
flight. A decision whose observation is older than 1,200 ms when it arrives is rejected
by the fixture and logged as stale. The executor keeps tracking, firing, and walking
between decisions, so latency degrades tactics, not aim.

## Evaluation

- `lab/lab.py --brain scripted` runs the control brain; `--brain jev` the real one.
- `--opponents bot_warfare:<level>:<count>` adds Bot Warfare bots to the same server.
- Every run writes `report.json`, `events.jsonl`, `combat-metrics.json` under
  `artifacts/jev-bot/<run>/`.
- Paired evaluation: same seed layout, same duration, Jev brain against scripted brain,
  each against Bot Warfare `medium`, three matches each.

## Safety and cost

- The API key lives only in the controller process environment and is scrubbed from the
  worker environment and every log.
- The live server under `/opt/cod4` is never modified; only private copies are.
- Match duration is the only run limit. A billing failure (HTTP 402) stops decisions and
  lets the executor finish the match on the last commands.
- The host has about 2 GB of free RAM; one private server per run, never more than two.

## Milestones

1. Executor plus scripted brain kills Bot Warfare `easy` in a 120 s match.
2. Jev brain live end to end; decisions logged; no stale storms.
3. Tuning of state wording and options until Jev beats scripted against `medium`.
4. Report with three matched matches and a handoff note.
