import { performance } from "node:perf_hooks";
import type { JevAnswer, JevClient, JevQuestions, JevResult } from "./jev.ts";
import type { WaypointGraph } from "./waypoints.ts";
import { buildState, estimateTokens } from "./state.ts";
import { buildQuestions } from "./questions.ts";
import { commandFields } from "./command.ts";
import type { ChoiceTrace, Decider } from "./brain.ts";

export interface JevEvaluator {
  evaluate(state: unknown, questions: JevQuestions): Promise<JevResult>;
}

export interface JevDeciderOptions {
  readonly client: JevEvaluator | JevClient;
  readonly task: string;
  readonly graph: WaypointGraph;
  readonly now?: () => number;
}

function choiceTraces(answers: Readonly<Record<string, JevAnswer>>): Record<string, ChoiceTrace> {
  const traces = Object.entries(answers).flatMap(([name, answer]): [string, ChoiceTrace][] => {
    if (answer.type !== "choice") return [];
    return [[name, { choice: answer.choice, confidence: answer.confidence, probabilities: answer.probabilities }]];
  });
  return Object.fromEntries(traces);
}

/** State in, questions asked, answers mapped to wire fields. Request errors propagate to the brain loop. */
export function jevDecider(options: JevDeciderOptions): Decider {
  const now = options.now ?? (() => performance.now());
  return async ({ obs, memory, candidates, graph, map, rounds }) => {
    const state = buildState(obs, memory, candidates, { task: options.task, graph, map, rounds });
    const decision = buildQuestions({ obs, memory, candidates, graph, map });
    const started = now();
    const result = await options.client.evaluate(state, decision.questions);
    const latencyMs = Math.round(now() - started);
    return {
      fields: commandFields(result.answers, decision.options, { enemyVisible: obs.enemies.visible.length > 0 }),
      trace: { latencyMs, model: result.model, inputTokens: result.usage.input_tokens, outputTokens: result.usage.output_tokens, stateTokens: estimateTokens(state), choices: choiceTraces(result.answers) },
    };
  };
}
