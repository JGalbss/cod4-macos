import type { Observation, Vec3 } from "./observation.ts";
import { predictedPosition, type BotMemory, type Sighting } from "./memory.ts";
import { distance2d, shortestPath, type WaypointGraph } from "./waypoints.ts";
import { MapKnowledge } from "./map.ts";

export type Candidate =
  | { readonly kind: "cover"; readonly node: number; readonly pathUnits: number; readonly enemyId: number }
  | { readonly kind: "toward_enemy"; readonly node: number; readonly pathUnits: number; readonly enemyId: number }
  | { readonly kind: "unexplored"; readonly node: number; readonly pathUnits: number; readonly lastVisitMs: number | undefined }
  | { readonly kind: "far"; readonly node: number; readonly pathUnits: number; readonly lastVisitMs: number | undefined }
  | { readonly kind: "flank"; readonly node: number; readonly pathUnits: number; readonly enemyId: number }
  | { readonly kind: "hold"; readonly node: number };

export interface CandidateInput {
  readonly obs: Observation;
  readonly memory: BotMemory;
  readonly graph: WaypointGraph;
  /** Sightline knowledge; without it cover and flank fall back to distance and angle heuristics. */
  readonly map?: MapKnowledge;
}

interface Reach {
  readonly node: number;
  readonly pathUnits: number;
}

export const COVER_MIN_UNITS = 350;
export const EXPLORE_RADIUS_UNITS = 400;
/** Beyond this a node counts as a different part of the map worth crossing to. */
export const FAR_MIN_UNITS = 700;
const FAR_WITHOUT_ENEMY = 2;
export const FLANK_MIN_UNITS = 200;
export const FLANK_MAX_UNITS = 400;
export const FLANK_TOLERANCE_DEG = 35;
const UNEXPLORED_WITHOUT_ENEMY = 3;

function reach(input: CandidateInput, node: number, taken: ReadonlySet<number>): Reach | undefined {
  if (node === input.obs.nav.node || taken.has(node)) return undefined;
  const path = shortestPath(input.graph, input.obs.nav.node, node, input.map?.blockedLinks);
  if (path === undefined) return undefined;
  return { node, pathUnits: Math.round(path.units) };
}

function reachable(input: CandidateInput, nodes: readonly number[], taken: ReadonlySet<number>): Reach[] {
  return nodes.map(node => reach(input, node, taken)).flatMap(entry => (entry === undefined ? [] : [entry]));
}

function nodesWhere(input: CandidateInput, keep: (pos: Vec3) => boolean): number[] {
  return input.graph.nodes.filter(node => keep(node.pos)).map(node => node.index);
}

function dot2d(a: readonly number[], b: readonly number[]): number {
  return a[0] * b[0] + a[1] * b[1];
}

function offset(from: Vec3, to: Vec3): [number, number] {
  return [to[0] - from[0], to[1] - from[1]];
}

function knowledge(input: CandidateInput): MapKnowledge | undefined {
  return input.map !== undefined && input.map.ready ? input.map : undefined;
}

/** Nodes far from the enemy prediction and behind the bot relative to it, nearest by path first. */
function coverByGeometry(input: CandidateInput, enemyPos: Vec3): number[] {
  const self = input.obs.pos;
  const toEnemy = offset(self, enemyPos);
  return nodesWhere(input, pos => distance2d(pos, enemyPos) > COVER_MIN_UNITS && dot2d(offset(self, pos), toEnemy) < 0);
}

/** With sightlines known: the nearest node the enemy's expected position cannot see, the least exposed first among ties. */
function coverCandidate(input: CandidateInput, enemy: Sighting, enemyPos: Vec3, taken: ReadonlySet<number>): Candidate | undefined {
  const map = knowledge(input);
  const hidden = map === undefined ? coverByGeometry(input, enemyPos) : map.hiddenFrom(map.nodeAt(enemyPos));
  const ranked = reachable(input, hidden, taken).sort((a, b) => a.pathUnits + (map?.openness(a.node) ?? 0) * 4 - (b.pathUnits + (map?.openness(b.node) ?? 0) * 4));
  const best = ranked[0];
  if (best === undefined) return undefined;
  return { kind: "cover", node: best.node, pathUnits: best.pathUnits, enemyId: enemy.id };
}

function towardEnemyCandidate(input: CandidateInput, enemy: Sighting, enemyPos: Vec3, taken: ReadonlySet<number>): Candidate | undefined {
  const byDistance = [...input.graph.nodes].sort((a, b) => distance2d(a.pos, enemyPos) - distance2d(b.pos, enemyPos)).map(node => node.index);
  const best = reachable(input, byDistance.slice(0, 3), taken)[0];
  if (best === undefined) return undefined;
  return { kind: "toward_enemy", node: best.node, pathUnits: best.pathUnits, enemyId: enemy.id };
}

function visitOrder(input: CandidateInput, a: Reach, b: Reach): number {
  const lastA = input.memory.visit(a.node)?.lastVisitMs;
  const lastB = input.memory.visit(b.node)?.lastVisitMs;
  if (lastA === undefined && lastB !== undefined) return -1;
  if (lastB === undefined && lastA !== undefined) return 1;
  if (lastA !== undefined && lastB !== undefined && lastA !== lastB) return lastA - lastB;
  return a.pathUnits - b.pathUnits;
}

/** Least recently visited reachable nodes within the exploration radius. */
function unexploredCandidates(input: CandidateInput, count: number, taken: ReadonlySet<number>): Candidate[] {
  const self = input.obs.pos;
  const nearby = nodesWhere(input, pos => distance2d(pos, self) <= EXPLORE_RADIUS_UNITS);
  return reachable(input, nearby, taken)
    .sort((a, b) => visitOrder(input, a, b))
    .slice(0, count)
    .map(entry => ({ kind: "unexplored", node: entry.node, pathUnits: entry.pathUnits, lastVisitMs: input.memory.visit(entry.node)?.lastVisitMs }));
}

function flankDeviation(self: Vec3, enemyPos: Vec3, pos: Vec3): number {
  const toEnemy = offset(self, enemyPos);
  const toNode = offset(self, pos);
  const cosine = dot2d(toEnemy, toNode) / (Math.hypot(...toEnemy) * Math.hypot(...toNode));
  const angle = (Math.acos(Math.min(1, Math.max(-1, cosine))) * 180) / Math.PI;
  return Math.abs(angle - 90);
}

/** Angle at the enemy between the line to the bot and the line to a node: a real flank approaches from a new side. */
function approachAngle(self: Vec3, enemyPos: Vec3, pos: Vec3): number {
  const toSelf = offset(enemyPos, self);
  const toNode = offset(enemyPos, pos);
  const cosine = dot2d(toSelf, toNode) / (Math.hypot(...toSelf) * Math.hypot(...toNode));
  return (Math.acos(Math.min(1, Math.max(-1, cosine))) * 180) / Math.PI;
}

export const FLANK_MIN_APPROACH_DEG = 50;

/** A node 200 to 400 units away, roughly perpendicular to the enemy bearing; with sightlines known, one that sees the enemy's node from a new side. */
function flankCandidate(input: CandidateInput, enemy: Sighting, enemyPos: Vec3, taken: ReadonlySet<number>): Candidate | undefined {
  const self = input.obs.pos;
  const map = knowledge(input);
  if (map !== undefined) {
    const enemyNode = map.nodeAt(enemyPos);
    const sides = map.seeing(enemyNode).filter(node => {
      const pos = input.graph.nodes[node].pos;
      const range = distance2d(pos, self);
      return range >= FLANK_MIN_UNITS && range <= FLANK_MAX_UNITS + 100 && approachAngle(self, enemyPos, pos) >= FLANK_MIN_APPROACH_DEG;
    });
    const best = reachable(input, sides, taken).sort((a, b) => a.pathUnits - b.pathUnits)[0];
    if (best !== undefined) return { kind: "flank", node: best.node, pathUnits: best.pathUnits, enemyId: enemy.id };
  }
  const ring = nodesWhere(input, pos => {
    const range = distance2d(pos, self);
    return range >= FLANK_MIN_UNITS && range <= FLANK_MAX_UNITS && flankDeviation(self, enemyPos, pos) <= FLANK_TOLERANCE_DEG;
  });
  const best = reachable(input, ring, taken).sort((a, b) => flankDeviation(self, enemyPos, input.graph.nodes[a.node].pos) - flankDeviation(self, enemyPos, input.graph.nodes[b.node].pos))[0];
  if (best === undefined) return undefined;
  return { kind: "flank", node: best.node, pathUnits: best.pathUnits, enemyId: enemy.id };
}

function nodesOf(candidates: readonly (Candidate | undefined)[]): Set<number> {
  return new Set(candidates.flatMap(candidate => (candidate === undefined ? [] : [candidate.node])));
}

function spanUnits(input: CandidateInput): number {
  const xs = input.graph.nodes.map(node => node.pos[0]);
  const ys = input.graph.nodes.map(node => node.pos[1]);
  return Math.max(Math.max(...xs) - Math.min(...xs), Math.max(...ys) - Math.min(...ys));
}

/** Least recently visited nodes far across the map, one per compass sector, so a big map is crossed rather than orbited. */
function farCandidates(input: CandidateInput, count: number, taken: ReadonlySet<number>): Candidate[] {
  const self = input.obs.pos;
  const minUnits = Math.max(FAR_MIN_UNITS, spanUnits(input) * 0.3);
  const far = nodesWhere(input, pos => distance2d(pos, self) >= minUnits);
  const ranked = reachable(input, far, taken).sort((a, b) => visitOrder(input, a, b));
  const sectors = new Set<string>();
  const picked: Candidate[] = [];
  for (const entry of ranked) {
    const pos = input.graph.nodes[entry.node].pos;
    const sector = `${Math.sign(pos[0] - self[0])}:${Math.sign(pos[1] - self[1])}`;
    if (sectors.has(sector)) continue;
    sectors.add(sector);
    picked.push({ kind: "far", node: entry.node, pathUnits: entry.pathUnits, lastVisitMs: input.memory.visit(entry.node)?.lastVisitMs });
    if (picked.length >= count) break;
  }
  return picked;
}

/** Up to five movement targets, each on its own node: cover, toward the enemy, unexplored, flank, and the current node as hold. */
export function selectCandidates(input: CandidateInput): readonly Candidate[] {
  const hold: Candidate = { kind: "hold", node: input.obs.nav.node };
  const enemy = input.memory.freshestEnemy();
  if (enemy === undefined) {
    const near = unexploredCandidates(input, UNEXPLORED_WITHOUT_ENEMY, new Set());
    const far = farCandidates(input, FAR_WITHOUT_ENEMY, nodesOf(near));
    return [...near, ...far, hold];
  }
  const enemyPos = predictedPosition(enemy, input.obs.gameTimeMs);
  const cover = coverCandidate(input, enemy, enemyPos, new Set());
  const toward = towardEnemyCandidate(input, enemy, enemyPos, nodesOf([cover]));
  const unexplored = unexploredCandidates(input, 1, nodesOf([cover, toward]))[0];
  const flank = flankCandidate(input, enemy, enemyPos, nodesOf([cover, toward, unexplored]));
  const far = farCandidates(input, 1, nodesOf([cover, toward, unexplored, flank]))[0];
  return [...[cover, toward, unexplored, flank, far].flatMap(candidate => (candidate === undefined ? [] : [candidate])), hold];
}
