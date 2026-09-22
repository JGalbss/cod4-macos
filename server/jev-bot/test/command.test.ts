import assert from "node:assert/strict";
import test from "node:test";
import type { JevAnswer } from "../src/jev.ts";
import { commandFields, commandMessage, DEFAULT_FIELDS, isWireSafe, nadeValue, WIRE_VALUE } from "../src/command.ts";
import type { DecisionOptions } from "../src/questions.ts";
import { sampleObservation } from "./fixtures.ts";

const options: DecisionOptions = {
  engage: [{ kind: "attack", id: "attack_2", enemyId: 2, criteria: "" }, { kind: "hold_fire", id: "hold_fire", trackId: 2, criteria: "" }],
  move: [
    { kind: "retreat", id: "retreat_n3", node: 3, criteria: "" },
    { kind: "advance", id: "advance_n6", node: 6, criteria: "" },
    { kind: "chase", id: "chase_1", enemyId: 1, criteria: "" },
    { kind: "hold", id: "hold", node: 27, criteria: "" },
  ],
  posture: [{ kind: "stand", id: "stand", criteria: "" }, { kind: "crouch", id: "crouch", criteria: "" }],
  weapon: [{ kind: "keep", id: "keep", criteria: "" }, { kind: "reload", id: "reload", criteria: "" }, { kind: "grenade", id: "grenade_1", enemyId: 1, target: [-120.4, 340.6, 192.1], criteria: "" }],
};

function choice(value: string): JevAnswer {
  return { type: "choice", choice: value, confidence: 0.9, probabilities: { [value]: 0.9 } };
}

test("maps every answer kind to the wire fields", () => {
  const fields = commandFields({ engage: choice("attack_2"), move: choice("advance_n6"), posture: choice("crouch"), weapon: choice("reload") }, options);
  assert.deepEqual(fields, { t: "2", e: "f", g: "n6", l: "auto", s: "crouch", r: "on", a: "auto", w: "reload" });
});

test("hold_fire keeps tracking the nearest enemy without firing; chase and grenade use the enemy id and prediction", () => {
  const fields = commandFields({ engage: choice("hold_fire"), move: choice("chase_1"), posture: choice("stand"), weapon: choice("grenade_1") }, options);
  assert.deepEqual(fields, { t: "2", e: "h", g: "chase1", l: "auto", s: "stand", r: "on", a: "auto", w: "nade-120:341:192" });
  assert.equal(nadeValue([100.6, -200.4, 192.2]), "nade101:-200:192");
  assert.ok(WIRE_VALUE.test(fields.w));
});

test("retreat forces stand even when the posture answer was crouch", () => {
  const fields = commandFields({ engage: choice("hold_fire"), move: choice("retreat_n3"), posture: choice("crouch"), weapon: choice("keep") }, options);
  assert.equal(fields.g, "n3");
  assert.equal(fields.s, "stand");
});

test("missing or unknown answers fall back to the defaults", () => {
  assert.deepEqual(commandFields({}, options), DEFAULT_FIELDS);
  assert.deepEqual(commandFields({ engage: choice("attack_9"), move: { type: "noul", noul: 0.5 } }, options), DEFAULT_FIELDS);
});

test("every produced value matches the wire grammar and the message carries the observation identity", () => {
  const fields = commandFields({ engage: choice("attack_2"), move: choice("retreat_n3"), posture: choice("crouch"), weapon: choice("grenade_1") }, options);
  assert.ok(isWireSafe(fields));
  const obs = sampleObservation({ botId: 3, sequence: 77, lifeId: 4, gameTimeMs: 9000 });
  assert.deepEqual(commandMessage(obs, fields), { type: "command", botId: 3, sequence: 77, lifeId: 4, gameTimeMs: 9000, fields });
  const wire = `77 4 9000 ${Object.entries(fields).map(([key, value]) => `${key}=${value}`).join(" ")}`;
  assert.ok(wire.length < 200);
});
