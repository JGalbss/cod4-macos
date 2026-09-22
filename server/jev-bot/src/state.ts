import type { BombSite, Observation, Teammate, Vec3, VisibleEnemy } from "./observation.ts";
import { predictedPosition, type BotMemory, type Sighting } from "./memory.ts";
import type { Candidate } from "./candidates.ts";
import { distance2d, graphCenter, nearestNode, type WaypointGraph } from "./waypoints.ts";
import { aimErrorDeg, ATTACKED_WINDOW_MS } from "./questions.ts";
import { areaName, bearingTo, exposurePhrase, lossPhrase, motionPhrase, relativeMotionPhrase, seconds, weaponName } from "./phrases.ts";
import { MapKnowledge } from "./map.ts";
import type { RoundLog } from "./rounds.ts";

export interface YouView {
  readonly hp: number;
  readonly pos: readonly [number, number];
  readonly facing: number;
  readonly moving: string;
  readonly weapon: string;
  readonly clip: number;
  readonly reserve: number;
  readonly ready: boolean;
  readonly reloading: boolean;
  readonly grenades: number;
  readonly tactical: string;
  readonly killstreak: string;
  readonly stance: string;
  readonly node: number;
  readonly area: string;
  readonly target: number | undefined;
}

export interface VisibleEnemyView {
  readonly id: number;
  readonly dist: number;
  readonly bearing: number;
  readonly elev: number;
  readonly exposed: string;
  readonly moving: string;
  readonly aim_error: number;
  readonly seen_for: number;
  readonly shooting_you: boolean;
  readonly looking_at_you: boolean;
}

export interface RememberedEnemyView {
  readonly id: number;
  readonly last_seen_s: number;
  readonly last_pos: readonly [number, number];
  readonly bearing: number;
  readonly dist: number;
  readonly was_moving: string;
  readonly predicted: readonly [number, number];
  readonly lost: string | undefined;
}

export interface GunfireView {
  readonly bearing: number;
  readonly dist: number;
  readonly age_s: number;
}

export interface ThreatsView {
  readonly damage_taken_2s: number;
  readonly from_bearing: number | undefined;
  readonly gunfire_heard: readonly GunfireView[];
  /** Where enemies were seen in the last 15 s, freshest first: "north lane (open): enemy 2, 4s ago". */
  readonly enemies_seen_at: readonly string[];
  /** Where you died in the last minute, newest first. */
  readonly you_died_at: readonly string[];
}

export interface MovementView {
  readonly goal: string;
  readonly remaining: number;
  readonly progress_ok: boolean;
}

export interface RecentView {
  readonly kills: number;
  readonly deaths: number;
  readonly hits_landed_10s: number;
  readonly shots_10s: number;
}

export interface SiteView {
  readonly label: string;
  readonly dist: number;
  readonly bearing: number;
  readonly place: string;
  readonly status: string;
}

export interface TeammateView {
  readonly id: number;
  readonly dist: number;
  readonly place: string;
  readonly doing: string;
}

export interface ObjectiveView {
  readonly role: string;
  readonly round: number;
  readonly bomb: string;
  readonly round_left_s: number | undefined;
  readonly sites: readonly SiteView[];
  readonly teammates: readonly TeammateView[];
  /** Earlier rounds, oldest first, so the plan can change from round to round. */
  readonly history: readonly string[];
}

export interface MapCoverageView {
  /** Share of waypoints visited this life and match. */
  readonly visited_pct: number;
  /** Place words for parts of the map never visited, farthest first. */
  readonly unvisited_regions: readonly string[];
}

export interface JevState {
  readonly task: string;
  readonly you: YouView;
  readonly map_coverage: MapCoverageView;
  /** Present only in objective modes such as Search and Destroy. */
  readonly objective?: ObjectiveView;
  readonly enemies_visible: readonly VisibleEnemyView[];
  readonly enemies_remembered: readonly RememberedEnemyView[];
  readonly threats: ThreatsView;
  readonly movement: MovementView;
  readonly recent: RecentView;
}

export interface StateContext {
  readonly task: string;
  readonly graph: WaypointGraph;
  readonly map?: MapKnowledge;
  readonly rounds?: RoundLog;
}

const THREAT_WINDOW_MS = 2_000;
const MAX_REMEMBERED = 4;
const MAX_GUNFIRE = 4;
const MAX_DEATHS = 2;
interface GoalForm {
  readonly pattern: RegExp;
  readonly phrase: (match: RegExpExecArray, obs: Observation, context: StateContext) => string;
}

function nodePhrase(match: RegExpExecArray, _obs: Observation, context: StateContext): string {
  const index = Number(match[1]);
  const waypoint = context.graph.nodes[index];
  if (waypoint === undefined) return `node ${index}`;
  return `node ${index} (${areaName(waypoint.pos, graphCenter(context.graph))})`;
}

const GOAL_FORMS: readonly GoalForm[] = [
  { pattern: /^n(\d+)$/, phrase: nodePhrase },
  { pattern: /^chase(\d+)$/, phrase: match => `chasing enemy ${match[1]}` },
  { pattern: /^hold$/, phrase: (_match, obs) => `holding at node ${obs.nav.node}` },
];

function point(pos: readonly number[]): readonly [number, number] {
  return [Math.round(pos[0]), Math.round(pos[1])];
}

function youView(obs: Observation, context: StateContext): YouView {
  return {
    hp: Math.round(obs.hp),
    pos: point(obs.pos),
    facing: Math.round(obs.yaw),
    moving: motionPhrase(obs.vel),
    weapon: weaponName(obs.weapon),
    clip: obs.clip,
    reserve: obs.reserve,
    ready: obs.ready,
    reloading: obs.reloading,
    grenades: obs.grenades,
    tactical: `${obs.tactical} ${tacticalWord(obs.tacticalName)}`,
    killstreak: streakWord(obs.streak),
    stance: obs.stance,
    node: obs.nav.node,
    area: placeOf(obs.nav.node, obs.pos, context),
    target: obs.aim?.target,
  };
}

function visibleView(obs: Observation, memory: BotMemory, enemy: VisibleEnemy): VisibleEnemyView {
  return {
    id: enemy.id,
    dist: Math.round(enemy.dist),
    bearing: Math.round(enemy.bearing),
    elev: Math.round(enemy.elev),
    exposed: exposurePhrase(enemy.exposed),
    moving: relativeMotionPhrase(enemy.pos, enemy.vel, obs.pos, obs.yaw),
    aim_error: aimErrorDeg(obs, enemy.id, enemy.bearing, enemy.elev),
    seen_for: seconds(enemy.seenMs),
    shooting_you: memory.attackedBy(enemy.id, ATTACKED_WINDOW_MS),
    looking_at_you: enemy.facingUs,
  };
}

function rememberedView(obs: Observation, sighting: Sighting): RememberedEnemyView {
  const predicted = predictedPosition(sighting, obs.gameTimeMs);
  return {
    id: sighting.id,
    last_seen_s: seconds(obs.gameTimeMs - sighting.seenAtMs),
    last_pos: point(sighting.pos),
    bearing: bearingTo(obs.pos, obs.yaw, predicted),
    dist: Math.round(distance2d(obs.pos, predicted)),
    was_moving: motionPhrase(sighting.vel),
    predicted: point(predicted),
    lost: sighting.lost === undefined ? undefined : lossPhrase(sighting.lost),
  };
}

const STREAK_WORDS: Readonly<Record<string, string>> = {
  radar_mp: "UAV ready to call in",
  airstrike_mp: "airstrike ready to call in",
  artillery_mp: "artillery barrage ready to call in",
  agm_mp: "Hellfire missile earned, but you cannot fly it",
  asf_mp: "fighter support ready to call in",
  helicopter_mp: "attack helicopter ready to call in",
  predator_mp: "Predator drone earned, but you cannot fly it",
  ac130_mp: "AC130 gunship ready to call in",
  mannedheli_mp: "manned helicopter earned, but you cannot fly it",
  nuke_mp: "tactical nuke ready to call in",
};

function streakWord(item: string): string {
  return STREAK_WORDS[item] ?? "none earned yet (3 kills UAV, 5 airstrike, 7 artillery, 11 fighter support, 13 helicopter)";
}

function tacticalWord(name: string): string {
  if (name.startsWith("flash")) return "flashbang";
  if (name.startsWith("concussion")) return "stun grenade";
  if (name.startsWith("smoke")) return "smoke grenade";
  return "special grenade";
}

const MAX_UNVISITED_REGIONS = 4;

function coverageView(obs: Observation, memory: BotMemory, context: StateContext): MapCoverageView {
  const visited = new Set(memory.visits().map(visit => visit.node));
  const nodes = context.graph.nodes;
  const unvisited = nodes.filter(node => !visited.has(node.index)).sort((a, b) => distance2d(b.pos, obs.pos) - distance2d(a.pos, obs.pos));
  const regions: string[] = [];
  for (const node of unvisited) {
    const place = placeOf(node.index, node.pos, context).replace(/ \((open|covered|enclosed)\)$/, "");
    if (!regions.includes(place)) regions.push(place);
    if (regions.length >= MAX_UNVISITED_REGIONS) break;
  }
  return { visited_pct: nodes.length === 0 ? 0 : Math.round((visited.size / nodes.length) * 100), unvisited_regions: regions };
}

/** Sightline-aware place words when the map is known, compass words before that. */
function placeOf(node: number, pos: Vec3, context: StateContext): string {
  if (context.map !== undefined) return context.map.describe(node);
  return areaName(pos, graphCenter(context.graph));
}

function placeAt(pos: Vec3, context: StateContext): string {
  return placeOf(nearestNode(context.graph, pos), pos, context);
}

function threatsView(obs: Observation, memory: BotMemory, context: StateContext): ThreatsView {
  const damage = memory.damageTaken(THREAT_WINDOW_MS);
  const visibleIds = new Set(obs.enemies.visible.map(enemy => enemy.id));
  return {
    damage_taken_2s: damage.reduce((total, hit) => total + hit.amount, 0),
    from_bearing: damage[0] === undefined ? undefined : Math.round(damage[0].bearing),
    gunfire_heard: memory.gunfireHeard(THREAT_WINDOW_MS).slice(0, MAX_GUNFIRE).map(shot => ({ bearing: Math.round(shot.bearing), dist: Math.round(shot.dist), age_s: seconds(memory.nowMs - shot.atMs) })),
    enemies_seen_at: memory.sightings().filter(sighting => !visibleIds.has(sighting.id)).slice(0, MAX_REMEMBERED).map(sighting => `${placeAt(sighting.pos, context)}: enemy ${sighting.id}, ${seconds(obs.gameTimeMs - sighting.seenAtMs)}s ago`),
    you_died_at: memory.recentDeaths().slice(0, MAX_DEATHS).map(death => `${placeAt(death.pos, context)}, ${seconds(obs.gameTimeMs - death.atMs)}s ago`),
  };
}

function goalPhrase(obs: Observation, context: StateContext): string {
  for (const form of GOAL_FORMS) {
    const match = form.pattern.exec(obs.nav.goal);
    if (match !== null) return form.phrase(match, obs, context);
  }
  return "none";
}

/** Movement options are the `move` question's criteria; repeating them here only costs tokens. */
function movementView(obs: Observation, context: StateContext): MovementView {
  return {
    goal: goalPhrase(obs, context),
    remaining: Math.round(obs.nav.remaining),
    progress_ok: !obs.nav.stuck,
  };
}

function recentView(memory: BotMemory): RecentView {
  const window = memory.tally();
  const totals = memory.totals();
  return { kills: totals.kills, deaths: totals.deaths, hits_landed_10s: window.hits, shots_10s: window.shots };
}

function siteStatus(site: BombSite, obs: Observation): string {
  const where = site.touching ? "you are in the zone" : "";
  const bomb = site.planted ? "bomb planted here" : site.occupied ? "someone is in the zone" : "no bomb";
  return [bomb, where].filter(text => text !== "").join(", ");
}

function bombPhrase(obs: Observation): string {
  const objective = obs.objective;
  if (!objective.planted) return objective.role === "attack" ? "not planted yet: plant it at a site" : "not planted: stop them or hold the sites";
  const left = objective.bombLeftMs >= 0 ? `, explodes in ${seconds(objective.bombLeftMs)}s` : "";
  return objective.role === "attack" ? `planted${left}: defend it` : `planted${left}: defuse it or lose the round`;
}

function teammateDoing(mate: Teammate): string {
  if (mate.planting) return "planting or defusing right now";
  if (mate.goal.startsWith("site")) return `heading to site ${mate.goal.slice(4)}`;
  if (mate.goal.startsWith("chase")) return `chasing enemy ${mate.goal.slice(5)}`;
  if (mate.goal === "hold") return "holding position";
  if (mate.goal === "cover" || mate.goal === "glitch") return "in cover";
  return "moving";
}

function objectiveView(obs: Observation, context: StateContext): ObjectiveView | undefined {
  const objective = obs.objective;
  if (objective.role === "none") return undefined;
  return {
    role: objective.role === "attack" ? "attacker: plant the bomb at site A or B (every attacker carries a bomb)" : "defender: keep the bomb from being planted, defuse it if it is",
    round: context.rounds?.roundNumber ?? 1,
    bomb: bombPhrase(obs),
    round_left_s: objective.roundLeftMs >= 0 ? seconds(objective.roundLeftMs) : undefined,
    sites: objective.sites.map(site => ({ label: site.label, dist: Math.round(site.dist), bearing: Math.round(site.bearing), place: placeAt(site.pos, context), status: siteStatus(site, obs) })),
    teammates: obs.enemies.team.map(mate => ({ id: mate.id, dist: Math.round(distance2d(obs.pos, mate.pos)), place: placeAt(mate.pos, context), doing: teammateDoing(mate) })),
    history: context.rounds?.summary(objective.role) ?? [],
  };
}

/** The compact state Jev reads. Bearings are relative to facing (positive left), distances in units, times in seconds. */
export function buildState(obs: Observation, memory: BotMemory, candidates: readonly Candidate[], context: StateContext): JevState {
  const visibleIds = new Set(obs.enemies.visible.map(enemy => enemy.id));
  const remembered = memory.sightings().filter(sighting => !visibleIds.has(sighting.id)).slice(0, MAX_REMEMBERED);
  const objective = objectiveView(obs, context);
  return {
    task: context.task,
    you: youView(obs, context),
    map_coverage: coverageView(obs, memory, context),
    ...(objective === undefined ? {} : { objective }),
    enemies_visible: [...obs.enemies.visible].sort((a, b) => a.dist - b.dist).map(enemy => visibleView(obs, memory, enemy)),
    enemies_remembered: remembered.map(sighting => rememberedView(obs, sighting)),
    threats: threatsView(obs, memory, context),
    movement: movementView(obs, context),
    recent: recentView(memory),
  };
}

/** Rough token count: one token per four characters of compact JSON. */
export function estimateTokens(value: unknown): number {
  return Math.ceil(JSON.stringify(value).length / 4);
}
