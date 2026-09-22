# Jev bot: wire protocol

Three hops: fixture (GSC, on the server) <-> worker (python, on the host) <-> controller
(TypeScript, local). Every hop is line-oriented JSON except the command wire, which is a
dvar string because the fixture reads it with `getDvar`.

## Command wire: controller -> fixture

The controller sends `{"type":"command","botId":n,"sequence":s,"lifeId":l,"gameTimeMs":t,"fields":{...}}`
on the worker's stdin. The worker validates and runs `rcon set jev_cmd_<n> "<wire>"`.

```
<sequence> <lifeId> <gameTimeMs> key=value [key=value ...]
```

- `sequence`, `lifeId`, `gameTimeMs` are the observation the decision was based on.
  The fixture rejects a command whose sequence is not newer than the last accepted, whose
  life is not the current life, or whose observation is older than 1200 ms.
- Keys and values, all optional, any order, no repeats. Whole wire under 200 bytes.

| key | values | meaning |
| --- | --- | --- |
| `t` | `auto`, `-`, or enemy id `0..7` | target to track. `auto` (the default) tracks the nearest visible enemy and keeps it while it stays visible. `-` clears. |
| `e` | `f` or `h` | fire at the target when aligned, or hold fire. Default `f`. |
| `g` | `n<idx>` waypoint index, `hold`, `chase<id>`, `site<L>` | movement goal. `chase` walks toward the enemy's live or predicted position; `site<L>` (Search and Destroy) walks to bomb site `A` or `B`. |
| `l` | `auto`, integer yaw `-360..360`, `e<id>` | look when no target is visible: automatic (along path or freshest memory), fixed world yaw, or toward remembered enemy id. |
| `s` | `stand`, `crouch`, `prone` | stance. Default `stand`. |
| `r` | `auto`, `on`, `off` | sprint. `auto` sprints with no target and over 200 units of path left. |
| `a` | `auto`, `on`, `off` | ADS. `auto` uses ADS beyond 260 units. |
| `w` | `keep`, `reload`, `nade<x>:<y>:<z>`, `plant`, `defuse` | weapon action. `nade` throws a frag at a world point (integers). One shot; the fixture clears it after the throw. `plant` / `defuse` hold the use button while standing in a bomb zone (Search and Destroy); the fixture clears them when the job is done, impossible, or after 9 s. |

Values match `[A-Za-z0-9_.:-]{1,24}`. Unknown keys are rejected by the worker, so the
fixture never sees them.

A command is held until the next accepted command or the bot's death. Death clears
everything except `s`, `r`, `a`. A freshly spawned bot runs the default command
(`t=auto e=f g=hold`), so it returns fire before the first decision arrives.

## Observations: fixture -> worker -> controller

The fixture prints `[jev-observation] {json}` records and appends them to
`jev_telemetry.jsonl`. Every record is under 1800 bytes because the engine's file write
buffer is 2048 bytes. One observation is five records that share `botId` and `sequence`;
`self` is last and carries `parts`. The worker joins the four and forwards one object
`{"type":"observation","observation":{...}}` to the controller.

### part `enemies`

```json
{"botId":0,"sequence":41,"part":"enemies",
 "visible":[{"id":2,"pos":[x,y,z],"vel":[x,y,z],"dist":310,"bearing":-12,"elev":1,"exposed":"both","seenMs":800}],
 "remembered":[{"id":1,"ageMs":4500,"pos":[x,y,z],"vel":[x,y,z],"bearing":40,"dist":480,"lost":"theirs"}],
 "team":[{"id":3,"pos":[x,y,z],"hp":70}]}
```

- `bearing` is degrees relative to the bot's view yaw; positive left, negative right.
- `elev` is degrees above the horizon. `exposed` is `head`, `body`, `both`, or `none`.
- `remembered` excludes enemies currently visible. `lost` is `ours` when we turned away,
  `theirs` when the trace broke while we still faced them.

### part `nav`

```json
{"botId":0,"sequence":41,"part":"nav","node":27,"goal":"n41","next":33,"remaining":220,
 "progress":54,"stuck":false,"moving":true,"sprinting":false,"path":[27,33,41]}
```

- `node` is the nearest waypoint. `progress` is units moved in the last second.
- `path` is at most 8 indices from the current node to the goal.

### part `events`

Everything since the previous observation of this bot.

```json
{"botId":0,"sequence":41,"part":"events",
 "dmgTaken":[{"from":2,"amount":35,"bearing":150,"ageMs":300}],
 "dmgDealt":[{"to":2,"amount":40,"ageMs":100}],
 "kills":[2],"died":false,"shots":3,"reloadStarted":false,
 "heard":[{"from":1,"bearing":150,"dist":400,"ageMs":500}],
 "rejected":[{"reason":"stale","sequence":39}]}
```

- `heard` lists other players who fired within 1400 units, from any team.
- `bearing` in `dmgTaken` is toward the attacker's position at the time of damage.

### part `objective`

```json
{"botId":0,"sequence":41,"part":"objective","role":"attack","planted":false,"bombLeftMs":-1,"roundLeftMs":124800,
 "sites":[{"label":"A","pos":[992,361,32],"dist":84,"bearing":-79,"planted":false,"occupied":false,"touching":true}]}
```

- `role` is `attack`, `defend`, or `none` outside objective modes. `bombLeftMs` counts down
  once planted; `roundLeftMs` is -1 when the mode has no round clock. `occupied` means another
  player stands in the zone; `touching` means this bot does.

### part `self`

```json
{"botId":0,"sequence":41,"part":"self","parts":4,"gameTimeMs":184250,"lifeId":3,
 "alive":true,"hp":100,"pos":[x,y,z],"vel":[x,y,z],"speed":180,"yaw":90,"pitch":-2,
 "stance":"stand","weapon":"m16_gl_mp","clip":24,"reserve":90,"clipSize":30,"ads":0,
 "ready":true,"reloading":false,"grenades":1,
 "cmd":{"sequence":39,"t":2,"e":"f","g":"n41","l":"auto","s":"stand","r":"auto","a":"auto","w":"keep"},
 "aim":{"target":2,"visible":true,"errorDeg":3.2,"firing":true},
 "native":{"stage":0,"remainingMs":0}}
```

- `ready` means the weapon can fire now. `native` is present only with the observation
  plugin.
- `cmd` echoes the command currently held so the controller can see what is executing.

### Events

`[jev-event] {"event":"...","gameTimeMs":t,...}` records as before: `ready`, `spawn`,
`death`, `kill`, `shot`, `damage`, `command_accepted`, `command_rejected`,
`bot_warfare_ready`, `summary`. The worker forwards them as `{"type":"event","line":...}`.

## Worker <-> controller

Unchanged from `jev-agent`: the controller spawns `lab/lab.py`, which spawns the SSH
worker with the worker source piped as an argument. The controller reads
`stream.jsonl` records (`ready`, `observation`, `event`, `done`) from the lab's stdout
and writes `command` records to its stdin. `lab.py` accepts `--brain scripted|jev`
only as a passthrough label; brains live in the controller.

## Bot Warfare opponents

`lab.py --opponents bot_warfare:<level>:<count>` makes the worker copy the vendored mod
files into the private copy, patch `maps/mp/bots/_bot.gsc` in the copy so any player
with `jevControlled` defined is skipped by `connected()`, `onPlayerDamage`, and
`onPlayerKilled`, pin `bots_skill` and the management dvars, and set `jev_bw_count`
and `jev_bw_skill`. The fixture starts Bot Warfare after the Jev bots have connected
and then adds `count` test clients that Bot Warfare adopts. Credit stays in
`server/vendor/bot-warfare/LICENSE-NOTICE.md`, copied alongside.
