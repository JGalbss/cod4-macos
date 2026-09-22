import { performance } from "node:perf_hooks";
import type { Observation } from "./observation.ts";
import { BotMemory } from "./memory.ts";
import { selectCandidates, type Candidate } from "./candidates.ts";
import type { WaypointGraph } from "./waypoints.ts";
import { commandMessage, type CommandFields, type CommandMessage } from "./command.ts";
import { JevError, type JevErrorCode } from "./jev.ts";
import type { MapKnowledge } from "./map.ts";
import type { RoundLog } from "./rounds.ts";

export type BrainKind = "scripted" | "jev";

export interface DecisionInput {
  readonly obs: Observation;
  readonly memory: BotMemory;
  readonly candidates: readonly Candidate[];
  readonly graph: WaypointGraph;
  /** Sightline knowledge learned from the server during the match; absent in unit tests. */
  readonly map?: MapKnowledge;
  /** Earlier rounds of an objective match; absent outside Search and Destroy and in unit tests. */
  readonly rounds?: RoundLog;
}

export interface ChoiceTrace {
  readonly choice: string;
  readonly confidence: number;
  readonly probabilities: Readonly<Record<string, number>>;
}

export interface DecisionTrace {
  readonly latencyMs: number;
  readonly model: string;
  readonly inputTokens: number;
  readonly outputTokens: number;
  readonly stateTokens: number;
  readonly choices: Readonly<Record<string, ChoiceTrace>>;
}

export interface Decision {
  readonly fields: CommandFields;
  readonly trace: DecisionTrace | undefined;
}

export type Decider = (input: DecisionInput) => Promise<Decision>;

export interface BrainOptions {
  readonly kind: BrainKind;
  readonly decide: Decider;
  readonly graph: WaypointGraph;
  readonly map?: MapKnowledge;
  readonly rounds?: RoundLog;
  readonly send: (message: CommandMessage) => void;
  readonly log: (record: Record<string, unknown>) => void;
  /** Game-time spacing between decisions for one bot. */
  readonly intervalMs?: number;
  /** Wall-clock age of the observation after which a finished decision is dropped instead of sent. */
  readonly maxAgeMs?: number;
  readonly now?: () => number;
}

export interface BrainStats {
  readonly requests: number;
  readonly decisions: number;
  readonly errors: number;
  readonly stale: number;
  readonly errorsByCode: Readonly<Record<string, number>>;
  readonly halted: boolean;
  readonly inputTokens: number;
  readonly outputTokens: number;
  readonly latencies: readonly number[];
}

interface BotSlot {
  readonly memory: BotMemory;
  latest: Observation;
  inFlight: Promise<void> | undefined;
  lastDecisionGameTimeMs: number | undefined;
  previous: CommandFields | undefined;
}

export const DEFAULT_INTERVAL_MS = 400;
const DEFAULT_MAX_AGE_MS = 1_100;

type FailureCode = JevErrorCode | "unknown";

function errorCode(error: unknown): { code: FailureCode; status: number | undefined } {
  if (error instanceof JevError) return { code: error.code, status: error.status };
  return { code: "unknown", status: undefined };
}

/** One decision per bot per interval with one request in flight. A failed request leaves the fixture's held command in place. */
export class Brain {
  readonly #options: BrainOptions;
  readonly #slots = new Map<number, BotSlot>();
  readonly #now: () => number;
  readonly #intervalMs: number;
  readonly #maxAgeMs: number;
  #stopped = false;
  #halted = false;
  #requests = 0;
  #decisions = 0;
  #errors = 0;
  #stale = 0;
  #inputTokens = 0;
  #outputTokens = 0;
  #latencies: number[] = [];
  readonly #errorsByCode: Record<string, number> = {};

  constructor(options: BrainOptions) {
    this.#options = options;
    this.#now = options.now ?? (() => performance.now());
    this.#intervalMs = options.intervalMs ?? DEFAULT_INTERVAL_MS;
    this.#maxAgeMs = options.maxAgeMs ?? DEFAULT_MAX_AGE_MS;
  }

  get kind(): BrainKind {
    return this.#options.kind;
  }

  get stats(): BrainStats {
    return { requests: this.#requests, decisions: this.#decisions, errors: this.#errors, stale: this.#stale, errorsByCode: { ...this.#errorsByCode }, halted: this.#halted, inputTokens: this.#inputTokens, outputTokens: this.#outputTokens, latencies: [...this.#latencies] };
  }

  memoryOf(botId: number): BotMemory | undefined {
    return this.#slots.get(botId)?.memory;
  }

  observe(obs: Observation): void {
    if (this.#stopped) return;
    const slot = this.#slot(obs);
    slot.memory.observe(obs);
    if (!this.#due(slot, obs)) return;
    this.#decide(slot, obs);
  }

  stop(): void {
    this.#stopped = true;
  }

  async settled(): Promise<void> {
    await Promise.all([...this.#slots.values()].map(slot => slot.inFlight ?? Promise.resolve()));
  }

  #slot(obs: Observation): BotSlot {
    const existing = this.#slots.get(obs.botId);
    if (existing === undefined) {
      const created: BotSlot = { memory: new BotMemory(), latest: obs, inFlight: undefined, lastDecisionGameTimeMs: undefined, previous: undefined };
      this.#slots.set(obs.botId, created);
      return created;
    }
    if (existing.latest.lifeId !== obs.lifeId) {
      existing.lastDecisionGameTimeMs = undefined;
      existing.previous = undefined;
    }
    existing.latest = obs;
    return existing;
  }

  #due(slot: BotSlot, obs: Observation): boolean {
    if (this.#halted || !obs.alive || slot.inFlight !== undefined) return false;
    if (slot.lastDecisionGameTimeMs === undefined) return true;
    return obs.gameTimeMs - slot.lastDecisionGameTimeMs >= this.#intervalMs;
  }

  #decide(slot: BotSlot, obs: Observation): void {
    const started = this.#now();
    slot.lastDecisionGameTimeMs = obs.gameTimeMs;
    this.#requests += 1;
    const { graph, map, rounds } = this.#options;
    const candidates = selectCandidates({ obs, memory: slot.memory, graph, map });
    slot.inFlight = Promise.resolve()
      .then(() => this.#options.decide({ obs, memory: slot.memory, candidates, graph, map, rounds }))
      .then(decision => this.#deliver(slot, obs, candidates, decision, started))
      .catch((error: unknown) => this.#failed(slot, obs, error, started))
      .finally(() => {
        slot.inFlight = undefined;
      });
  }

  #deliver(slot: BotSlot, obs: Observation, candidates: readonly Candidate[], decision: Decision, started: number): void {
    const ageMs = Math.round(this.#now() - started);
    if (decision.trace !== undefined) {
      this.#inputTokens += decision.trace.inputTokens;
      this.#outputTokens += decision.trace.outputTokens;
      this.#latencies.push(decision.trace.latencyMs);
    }
    if (this.#stopped) return;
    const fresh = slot.latest.alive && slot.latest.lifeId === obs.lifeId && ageMs <= this.#maxAgeMs;
    if (!fresh) {
      this.#stale += 1;
      this.#options.log({ type: "stale_decision", botId: obs.botId, sequence: obs.sequence, lifeId: obs.lifeId, ageMs });
      return;
    }
    const message = commandMessage(obs, decision.fields);
    this.#decisions += 1;
    slot.previous = decision.fields;
    slot.memory.recordCommand({ gameTimeMs: obs.gameTimeMs, sequence: obs.sequence, fields: decision.fields });
    this.#options.log({ type: "decision", brain: this.#options.kind, botId: obs.botId, sequence: obs.sequence, lifeId: obs.lifeId, gameTimeMs: obs.gameTimeMs, fields: decision.fields, candidates, trace: decision.trace });
    this.#options.send(message);
  }

  #failed(slot: BotSlot, obs: Observation, error: unknown, started: number): void {
    const { code, status } = errorCode(error);
    this.#errors += 1;
    this.#errorsByCode[code] = (this.#errorsByCode[code] ?? 0) + 1;
    this.#options.log({ type: "decision_error", brain: this.#options.kind, botId: obs.botId, sequence: obs.sequence, code, status, latencyMs: Math.round(this.#now() - started), previous: slot.previous });
    if (code !== "billing" || this.#halted) return;
    this.#halted = true;
    this.#options.log({ type: "billing_stop", botId: obs.botId, sequence: obs.sequence });
  }
}
