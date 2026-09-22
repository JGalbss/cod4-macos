import type { JevQuestions } from "./jev.ts";
import type { BombSite, Observation, Vec3 } from "./observation.ts";
import { predictedPosition, SIGHTING_MEMORY_MS, type BotMemory, type Sighting } from "./memory.ts";
import type { Candidate } from "./candidates.ts";
import { distance2d, graphCenter, nearestNode, shortestPath, type WaypointGraph } from "./waypoints.ts";
import { areaName, exposurePhrase, relativeMotionPhrase, seconds } from "./phrases.ts";
import { MapKnowledge } from "./map.ts";

export type EngageOption =
  | { readonly kind: "attack"; readonly id: string; readonly enemyId: number; readonly criteria: string }
  | { readonly kind: "knife"; readonly id: string; readonly enemyId: number; readonly criteria: string }
  | { readonly kind: "hold_fire"; readonly id: "hold_fire"; readonly trackId: number | undefined; readonly criteria: string };

export type MoveOption =
  | { readonly kind: "hold"; readonly id: "hold"; readonly node: number; readonly criteria: string }
  | { readonly kind: "advance"; readonly id: string; readonly node: number; readonly criteria: string }
  | { readonly kind: "retreat"; readonly id: string; readonly node: number; readonly criteria: string }
  | { readonly kind: "chase"; readonly id: string; readonly enemyId: number; readonly criteria: string }
  | { readonly kind: "site"; readonly id: string; readonly label: string; readonly criteria: string }
  | { readonly kind: "cover_now"; readonly id: "cover_now"; readonly enemyId: number; readonly criteria: string }
  | { readonly kind: "head_glitch"; readonly id: "head_glitch"; readonly enemyId: number; readonly criteria: string }
  | { readonly kind: "rush"; readonly id: string; readonly enemyId: number; readonly criteria: string };

export type PostureOption =
  | { readonly kind: "stand"; readonly id: "stand"; readonly criteria: string }
  | { readonly kind: "crouch"; readonly id: "crouch"; readonly criteria: string }
  | { readonly kind: "prone"; readonly id: "dropshot"; readonly criteria: string }
  | { readonly kind: "jump"; readonly id: "jumpshot"; readonly criteria: string };

export type WeaponOption =
  | { readonly kind: "keep"; readonly id: "keep"; readonly criteria: string }
  | { readonly kind: "reload"; readonly id: "reload"; readonly criteria: string }
  | { readonly kind: "plant"; readonly id: "plant"; readonly criteria: string }
  | { readonly kind: "defuse"; readonly id: "defuse"; readonly criteria: string }
  | { readonly kind: "grenade"; readonly id: string; readonly enemyId: number; readonly target: Vec3; readonly criteria: string }
  | { readonly kind: "tactical"; readonly id: string; readonly enemyId: number; readonly target: Vec3; readonly criteria: string }
  | { readonly kind: "streak"; readonly id: "streak"; readonly criteria: string };

export interface DecisionOptions {
  readonly engage: readonly EngageOption[];
  readonly move: readonly MoveOption[];
  readonly posture: readonly PostureOption[];
  readonly weapon: readonly WeaponOption[];
}

export interface DecisionQuestions {
  readonly questions: JevQuestions;
  readonly options: DecisionOptions;
}

export interface OptionInput {
  readonly obs: Observation;
  readonly memory: BotMemory;
  readonly candidates: readonly Candidate[];
  readonly graph: WaypointGraph;
  readonly map?: MapKnowledge;
}

export const GRENADE_MIN_UNITS = 150;
export const GRENADE_MAX_UNITS = 800;
/** Inside this range a visible enemy is shot, not fragged: the throw takes the hands for about a second. */
export const GRENADE_SHOOT_INSTEAD_UNITS = 350;
export const TACTICAL_MIN_UNITS = 120;
export const TACTICAL_MAX_UNITS = 700;
/** A visible enemy this close is shot, not flashed. */
export const TACTICAL_SHOOT_INSTEAD_UNITS = 250;
export const ATTACKED_WINDOW_MS = 2_000;
const MAX_CHASE_OPTIONS = 3;
/** Older sightings are offered as nodes toward the last position, not as chases. */
export const CHASE_MAX_AGE_MS = 6_000;
const MAX_GRENADE_OPTIONS = 2;

/** Angular error to an enemy: the fixture's tracked error when it is the target, else the offset from the view. */
export function aimErrorDeg(obs: Observation, enemyId: number, bearing: number, elev: number): number {
  const aim = obs.aim;
  if (aim !== undefined && aim.target === enemyId) return Math.round(aim.errorDeg);
  return Math.round(Math.hypot(bearing, elev));
}

function attackCriteria(obs: Observation, memory: BotMemory, enemyId: number): string | undefined {
  const enemy = obs.enemies.visible.find(candidate => candidate.id === enemyId);
  if (enemy === undefined) return undefined;
  const motion = relativeMotionPhrase(enemy.pos, enemy.vel, obs.pos, obs.yaw);
  const shooting = memory.attackedBy(enemy.id, ATTACKED_WINDOW_MS) ? ", shooting you" : "";
  const facing = enemy.facingUs ? "" : ", back turned to you";
  return `enemy ${enemy.id}: ${Math.round(enemy.dist)}u, ${exposurePhrase(enemy.exposed)}, aim error ${aimErrorDeg(obs, enemy.id, enemy.bearing, enemy.elev)} deg, ${motion}${shooting}${facing}`;
}

export const KNIFE_MAX_UNITS = 600;

/** A sneak-and-stab is offered for an enemy who faces away, is not shooting us, and is within a short walk. */
function knifeOptions(obs: Observation, memory: BotMemory): readonly EngageOption[] {
  return obs.enemies.visible
    .filter(enemy => !enemy.facingUs && enemy.dist <= KNIFE_MAX_UNITS && !memory.attackedBy(enemy.id, ATTACKED_WINDOW_MS))
    .map(enemy => ({ kind: "knife", id: `knife_${enemy.id}`, enemyId: enemy.id, criteria: `sneak up and knife enemy ${enemy.id}: back turned, ${Math.round(enemy.dist)}u; you stop shooting and crouch-walk to them, one hit kills, fails if they turn around` }));
}

function holdFireCriteria(obs: Observation, nearest: number): string {
  if (obs.reloading) return `reloading: track enemy ${nearest} without firing until the reload ends`;
  return `track enemy ${nearest} without firing: only right when they have not noticed you and you want them closer`;
}

/** No question when nothing is visible: the executor already fires back at whoever appears. */
export function engageOptions(obs: Observation, memory: BotMemory): readonly EngageOption[] {
  const visible = [...obs.enemies.visible].sort((a, b) => a.dist - b.dist);
  const nearest = visible[0]?.id;
  if (nearest === undefined) return [];
  const attacks = visible.flatMap((enemy): EngageOption[] => {
    const criteria = attackCriteria(obs, memory, enemy.id);
    if (criteria === undefined) return [];
    return [{ kind: "attack", id: `attack_${enemy.id}`, enemyId: enemy.id, criteria }];
  });
  return [...attacks, ...knifeOptions(obs, memory), { kind: "hold_fire", id: "hold_fire", trackId: nearest, criteria: holdFireCriteria(obs, nearest) }];
}

/** Place words for a node: sightline-aware when the map is known, compass words before that. */
function placeOf(node: number, input: OptionInput, center: Vec3): string {
  if (input.map !== undefined) return input.map.describe(node);
  return areaName(input.graph.nodes[node].pos, center);
}

/** ", sees the enemy's expected position" or ", hidden from it", only when both the map and an enemy are known. */
function enemyRelation(node: number, input: OptionInput): string {
  const map = input.map;
  const enemy = input.memory.freshestEnemy();
  if (map === undefined || !map.ready || enemy === undefined) return "";
  const relation = map.relation(node, map.nodeAt(predictedPosition(enemy, input.obs.gameTimeMs)));
  return relation === "" ? "" : `, ${relation}`;
}

function candidateOption(candidate: Candidate, input: OptionInput, center: Vec3): MoveOption {
  const area = placeOf(candidate.node, input, center);
  if (candidate.kind === "hold") return { kind: "hold", id: "hold", node: candidate.node, criteria: `stay at node ${candidate.node}, ${area}${enemyRelation(candidate.node, input)}` };
  if (candidate.kind === "cover") return { kind: "retreat", id: `retreat_n${candidate.node}`, node: candidate.node, criteria: `cover at ${area}, ${candidate.pathUnits}u${enemyRelation(candidate.node, input)}` };
  if (candidate.kind === "toward_enemy") return { kind: "advance", id: `advance_n${candidate.node}`, node: candidate.node, criteria: `${area}, ${candidate.pathUnits}u, nearest to enemy ${candidate.enemyId}'s expected position` };
  if (candidate.kind === "flank") return { kind: "advance", id: `advance_n${candidate.node}`, node: candidate.node, criteria: `${area}, ${candidate.pathUnits}u, flanks enemy ${candidate.enemyId} from a new side${enemyRelation(candidate.node, input)}` };
  const visited = candidate.lastVisitMs === undefined ? "unexplored" : `last visited ${seconds(input.obs.gameTimeMs - candidate.lastVisitMs)}s ago`;
  if (candidate.kind === "far") return { kind: "advance", id: `advance_n${candidate.node}`, node: candidate.node, criteria: `cross the map to ${area}, ${candidate.pathUnits}u away, ${visited}; a different part of the map${enemyRelation(candidate.node, input)}` };
  return { kind: "advance", id: `advance_n${candidate.node}`, node: candidate.node, criteria: `${area}, ${candidate.pathUnits}u, ${visited}${enemyRelation(candidate.node, input)}` };
}

function chaseOption(sighting: Sighting, input: OptionInput): MoveOption {
  const target = predictedPosition(sighting, input.obs.gameTimeMs);
  const dist = Math.round(distance2d(input.obs.pos, target));
  if (sighting.visible) return { kind: "chase", id: `chase_${sighting.id}`, enemyId: sighting.id, criteria: `chase enemy ${sighting.id}, ${dist}u, visible` };
  return { kind: "chase", id: `chase_${sighting.id}`, enemyId: sighting.id, criteria: `chase enemy ${sighting.id}, seen ${seconds(input.obs.gameTimeMs - sighting.seenAtMs)}s ago, ${dist}u to expected position` };
}

function knownEnemies(input: OptionInput): readonly Sighting[] {
  return input.memory.sightings().filter(sighting => input.obs.gameTimeMs - sighting.seenAtMs <= SIGHTING_MEMORY_MS);
}

function chaseable(input: OptionInput): readonly Sighting[] {
  return knownEnemies(input).filter(sighting => input.obs.gameTimeMs - sighting.seenAtMs <= CHASE_MAX_AGE_MS);
}

function siteState(site: BombSite, obs: Observation): string {
  if (site.planted) return obs.objective.role === "defend" ? "the bomb is planted here, defuse it" : "the bomb is planted here, defend it";
  if (site.occupied) return "someone is in the zone";
  return "no bomb planted";
}

const APPROACH_MIN_UNITS = 350;
const APPROACH_MAX_UNITS = 750;

/** A node near a site that the site itself cannot see (a covered approach), or one that sees it (overwatch). */
function siteRelatedNode(input: OptionInput, site: BombSite, seesSite: boolean): { node: number; units: number } | undefined {
  const map = input.map;
  if (map === undefined || !map.ready) return undefined;
  const siteNode = map.nodeAt(site.pos);
  const pool = seesSite ? map.seeing(siteNode) : map.hiddenFrom(siteNode);
  const ranked = pool
    .filter(node => node !== input.obs.nav.node)
    .map(node => ({ node, siteUnits: distance2d(input.graph.nodes[node].pos, site.pos) }))
    .filter(entry => entry.siteUnits >= APPROACH_MIN_UNITS && entry.siteUnits <= APPROACH_MAX_UNITS)
    .map(entry => ({ ...entry, path: shortestPath(input.graph, input.obs.nav.node, entry.node, map.blockedLinks) }))
    .filter((entry): entry is { node: number; siteUnits: number; path: NonNullable<ReturnType<typeof shortestPath>> } => entry.path !== undefined)
    .sort((a, b) => a.path.units - b.path.units);
  const best = ranked[0];
  if (best === undefined) return undefined;
  return { node: best.node, units: Math.round(best.path.units) };
}

/** Covered approaches and overwatch spots per site, so a push can come from a new side or be covered by a teammate. */
function siteTacticOptions(input: OptionInput, center: Vec3): readonly MoveOption[] {
  const objective = input.obs.objective;
  if (objective.role === "none") return [];
  return objective.sites.flatMap(site => {
    const options: MoveOption[] = [];
    const approach = siteRelatedNode(input, site, false);
    if (approach !== undefined && !site.touching) options.push({ kind: "advance", id: `approach_${site.label}_n${approach.node}`, node: approach.node, criteria: `approach site ${site.label} under cover via ${placeOf(approach.node, input, center)}, ${approach.units}u, out of the site's view until the last stretch` });
    const overwatch = siteRelatedNode(input, site, true);
    if (overwatch !== undefined) options.push({ kind: "advance", id: `overwatch_${site.label}_n${overwatch.node}`, node: overwatch.node, criteria: `overwatch site ${site.label} from ${placeOf(overwatch.node, input, center)}, ${overwatch.units}u, with a sightline onto the zone; cover a teammate's plant or wait for a planter` });
    return options;
  });
}

/** One option per bomb site: attackers go there to plant, defenders to guard or defuse. */
function siteOptions(input: OptionInput, center: Vec3): readonly MoveOption[] {
  const objective = input.obs.objective;
  if (objective.role === "none") return [];
  return objective.sites.map(site => {
    const place = placeOf(input.map?.nodeAt(site.pos) ?? nearestNode(input.graph, site.pos), input, center);
    const here = site.touching ? "you are in the zone" : `${Math.round(site.dist)}u, bearing ${Math.round(site.bearing)}`;
    return { kind: "site", id: `site_${site.label}`, label: site.label, criteria: `bomb site ${site.label}: ${here}, ${place}, ${siteState(site, input.obs)}` };
  });
}

/** Two steps behind the nearest object out of the enemy's line of fire; offered while an enemy is visible or has just hit the bot. */
function coverNowOption(input: OptionInput): readonly MoveOption[] {
  const obs = input.obs;
  const visible = [...obs.enemies.visible].sort((a, b) => a.dist - b.dist)[0];
  const recentHit = input.memory.damageTaken(ATTACKED_WINDOW_MS)[0];
  const enemyId = visible?.id ?? recentHit?.from;
  if (enemyId === undefined || enemyId < 0) return [];
  const taken = input.memory.damageTaken(ATTACKED_WINDOW_MS).reduce((total, hit) => total + hit.amount, 0);
  const state = taken > 0 ? `you took ${taken} damage in the last 2 s` : "before they land a shot";
  return [{ kind: "cover_now", id: "cover_now", enemyId, criteria: `cover now: duck behind the nearest object out of enemy ${enemyId}'s line of fire, one or two steps away, and fight from there; ${state}` }];
}

/** Crouch behind the nearest object that hides the body but keeps eyes on the enemy's expected position; a holding spot, not a chase. */
function headGlitchOption(input: OptionInput): readonly MoveOption[] {
  const enemy = input.memory.freshestEnemy();
  if (enemy === undefined) return [];
  const dist = Math.round(distance2d(input.obs.pos, predictedPosition(enemy, input.obs.gameTimeMs)));
  if (dist < 250 || dist > 1200) return [];
  return [{ kind: "head_glitch", id: "head_glitch", enemyId: enemy.id, criteria: `head glitch: settle crouched behind the nearest object that hides your body but leaves your eyes on enemy ${enemy.id}'s expected position (${dist}u), and hold that angle` }];
}

/** Sprint straight at a fresh enemy position to hit them before they settle. */
function rushOptions(input: OptionInput): readonly MoveOption[] {
  return chaseable(input).slice(0, 2).map(sighting => {
    const dist = Math.round(distance2d(input.obs.pos, predictedPosition(sighting, input.obs.gameTimeMs)));
    const hurt = input.memory.damageDealtTo(sighting.id, 4_000) > 0 ? "; you have already hurt them" : "";
    return { kind: "rush", id: `rush_${sighting.id}`, enemyId: sighting.id, criteria: `rush enemy ${sighting.id}: sprint straight at their position ${dist}u away and hit them before they settle${hurt}` };
  });
}

/** Candidate nodes plus chases toward fresh enemies, bomb sites in Search and Destroy, and hold only while an enemy is visible: standing still with nothing in sight never scores. */
export function moveOptions(input: OptionInput): readonly MoveOption[] {
  const center = graphCenter(input.graph);
  const nodes = input.candidates.filter(candidate => candidate.kind !== "hold").map(candidate => candidateOption(candidate, input, center));
  const chases = chaseable(input).slice(0, MAX_CHASE_OPTIONS).map(sighting => chaseOption(sighting, input));
  const sites = siteOptions(input, center);
  const holdAllowed = input.obs.enemies.visible.length > 0 || input.obs.objective.sites.some(site => site.touching);
  const hold = holdAllowed ? input.candidates.filter(candidate => candidate.kind === "hold").map(candidate => candidateOption(candidate, input, center)) : [];
  return [...coverNowOption(input), ...headGlitchOption(input), ...nodes, ...chases, ...rushOptions(input), ...sites, ...siteTacticOptions(input, center), ...hold];
}

export function postureOptions(obs?: Observation): readonly PostureOption[] {
  const base: PostureOption[] = [
    { kind: "stand", id: "stand", criteria: "stand: full speed and sprint; only while nobody is in view and you need to move" },
    { kind: "crouch", id: "crouch", criteria: "crouch: smaller target and tighter bursts at range; slow, so only while holding a spot" },
  ];
  const target = obs === undefined ? undefined : [...obs.enemies.visible].sort((a, b) => a.dist - b.dist)[0];
  if (target === undefined || obs === undefined || /m40a3|remington700|barrett|dragunov|m21/.test(obs.weapon)) return base;
  return [
    ...base,
    { kind: "prone", id: "dropshot", criteria: `dropshot: drop prone this instant and keep firing at enemy ${target.id} (${Math.round(target.dist)}u); the usual move when you open fire, shots aimed at your chest miss` },
    { kind: "jump", id: "jumpshot", criteria: target.seenMs < 700 && target.dist < 350 ? `jumpshot: you just came face to face with enemy ${target.id} at ${Math.round(target.dist)}u, jump this instant while firing; their first burst misses` : `jumpshot: jump right now while firing at enemy ${target.id}; throws off their aim for a moment, best when you round a corner into them` },
  ];
}

export const ENGAGE_INSTRUCTIONS = "Choose which visible enemy to track and fire at. The executor aims and bursts for you. Prefer the enemy shooting you, then the nearest exposed one. Knife an enemy whose back is turned when nobody else is shooting you: silent and certain if they do not turn. Hold fire only while reloading or to let an unaware enemy come closer.";
export const MOVE_INSTRUCTIONS = "Choose where to move for the next second or two. Kills are the score, so be where the enemies are. When you are being hit and not clearly winning (you took 40 or more damage in the last 2 s, or you are under 60 hp with an enemy in view), take cover now first and fight from behind it; re-peek once you have reloaded or they must come to you. Otherwise with an enemy visible, close to under 400u where one burst kills, or hold if you already have a clear shot and cover. Head glitch when you expect an enemy to come to you and you have a few seconds; rush an enemy you have hurt or who is reloading. Chase an enemy who breaks away or was seen in the last few seconds. With no enemy in sight, head toward the latest sighting, gunfire, or an unexplored area; on a big map do not orbit your spawn, cross to the parts of the map you have not covered (see map_coverage), because that is where the enemies are.";
export const POSTURE_INSTRUCTIONS = "Choose your stance. Jumpshot the instant an enemy first appears inside 350u or you round a corner into one. Dropshot in every other exchange of fire, at any range: pick it more often than not. Stand while travelling with nobody in view; crouch only when holding a spot at long range.";
/** Search and Destroy changes what movement is for; appended to the move instructions by role. */
function objectiveHint(obs: Observation): string {
  const objective = obs.objective;
  const mateSite = obs.enemies.team.find(mate => mate.goal.startsWith("site") || mate.planting);
  const pair = mateSite === undefined ? "" : ` Your teammate is already going to site ${mateSite.goal.startsWith("site") ? mateSite.goal.slice(4) : "?"}: do not stack on them, take an overwatch or the covered approach and cover their plant, or hit the other site to split the defence.`;
  if (objective.role === "attack") return objective.planted ? " The bomb is planted: stay near it and kill anyone who comes to defuse." : " You are attacking in Search and Destroy: the round is won by planting. Do not run the same straight line every round: read objective.history, hit the other site or come in by the covered approach, flash the zone before you enter, and plant as soon as it is clear. Hunting every defender first wastes the round clock." + pair;
  if (objective.role === "defend") return objective.planted ? " The bomb is planted: get to it and defuse, killing anyone guarding it." : " You are defending in Search and Destroy: hold a site with cover and a sightline onto the zone, from a spot you did not use last round; a planter standing still in the zone is an easy kill." + pair;
  return "";
}

function objectiveWeaponHint(obs: Observation): string {
  if (obs.objective.role === "none") return "";
  return " In a bomb zone with no enemy visible, plant or defuse at once; it takes 5 s and wins or saves the round.";
}

export const WEAPON_INSTRUCTIONS = "Choose a weapon action. Call in a killstreak the moment you have one and nobody is in view. Grenades are meant to be used, not saved, but thrown with purpose: frag an enemy who is behind cover, holding a spot, or just went out of sight 150 to 800u away; throw the stun or flash into the corner or room you are about to push, then rush in. Never lob at someone you can already shoot up close. Reload when the clip is under 10 and no enemy is visible, or under 5 in any case. Otherwise keep.";

function isFragWorthy(entry: { readonly sighting: Sighting; readonly dist: number }): boolean {
  if (entry.dist < GRENADE_MIN_UNITS || entry.dist > GRENADE_MAX_UNITS) return false;
  return !entry.sighting.visible || entry.dist >= GRENADE_SHOOT_INSTEAD_UNITS;
}

function grenadeCriteria(input: OptionInput, entry: { readonly sighting: Sighting; readonly dist: number }): string {
  const where = entry.sighting.visible ? "visible" : `seen ${seconds(input.obs.gameTimeMs - entry.sighting.seenAtMs)}s ago, likely behind cover`;
  return `frag enemy ${entry.sighting.id}'s expected position, ${entry.dist}u, ${where}; a kill or a flush-out, hands busy about 1s`;
}

function tacticalCriteria(input: OptionInput, entry: { readonly sighting: Sighting; readonly dist: number }): string {
  const name = input.obs.tacticalName.startsWith("concussion") ? "stun" : input.obs.tacticalName.startsWith("smoke") ? "smoke" : "flash";
  const where = entry.sighting.visible ? "visible" : `seen ${seconds(input.obs.gameTimeMs - entry.sighting.seenAtMs)}s ago`;
  return `${name} enemy ${entry.sighting.id}'s position, ${entry.dist}u, ${where}, then push in while they cannot fight back; hands busy about 1s`;
}

const STREAK_CRITERIA: Readonly<Record<string, string>> = {
  radar_mp: "call in your UAV now: shows every enemy on the map for 30 s; about 2 s with your gun down",
  airstrike_mp: "call in your airstrike now on the freshest enemy position: kills anyone in the open there; about 3 s with your gun down",
  artillery_mp: "call in an artillery barrage on the freshest enemy position: several shells over a wide area; about 3 s with your gun down",
  asf_mp: "call in fighter support now: jets strafe enemies for a while; about 2 s with your gun down",
  helicopter_mp: "call in your attack helicopter now: hunts enemies for a minute; about 2 s with your gun down",
  ac130_mp: "call in the AC130 gunship now: heavy fire on enemies from above; about 2 s with your gun down",
  nuke_mp: "call in the tactical nuke now: ends the match in your favour; about 3 s with your gun down",
};

function streakOptions(obs: Observation): readonly WeaponOption[] {
  const criteria = STREAK_CRITERIA[obs.streak];
  if (criteria === undefined) return [];
  const threat = obs.enemies.visible.length > 0 ? "; an enemy is visible, so finish the fight first unless you are safe" : "";
  return [{ kind: "streak", id: "streak", criteria: criteria + threat }];
}

function tacticalOptions(input: OptionInput): readonly WeaponOption[] {
  if (input.obs.tactical <= 0 || input.obs.tacticalName === "none") return [];
  return knownEnemies(input)
    .map(sighting => ({ sighting, target: predictedPosition(sighting, input.obs.gameTimeMs) }))
    .map(entry => ({ ...entry, dist: Math.round(distance2d(input.obs.pos, entry.target)) }))
    .filter(entry => entry.dist >= TACTICAL_MIN_UNITS && entry.dist <= TACTICAL_MAX_UNITS && (!entry.sighting.visible || entry.dist >= TACTICAL_SHOOT_INSTEAD_UNITS))
    .slice(0, MAX_GRENADE_OPTIONS)
    .map(entry => ({ kind: "tactical", id: `flash_${entry.sighting.id}`, enemyId: entry.sighting.id, target: entry.target, criteria: tacticalCriteria(input, entry) }));
}

function grenadeOptions(input: OptionInput): readonly WeaponOption[] {
  if (input.obs.grenades <= 0) return [];
  return knownEnemies(input)
    .map(sighting => ({ sighting, target: predictedPosition(sighting, input.obs.gameTimeMs) }))
    .map(entry => ({ ...entry, dist: Math.round(distance2d(input.obs.pos, entry.target)) }))
    .filter(isFragWorthy)
    .slice(0, MAX_GRENADE_OPTIONS)
    .map(entry => ({ kind: "grenade", id: `grenade_${entry.sighting.id}`, enemyId: entry.sighting.id, target: entry.target, criteria: grenadeCriteria(input, entry) }));
}

/** Plant or defuse is offered only while standing in a zone where it is possible; the executor holds the use button. */
function objectiveOptions(obs: Observation): readonly WeaponOption[] {
  const objective = obs.objective;
  const here = objective.sites.find(site => site.touching);
  if (here === undefined) return [];
  const threat = obs.enemies.visible.length > 0 ? "; an enemy is visible, so you would be shot while doing it" : "";
  if (objective.role === "attack" && !objective.planted) return [{ kind: "plant", id: "plant", criteria: `plant the bomb at site ${here.label} now: 5s with your hands busy and no shooting${threat}` }];
  if (objective.role === "defend" && objective.planted && here.planted) return [{ kind: "defuse", id: "defuse", criteria: `defuse the bomb at site ${here.label} now: 5s with your hands busy and no shooting${threat}` }];
  return [];
}

export function weaponOptions(input: OptionInput): readonly WeaponOption[] {
  const obs = input.obs;
  const keep: WeaponOption = { kind: "keep", id: "keep", criteria: `keep shooting as is (${obs.clip} rounds in the clip)` };
  const reload: WeaponOption[] = obs.clip < obs.clipSize && obs.reserve > 0 ? [{ kind: "reload", id: "reload", criteria: `reload now: ${obs.clip}/${obs.clipSize} in the clip, ${obs.reserve} in reserve; takes 2s and stops firing` }] : [];
  return [keep, ...streakOptions(obs), ...objectiveOptions(obs), ...reload, ...grenadeOptions(input), ...tacticalOptions(input)];
}

function criteria(options: readonly { readonly id: string; readonly criteria: string }[]): Record<string, string> {
  return Object.fromEntries(options.map(option => [option.id, option.criteria]));
}

export function decisionOptions(input: OptionInput): DecisionOptions {
  return { engage: engageOptions(input.obs, input.memory), move: moveOptions(input), posture: postureOptions(input.obs), weapon: weaponOptions(input) };
}

/** Four choice questions whose options are legal by construction. */
export function buildQuestions(input: OptionInput): DecisionQuestions {
  const options = decisionOptions(input);
  const engage: JevQuestions = options.engage.length === 0 ? {} : { engage: { type: "choice", instructions: ENGAGE_INSTRUCTIONS, criteria: criteria(options.engage) } };
  const questions: JevQuestions = {
    ...engage,
    move: { type: "choice", instructions: MOVE_INSTRUCTIONS + objectiveHint(input.obs), criteria: criteria(options.move) },
    posture: { type: "choice", instructions: POSTURE_INSTRUCTIONS, criteria: criteria(options.posture) },
    weapon: { type: "choice", instructions: WEAPON_INSTRUCTIONS + objectiveWeaponHint(input.obs), criteria: criteria(options.weapon) },
  };
  return { questions, options };
}
