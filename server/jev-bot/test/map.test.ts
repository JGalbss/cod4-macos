import assert from "node:assert/strict";
import test from "node:test";
import { MapKnowledge } from "../src/map.ts";
import { loadWaypoints } from "../src/waypoints.ts";
import { selectCandidates } from "../src/candidates.ts";
import { BotMemory, predictedPosition } from "../src/memory.ts";
import { buildQuestions } from "../src/questions.ts";
import { buildState } from "../src/state.ts";
import { sampleObservation, visibleEnemy } from "./fixtures.ts";

const graph = loadWaypoints();

/** A synthetic yard: every node sees every node within 500u of it, so the centre is open and corners are enclosed. */
function learnedMap(): MapKnowledge {
  const map = new MapKnowledge(graph);
  for (const node of graph.nodes) {
    const sees = graph.nodes.filter(other => other.index !== node.index && Math.hypot(other.pos[0] - node.pos[0], other.pos[1] - node.pos[1]) < 500).map(other => other.index);
    map.learn({ node: node.index, sees });
  }
  return map;
}

test("place words come from position before sightlines arrive and gain a cover word once every node is known", () => {
  const blank = new MapKnowledge(graph);
  assert.equal(blank.ready, false);
  assert.match(blank.describe(18), /^center$/);
  assert.match(blank.describe(11), /^(south|north)-(west|east) corner$/);
  assert.match(blank.describe(12), /^(south|north)-(west|east) edge$/);
  const map = learnedMap();
  assert.equal(map.ready, true);
  assert.match(map.describe(18), /^center \((open|covered)\)$/);
  assert.match(map.describe(11), /corner \((enclosed|covered)\)$/);
  assert.ok(map.openness(18) > map.openness(11), "the centre is seen from more nodes than a corner");
});

test("cover hides from the enemy's node and a flank sees it from a new side", () => {
  const map = learnedMap();
  const memory = new BotMemory();
  const obs = sampleObservation({ enemies: { visible: [visibleEnemy()], remembered: [], team: [] } });
  memory.observe(obs);
  const candidates = selectCandidates({ obs, memory, graph, map });
  const enemyNode = map.nodeAt(predictedPosition(memory.freshestEnemy()!, obs.gameTimeMs));
  const cover = candidates.find(candidate => candidate.kind === "cover");
  assert.ok(cover !== undefined);
  assert.equal(map.sees(enemyNode, cover.node), false, "cover is not visible from the enemy's node");
  const questions = buildQuestions({ obs, memory, candidates, graph, map });
  const move = questions.questions.move;
  assert.ok(move.type === "choice");
  const texts = Object.values(move.criteria).filter((text): text is string => typeof text === "string");
  assert.ok(texts.some(text => /hidden from the enemy's expected position/.test(text)));
  const state = buildState(obs, memory, candidates, { task: "t", graph, map });
  assert.match(state.you.area, /\((open|covered|enclosed)\)$/);
});

test("the state tells Jev where enemies were seen and where the bot died", () => {
  const map = learnedMap();
  const memory = new BotMemory();
  memory.observe(sampleObservation({ gameTimeMs: 1000, enemies: { visible: [visibleEnemy({ id: 2 })], remembered: [], team: [] } }));
  const later = sampleObservation({ gameTimeMs: 4000, enemies: { visible: [], remembered: [{ id: 2, ageMs: 3000, pos: [401.8, 57.6, 192], vel: [0, 0, 0], bearing: 0, dist: 400, lost: "theirs" }], team: [] }, events: { dmgTaken: [], dmgDealt: [], kills: [], died: true, shots: 0, reloadStarted: false, heard: [], rejected: [] } });
  memory.observe(later);
  const state = buildState(later, memory, [], { task: "t", graph, map });
  assert.equal(state.threats.enemies_seen_at.length, 1);
  assert.match(state.threats.enemies_seen_at[0], /enemy 2, 3s ago$/);
  assert.equal(state.threats.you_died_at.length, 1);
  assert.match(state.threats.you_died_at[0], /, 0s ago$/);
});
