import assert from "node:assert/strict";
import test from "node:test";
import { selectCandidates } from "../src/candidates.ts";
import { BotMemory } from "../src/memory.ts";
import type { JevQuestion } from "../src/jev.ts";
import { buildQuestions } from "../src/questions.ts";
import { loadWaypoints } from "../src/waypoints.ts";
import { rememberedEnemy, sampleObservation, visibleEnemy } from "./fixtures.ts";

const graph = loadWaypoints();

function criteria(question: JevQuestion): Record<string, string | null> {
  if (question.type !== "choice") throw new Error("expected a choice question");
  return question.criteria;
}

function questionsFor(obs: ReturnType<typeof sampleObservation>) {
  const memory = new BotMemory();
  memory.observe(obs);
  const candidates = selectCandidates({ obs, memory, graph });
  return buildQuestions({ obs, memory, candidates, graph });
}

test("engage lists one attack per visible enemy plus hold_fire, and is not asked when nothing is visible", () => {
  const seen = questionsFor(sampleObservation({ enemies: { visible: [visibleEnemy({ id: 2 }), visibleEnemy({ id: 4, dist: 200 })], remembered: [], team: [] } }));
  assert.deepEqual(Object.keys(criteria(seen.questions.engage)), ["attack_4", "attack_2", "hold_fire"]);
  assert.match(criteria(seen.questions.engage).attack_2 ?? "", /640u, head and body exposed, aim error \d+ deg, toward you/);
  const blind = questionsFor(sampleObservation());
  assert.equal(blind.questions.engage, undefined);
  assert.deepEqual(blind.options.engage, []);
});

test("move offers candidate nodes, chases toward known enemies, and hold last", () => {
  const decision = questionsFor(sampleObservation({ enemies: { visible: [visibleEnemy({ id: 2 })], remembered: [rememberedEnemy({ id: 1 })], team: [] } }));
  const ids = Object.keys(criteria(decision.questions.move));
  assert.ok(ids.includes("retreat_n3"));
  assert.ok(ids.some(id => id.startsWith("advance_n")));
  assert.ok(ids.includes("chase_2"));
  assert.ok(ids.includes("chase_1"));
  assert.equal(ids.at(-1), "hold");
  assert.match(criteria(decision.questions.move).chase_1 ?? "", /seen 4\.5s ago/);
  assert.match(criteria(decision.questions.move).retreat_n3 ?? "", /^cover at .*, [0-9]+u/);
  for (const option of decision.options.move) assert.equal(option.criteria, criteria(decision.questions.move)[option.id]);
});

test("posture always offers stand and crouch", () => {
  assert.deepEqual(Object.keys(criteria(questionsFor(sampleObservation()).questions.posture)), ["stand", "crouch"]);
  assert.deepEqual(Object.keys(criteria(questionsFor(sampleObservation({ enemies: { visible: [visibleEnemy()], remembered: [], team: [] } })).questions.posture)), ["stand", "crouch", "dropshot", "jumpshot"]);
});

test("weapon offers reload only with a partial clip and reserve, and grenades only with ammo and a target in range", () => {
  const full = questionsFor(sampleObservation({ clip: 30, clipSize: 30, grenades: 0 }));
  assert.deepEqual(Object.keys(criteria(full.questions.weapon)), ["keep"]);
  const empty = questionsFor(sampleObservation({ clip: 3, reserve: 0, grenades: 1 }));
  assert.deepEqual(Object.keys(criteria(empty.questions.weapon)), ["keep"]);
  const partial = questionsFor(sampleObservation({ clip: 12, reserve: 60, grenades: 0 }));
  assert.deepEqual(Object.keys(criteria(partial.questions.weapon)), ["keep", "reload"]);
  assert.equal(criteria(partial.questions.weapon).reload, "reload now: 12/30 in the clip, 60 in reserve; takes 2s and stops firing");
  const armed = questionsFor(sampleObservation({ clip: 30, grenades: 1, enemies: { visible: [visibleEnemy({ id: 2 })], remembered: [rememberedEnemy({ id: 1, pos: [900, -600, 192], vel: [0, 0, 0] })], team: [] } }));
  assert.deepEqual(Object.keys(criteria(armed.questions.weapon)), ["keep", "grenade_2", "flash_2"]);
  const grenade = armed.options.weapon.find(option => option.kind === "grenade");
  assert.ok(grenade !== undefined && grenade.kind === "grenade");
  assert.equal(grenade.enemyId, 2);
  assert.deepEqual(grenade.target, [450.1, 385.7, 192], "a visible enemy's prediction is its live position");
});

test("every question is a choice with non-empty string criteria", () => {
  const decision = questionsFor(sampleObservation({ enemies: { visible: [visibleEnemy()], remembered: [], team: [] } }));
  for (const question of Object.values(decision.questions)) {
    assert.equal(question.type, "choice");
    if (question.type !== "choice") continue;
    assert.ok(Object.keys(question.criteria).length > 0);
    for (const value of Object.values(question.criteria)) assert.ok(typeof value === "string" && value.length > 0);
  }
});
