import type { Observation, VisibleEnemy } from "./observation.ts";
import type { BotMemory } from "./memory.ts";
import type { Candidate } from "./candidates.ts";
import { chaseGoal, DEFAULT_FIELDS, nodeGoal, targetValue, type CommandFields } from "./command.ts";
import type { Decider } from "./brain.ts";

export const RETREAT_BELOW_HP = 40;
export const CHASE_FRESHNESS_MS = 6_000;
export const RELOAD_AT_CLIP = 8;

function nearestVisible(obs: Observation): VisibleEnemy | undefined {
  return [...obs.enemies.visible].sort((a, b) => a.dist - b.dist)[0];
}

function movement(obs: Observation, memory: BotMemory, candidates: readonly Candidate[], target: VisibleEnemy | undefined): Partial<CommandFields> {
  const cover = candidates.find(candidate => candidate.kind === "cover");
  if (obs.hp < RETREAT_BELOW_HP && cover !== undefined) return { g: nodeGoal(cover.node), s: "stand" };
  if (target !== undefined) return { g: chaseGoal(target.id) };
  const enemy = memory.freshestEnemy();
  if (enemy !== undefined && obs.gameTimeMs - enemy.seenAtMs < CHASE_FRESHNESS_MS) return { g: chaseGoal(enemy.id) };
  const unexplored = candidates.find(candidate => candidate.kind === "unexplored");
  if (unexplored !== undefined) return { g: nodeGoal(unexplored.node) };
  return { g: "hold" };
}

function weapon(obs: Observation, target: VisibleEnemy | undefined): string {
  if (target === undefined && obs.clip <= RELOAD_AT_CLIP && obs.reserve > 0) return "reload";
  return "keep";
}

/** The control brain: same executor, no model. */
export function scriptedBrain(obs: Observation, memory: BotMemory, candidates: readonly Candidate[]): CommandFields {
  const target = nearestVisible(obs);
  return { ...DEFAULT_FIELDS, t: targetValue(target?.id), e: "f", ...movement(obs, memory, candidates, target), w: weapon(obs, target) };
}

export const scriptedDecider: Decider = async input => ({ fields: scriptedBrain(input.obs, input.memory, input.candidates), trace: undefined });
