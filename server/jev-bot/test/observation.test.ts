import assert from "node:assert/strict";
import test from "node:test";
import { parseObservation } from "../src/observation.ts";
import { protocolExample } from "./fixtures.ts";

test("parses the PROTOCOL.md example with self fields at the top level and the three parts", () => {
  const obs = parseObservation(protocolExample());
  assert.ok(obs !== undefined);
  assert.equal(obs.botId, 0);
  assert.equal(obs.gameTimeMs, 184250);
  assert.deepEqual(obs.pos, [-120, 340, 192]);
  assert.equal(obs.enemies.visible[0].exposed, "both");
  assert.equal(obs.enemies.remembered[0].lost, "theirs");
  assert.equal(obs.enemies.team[0].hp, 70);
  assert.deepEqual(obs.nav.path, [27, 33, 41]);
  assert.equal(obs.events.dmgTaken[0].amount, 35);
  assert.deepEqual(obs.events.kills, [2]);
  assert.equal(obs.events.rejected[0].reason, "stale");
  assert.deepEqual(obs.native, { stage: 0, remainingMs: 0 });
  assert.equal(obs.aim?.target, 2);
});

test("echoed command values are normalised to wire strings", () => {
  const obs = parseObservation(protocolExample());
  assert.deepEqual(obs?.cmd, { sequence: 39, fields: { t: "2", e: "f", g: "n41", l: "auto", s: "stand", r: "auto", a: "auto", w: "keep" } });
});

test("cmd, aim and native are optional; a negative or null aim target means no target", () => {
  const withoutExtras = { ...protocolExample(), cmd: undefined, aim: undefined, native: undefined };
  const obs = parseObservation(withoutExtras);
  assert.ok(obs !== undefined);
  assert.equal(obs.cmd, undefined);
  assert.equal(obs.aim, undefined);
  assert.equal(obs.native, undefined);
  const noTarget = parseObservation({ ...protocolExample(), aim: { target: -1, visible: false, errorDeg: 0, firing: false } });
  assert.equal(noTarget?.aim?.target, undefined);
  const nullTarget = parseObservation({ ...protocolExample(), aim: { target: null, visible: false, errorDeg: 0, firing: false } });
  assert.equal(nullTarget?.aim?.target, undefined);
});

test("rejects malformed observations without throwing", () => {
  const example = protocolExample();
  const broken: unknown[] = [
    undefined,
    null,
    "text",
    [],
    42,
    { ...example, botId: "0" },
    { ...example, gameTimeMs: -1 },
    { ...example, pos: [1, 2] },
    { ...example, pos: [1, 2, Number.NaN] },
    { ...example, stance: "flying" },
    { ...example, nav: undefined },
    { ...example, nav: { ...(example.nav as object), node: "27" } },
    { ...example, enemies: { visible: [{ id: 2 }] } },
    { ...example, enemies: { visible: [{ ...(example.enemies as { visible: object[] }).visible[0], exposed: "partial" }] } },
    { ...example, events: { ...(example.events as object), shots: -3 } },
    { ...example, cmd: { sequence: "39" } },
    { ...example, aim: { target: "2" } },
    { ...example, native: { stage: "x" } },
    { ...example, clip: 1.5 },
  ];
  for (const value of broken) assert.equal(parseObservation(value), undefined, JSON.stringify(value)?.slice(0, 80));
});

test("missing event lists default to empty so a quiet tick still parses", () => {
  const quiet = parseObservation({ ...protocolExample(), events: { botId: 0, sequence: 41, part: "events" }, enemies: { part: "enemies" } });
  assert.ok(quiet !== undefined);
  assert.deepEqual(quiet.events.kills, []);
  assert.equal(quiet.events.shots, 0);
  assert.deepEqual(quiet.enemies.visible, []);
});
