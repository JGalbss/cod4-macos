import assert from "node:assert/strict";
import test from "node:test";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { DEFAULT_FIELDS } from "../src/command.ts";
import { labArguments, LabStream, parseLabLine, scrubEnvironment, type LabMessage, type LabProcess, type SpawnLab } from "../src/lab-stream.ts";
import { protocolExample } from "./fixtures.ts";

class FakeChild extends EventEmitter implements LabProcess {
  readonly stdin = new PassThrough();
  readonly stdout = new PassThrough();
  readonly stderr = new PassThrough();
  readonly written: string[] = [];

  constructor() {
    super();
    this.stdin.on("data", chunk => this.written.push(String(chunk)));
  }

  emitLine(value: unknown): void {
    this.stdout.write(`${JSON.stringify(value)}\n`);
  }
}

const args = { seconds: 120, bots: 2, gameMode: "dm" as const, brain: "jev" as const, output: "/tmp/out", port: 28985, ssh: "root@host", nativePlugin: undefined, spawnLayout: undefined, opponents: "bot_warfare:medium:3", public: undefined, map: undefined, waypoints: undefined, loadout: undefined };

test("builds the lab command line with only the flags that are set", () => {
  assert.deepEqual(labArguments("/x/lab/lab.py", args), ["/x/lab/lab.py", "--seconds", "120", "--bots", "2", "--game-mode", "dm", "--brain", "jev", "--output", "/tmp/out", "--port", "28985", "--ssh", "root@host", "--opponents", "bot_warfare:medium:3"]);
  assert.deepEqual(labArguments("/x/lab/lab.py", { ...args, public: "rogo" }).slice(-2), ["--public", "rogo"]);
});

test("the worker environment never carries the API key", () => {
  const env = scrubEnvironment({ PATH: "/bin", TYPESAFE_API_KEY: "secret-value", HOME: "/home" });
  assert.deepEqual(env, { PATH: "/bin", HOME: "/home" });
});

test("parses ready, observation, event (raw line or parsed), done and rejects the rest", () => {
  assert.deepEqual(parseLabLine('{"type":"ready","port":1}'), { kind: "ready", message: { type: "ready", port: 1 } });
  const observation = parseLabLine(JSON.stringify({ type: "observation", observation: protocolExample() }));
  assert.equal(observation.kind, "observation");
  assert.deepEqual(parseLabLine('{"type":"event","line":"[jev-event] {\\"event\\":\\"kill\\",\\"gameTimeMs\\":5}"}'), { kind: "event", event: { event: "kill", gameTimeMs: 5 } });
  assert.deepEqual(parseLabLine('{"type":"event","event":{"event":"spawn"}}'), { kind: "event", event: { event: "spawn" } });
  assert.deepEqual(parseLabLine('{"type":"done","reason":"duration_elapsed"}'), { kind: "done", message: { type: "done", reason: "duration_elapsed" } });
  assert.deepEqual(parseLabLine('{"type":"observation","observation":{"botId":"x"}}'), { kind: "invalid_observation" });
  assert.deepEqual(parseLabLine('{"type":"event","line":"no json"}'), { kind: "invalid_event" });
  assert.deepEqual(parseLabLine('{"type":"event","line":"[lab] rejected command: Invalid command field t"}'), { kind: "lab_rejected", reason: "Invalid command field t" });
  assert.deepEqual(parseLabLine("not json"), { kind: "invalid_line" });
  assert.deepEqual(parseLabLine('{"type":"mystery"}'), { kind: "unknown", type: "mystery" });
  assert.deepEqual(parseLabLine('{"type":"__proto__"}'), { kind: "unknown", type: "__proto__" });
});

test("routes stdout lines to the handler and writes commands and stop to stdin", async () => {
  const child = new FakeChild();
  const spawned: { command: string; args: readonly string[]; env: NodeJS.ProcessEnv; cwd: string }[] = [];
  const spawn: SpawnLab = (command, spawnArgs, options) => {
    spawned.push({ command, args: spawnArgs, env: options.env, cwd: options.cwd });
    return child;
  };
  const messages: LabMessage[] = [];
  const stderr: string[] = [];
  const stream = new LabStream({ spawn, script: "/x/lab/lab.py", cwd: "/repo", env: { PATH: "/bin", TYPESAFE_API_KEY: "secret-value" }, args, onMessage: message => messages.push(message), onStderr: line => stderr.push(line) });
  stream.start();
  assert.equal(spawned.length, 1);
  assert.equal(spawned[0].command, "python3");
  assert.equal(spawned[0].cwd, "/repo");
  assert.equal(spawned[0].env.TYPESAFE_API_KEY, undefined);
  assert.equal(spawned[0].args[0], "/x/lab/lab.py");
  child.emitLine({ type: "ready", port: 28985 });
  child.emitLine({ type: "observation", observation: protocolExample() });
  child.emitLine({ type: "event", line: '[jev-event] {"event":"spawn","gameTimeMs":1}' });
  child.stderr.write("warning line\n");
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(messages.map(message => message.kind), ["ready", "observation", "event"]);
  assert.deepEqual(stderr, ["warning line"]);
  stream.send({ type: "command", botId: 0, sequence: 41, lifeId: 3, gameTimeMs: 184250, fields: DEFAULT_FIELDS });
  stream.stop();
  stream.stop();
  child.emitLine({ type: "done", reason: "duration_elapsed" });
  await new Promise(resolve => setImmediate(resolve));
  child.emit("close", 0);
  assert.equal(await stream.closed, 0);
  const lines = child.written.join("").trim().split("\n").map(line => JSON.parse(line));
  assert.deepEqual(lines, [{ type: "command", botId: 0, sequence: 41, lifeId: 3, gameTimeMs: 184250, fields: DEFAULT_FIELDS }, { type: "stop" }]);
  assert.equal(messages.at(-1)?.kind, "done");
});
