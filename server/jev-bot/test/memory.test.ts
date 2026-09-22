import assert from "node:assert/strict";
import test from "node:test";
import { BotMemory, predictedPosition, ROLLING_WINDOW_MS, SIGHTING_MEMORY_MS } from "../src/memory.ts";
import { DEFAULT_FIELDS } from "../src/command.ts";
import { events, nav, rememberedEnemy, sampleObservation, visibleEnemy } from "./fixtures.ts";

test("node visits count arrivals and remember the latest visit time", () => {
  const memory = new BotMemory();
  memory.observe(sampleObservation({ gameTimeMs: 1000, nav: nav({ node: 27 }) }));
  memory.observe(sampleObservation({ gameTimeMs: 1200, nav: nav({ node: 27 }) }));
  memory.observe(sampleObservation({ gameTimeMs: 1400, nav: nav({ node: 0 }) }));
  memory.observe(sampleObservation({ gameTimeMs: 1600, nav: nav({ node: 27 }) }));
  assert.deepEqual(memory.visit(27), { node: 27, lastVisitMs: 1600, visits: 2 });
  assert.deepEqual(memory.visit(0), { node: 0, lastVisitMs: 1400, visits: 1 });
  assert.equal(memory.visit(5), undefined);
});

test("dead observations do not count as visits", () => {
  const memory = new BotMemory();
  memory.observe(sampleObservation({ gameTimeMs: 1000, alive: false, nav: nav({ node: 12 }) }));
  assert.equal(memory.visit(12), undefined);
});

test("sightings merge visible and remembered enemies, keep the freshest, and expire", () => {
  const memory = new BotMemory();
  memory.observe(sampleObservation({ gameTimeMs: 10_000, enemies: { visible: [visibleEnemy({ id: 2 })], remembered: [rememberedEnemy({ id: 1, ageMs: 4500 })], team: [] } }));
  const [freshest, older] = memory.sightings();
  assert.equal(freshest.id, 2);
  assert.equal(freshest.visible, true);
  assert.equal(older.id, 1);
  assert.equal(older.seenAtMs, 5500);
  assert.equal(older.lost, "theirs");
  memory.observe(sampleObservation({ gameTimeMs: 10_200, enemies: { visible: [], remembered: [rememberedEnemy({ id: 2, ageMs: 200 }), rememberedEnemy({ id: 1, ageMs: 4700 })], team: [] } }));
  assert.equal(memory.sighting(2)?.visible, false);
  assert.equal(memory.sighting(2)?.seenAtMs, 10_000);
  memory.observe(sampleObservation({ gameTimeMs: 10_400, enemies: { visible: [], remembered: [rememberedEnemy({ id: 1, ageMs: 4900 })], team: [] } }));
  assert.equal(memory.sighting(2), undefined, "an enemy the fixture stopped reporting (dead or long gone) is forgotten at once");
  assert.equal(memory.sighting(1)?.seenAtMs, 5500);
  memory.observe(sampleObservation({ gameTimeMs: 10_000 + SIGHTING_MEMORY_MS + 1, enemies: { visible: [], remembered: [rememberedEnemy({ id: 1, ageMs: SIGHTING_MEMORY_MS + 4501 })], team: [] } }));
  assert.equal(memory.sighting(1), undefined);
  assert.equal(memory.freshestEnemy(), undefined);
});

test("a stale remembered entry never overwrites a fresher sighting", () => {
  const memory = new BotMemory();
  memory.observe(sampleObservation({ gameTimeMs: 5000, enemies: { visible: [visibleEnemy({ id: 2, pos: [10, 10, 0] })], remembered: [], team: [] } }));
  memory.observe(sampleObservation({ gameTimeMs: 5200, enemies: { visible: [], remembered: [rememberedEnemy({ id: 2, ageMs: 3000, pos: [99, 99, 0] })], team: [] } }));
  assert.deepEqual(memory.sighting(2)?.pos, [10, 10, 0]);
});

test("prediction extrapolates velocity for at most 1.5 seconds", () => {
  const sighting = { id: 1, pos: [0, 0, 0] as const, vel: [100, 0, 0] as const, seenAtMs: 1000, visible: false, lost: undefined };
  assert.deepEqual(predictedPosition(sighting, 2000), [100, 0, 0]);
  assert.deepEqual(predictedPosition(sighting, 9000), [150, 0, 0]);
  assert.deepEqual(predictedPosition(sighting, 500), [0, 0, 0]);
});

test("kill, death, shot and hit tallies roll over a ten second window while totals keep growing", () => {
  const memory = new BotMemory();
  memory.observe(sampleObservation({ gameTimeMs: 1000, events: events({ kills: [2], shots: 6, dmgDealt: [{ to: 2, amount: 40, ageMs: 100 }, { to: 2, amount: 60, ageMs: 50 }] }) }));
  memory.observe(sampleObservation({ gameTimeMs: 4000, events: events({ died: true, shots: 3 }) }));
  assert.deepEqual(memory.tally(), { kills: 1, deaths: 1, shots: 9, hits: 2, damageDealt: 100, damageTaken: 0 });
  memory.observe(sampleObservation({ gameTimeMs: 1000 + ROLLING_WINDOW_MS + 1 }));
  assert.deepEqual(memory.tally(), { kills: 0, deaths: 1, shots: 3, hits: 0, damageDealt: 0, damageTaken: 0 });
  assert.deepEqual(memory.totals(), { kills: 1, deaths: 1, shots: 9, hits: 2, damageDealt: 100, damageTaken: 0 });
});

test("damage and gunfire are stamped by age and answer attackedBy", () => {
  const memory = new BotMemory();
  memory.observe(sampleObservation({ gameTimeMs: 3000, events: events({ dmgTaken: [{ from: 2, amount: 35, bearing: 150, ageMs: 300 }], heard: [{ from: 1, bearing: 10, dist: 400, ageMs: 500 }] }) }));
  assert.deepEqual(memory.damageTaken(2000), [{ from: 2, amount: 35, bearing: 150, atMs: 2700 }]);
  assert.deepEqual(memory.gunfireHeard(2000), [{ from: 1, bearing: 10, dist: 400, atMs: 2500 }]);
  assert.equal(memory.attackedBy(2, 2000), true);
  assert.equal(memory.attackedBy(1, 2000), true);
  assert.equal(memory.attackedBy(3, 2000), false);
  memory.observe(sampleObservation({ gameTimeMs: 5000 }));
  assert.deepEqual(memory.damageTaken(2000), []);
  assert.equal(memory.attackedBy(2, 2000), false);
});

test("keeps the last eight commands", () => {
  const memory = new BotMemory();
  for (let sequence = 0; sequence < 12; sequence++) memory.recordCommand({ gameTimeMs: sequence * 400, sequence, fields: DEFAULT_FIELDS });
  const commands = memory.recentCommands();
  assert.equal(commands.length, 8);
  assert.equal(commands[0].sequence, 4);
  assert.equal(commands[7].sequence, 11);
});
