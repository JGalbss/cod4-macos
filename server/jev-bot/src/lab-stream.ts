import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import type { Readable, Writable } from "node:stream";
import { parseObservation, type Observation } from "./observation.ts";
import type { CommandMessage } from "./command.ts";
import type { BrainKind } from "./brain.ts";

export type GameMode = "dm" | "war" | "sd" | "dom" | "koth";
type Fields = Readonly<Record<string, unknown>>;

/** The subset of a child process the stream needs, so tests can inject a fake. */
export interface LabProcess {
  readonly stdin: Writable;
  readonly stdout: Readable;
  readonly stderr: Readable;
  on(event: "close", listener: (code: number | null) => void): unknown;
  on(event: "error", listener: (error: Error) => void): unknown;
}

export interface SpawnOptions {
  readonly cwd: string;
  readonly env: NodeJS.ProcessEnv;
}

export type SpawnLab = (command: string, args: readonly string[], options: SpawnOptions) => LabProcess;

export interface LabArguments {
  readonly seconds: number;
  readonly bots: number;
  readonly gameMode: GameMode;
  readonly brain: BrainKind;
  readonly output: string;
  readonly port: number | undefined;
  readonly ssh: string | undefined;
  readonly nativePlugin: string | undefined;
  readonly spawnLayout: number | undefined;
  readonly opponents: string | undefined;
  /** Game password for a match a human joins; the server then binds every interface. */
  readonly public: string | undefined;
  readonly map: string | undefined;
  readonly waypoints: string | undefined;
  readonly loadout: string | undefined;
}

export type LabMessage =
  | { readonly kind: "ready"; readonly message: Fields }
  | { readonly kind: "observation"; readonly observation: Observation }
  | { readonly kind: "event"; readonly event: Fields }
  | { readonly kind: "done"; readonly message: Fields }
  | { readonly kind: "error"; readonly message: Fields }
  | { readonly kind: "invalid_observation" }
  | { readonly kind: "invalid_event" }
  | { readonly kind: "lab_rejected"; readonly reason: string }
  | { readonly kind: "invalid_line" }
  | { readonly kind: "unknown"; readonly type: string };

export interface LabStreamOptions {
  /** When set, launched verbatim instead of lab.py with `labArguments`: the live worker on the host itself. */
  readonly commandArgs?: readonly string[];
  readonly script: string;
  readonly cwd: string;
  readonly env: NodeJS.ProcessEnv;
  readonly args: LabArguments;
  readonly onMessage: (message: LabMessage) => void;
  readonly onStderr: (line: string) => void;
  readonly spawn?: SpawnLab;
  readonly command?: string;
}

export const API_KEY_VARIABLE = "TYPESAFE_API_KEY";
const MAX_STDERR_CHARS = 1_000;

/** The credential stays in the controller. The worker never sees it. */
export function scrubEnvironment(env: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  return Object.fromEntries(Object.entries(env).filter(([name]) => name !== API_KEY_VARIABLE));
}

function optionalArgument(flag: string, value: string | number | undefined): string[] {
  if (value === undefined) return [];
  return [flag, String(value)];
}

export function labArguments(script: string, args: LabArguments): string[] {
  return [
    script,
    "--seconds", String(args.seconds),
    "--bots", String(args.bots),
    "--game-mode", args.gameMode,
    "--brain", args.brain,
    "--output", args.output,
    ...optionalArgument("--port", args.port),
    ...optionalArgument("--ssh", args.ssh),
    ...optionalArgument("--native-plugin", args.nativePlugin),
    ...optionalArgument("--spawn-layout", args.spawnLayout),
    ...optionalArgument("--opponents", args.opponents),
    ...optionalArgument("--public", args.public),
    ...optionalArgument("--map", args.map),
    ...optionalArgument("--waypoints", args.waypoints),
    ...optionalArgument("--loadout", args.loadout),
  ];
}

function record(value: unknown): Fields | undefined {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return undefined;
  return Object.fromEntries(Object.entries(value));
}

function parseJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

function observationMessage(message: Fields): LabMessage {
  const observation = parseObservation(message.observation);
  if (observation === undefined) return { kind: "invalid_observation" };
  return { kind: "observation", observation };
}

/** The worker refused a command before it reached the server; every one of these is a controller bug. */
const LAB_REJECTION = "[lab] rejected command:";

/** Worker events arrive either parsed under `event` or as the raw `[jev-event] {json}` line. */
function eventMessage(message: Fields): LabMessage {
  const parsed = record(message.event);
  if (parsed !== undefined) return { kind: "event", event: parsed };
  const line = message.line;
  if (typeof line !== "string") return { kind: "invalid_event" };
  if (line.startsWith(LAB_REJECTION)) return { kind: "lab_rejected", reason: line.slice(LAB_REJECTION.length).trim() };
  const start = line.indexOf("{");
  if (start < 0) return { kind: "invalid_event" };
  const event = record(parseJson(line.slice(start)));
  if (event === undefined) return { kind: "invalid_event" };
  return { kind: "event", event };
}

const ROUTES: Readonly<Record<string, (message: Fields) => LabMessage>> = {
  ready: message => ({ kind: "ready", message }),
  observation: observationMessage,
  event: eventMessage,
  done: message => ({ kind: "done", message }),
  error: message => ({ kind: "error", message }),
};

export function parseLabLine(line: string): LabMessage {
  const message = record(parseJson(line));
  if (message === undefined) return { kind: "invalid_line" };
  const type = typeof message.type === "string" ? message.type : "";
  const route = Object.hasOwn(ROUTES, type) ? ROUTES[type] : undefined;
  if (route === undefined) return { kind: "unknown", type };
  return route(message);
}

const spawnChild: SpawnLab = (command, args, options) => spawn(command, [...args], { cwd: options.cwd, env: options.env, stdio: ["pipe", "pipe", "pipe"] });

/** Runs `python3 lab/lab.py`, reads its JSON lines, and writes command lines to its stdin. */
export class LabStream {
  readonly #options: LabStreamOptions;
  #child: LabProcess | undefined;
  #stopSent = false;
  #resolveClosed: (code: number | null) => void = () => {};
  readonly closed: Promise<number | null>;

  constructor(options: LabStreamOptions) {
    this.#options = options;
    this.closed = new Promise(resolve => {
      this.#resolveClosed = resolve;
    });
  }

  start(): void {
    if (this.#child !== undefined) return;
    const launch = this.#options.spawn ?? spawnChild;
    const argv = this.#options.commandArgs ?? labArguments(this.#options.script, this.#options.args);
    const child = launch(this.#options.command ?? "python3", argv, { cwd: this.#options.cwd, env: scrubEnvironment(this.#options.env) });
    this.#child = child;
    child.on("close", code => this.#resolveClosed(code));
    child.on("error", () => this.#options.onMessage({ kind: "error", message: { type: "error", reason: "worker_launch_failed" } }));
    child.stdin.on("error", () => this.#options.onMessage({ kind: "error", message: { type: "error", reason: "worker_pipe_closed" } }));
    createInterface({ input: child.stdout }).on("line", line => this.#options.onMessage(parseLabLine(line)));
    createInterface({ input: child.stderr }).on("line", line => this.#options.onStderr(line.slice(0, MAX_STDERR_CHARS)));
  }

  send(message: CommandMessage): void {
    this.#write(JSON.stringify(message));
  }

  stop(): void {
    if (this.#stopSent) return;
    this.#write(JSON.stringify({ type: "stop" }));
    this.#stopSent = true;
    this.#child?.stdin.end();
  }

  #write(line: string): void {
    const child = this.#child;
    if (child === undefined || this.#stopSent || child.stdin.destroyed || !child.stdin.writable) return;
    child.stdin.write(`${line}\n`);
  }
}
