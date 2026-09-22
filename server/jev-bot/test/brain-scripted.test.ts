import assert from "node:assert/strict";
import test from "node:test";
import { scriptedBrain } from "../src/brain-scripted.ts";
import { selectCandidates } from "../src/candidates.ts";
import { BotMemory } from "../src/memory.ts";
import { loadWaypoints } from "../src/waypoints.ts";
import { rememberedEnemy, sampleObservation, visibleEnemy } from "./fixtures.ts";

const graph = loadWaypoints();

function decide(obs: ReturnType<typeof sampleObservation>, memory = new BotMemory()) {
  memory.observe(obs);
  const candidates = selectCandidates({ obs, memory, graph });
  return { fields: scriptedBrain(obs, memory, candidates), candidates };
}

test("attacks the nearest visible enemy and chases it", () => {
  const { fields } = decide(sampleObservation({ enemies: { visible: [visibleEnemy({ id: 2, dist: 640 }), visibleEnemy({ id: 4, dist: 300 })], remembered: [], team: [] } }));
  assert.equal(fields.t, "4");
  assert.equal(fields.e, "f");
  assert.equal(fields.g, "chase4");
  assert.equal(fields.w, "keep");
});

test("retreats to the cover candidate when hurt", () => {
  const { fields, candidates } = decide(sampleObservation({ hp: 30, enemies: { visible: [visibleEnemy()], remembered: [], team: [] } }));
  const cover = candidates.find(candidate => candidate.kind === "cover");
  assert.ok(cover !== undefined);
  assert.equal(fields.g, `n${cover.node}`);
  assert.equal(fields.s, "stand");
});

test("chases a remembered enemy fresher than six seconds, otherwise explores", () => {
  const fresh = decide(sampleObservation({ enemies: { visible: [], remembered: [rememberedEnemy({ id: 1, ageMs: 5000 })], team: [] } }));
  assert.equal(fresh.fields.t, "auto");
  assert.equal(fresh.fields.g, "chase1");
  const stale = decide(sampleObservation({ enemies: { visible: [], remembered: [rememberedEnemy({ id: 1, ageMs: 7000 })], team: [] } }));
  const unexplored = stale.candidates.find(candidate => candidate.kind === "unexplored");
  assert.ok(unexplored !== undefined);
  assert.equal(stale.fields.g, `n${unexplored.node}`);
});

test("reloads at eight rounds or fewer with no enemy visible, never while one is visible", () => {
  assert.equal(decide(sampleObservation({ clip: 8 })).fields.w, "reload");
  assert.equal(decide(sampleObservation({ clip: 9 })).fields.w, "keep");
  assert.equal(decide(sampleObservation({ clip: 2, reserve: 0 })).fields.w, "keep");
  assert.equal(decide(sampleObservation({ clip: 2, enemies: { visible: [visibleEnemy()], remembered: [], team: [] } })).fields.w, "keep");
});

test("defaults keep look, sprint and ADS automatic", () => {
  const { fields } = decide(sampleObservation());
  assert.equal(fields.l, "auto");
  assert.equal(fields.r, "auto");
  assert.equal(fields.a, "auto");
});
