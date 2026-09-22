import assert from "node:assert/strict";
import test from "node:test";
import { COVER_MIN_UNITS, EXPLORE_RADIUS_UNITS, FLANK_MAX_UNITS, FLANK_MIN_UNITS, FLANK_TOLERANCE_DEG, selectCandidates } from "../src/candidates.ts";
import { BotMemory, predictedPosition } from "../src/memory.ts";
import { distance2d, loadWaypoints } from "../src/waypoints.ts";
import { nav, sampleObservation, visibleEnemy } from "./fixtures.ts";

const graph = loadWaypoints();

function angleFromEnemy(self: readonly number[], enemy: readonly number[], node: readonly number[]): number {
  const a = [enemy[0] - self[0], enemy[1] - self[1]];
  const b = [node[0] - self[0], node[1] - self[1]];
  const cosine = (a[0] * b[0] + a[1] * b[1]) / (Math.hypot(a[0], a[1]) * Math.hypot(b[0], b[1]));
  return (Math.acos(cosine) * 180) / Math.PI;
}

test("with an enemy east of the bot the five candidates cover every role and end with hold", () => {
  const memory = new BotMemory();
  const obs = sampleObservation({ enemies: { visible: [visibleEnemy()], remembered: [], team: [] } });
  memory.observe(obs);
  const candidates = selectCandidates({ obs, memory, graph });
  assert.deepEqual(candidates.map(candidate => candidate.kind), ["cover", "toward_enemy", "unexplored", "flank", "far", "hold"]);
  assert.equal(new Set(candidates.map(candidate => candidate.node)).size, 6);
  assert.deepEqual(candidates.at(-1), { kind: "hold", node: 27 });
  const enemy = predictedPosition(memory.freshestEnemy()!, obs.gameTimeMs);
  const cover = candidates[0];
  assert.ok(distance2d(graph.nodes[cover.node].pos, enemy) > COVER_MIN_UNITS);
  assert.ok(angleFromEnemy(obs.pos, enemy, graph.nodes[cover.node].pos) > 90);
  assert.equal(cover.node, 3);
  const toward = candidates[1];
  const nearestToEnemy = [...graph.nodes].sort((a, b) => distance2d(a.pos, enemy) - distance2d(b.pos, enemy))[0].index;
  assert.equal(toward.node, nearestToEnemy);
  const unexplored = candidates[2];
  assert.ok(distance2d(graph.nodes[unexplored.node].pos, obs.pos) <= EXPLORE_RADIUS_UNITS);
  assert.notEqual(unexplored.node, 27);
  const flank = candidates[3];
  const range = distance2d(graph.nodes[flank.node].pos, obs.pos);
  assert.ok(range >= FLANK_MIN_UNITS && range <= FLANK_MAX_UNITS);
  assert.ok(Math.abs(angleFromEnemy(obs.pos, enemy, graph.nodes[flank.node].pos) - 90) <= FLANK_TOLERANCE_DEG);
  for (const candidate of candidates) {
    if (candidate.kind === "hold") continue;
    assert.ok(candidate.pathUnits > 0);
  }
});

test("without a known enemy the bot gets exploration options and hold", () => {
  const memory = new BotMemory();
  const obs = sampleObservation();
  memory.observe(obs);
  const candidates = selectCandidates({ obs, memory, graph });
  assert.deepEqual(candidates.map(candidate => candidate.kind), ["unexplored", "unexplored", "unexplored", "far", "far", "hold"]);
  assert.ok(candidates.length <= 6);
});

test("least recently visited nodes come first, unvisited before visited", () => {
  const memory = new BotMemory();
  memory.observe(sampleObservation({ gameTimeMs: 1000, nav: nav({ node: 32 }), pos: [-156, 617, 194] }));
  memory.observe(sampleObservation({ gameTimeMs: 2000, nav: nav({ node: 51 }), pos: [-75, 597, 193] }));
  const obs = sampleObservation({ gameTimeMs: 3000 });
  memory.observe(obs);
  const [first, second, third] = selectCandidates({ obs, memory, graph });
  assert.equal(memory.visit(first.node), undefined);
  assert.equal(memory.visit(second.node), undefined);
  assert.equal(memory.visit(third.node), undefined);
  const visitedLater = selectCandidates({ obs, memory, graph }).map(candidate => candidate.node);
  assert.ok(!visitedLater.slice(0, 3).includes(32));
  assert.ok(!visitedLater.slice(0, 3).includes(51));
});
