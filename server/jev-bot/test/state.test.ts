import assert from "node:assert/strict";
import test from "node:test";
import { selectCandidates } from "../src/candidates.ts";
import { BotMemory } from "../src/memory.ts";
import { buildState, estimateTokens } from "../src/state.ts";
import { loadWaypoints } from "../src/waypoints.ts";
import { events, nav, rememberedEnemy, sampleObservation, visibleEnemy } from "./fixtures.ts";

const graph = loadWaypoints();
const context = { task: "Free-for-all on Shipment against 3 bots. Win fights, keep moving, avoid dying.", graph };

function busyObservation() {
  return sampleObservation({
    gameTimeMs: 184_250,
    aim: { target: 2, visible: true, errorDeg: 3.2, firing: true },
    enemies: {
      visible: [visibleEnemy({ id: 2 }), visibleEnemy({ id: 4, pos: [-3.1, -299.5, 192], vel: [0, 0, 0], dist: 780, bearing: -170, elev: -1, exposed: "head" }), visibleEnemy({ id: 5, pos: [-669, 706, 193], vel: [0, -200, 0], dist: 540, bearing: 63, elev: 0, exposed: "body" })],
      remembered: [rememberedEnemy({ id: 1 }), rememberedEnemy({ id: 6, ageMs: 9000, pos: [660, 688, 192], lost: "ours" }), rememberedEnemy({ id: 7, ageMs: 12_000, pos: [-704, -302, 192] }), rememberedEnemy({ id: 3, ageMs: 2000, pos: [175, -495, 192], vel: [0, 100, 0] })],
      team: [],
    },
    events: events({
      dmgTaken: [{ from: 2, amount: 35, bearing: 150, ageMs: 300 }],
      dmgDealt: [{ to: 2, amount: 40, ageMs: 100 }],
      shots: 3,
      heard: [{ from: 1, bearing: 150, dist: 400, ageMs: 500 }, { from: 3, bearing: -20, dist: 900, ageMs: 900 }, { from: 6, bearing: 90, dist: 1200, ageMs: 1500 }, { from: 7, bearing: 10, dist: 300, ageMs: 100 }],
    }),
  });
}

test("a full synthetic state stays under the token budget", () => {
  const memory = new BotMemory();
  const obs = busyObservation();
  memory.observe(obs);
  const candidates = selectCandidates({ obs, memory, graph });
  const state = buildState(obs, memory, candidates, context);
  assert.equal(state.enemies_visible.length, 3);
  assert.equal(state.enemies_remembered.length, 4);
  const tokens = estimateTokens(state);
  assert.ok(tokens < 2500, `state is ${tokens} tokens`);
});

test("bearings stay relative to facing (positive left), times are seconds, and phrases read plainly", () => {
  const memory = new BotMemory();
  const obs = busyObservation();
  memory.observe(obs);
  const state = buildState(obs, memory, selectCandidates({ obs, memory, graph }), context);
  assert.equal(state.you.facing, 90);
  assert.equal(state.you.moving, "north 180u/s");
  assert.equal(state.you.weapon, "M16");
  assert.equal(state.you.area, "northwest");
  assert.equal(state.you.target, 2);
  const [closest] = state.enemies_visible;
  assert.equal(closest.id, 5);
  assert.equal(closest.dist, 540);
  assert.equal(closest.seen_for, 0.8);
  const tracked = state.enemies_visible.find(enemy => enemy.id === 2);
  assert.ok(tracked !== undefined);
  assert.equal(tracked.aim_error, 3);
  assert.equal(tracked.moving, "toward you");
  assert.equal(tracked.shooting_you, true);
  assert.equal(tracked.exposed, "head and body exposed");
  const remembered = state.enemies_remembered.find(enemy => enemy.id === 1);
  assert.ok(remembered !== undefined);
  assert.equal(remembered.last_seen_s, 4.5);
  assert.equal(remembered.was_moving, "west 100u/s");
  assert.equal(remembered.lost, "they broke away");
  assert.ok(remembered.bearing < 0, "enemy 1 lies to the right when facing north");
  assert.deepEqual(remembered.predicted, [252, 58]);
  assert.equal(state.threats.damage_taken_2s, 35);
  assert.equal(state.threats.from_bearing, 150);
  assert.equal(state.threats.gunfire_heard.length, 4);
  assert.equal(state.threats.gunfire_heard[0].age_s, 0.1);
  assert.equal(state.movement.goal, "node 0 (north)");
  assert.equal(state.movement.progress_ok, true);
  assert.deepEqual(state.recent, { kills: 0, deaths: 0, hits_landed_10s: 1, shots_10s: 3 });
});

test("movement goal phrases cover node, chase and hold goals", () => {
  const memory = new BotMemory();
  const chasing = sampleObservation({ nav: nav({ goal: "chase2" }) });
  memory.observe(chasing);
  assert.equal(buildState(chasing, memory, [], context).movement.goal, "chasing enemy 2");
  const holding = sampleObservation({ nav: nav({ goal: "hold" }) });
  assert.equal(buildState(holding, memory, [], context).movement.goal, "holding at node 27");
  const idle = sampleObservation({ nav: nav({ goal: "" }) });
  assert.equal(buildState(idle, memory, [], context).movement.goal, "none");
});
