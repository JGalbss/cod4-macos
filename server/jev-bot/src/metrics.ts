/** Offline analysis of events.jsonl. Never starts a game or contacts a model. */
import type { BrainKind } from "./brain.ts";

type Fields = Readonly<Record<string, unknown>>;

export interface Distribution {
  readonly count: number;
  readonly p50: number | null;
  readonly p95: number | null;
  readonly max: number | null;
  readonly mean: number | null;
}

export interface BotMetrics {
  readonly botId: number;
  readonly observations: number;
  readonly lives: number;
  readonly observedSeconds: number;
  readonly distanceUnits: number;
  readonly observationsWithEnemyVisible: number;
  readonly kills: number;
  /** Bombs this bot planted in Search and Destroy. */
  readonly plants: number;
  readonly deaths: number;
  readonly killDeathRatio: number | null;
  readonly damageDealt: number;
  readonly damageTaken: number;
  readonly shots: number;
  readonly hits: number;
  readonly hitsPerShot: number | null;
  readonly shotsPerKill: number | null;
  readonly timeToFirstKillSeconds: number | null;
  readonly decisions: number;
  readonly commandsSent: number;
  readonly commandsAccepted: number;
  readonly commandsRejected: number;
  readonly rejectionsReportedInObservations: number;
  readonly staleDecisions: number;
  readonly decisionsPerSecond: number | null;
  readonly requestLatencyMs: Distribution;
  readonly tokens: { readonly input: number; readonly output: number; readonly meanInputPerDecision: number | null };
  readonly errorsByCode: Readonly<Record<string, number>>;
}

export interface Check {
  readonly name: string;
  readonly ok: boolean;
  readonly reason: string;
}

export interface Totals {
  readonly kills: number;
  readonly deaths: number;
  readonly damageDealt: number;
  readonly damageTaken: number;
  readonly shots: number;
  readonly hits: number;
  readonly decisions: number;
  readonly commandsSent: number;
  readonly commandsAccepted: number;
  readonly commandsRejected: number;
  readonly requests: number;
  readonly errors: number;
  readonly errorRate: number | null;
  readonly inputTokens: number;
  readonly outputTokens: number;
  readonly requestLatencyMs: Distribution;
}

export interface CombatMetrics {
  readonly brain: BrainKind;
  readonly botCount: number;
  readonly observedSeconds: number;
  readonly bots: readonly BotMetrics[];
  readonly totals: Totals;
  readonly errorsByCode: Readonly<Record<string, number>>;
  /** Commands the worker refused before they reached the server. */
  readonly labRejections: number;
  /** Search and Destroy rounds seen, the final team scores, which team the Jev bots were on, and bombs planted. */
  readonly objective: { readonly rounds: number; readonly scores: Readonly<Record<string, number>>; readonly team: string; readonly plants: number };
  readonly checks: readonly Check[];
}

export interface RunContext {
  readonly brain: BrainKind;
  readonly botCount: number;
  readonly requestedSeconds: number;
  readonly stopReason: string;
  readonly exitCode: number | null;
  readonly fatalReason: string | undefined;
  readonly inputTokenBudget: number;
  readonly targetDecisionsPerSecond: number;
}

interface BotAccumulator {
  botId: number;
  observations: number;
  lives: Set<number>;
  firstGameTimeMs: number | undefined;
  lastGameTimeMs: number | undefined;
  lastPos: readonly number[] | undefined;
  lastLifeId: number | undefined;
  distance: number;
  enemyVisible: number;
  kills: number;
  plants: number;
  deaths: number;
  damageDealt: number;
  damageTaken: number;
  shots: number;
  hits: number;
  firstKillGameTimeMs: number | undefined;
  decisions: number;
  commands: number;
  accepted: number;
  rejected: number;
  rejectedInObservations: number;
  stale: number;
  latencies: number[];
  inputTokens: number;
  outputTokens: number;
  errorsByCode: Record<string, number>;
}

const round = (value: number): number => Math.round(value * 1000) / 1000;

function record(value: unknown): Fields | undefined {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return undefined;
  return Object.fromEntries(Object.entries(value));
}

function finite(value: unknown): number | undefined {
  if (typeof value !== "number" || !Number.isFinite(value)) return undefined;
  return value;
}

function list(value: unknown): readonly unknown[] {
  return Array.isArray(value) ? value : [];
}

export function distribution(values: readonly number[]): Distribution {
  const sorted = values.filter(Number.isFinite).toSorted((a, b) => a - b);
  const percentile = (p: number): number | null => (sorted.length === 0 ? null : round(sorted[Math.max(0, Math.ceil(sorted.length * p) - 1)]));
  const last = sorted.at(-1);
  return { count: sorted.length, p50: percentile(0.5), p95: percentile(0.95), max: last === undefined ? null : round(last), mean: sorted.length === 0 ? null : round(sorted.reduce((a, b) => a + b, 0) / sorted.length) };
}

function ratio(numerator: number, denominator: number): number | null {
  return denominator === 0 ? null : round(numerator / denominator);
}

/** Kills per death; with no deaths the kill count stands in, and with nothing at all there is no ratio. */
function killDeathRatio(kills: number, deaths: number): number | null {
  if (deaths > 0) return round(kills / deaths);
  if (kills === 0) return null;
  return kills;
}

function emptyAccumulator(botId: number): BotAccumulator {
  return { botId, observations: 0, lives: new Set(), firstGameTimeMs: undefined, lastGameTimeMs: undefined, lastPos: undefined, lastLifeId: undefined, distance: 0, enemyVisible: 0, kills: 0, plants: 0, deaths: 0, damageDealt: 0, damageTaken: 0, shots: 0, hits: 0, firstKillGameTimeMs: undefined, decisions: 0, commands: 0, accepted: 0, rejected: 0, rejectedInObservations: 0, stale: 0, latencies: [], inputTokens: 0, outputTokens: 0, errorsByCode: {} };
}

class Accumulators {
  readonly #bots = new Map<number, BotAccumulator>();
  labRejections = 0;
  /** Search and Destroy: latest team scores and the Jev bots' team, from `round_end` events. */
  rounds = 0;
  scores: Record<string, number> = {};
  team = "none";
  plants = 0;

  for(botId: unknown): BotAccumulator | undefined {
    const id = finite(botId);
    if (id === undefined) return undefined;
    const existing = this.#bots.get(id);
    if (existing !== undefined) return existing;
    const created = emptyAccumulator(id);
    this.#bots.set(id, created);
    return created;
  }

  all(): BotAccumulator[] {
    return [...this.#bots.values()].sort((a, b) => a.botId - b.botId);
  }
}

function travelled(bot: BotAccumulator, pos: readonly number[] | undefined, lifeId: number | undefined, alive: boolean): number {
  if (pos === undefined || bot.lastPos === undefined || lifeId !== bot.lastLifeId || !alive) return 0;
  return Math.hypot(pos[0] - bot.lastPos[0], pos[1] - bot.lastPos[1]);
}

function observation(bots: Accumulators, source: Fields): void {
  const obs = record(source.observation);
  const bot = bots.for(obs?.botId);
  if (obs === undefined || bot === undefined) return;
  const time = finite(obs.gameTimeMs);
  const lifeId = finite(obs.lifeId);
  const events = record(obs.events) ?? {};
  const enemies = record(obs.enemies) ?? {};
  const pos = list(obs.pos).map(finite).flatMap(value => (value === undefined ? [] : [value]));
  const alive = obs.alive === true;
  bot.observations += 1;
  if (lifeId !== undefined) bot.lives.add(lifeId);
  bot.firstGameTimeMs = bot.firstGameTimeMs ?? time;
  bot.lastGameTimeMs = time ?? bot.lastGameTimeMs;
  bot.distance += travelled(bot, pos.length === 3 ? pos : undefined, lifeId, alive);
  bot.lastPos = pos.length === 3 ? pos : bot.lastPos;
  bot.lastLifeId = lifeId;
  bot.enemyVisible += list(enemies.visible).length > 0 ? 1 : 0;
  bot.shots += finite(events.shots) ?? 0;
  bot.rejectedInObservations += list(events.rejected).length;
}

function decision(bots: Accumulators, source: Fields): void {
  const bot = bots.for(source.botId);
  if (bot === undefined) return;
  bot.decisions += 1;
  const trace = record(source.trace);
  if (trace === undefined) return;
  const latency = finite(trace.latencyMs);
  if (latency !== undefined) bot.latencies.push(latency);
  bot.inputTokens += finite(trace.inputTokens) ?? 0;
  bot.outputTokens += finite(trace.outputTokens) ?? 0;
}

function decisionError(bots: Accumulators, source: Fields): void {
  const bot = bots.for(source.botId);
  if (bot === undefined) return;
  const code = typeof source.code === "string" ? source.code : "unknown";
  bot.errorsByCode[code] = (bot.errorsByCode[code] ?? 0) + 1;
}

function command(bots: Accumulators, source: Fields): void {
  const bot = bots.for(source.botId);
  if (bot === undefined) return;
  bot.commands += 1;
}

function stale(bots: Accumulators, source: Fields): void {
  const bot = bots.for(source.botId);
  if (bot === undefined) return;
  bot.stale += 1;
}

/** Game events are complete where observations are not: a parser rejection or a coalesced record loses an observation, never an event. */
const GAME_EVENT_ROUTES: Readonly<Record<string, (bots: Accumulators, event: Fields) => void>> = {
  command_accepted: (bots, event) => {
    const bot = bots.for(event.botId);
    if (bot !== undefined) bot.accepted += 1;
  },
  command_rejected: (bots, event) => {
    const bot = bots.for(event.botId);
    if (bot !== undefined) bot.rejected += 1;
  },
  kill: (bots, event) => {
    const bot = bots.for(event.botId);
    if (bot === undefined) return;
    bot.kills += 1;
    bot.firstKillGameTimeMs = bot.firstKillGameTimeMs ?? finite(event.gameTimeMs);
  },
  plant_done: (bots, event) => {
    const bot = bots.for(event.botId);
    if (bot !== undefined) bot.plants += 1;
  },
  round_end: (bots, event) => {
    bots.rounds += 1;
    const scores = record(event.scores) ?? {};
    bots.scores = Object.fromEntries(Object.entries(scores).flatMap(([team, value]) => (typeof value === "number" ? [[team, value]] : [])));
    if (typeof event.team === "string") bots.team = event.team;
  },
  bomb_planted: bots => {
    bots.plants += 1;
  },
  death: (bots, event) => {
    const bot = bots.for(event.botId);
    if (bot !== undefined) bot.deaths += 1;
  },
  damage: (bots, event) => {
    const amount = finite(event.amount) ?? 0;
    const attacker = bots.for(event.attackerId);
    const victim = bots.for(event.botId);
    if (attacker !== undefined) {
      attacker.hits += 1;
      attacker.damageDealt += amount;
    }
    if (victim !== undefined) victim.damageTaken += amount;
  },
};

function gameEvent(bots: Accumulators, source: Fields): void {
  const event = record(source.event);
  const name = typeof event?.event === "string" ? event.event : "";
  const route = Object.hasOwn(GAME_EVENT_ROUTES, name) ? GAME_EVENT_ROUTES[name] : undefined;
  if (route === undefined || event === undefined) return;
  route(bots, event);
}

const ROUTES: Readonly<Record<string, (bots: Accumulators, source: Fields) => void>> = {
  lab_rejected: bots => {
    bots.labRejections += 1;
  },
  observation,
  decision,
  decision_error: decisionError,
  command,
  stale_decision: stale,
  event: gameEvent,
};

function route(bots: Accumulators, line: string): void {
  const source = record(parseLine(line));
  if (source === undefined) return;
  const type = typeof source.type === "string" ? source.type : "";
  const handler = Object.hasOwn(ROUTES, type) ? ROUTES[type] : undefined;
  if (handler === undefined) return;
  handler(bots, source);
}

function parseLine(line: string): unknown {
  try {
    return JSON.parse(line);
  } catch {
    return undefined;
  }
}

function botMetrics(bot: BotAccumulator): BotMetrics {
  const observedSeconds = bot.firstGameTimeMs === undefined || bot.lastGameTimeMs === undefined ? 0 : (bot.lastGameTimeMs - bot.firstGameTimeMs) / 1000;
  return {
    botId: bot.botId,
    observations: bot.observations,
    lives: bot.lives.size,
    observedSeconds: round(observedSeconds),
    distanceUnits: Math.round(bot.distance),
    observationsWithEnemyVisible: bot.enemyVisible,
    kills: bot.kills,
    plants: bot.plants,
    deaths: bot.deaths,
    killDeathRatio: killDeathRatio(bot.kills, bot.deaths),
    damageDealt: bot.damageDealt,
    damageTaken: bot.damageTaken,
    shots: bot.shots,
    hits: bot.hits,
    hitsPerShot: ratio(bot.hits, bot.shots),
    shotsPerKill: ratio(bot.shots, bot.kills),
    timeToFirstKillSeconds: bot.firstKillGameTimeMs === undefined || bot.firstGameTimeMs === undefined ? null : round((bot.firstKillGameTimeMs - bot.firstGameTimeMs) / 1000),
    decisions: bot.decisions,
    commandsSent: bot.commands,
    commandsAccepted: bot.accepted,
    commandsRejected: bot.rejected,
    rejectionsReportedInObservations: bot.rejectedInObservations,
    staleDecisions: bot.stale,
    decisionsPerSecond: observedSeconds === 0 ? null : round(bot.decisions / observedSeconds),
    requestLatencyMs: distribution(bot.latencies),
    tokens: { input: bot.inputTokens, output: bot.outputTokens, meanInputPerDecision: ratio(bot.inputTokens, bot.latencies.length) },
    errorsByCode: { ...bot.errorsByCode },
  };
}

function mergeCounts(counts: readonly Readonly<Record<string, number>>[]): Record<string, number> {
  const merged: Record<string, number> = {};
  for (const entry of counts) {
    for (const [code, count] of Object.entries(entry)) merged[code] = (merged[code] ?? 0) + count;
  }
  return merged;
}

function totals(bots: readonly BotMetrics[], accumulators: readonly BotAccumulator[]): Totals {
  const sum = (pick: (bot: BotMetrics) => number): number => bots.reduce((total, bot) => total + pick(bot), 0);
  const errors = sum(bot => Object.values(bot.errorsByCode).reduce((a, b) => a + b, 0));
  const requests = sum(bot => bot.requestLatencyMs.count) + errors;
  return {
    kills: sum(bot => bot.kills),
    deaths: sum(bot => bot.deaths),
    damageDealt: sum(bot => bot.damageDealt),
    damageTaken: sum(bot => bot.damageTaken),
    shots: sum(bot => bot.shots),
    hits: sum(bot => bot.hits),
    decisions: sum(bot => bot.decisions),
    commandsSent: sum(bot => bot.commandsSent),
    commandsAccepted: sum(bot => bot.commandsAccepted),
    commandsRejected: sum(bot => bot.commandsRejected),
    requests,
    errors,
    errorRate: ratio(errors, requests),
    inputTokens: sum(bot => bot.tokens.input),
    outputTokens: sum(bot => bot.tokens.output),
    requestLatencyMs: distribution(accumulators.flatMap(bot => bot.latencies)),
  };
}

function isDurationElapsed(stopReason: string): boolean {
  return stopReason === "duration_elapsed";
}

function check(name: string, ok: boolean, reason: string): Check {
  return { name, ok, reason };
}

function checks(context: RunContext, bots: readonly BotMetrics[], total: Totals, labRejections: number): Check[] {
  const modelRun = context.brain === "jev";
  const meanInput = total.requestLatencyMs.count === 0 ? null : total.inputTokens / total.requestLatencyMs.count;
  const slowest = bots.map(bot => bot.decisionsPerSecond ?? 0).reduce((low, value) => Math.min(low, value), Infinity);
  const rejectionRate = ratio(total.commandsRejected, total.commandsAccepted + total.commandsRejected);
  return [
    check("allBotsObserved", bots.length === context.botCount, `${bots.length} of ${context.botCount} bots produced observations`),
    check("allMoved", bots.length > 0 && bots.every(bot => bot.distanceUnits > 100), `distances ${bots.map(bot => bot.distanceUnits).join(", ")} units`),
    check("allSawEnemy", bots.length > 0 && bots.every(bot => bot.observationsWithEnemyVisible > 0), `observations with an enemy visible ${bots.map(bot => bot.observationsWithEnemyVisible).join(", ")}`),
    check("allFired", bots.length > 0 && bots.every(bot => bot.shots > 0), `shots ${bots.map(bot => bot.shots).join(", ")}`),
    check("dealtDamage", total.damageDealt > 0, `${total.damageDealt} damage dealt`),
    check("scoredKill", total.kills > 0, `${total.kills} kills`),
    check("positiveKillDeath", total.kills > total.deaths, `${total.kills} kills against ${total.deaths} deaths`),
    check("decisionsFlowing", bots.length > 0 && bots.every(bot => bot.decisions >= 10), `decisions ${bots.map(bot => bot.decisions).join(", ")}`),
    check("decisionCadence", bots.length > 0 && slowest >= context.targetDecisionsPerSecond * 0.6, `slowest bot ${round(slowest)} decisions per second against a target of ${context.targetDecisionsPerSecond}`),
    check("requestErrorsUnder2Percent", (total.errorRate ?? 0) < 0.02, `${total.errors} errors in ${total.requests} requests`),
    check("commandRejectionsUnder5Percent", (rejectionRate ?? 0) < 0.05, `${total.commandsRejected} rejected against ${total.commandsAccepted} accepted`),
    check("noWorkerRejections", labRejections === 0, `${labRejections} commands refused by the worker`),
    check("inputTokenBudget", !modelRun || (meanInput !== null && meanInput <= context.inputTokenBudget), modelRun ? `mean ${meanInput === null ? "n/a" : Math.round(meanInput)} input tokens against a budget of ${context.inputTokenBudget}` : "not a model run"),
    check("durationCompleted", isDurationElapsed(context.stopReason), `stop reason ${context.stopReason}`),
    check("workerExited", context.exitCode === 0, `exit code ${context.exitCode ?? "none"}`),
    check("noFatal", context.fatalReason === undefined, context.fatalReason ?? "no fatal reason"),
  ];
}

export function analyzeEvents(jsonl: string, context: RunContext): CombatMetrics {
  const accumulators = new Accumulators();
  for (const line of jsonl.split("\n")) {
    if (line.trim() === "") continue;
    route(accumulators, line);
  }
  const all = accumulators.all().filter(bot => bot.observations > 0);
  const bots = all.map(botMetrics);
  const total = totals(bots, all);
  const observedSeconds = bots.reduce((longest, bot) => Math.max(longest, bot.observedSeconds), 0);
  return { brain: context.brain, botCount: context.botCount, observedSeconds, bots, totals: total, errorsByCode: mergeCounts(bots.map(bot => bot.errorsByCode)), labRejections: accumulators.labRejections, objective: { rounds: accumulators.rounds, scores: accumulators.scores, team: accumulators.team, plants: accumulators.plants }, checks: checks(context, bots, total, accumulators.labRejections) };
}
