import assert from "node:assert/strict";
import test from "node:test";
import { analyzeEvents, distribution } from "../src/metrics.ts";
import { protocolExample } from "./fixtures.ts";

function line(record: Record<string, unknown>): string {
  return JSON.stringify(record);
}

function observation(botId: number, gameTimeMs: number, extra: Record<string, unknown> = {}): string {
  const base = protocolExample();
  return line({ type: "observation", observation: { ...base, botId, gameTimeMs, sequence: gameTimeMs / 200, pos: [gameTimeMs / 10, 0, 192], events: { dmgTaken: [], dmgDealt: [], kills: [], died: false, shots: 0, heard: [], rejected: [] }, enemies: { visible: [], remembered: [], team: [] }, ...extra } });
}

const context = { brain: "jev" as const, botCount: 2, requestedSeconds: 60, stopReason: "duration_elapsed", exitCode: 0, fatalReason: undefined, inputTokenBudget: 2500, targetDecisionsPerSecond: 2.5 };

test("per-bot combat, decision and request metrics from events.jsonl", () => {
  const jsonl = [
    observation(0, 1000),
    observation(0, 3000, { events: { dmgDealt: [{ to: 2, amount: 40, ageMs: 100 }, { to: 2, amount: 60, ageMs: 50 }], kills: [2], shots: 6, dmgTaken: [{ from: 2, amount: 35, bearing: 0, ageMs: 0 }], died: false, heard: [], rejected: [{ reason: "stale", sequence: 3 }] }, enemies: { visible: [{ id: 2, pos: [0, 0, 0], vel: [0, 0, 0], dist: 100, bearing: 0, elev: 0, exposed: "both", seenMs: 100 }], remembered: [], team: [] } }),
    observation(0, 5000, { events: { dmgDealt: [], kills: [], shots: 3, dmgTaken: [], died: true, heard: [], rejected: [] } }),
    observation(1, 1000),
    observation(1, 5000),
    line({ type: "decision", botId: 0, trace: { latencyMs: 300, inputTokens: 1000, outputTokens: 20 } }),
    line({ type: "decision", botId: 0, trace: { latencyMs: 500, inputTokens: 1400, outputTokens: 30 } }),
    line({ type: "decision_error", botId: 0, code: "timeout" }),
    line({ type: "command", botId: 0 }),
    line({ type: "command", botId: 0 }),
    line({ type: "stale_decision", botId: 1 }),
    line({ type: "lab_rejected", reason: "Invalid command field t" }),
    line({ type: "event", event: { event: "command_accepted", botId: 0, gameTimeMs: 1100 } }),
    line({ type: "event", event: { event: "command_rejected", botId: 0, gameTimeMs: 3100 } }),
    line({ type: "event", event: { event: "damage", botId: 2, attackerId: 0, amount: 40, gameTimeMs: 2900 } }),
    line({ type: "event", event: { event: "damage", botId: 2, attackerId: 0, amount: 60, gameTimeMs: 2950 } }),
    line({ type: "event", event: { event: "damage", botId: 0, attackerId: 2, amount: 35, gameTimeMs: 3000 } }),
    line({ type: "event", event: { event: "kill", botId: 0, victimId: 2, gameTimeMs: 3000 } }),
    line({ type: "event", event: { event: "death", botId: 2, attackerId: 0, gameTimeMs: 3000 } }),
    line({ type: "event", event: { event: "death", botId: 0, attackerId: 2, gameTimeMs: 5000 } }),
    line({ type: "event", event: { event: "kill", botId: 2, victimId: 0, gameTimeMs: 5000 } }),
    "not json",
    "",
  ].join("\n");
  const metrics = analyzeEvents(jsonl, context);
  assert.equal(metrics.bots.length, 2);
  const [bot0, bot1] = metrics.bots;
  assert.equal(bot0.kills, 1);
  assert.equal(bot0.deaths, 1);
  assert.equal(bot0.damageDealt, 100);
  assert.equal(bot0.damageTaken, 35);
  assert.equal(bot0.shots, 9);
  assert.equal(bot0.hits, 2);
  assert.equal(bot0.shotsPerKill, 9);
  assert.equal(bot0.timeToFirstKillSeconds, 2);
  assert.equal(bot0.observationsWithEnemyVisible, 1);
  assert.equal(bot0.decisions, 2);
  assert.equal(bot0.commandsSent, 2);
  assert.equal(bot0.commandsAccepted, 1);
  assert.equal(bot0.commandsRejected, 1);
  assert.equal(bot0.rejectionsReportedInObservations, 1);
  assert.equal(bot0.decisionsPerSecond, 0.5);
  assert.deepEqual(bot0.requestLatencyMs, { count: 2, p50: 300, p95: 500, max: 500, mean: 400 });
  assert.deepEqual(bot0.tokens, { input: 2400, output: 50, meanInputPerDecision: 1200 });
  assert.deepEqual(bot0.errorsByCode, { timeout: 1 });
  assert.equal(bot0.distanceUnits, 400);
  assert.equal(bot1.staleDecisions, 1);
  assert.equal(bot1.kills, 0);
  assert.equal(metrics.totals.requests, 3);
  assert.equal(metrics.totals.errors, 1);
  assert.equal(metrics.observedSeconds, 4);
  const byName = Object.fromEntries(metrics.checks.map(check => [check.name, check]));
  assert.equal(byName.allBotsObserved.ok, true);
  assert.equal(byName.allMoved.ok, true);
  assert.equal(byName.allFired.ok, false);
  assert.equal(byName.scoredKill.ok, true);
  assert.equal(byName.positiveKillDeath.ok, false);
  assert.equal(byName.requestErrorsUnder2Percent.ok, false);
  assert.equal(byName.inputTokenBudget.ok, true);
  assert.equal(byName.durationCompleted.ok, true);
  assert.equal(byName.noFatal.ok, true);
  assert.equal(metrics.labRejections, 1);
  assert.equal(byName.noWorkerRejections.ok, false);
  for (const check of metrics.checks) assert.ok(check.reason.length > 0);
});

test("a scripted run is exempt from the token budget and an empty log fails the presence checks", () => {
  const metrics = analyzeEvents("", { ...context, brain: "scripted", exitCode: 1, fatalReason: "run_timeout" });
  const byName = Object.fromEntries(metrics.checks.map(check => [check.name, check]));
  assert.equal(byName.inputTokenBudget.ok, true);
  assert.equal(byName.allBotsObserved.ok, false);
  assert.equal(byName.workerExited.ok, false);
  assert.equal(byName.noFatal.ok, false);
  assert.equal(metrics.totals.requestLatencyMs.count, 0);
});

test("distribution percentiles", () => {
  assert.deepEqual(distribution([]), { count: 0, p50: null, p95: null, max: null, mean: null });
  assert.deepEqual(distribution([5, 1, 3]), { count: 3, p50: 3, p95: 5, max: 5, mean: 3 });
});
