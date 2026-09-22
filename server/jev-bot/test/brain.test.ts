import assert from "node:assert/strict";
import test from "node:test";
import { Brain } from "../src/brain.ts";
import { jevDecider } from "../src/brain-jev.ts";
import { scriptedDecider } from "../src/brain-scripted.ts";
import type { CommandMessage } from "../src/command.ts";
import { JevError, type JevQuestions, type JevResult } from "../src/jev.ts";
import { loadWaypoints } from "../src/waypoints.ts";
import { sampleObservation, visibleEnemy } from "./fixtures.ts";

const graph = loadWaypoints();

function firstChoices(questions: JevQuestions): JevResult {
  const answers = Object.fromEntries(Object.entries(questions).map(([name, question]) => {
    if (question.type !== "choice") return [name, { type: "noul", noul: 0 }];
    const ids = Object.keys(question.criteria);
    return [name, { type: "choice", choice: ids[0], confidence: 0.8, probabilities: Object.fromEntries(ids.map((id, position) => [id, position === 0 ? 0.8 : 0.2 / Math.max(1, ids.length - 1)])) }];
  }));
  return { model: "jev-test", answers, usage: { input_tokens: 1200, output_tokens: 40 } };
}

interface Harness {
  brain: Brain;
  sent: CommandMessage[];
  logged: Record<string, unknown>[];
  calls: JevQuestions[];
  now: { value: number };
}

function harness(respond: (questions: JevQuestions, call: number) => Promise<JevResult> | JevResult): Harness {
  const sent: CommandMessage[] = [];
  const logged: Record<string, unknown>[] = [];
  const calls: JevQuestions[] = [];
  const now = { value: 0 };
  const client = {
    evaluate: async (_state: unknown, questions: JevQuestions): Promise<JevResult> => {
      calls.push(questions);
      return respond(questions, calls.length);
    },
  };
  const brain = new Brain({ kind: "jev", graph, decide: jevDecider({ client, task: "test", graph, now: () => now.value }), send: message => sent.push(message), log: record => logged.push(record), now: () => now.value });
  return { brain, sent, logged, calls, now };
}

const tick = (): Promise<void> => new Promise(resolve => setImmediate(resolve));

test("decides every 400 ms of game time and emits commands carrying the observation identity", async () => {
  const h = harness(firstChoices);
  for (const gameTimeMs of [1000, 1200, 1400, 1600, 1800]) {
    h.brain.observe(sampleObservation({ sequence: gameTimeMs / 200, gameTimeMs, enemies: { visible: [visibleEnemy()], remembered: [], team: [] } }));
    await tick();
  }
  await h.brain.settled();
  assert.equal(h.calls.length, 3);
  assert.deepEqual(h.sent.map(message => message.gameTimeMs), [1000, 1400, 1800]);
  assert.deepEqual(h.sent[0], { type: "command", botId: 0, sequence: 5, lifeId: 3, gameTimeMs: 1000, fields: h.sent[0].fields });
  assert.equal(h.sent[0].fields.t, "2");
  const decision = h.logged.find(record => record.type === "decision");
  assert.ok(decision !== undefined);
  const trace = decision.trace as { model: string; inputTokens: number; choices: Record<string, { choice: string }> };
  assert.equal(trace.model, "jev-test");
  assert.equal(trace.inputTokens, 1200);
  assert.equal(trace.choices.engage.choice, "attack_2");
  assert.equal(h.brain.stats.decisions, 3);
  assert.equal(h.brain.stats.inputTokens, 3600);
});

test("keeps one request in flight per bot and skips observations while waiting", async () => {
  let release: (result: JevResult) => void = () => {};
  const h = harness(questions => new Promise<JevResult>(resolve => {
    release = () => resolve(firstChoices(questions));
  }));
  h.brain.observe(sampleObservation({ sequence: 1, gameTimeMs: 1000 }));
  h.brain.observe(sampleObservation({ sequence: 3, gameTimeMs: 1400 }));
  h.brain.observe(sampleObservation({ sequence: 5, gameTimeMs: 1800 }));
  await tick();
  assert.equal(h.calls.length, 1);
  release(firstChoices(h.calls[0]));
  await h.brain.settled();
  assert.equal(h.sent.length, 1);
  assert.equal(h.sent[0].sequence, 1);
  h.brain.observe(sampleObservation({ sequence: 7, gameTimeMs: 2200 }));
  await tick();
  assert.equal(h.calls.length, 2);
});

test("a failed request leaves the previous command standing and is logged with its code", async () => {
  const h = harness((questions, call) => {
    if (call === 2) throw new JevError("rate_limit", 429);
    return firstChoices(questions);
  });
  h.brain.observe(sampleObservation({ sequence: 1, gameTimeMs: 1000 }));
  await h.brain.settled();
  h.brain.observe(sampleObservation({ sequence: 3, gameTimeMs: 1400 }));
  await h.brain.settled();
  h.brain.observe(sampleObservation({ sequence: 5, gameTimeMs: 1800 }));
  await h.brain.settled();
  assert.deepEqual(h.sent.map(message => message.sequence), [1, 5]);
  const failure = h.logged.find(record => record.type === "decision_error");
  assert.deepEqual({ code: failure?.code, status: failure?.status }, { code: "rate_limit", status: 429 });
  assert.deepEqual(h.brain.stats.errorsByCode, { rate_limit: 1 });
  assert.equal(h.brain.stats.errors, 1);
});

test("a billing failure stops requests and logs once", async () => {
  const h = harness(() => {
    throw new JevError("billing", 402);
  });
  for (const gameTimeMs of [1000, 1400, 1800, 2200]) {
    h.brain.observe(sampleObservation({ sequence: gameTimeMs / 200, gameTimeMs }));
    await h.brain.settled();
  }
  assert.equal(h.calls.length, 1);
  assert.equal(h.logged.filter(record => record.type === "billing_stop").length, 1);
  assert.equal(h.brain.stats.halted, true);
  assert.equal(h.sent.length, 0);
});

test("a decision for a bot that died or respawned in the meantime is dropped as stale", async () => {
  let release: (result: JevResult) => void = () => {};
  const h = harness(questions => new Promise<JevResult>(resolve => {
    release = () => resolve(firstChoices(questions));
  }));
  h.brain.observe(sampleObservation({ sequence: 1, gameTimeMs: 1000, lifeId: 3 }));
  await tick();
  h.brain.observe(sampleObservation({ sequence: 2, gameTimeMs: 1200, lifeId: 4 }));
  release(firstChoices(h.calls[0]));
  await h.brain.settled();
  assert.equal(h.sent.length, 0);
  assert.equal(h.brain.stats.stale, 1);
  assert.equal(h.logged.filter(record => record.type === "stale_decision").length, 1);
});

test("a slow answer older than the age limit is dropped", async () => {
  let release: (result: JevResult) => void = () => {};
  const h = harness(questions => new Promise<JevResult>(resolve => {
    release = () => resolve(firstChoices(questions));
  }));
  h.brain.observe(sampleObservation({ sequence: 1, gameTimeMs: 1000 }));
  await tick();
  h.now.value = 1500;
  release(firstChoices(h.calls[0]));
  await h.brain.settled();
  assert.equal(h.sent.length, 0);
  assert.equal(h.brain.stats.stale, 1);
});

test("dead bots get no decisions and the scripted decider runs through the same loop", async () => {
  const sent: CommandMessage[] = [];
  const brain = new Brain({ kind: "scripted", graph, decide: scriptedDecider, send: message => sent.push(message), log: () => {} });
  brain.observe(sampleObservation({ sequence: 1, gameTimeMs: 1000, alive: false }));
  brain.observe(sampleObservation({ sequence: 2, gameTimeMs: 1200, enemies: { visible: [visibleEnemy()], remembered: [], team: [] } }));
  await brain.settled();
  assert.equal(sent.length, 1);
  assert.equal(sent[0].fields.g, "chase2");
  assert.equal(brain.memoryOf(0)?.sighting(2)?.visible, true);
});
