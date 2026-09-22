import { execFileSync } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { JevClient, JevError, type JevResult } from "./jev.ts";
import { loadWaypoints, parseWaypointsCsv, WAYPOINTS_FILE, type WaypointGraph } from "./waypoints.ts";
import { MapKnowledge, type MapSightRecord } from "./map.ts";
import { RoundLog, type RoundEndEvent } from "./rounds.ts";
import { Brain, DEFAULT_INTERVAL_MS, type BrainKind, type Decider } from "./brain.ts";
import { scriptedDecider } from "./brain-scripted.ts";
import { jevDecider } from "./brain-jev.ts";
import { API_KEY_VARIABLE, labArguments as labCommandLine, LabStream, scrubEnvironment, type GameMode, type LabArguments, type LabMessage } from "./lab-stream.ts";
import { analyzeEvents, type CombatMetrics } from "./metrics.ts";

interface RunConfig {
  readonly seconds: number;
  readonly bots: number;
  readonly gameMode: GameMode;
  readonly brain: BrainKind;
  readonly model: string | undefined;
  readonly intervalMs: number;
  readonly timeoutMs: number;
  readonly output: string;
  readonly port: number | undefined;
  readonly ssh: string | undefined;
  readonly nativePlugin: string | undefined;
  readonly spawnLayout: number | undefined;
  readonly opponents: string | undefined;
  readonly public: string | undefined;
  readonly map: string;
  readonly waypoints: string;
  readonly loadout: Loadout;
  readonly opponentCount: number;
  /** Live mode: drive the bots on an already running server through the local live worker. */
  readonly live: boolean;
  readonly telemetry: string | undefined;
  readonly rconPort: number;
  readonly rconPasswordFile: string | undefined;
  readonly waypointsDir: string | undefined;
}

type Log = (record: Record<string, unknown>) => void;

const here = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repo = resolve(here, "../..");
const INPUT_TOKEN_BUDGET = 2_500;
const OPPONENTS = /^bot_warfare:([A-Za-z0-9_ -]+):(\d+)$/;
const GAME_MODES: readonly GameMode[] = ["dm", "war", "sd", "dom", "koth"];
const MAP_NAME = /^mp_[a-z0-9_]{1,40}$/;
type Loadout = "assault" | "specops" | "heavygunner" | "demolitions" | "sniper";
const LOADOUTS: readonly Loadout[] = ["assault", "specops", "heavygunner", "demolitions", "sniper"];
const WEAPON_NOTES: Readonly<Record<Loadout, string>> = {
  assault: "You carry an M16: one aimed burst kills inside 400u, two bursts beyond that; the executor does the aiming and firing at the enemy you pick.",
  specops: "You carry an MP5: deadly inside 300u, weak past 500u, so close the distance; the executor does the aiming and firing at the enemy you pick.",
  heavygunner: "You carry an M249 SAW: a long belt and steady fire at any range but slow handling; the executor does the aiming and firing at the enemy you pick.",
  demolitions: "You carry a W1200 shotgun: one shot kills inside 200u and does nothing past 400u, so fight around corners and containers; the executor does the aiming and firing at the enemy you pick.",
  sniper: "You carry an M40A3 bolt-action sniper: one scoped shot kills at any range if it lands, then about 1.3 s to cycle the bolt, and scoping in takes half a second, so hold long sightlines, never fight inside 200u, and relocate after a shot; the executor scopes, aims and fires at the enemy you pick.",
};
const BRAINS: readonly BrainKind[] = ["scripted", "jev"];

function integerIn(name: string, raw: string | undefined, low: number, high: number): number | undefined {
  if (raw === undefined) return undefined;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < low || value > high) throw new Error(`${name} must be an integer from ${low} to ${high}`);
  return value;
}

function oneOf<T extends string>(name: string, raw: string, allowed: readonly T[]): T {
  const match = allowed.find(option => option === raw);
  if (match === undefined) throw new Error(`${name} must be one of ${allowed.join(", ")}`);
  return match;
}

function mapName(raw: string | undefined): string {
  const name = raw ?? "mp_shipment";
  if (!MAP_NAME.test(name)) throw new Error("--map must look like mp_<name>");
  return name;
}

/** Compiled waypoint tables live beside the fixture: Shipment under the historical name, others by map. */
function waypointsFor(map: string): string {
  return map === "mp_shipment" ? WAYPOINTS_FILE : resolve(here, `game/jev_bot_waypoints_${map}.gsx`);
}

function opponentCount(opponents: string | undefined): number {
  if (opponents === undefined) return 0;
  const match = OPPONENTS.exec(opponents);
  if (match === null) throw new Error("--opponents must look like bot_warfare:<level>:<count>");
  return Number(match[2]);
}

function parseConfig(argv: readonly string[]): RunConfig {
  const { values } = parseArgs({
    args: [...argv],
    options: {
      seconds: { type: "string", default: "300" },
      bots: { type: "string", default: "1" },
      "game-mode": { type: "string", default: "dm" },
      port: { type: "string" },
      ssh: { type: "string" },
      "native-plugin": { type: "string" },
      "spawn-layout": { type: "string" },
      opponents: { type: "string" },
      public: { type: "string" },
      map: { type: "string", default: "mp_shipment" },
      waypoints: { type: "string" },
      loadout: { type: "string", default: "assault" },
      live: { type: "boolean", default: false },
      telemetry: { type: "string" },
      "rcon-port": { type: "string", default: "28961" },
      "rcon-password-file": { type: "string" },
      "waypoints-dir": { type: "string" },
      output: { type: "string" },
      "timeout-ms": { type: "string", default: "900" },
      brain: { type: "string", default: "scripted" },
      model: { type: "string" },
      "interval-ms": { type: "string", default: String(DEFAULT_INTERVAL_MS) },
    },
  });
  const opponents = values.opponents;
  return {
    seconds: integerIn("--seconds", values.seconds, 1, 3600) ?? 300,
    bots: integerIn("--bots", values.bots, 1, 8) ?? 1,
    gameMode: oneOf("--game-mode", values["game-mode"], GAME_MODES),
    brain: oneOf("--brain", values.brain, BRAINS),
    model: values.model,
    intervalMs: integerIn("--interval-ms", values["interval-ms"], 200, 2000) ?? DEFAULT_INTERVAL_MS,
    timeoutMs: integerIn("--timeout-ms", values["timeout-ms"], 100, 5000) ?? 900,
    output: resolve(values.output ?? resolve(values.live ? "/var/lib/jev-bots" : resolve(repo, "artifacts/jev-bot"), `run-${new Date().toISOString().replace(/[:.]/g, "-")}`)),
    port: integerIn("--port", values.port, 1024, 65535),
    ssh: values.ssh,
    nativePlugin: values["native-plugin"] === undefined ? undefined : resolve(values["native-plugin"]),
    spawnLayout: integerIn("--spawn-layout", values["spawn-layout"], 0, 2),
    opponents,
    public: values.public,
    map: mapName(values.map),
    waypoints: values.waypoints === undefined ? waypointsFor(mapName(values.map)) : resolve(values.waypoints),
    loadout: oneOf("--loadout", values.loadout, LOADOUTS),
    opponentCount: opponentCount(opponents),
    live: values.live,
    telemetry: values.telemetry,
    rconPort: integerIn("--rcon-port", values["rcon-port"], 1024, 65535) ?? 28961,
    rconPasswordFile: values["rcon-password-file"],
    waypointsDir: values["waypoints-dir"],
  };
}

/** The fixture's `round_end` event in objective modes: did our side plant, and the scores after the round. */
function roundEndEvent(event: Readonly<Record<string, unknown>>): RoundEndEvent | undefined {
  if (event.event !== "round_end") return undefined;
  const scoresRecord = event.scores;
  const scores = scoresRecord !== null && typeof scoresRecord === "object" ? Object.fromEntries(Object.entries(scoresRecord).flatMap(([team, value]) => (typeof value === "number" ? [[team, value]] : []))) : {};
  return { planted: event.planted === true, team: typeof event.team === "string" ? event.team : "none", scores };
}

/** The `map_sight` event the fixture emits once per waypoint at match start. */
function mapSightRecord(event: Readonly<Record<string, unknown>>): MapSightRecord | undefined {
  if (event.event !== "map_sight" || typeof event.node !== "number" || !Array.isArray(event.sees)) return undefined;
  const sees = event.sees.filter((value): value is number => typeof value === "number");
  return { node: event.node, sees };
}

const MAP_NOTES: Readonly<Record<string, string>> = {
  mp_shipment: "Shipment is a square yard about 1500u across: shipping containers in a rough 3x3 grid leave two lanes running north-south and two running east-west, the center is open ground seen from almost everywhere, the edges and corners are enclosed pockets behind containers where fights are short-range.",
  mp_nuketown: "Nuketown is a small suburban street: two houses face each other across a road with a bus and cars in the middle, back yards behind each house, and the bomb sites sit near the houses; the street is open and seen from both houses, the houses and yards are covered.",
  mp_highrise: "Highrise is a large rooftop: two office buildings at opposite ends joined by a long open middle deck with helipads, air-conditioning units and a crane, plus enclosed office interiors, a lower maintenance walkway under the deck, and a rooftop rim with long sightlines; the middle is wide open and seen from both buildings, the offices and the underpass are covered, and distances run to 2000u.",
};

const MODE_NOTES: Readonly<Record<GameMode, string>> = {
  dm: "Free-for-all; the score is kills minus deaths. Enemies respawn within seconds, and a bot that stands still in the open dies.",
  war: "Team deathmatch; the score is your team's kills minus deaths. Enemies respawn within seconds, and a bot that stands still in the open dies.",
  dom: "Domination, team mode with three flags A, B and C; the team holding more flags scores faster. Capture a flag by standing next to it for ten seconds, defend the ones you hold, and expect enemies to respawn near their flags. Fight as a team: the score is flags held, not kills alone.",
  koth: "Hardpoint, team mode with one moving hill; the team standing in the hill scores. Push to the hill, clear it, hold it from cover nearby, and rotate when it moves. Enemies respawn within seconds.",
  sd: "Search and Destroy, one life per round: attackers win by planting the bomb at site A or B and keeping it alive 45 s until it explodes, or by killing every defender; defenders win by defusing, by killing every attacker, or when the round clock runs out unplanted. Every attacker carries a bomb, so any attacker can plant. Planting or defusing takes 5 s standing still in the zone with your hands busy and cannot be interrupted once begun, so clear the zone first, have a teammate cover you, and watch the round clock.",
};

function taskDescription(config: RunConfig, map: string = config.map, gameMode: GameMode = config.gameMode): string {
  const enemies = gameMode === "dm" ? config.bots - 1 + config.opponentCount : config.opponentCount + Math.floor(config.bots / 2);
  const opponents = config.live ? "You face human players and other bots; the count changes as people join and leave." : `You face ${enemies} enemy bots.`;
  const mapNote = MAP_NOTES[map] ?? `${map} is the map; places are named by position and exposure.`;
  const places = "Places are named by position (center, lane, edge, corner) and by how exposed they are (open, covered, enclosed).";
  return `${MODE_NOTES[gameMode]} ${opponents} ${mapNote} ${places} ${WEAPON_NOTES[config.loadout]}`;
}

function liveGameMode(value: unknown): GameMode {
  return typeof value === "string" && (GAME_MODES as readonly string[]).includes(value) ? (value as GameMode) : "war";
}

function failureRecord(error: unknown): { code: string; httpStatus: number | undefined } {
  if (error instanceof JevError) return { code: error.code, httpStatus: error.status };
  return { code: "unknown", httpStatus: undefined };
}

/** One tiny request before any game time is spent, so auth and billing problems stop the run here. */
async function preflight(client: JevClient, log: Log, output: string, started: number): Promise<JevResult> {
  try {
    const result = await client.evaluate({ purpose: "Jev bot connection check" }, { ready: { type: "choice", instructions: "Select ready.", criteria: { ready: "The interface is ready." } } });
    log({ type: "provider_ready", model: result.model });
    return result;
  } catch (error) {
    const failure = { phase: "provider_preflight", ...failureRecord(error) };
    log({ type: "preflight_failed", ...failure });
    writeFileSync(resolve(output, "report.json"), `${JSON.stringify({ started: new Date(started).toISOString(), failure, gameStarted: false }, null, 2)}\n`);
    console.log(JSON.stringify({ status: "Provider unavailable; game was not started", report: resolve(output, "report.json"), ...failure }));
    process.exit(1);
  }
}

interface ChosenDecider {
  readonly decider: Decider;
  readonly preflight: JevResult | undefined;
  readonly model: string | undefined;
  /** The same brain briefed for another map and mode; a live server changes both. */
  readonly rebrief: (map: string, gameMode: GameMode, graph: WaypointGraph) => Decider;
}

async function chooseDecider(config: RunConfig, graph: WaypointGraph, log: Log, started: number): Promise<ChosenDecider> {
  if (config.brain === "scripted") return { decider: scriptedDecider, preflight: undefined, model: undefined, rebrief: () => scriptedDecider };
  if (process.env[API_KEY_VARIABLE] === undefined) throw new Error(`Set ${API_KEY_VARIABLE} before starting a jev brain`);
  const client = new JevClient({ timeoutMs: config.timeoutMs, model: config.model });
  const checked = await preflight(new JevClient({ timeoutMs: 5000, model: config.model }), log, config.output, started);
  const rebrief = (map: string, gameMode: GameMode, mapGraph: WaypointGraph): Decider => jevDecider({ client, task: taskDescription(config, map, gameMode), graph: mapGraph });
  return { decider: rebrief(config.map, config.gameMode, graph), preflight: checked, model: client.model, rebrief };
}

function labArguments(config: RunConfig): LabArguments {
  return { seconds: config.seconds, bots: config.bots, gameMode: config.gameMode, brain: config.brain, output: config.output, port: config.port, ssh: config.ssh, nativePlugin: config.nativePlugin, spawnLayout: config.spawnLayout, opponents: config.opponents, public: config.public, map: config.map, waypoints: config.waypoints, loadout: config.loadout };
}

/** The live worker tails the running server's telemetry and talks rcon to it; nothing is staged or launched. */
function liveWorkerArguments(config: RunConfig): string[] {
  if (config.telemetry === undefined || config.rconPasswordFile === undefined) throw new Error("--live needs --telemetry and --rcon-password-file");
  return [resolve(here, "lab/live_worker.py"), "--telemetry", config.telemetry, "--port", String(config.rconPort), "--rcon-password-file", config.rconPasswordFile];
}

/** lab.py checks the fixture, waypoints and plugin locally, without SSH, so a bad input never costs a model request. */
function validateLabInputs(config: RunConfig): void {
  const args = [...labCommandLine(resolve(here, "lab/lab.py"), labArguments(config)), "--validate-only"];
  execFileSync("python3", args, { cwd: repo, env: scrubEnvironment(process.env), stdio: "pipe", timeout: 10_000 });
}

function isSummary(event: Readonly<Record<string, unknown>>): boolean {
  return event.event === "summary";
}

async function main(): Promise<void> {
  const config = parseConfig(process.argv.slice(2));
  if (existsSync(config.output)) throw new Error("Output directory must be new");
  mkdirSync(config.output, { recursive: true });
  const started = Date.now();
  const eventsFile = resolve(config.output, "events.jsonl");
  const log: Log = record => appendFileSync(eventsFile, `${JSON.stringify({ elapsedMs: Date.now() - started, ...record })}\n`);
  let graph = loadWaypoints(config.waypoints);
  let map = new MapKnowledge(graph);
  let rounds = new RoundLog();
  if (!config.live) validateLabInputs(config);
  const chosen = await chooseDecider(config, graph, log, started);
  log({ type: "run_started", brain: config.brain, model: chosen.model, seconds: config.seconds, bots: config.bots, gameMode: config.gameMode, opponents: config.opponents, intervalMs: config.intervalMs });

  let fatalReason: string | undefined;
  let done: Readonly<Record<string, unknown>> | undefined;
  let summary: Readonly<Record<string, unknown>> | undefined;
  let stopped = false;
  const lab = new LabStream({
    script: resolve(here, "lab/lab.py"),
    commandArgs: config.live ? liveWorkerArguments(config) : undefined,
    cwd: repo,
    env: process.env,
    args: labArguments(config),
    onStderr: line => log({ type: "worker_stderr", line }),
    onMessage: message => route(message),
  });
  let decider = chosen.decider;
  const buildBrain = (): Brain => new Brain({
    kind: config.brain,
    decide: decider,
    graph,
    map,
    rounds,
    intervalMs: config.intervalMs,
    log,
    send: message => {
      log({ ...message });
      if (message.fields.g.startsWith("site")) rounds.noteSite(message.fields.g.slice(4));
      lab.send(message);
    },
  });
  let brain = buildBrain();
  /** A live server changes maps: load that map's waypoints and start the tactical layer fresh. */
  const changeMap = (mapName: string, gameMode: GameMode): void => {
    if (!config.live || config.waypointsDir === undefined) return;
    const file = resolve(config.waypointsDir, `${mapName}_wp.csv`);
    if (!existsSync(file)) {
      log({ type: "map_unsupported", map: mapName });
      return;
    }
    graph = parseWaypointsCsv(readFileSync(file, "utf8"));
    map = new MapKnowledge(graph);
    rounds = new RoundLog();
    decider = chosen.rebrief(mapName, gameMode, graph);
    brain.stop();
    brain = buildBrain();
    log({ type: "map_changed", map: mapName, gameMode, nodes: graph.nodes.length });
  };
  const stop = (reason?: string): void => {
    if (stopped) return;
    stopped = true;
    fatalReason = reason;
    brain.stop();
    lab.stop();
  };
  const route = (message: LabMessage): void => {
    if (message.kind === "observation") {
      log({ type: "observation", observation: message.observation });
      brain.observe(message.observation);
      return;
    }
    if (message.kind === "event") {
      log({ type: "event", event: message.event });
      if (message.event.event === "ready" && typeof message.event.map === "string") changeMap(message.event.map, liveGameMode(message.event.gameMode));
      const sight = mapSightRecord(message.event);
      if (sight !== undefined) map.learn(sight);
      if (message.event.event === "link_blocked" && typeof message.event.from === "number" && typeof message.event.to === "number") map.blockLink(message.event.from, message.event.to);
      const roundEnd = roundEndEvent(message.event);
      if (roundEnd !== undefined) rounds.roundEnded(roundEnd);
      if (isSummary(message.event) && !config.live) {
        summary = message.event;
        stop();
      }
      return;
    }
    if (message.kind === "ready") {
      log({ type: "ready", ...message.message });
      console.log(JSON.stringify({ status: config.live ? "live controller attached" : "Shipment lab started", output: config.output, root: message.message.root, port: message.message.port }));
      return;
    }
    if (message.kind === "done") {
      log({ type: "done", ...message.message });
      done = message.message;
      stop();
      return;
    }
    if (message.kind === "error") {
      log({ type: "worker_error", ...message.message });
      stop("game_worker_error");
      return;
    }
    if (message.kind === "lab_rejected") {
      log({ type: "lab_rejected", reason: message.reason });
      return;
    }
    log({ type: message.kind });
  };

  lab.start();
  const status = setInterval(() => console.log(JSON.stringify({ status: "running", seconds: Math.round((Date.now() - started) / 1000), decisions: brain.stats.decisions, errors: brain.stats.errors, stale: brain.stats.stale })), 10_000);
  // A lab run has a duration; a live controller stays attached until the service stops it.
  const watchdog = config.live ? undefined : setTimeout(() => stop("run_timeout"), (config.seconds + 90) * 1000);
  process.on("SIGINT", () => stop("interrupted"));
  process.on("SIGTERM", () => stop("interrupted"));
  const exitCode = await lab.closed;
  clearInterval(status);
  if (watchdog !== undefined) clearTimeout(watchdog);
  brain.stop();
  await brain.settled();

  const stats = brain.stats;
  const doneReason = typeof done?.reason === "string" ? done.reason : undefined;
  const summaryReason = typeof summary?.reason === "string" ? summary.reason : undefined;
  const stopReason = fatalReason ?? summaryReason ?? doneReason ?? "unknown";
  const metrics: CombatMetrics = analyzeEvents(readFileSync(eventsFile, "utf8"), {
    brain: config.brain,
    botCount: config.bots,
    requestedSeconds: config.seconds,
    stopReason,
    exitCode,
    fatalReason,
    inputTokenBudget: INPUT_TOKEN_BUDGET,
    targetDecisionsPerSecond: 1000 / config.intervalMs,
  });
  const report = {
    map: "mp_shipment",
    gameMode: config.gameMode,
    botCount: config.bots,
    brain: config.brain,
    model: chosen.model ?? null,
    opponents: config.opponents ?? null,
    spawnLayout: config.spawnLayout ?? null,
    intervalMs: config.intervalMs,
    timeoutMs: config.timeoutMs,
    started: new Date(started).toISOString(),
    durationSeconds: (Date.now() - started) / 1000,
    requestedSeconds: config.seconds,
    exitCode,
    stopReason,
    fatalReason: fatalReason ?? null,
    requests: stats.requests,
    decisions: stats.decisions,
    staleDecisions: stats.stale,
    errors: stats.errors,
    errorsByCode: stats.errorsByCode,
    billingHalted: stats.halted,
    usage: { inputTokens: stats.inputTokens + (chosen.preflight?.usage.input_tokens ?? 0), outputTokens: stats.outputTokens + (chosen.preflight?.usage.output_tokens ?? 0), preflightInputTokens: chosen.preflight?.usage.input_tokens ?? 0 },
    latencyMs: metrics.totals.requestLatencyMs,
    totals: metrics.totals,
    summary: summary ?? null,
    lab: done ?? null,
    checks: metrics.checks,
  };
  writeFileSync(resolve(config.output, "report.json"), `${JSON.stringify(report, null, 2)}\n`);
  writeFileSync(resolve(config.output, "combat-metrics.json"), `${JSON.stringify(metrics, null, 2)}\n`);
  console.log(JSON.stringify({ status: "finished", report: resolve(config.output, "report.json"), checks: metrics.checks.filter(check => !check.ok).map(check => check.name), latencyMs: metrics.totals.requestLatencyMs }));
  if (metrics.checks.some(check => !check.ok)) process.exitCode = 1;
}

await main();
