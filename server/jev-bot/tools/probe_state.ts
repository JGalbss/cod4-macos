/**
 * Replay one bot's observations from a recorded events.jsonl through the controller memory and
 * print the Jev state and questions at chosen moments. With --ask, send them to Jev and print
 * the answers, latency and token usage. Reads TYPESAFE_API_KEY from the environment only.
 *
 *   node --experimental-strip-types tools/probe_state.ts <events.jsonl> [--bot 0] [--pick visible|hurt|idle] [--count 3] [--ask]
 */
import { readFileSync } from "node:fs";
import { performance } from "node:perf_hooks";
import { parseArgs } from "node:util";
import { parseObservation, type Observation } from "../src/observation.ts";
import { BotMemory } from "../src/memory.ts";
import { selectCandidates } from "../src/candidates.ts";
import { loadWaypoints } from "../src/waypoints.ts";
import { buildState, estimateTokens } from "../src/state.ts";
import { buildQuestions } from "../src/questions.ts";
import { commandFields } from "../src/command.ts";
import { JevClient } from "../src/jev.ts";
import { MapKnowledge } from "../src/map.ts";

const { values, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    bot: { type: "string", default: "0" },
    pick: { type: "string", default: "visible" },
    count: { type: "string", default: "3" },
    ask: { type: "boolean", default: false },
    task: { type: "string", default: "Free-for-all on Shipment against 3 bots. Win fights, keep moving, avoid dying." },
  },
});

type Picker = (obs: Observation, memory: BotMemory) => boolean;
const PICKERS: Record<string, Picker> = {
  visible: obs => obs.enemies.visible.length > 0,
  hurt: (_obs, memory) => memory.damageTaken(2_000).length > 0,
  idle: (obs, memory) => obs.enemies.visible.length === 0 && memory.sightings().length === 0,
  remembered: (obs, memory) => obs.enemies.visible.length === 0 && memory.sightings().length > 0,
};

const file = positionals[0];
if (file === undefined) throw new Error("events.jsonl path required");
const botId = Number(values.bot);
const wanted = Number(values.count);
const picker = PICKERS[values.pick ?? "visible"];
if (picker === undefined) throw new Error(`unknown --pick ${values.pick}`);

const graph = loadWaypoints();
const map = new MapKnowledge(graph);
const memory = new BotMemory();
const client = values.ask ? new JevClient({ timeoutMs: 5_000 }) : undefined;
let printed = 0;
let lastPrintedMs = -Infinity;

for (const line of readFileSync(file, "utf8").split("\n")) {
  if (printed >= wanted) break;
  if (line.trim() === "") continue;
  const record = JSON.parse(line) as { type?: string; observation?: unknown; event?: { event?: string; node?: number; sees?: number[] } };
  if (record.type === "event" && record.event?.event === "map_sight" && typeof record.event.node === "number" && Array.isArray(record.event.sees)) map.learn({ node: record.event.node, sees: record.event.sees });
  if (record.type !== "observation") continue;
  const obs = parseObservation(record.observation);
  if (obs === undefined || obs.botId !== botId) continue;
  memory.observe(obs);
  if (!obs.alive || !picker(obs, memory) || obs.gameTimeMs - lastPrintedMs < 10_000) continue;
  lastPrintedMs = obs.gameTimeMs;
  printed += 1;
  const candidates = selectCandidates({ obs, memory, graph, map });
  const state = buildState(obs, memory, candidates, { task: values.task ?? "", graph, map });
  const decision = buildQuestions({ obs, memory, candidates, graph, map });
  console.log(`\n=== bot ${botId} t=${obs.gameTimeMs} ms, state ~${estimateTokens(state)} tokens, questions ~${estimateTokens(decision.questions)} tokens ===`);
  console.log(JSON.stringify(state, null, 1));
  console.log(JSON.stringify(decision.questions, null, 1));
  if (client === undefined) continue;
  const started = performance.now();
  const result = await client.evaluate(state, decision.questions);
  const latency = Math.round(performance.now() - started);
  const summary = Object.fromEntries(Object.entries(result.answers).map(([name, answer]) => [name, answer.type === "choice" ? { choice: answer.choice, confidence: Math.round(answer.confidence * 100), probabilities: Object.fromEntries(Object.entries(answer.probabilities).map(([id, p]) => [id, Math.round(p * 100)])) } : answer.noul]));
  console.log(`--- jev ${result.model}: ${latency} ms, ${result.usage.input_tokens} in / ${result.usage.output_tokens} out`);
  console.log(JSON.stringify(summary));
  console.log(JSON.stringify(commandFields(result.answers, decision.options)));
}
