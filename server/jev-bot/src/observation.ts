/** Merged observation as the worker forwards it: `self` fields at the top level plus the other parts. See PROTOCOL.md. */
export type Vec3 = readonly [number, number, number];
export type Exposure = "head" | "body" | "both" | "none";
export type Stance = "stand" | "crouch" | "prone";
export type SightLoss = "ours" | "theirs";

export interface VisibleEnemy {
  readonly id: number;
  readonly pos: Vec3;
  readonly vel: Vec3;
  readonly dist: number;
  /** Degrees relative to the view yaw, positive left. */
  readonly bearing: number;
  readonly elev: number;
  readonly exposed: Exposure;
  readonly seenMs: number;
  /** Whether the enemy's view points at the bot; false means their back is turned. */
  readonly facingUs: boolean;
}

export interface RememberedEnemy {
  readonly id: number;
  readonly ageMs: number;
  readonly pos: Vec3;
  readonly vel: Vec3;
  readonly bearing: number;
  readonly dist: number;
  readonly lost: SightLoss;
}

export interface Teammate {
  readonly id: number;
  readonly pos: Vec3;
  readonly hp: number;
  /** The teammate's current movement goal on the wire ("siteA", "chase2", "n41", "none") and whether it is planting or defusing. */
  readonly goal: string;
  readonly planting: boolean;
}

export interface EnemiesPart {
  readonly visible: readonly VisibleEnemy[];
  readonly remembered: readonly RememberedEnemy[];
  readonly team: readonly Teammate[];
}

export interface NavPart {
  readonly node: number;
  readonly goal: string;
  readonly next: number;
  readonly remaining: number;
  /** Units moved in the last second. */
  readonly progress: number;
  readonly stuck: boolean;
  readonly moving: boolean;
  readonly sprinting: boolean;
  readonly path: readonly number[];
}

export interface DamageTaken {
  readonly from: number;
  readonly amount: number;
  readonly bearing: number;
  readonly ageMs: number;
}

export interface DamageDealt {
  readonly to: number;
  readonly amount: number;
  readonly ageMs: number;
}

export interface Gunfire {
  readonly from: number;
  readonly bearing: number;
  readonly dist: number;
  readonly ageMs: number;
}

export interface RejectedCommand {
  readonly reason: string;
  readonly sequence: number;
}

export interface EventsPart {
  readonly dmgTaken: readonly DamageTaken[];
  readonly dmgDealt: readonly DamageDealt[];
  readonly kills: readonly number[];
  readonly died: boolean;
  readonly shots: number;
  readonly reloadStarted: boolean;
  readonly heard: readonly Gunfire[];
  readonly rejected: readonly RejectedCommand[];
}

/** Echo of the command the fixture holds. Values are kept as wire strings. */
export interface HeldCommand {
  readonly sequence: number;
  readonly fields: Readonly<Record<string, string>>;
}

export interface AimState {
  readonly target: number | undefined;
  readonly visible: boolean;
  readonly errorDeg: number;
  readonly firing: boolean;
}

export interface NativeState {
  readonly stage: number;
  readonly remainingMs: number;
}

export interface Observation {
  readonly botId: number;
  readonly sequence: number;
  readonly gameTimeMs: number;
  readonly lifeId: number;
  readonly alive: boolean;
  readonly hp: number;
  readonly pos: Vec3;
  readonly vel: Vec3;
  readonly speed: number;
  readonly yaw: number;
  readonly pitch: number;
  readonly stance: Stance;
  readonly weapon: string;
  readonly clip: number;
  readonly reserve: number;
  readonly clipSize: number;
  readonly ads: number;
  readonly ready: boolean;
  readonly reloading: boolean;
  readonly grenades: number;
  /** Special grenades left (flash, stun or smoke) and which one the class carries; "none" without one. */
  readonly tactical: number;
  readonly tacticalName: string;
  /** Earned classic killstreak held: radar_mp, airstrike_mp, helicopter_mp, or "none". */
  readonly streak: string;
  readonly cmd: HeldCommand | undefined;
  readonly aim: AimState | undefined;
  readonly enemies: EnemiesPart;
  readonly nav: NavPart;
  readonly events: EventsPart;
  readonly native: NativeState | undefined;
  /** Search and Destroy objective state; `role` is `none` in other modes. */
  readonly objective: ObjectivePart;
}

type Parser<T> = (value: unknown) => T | undefined;
type Fields = Readonly<Record<string, unknown>>;

const INVALID: unique symbol = Symbol("invalid");
type Invalid = typeof INVALID;

const EXPOSURES: readonly Exposure[] = ["head", "body", "both", "none"];
const STANCES: readonly Stance[] = ["stand", "crouch", "prone"];
const SIGHT_LOSSES: readonly SightLoss[] = ["ours", "theirs"];
const COMMAND_KEYS: readonly string[] = ["t", "e", "g", "l", "s", "r", "a", "w"];

function record(value: unknown): Fields | undefined {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return undefined;
  return Object.fromEntries(Object.entries(value));
}

function finite(value: unknown): number | undefined {
  if (typeof value !== "number" || !Number.isFinite(value)) return undefined;
  return value;
}

function integer(value: unknown): number | undefined {
  if (!Number.isSafeInteger(value) || typeof value !== "number") return undefined;
  return value;
}

function boolean(value: unknown): boolean | undefined {
  if (typeof value !== "boolean") return undefined;
  return value;
}

function text(value: unknown): string | undefined {
  if (typeof value !== "string" || value.length > 256) return undefined;
  return value;
}

function vec3(value: unknown): Vec3 | undefined {
  if (!Array.isArray(value) || value.length !== 3) return undefined;
  const [x, y, z] = value.map(finite);
  if (x === undefined || y === undefined || z === undefined) return undefined;
  return [x, y, z];
}

function oneOf<T extends string>(allowed: readonly T[]): Parser<T> {
  return value => allowed.find(option => option === value);
}

function listOf<T>(item: Parser<T>): Parser<readonly T[]> {
  return value => {
    if (!Array.isArray(value)) return undefined;
    const parsed = value.map(item);
    if (parsed.some(entry => entry === undefined)) return undefined;
    return parsed.flatMap(entry => (entry === undefined ? [] : [entry]));
  };
}

/** Absent or null is fine; present but malformed is not. */
function optional<T>(item: Parser<T>, value: unknown): T | undefined | Invalid {
  if (value === undefined || value === null) return undefined;
  const parsed = item(value);
  if (parsed === undefined) return INVALID;
  return parsed;
}

function parseVisibleEnemy(value: unknown): VisibleEnemy | undefined {
  const source = record(value);
  if (source === undefined) return undefined;
  const id = integer(source.id);
  const pos = vec3(source.pos);
  const vel = vec3(source.vel);
  const dist = finite(source.dist);
  const bearing = finite(source.bearing);
  const elev = finite(source.elev);
  const exposed = oneOf(EXPOSURES)(source.exposed);
  const seenMs = finite(source.seenMs);
  const facingUs = boolean(source.facingUs ?? true);
  if (id === undefined || pos === undefined || vel === undefined || dist === undefined || bearing === undefined || elev === undefined || exposed === undefined || seenMs === undefined || facingUs === undefined) return undefined;
  return { id, pos, vel, dist, bearing, elev, exposed, seenMs, facingUs };
}

/** Older fixtures sent an empty string while the sighting was still fresh; read that as the enemy breaking away. */
function sightLoss(value: unknown): SightLoss | undefined {
  if (value === undefined || value === "") return "theirs";
  return oneOf(SIGHT_LOSSES)(value);
}

function parseRememberedEnemy(value: unknown): RememberedEnemy | undefined {
  const source = record(value);
  if (source === undefined) return undefined;
  const id = integer(source.id);
  const ageMs = finite(source.ageMs);
  const pos = vec3(source.pos);
  const vel = vec3(source.vel);
  const bearing = finite(source.bearing);
  const dist = finite(source.dist);
  const lost = sightLoss(source.lost);
  if (id === undefined || ageMs === undefined || pos === undefined || vel === undefined || bearing === undefined || dist === undefined || lost === undefined) return undefined;
  return { id, ageMs, pos, vel, bearing, dist, lost };
}

function parseTeammate(value: unknown): Teammate | undefined {
  const source = record(value);
  if (source === undefined) return undefined;
  const id = integer(source.id);
  const pos = vec3(source.pos);
  const hp = finite(source.hp);
  const goal = typeof source.goal === "string" ? source.goal : "none";
  const planting = boolean(source.planting ?? false) ?? false;
  if (id === undefined || pos === undefined || hp === undefined) return undefined;
  return { id, pos, hp, goal, planting };
}

function parseEnemies(value: unknown): EnemiesPart | undefined {
  const source = record(value);
  if (source === undefined) return undefined;
  const visible = listOf(parseVisibleEnemy)(source.visible ?? []);
  const remembered = listOf(parseRememberedEnemy)(source.remembered ?? []);
  const team = listOf(parseTeammate)(source.team ?? []);
  if (visible === undefined || remembered === undefined || team === undefined) return undefined;
  return { visible, remembered, team };
}

function parseNav(value: unknown): NavPart | undefined {
  const source = record(value);
  if (source === undefined) return undefined;
  const node = integer(source.node);
  const goal = text(source.goal ?? "");
  const next = integer(source.next ?? -1);
  const remaining = finite(source.remaining);
  const progress = finite(source.progress);
  const stuck = boolean(source.stuck);
  const moving = boolean(source.moving);
  const sprinting = boolean(source.sprinting);
  const path = listOf(integer)(source.path ?? []);
  if (node === undefined || node < 0 || goal === undefined || next === undefined || remaining === undefined || progress === undefined || stuck === undefined || moving === undefined || sprinting === undefined || path === undefined) return undefined;
  return { node, goal, next, remaining, progress, stuck, moving, sprinting, path };
}

function parseDamageTaken(value: unknown): DamageTaken | undefined {
  const source = record(value);
  if (source === undefined) return undefined;
  const from = integer(source.from);
  const amount = finite(source.amount);
  const bearing = finite(source.bearing);
  const ageMs = finite(source.ageMs);
  if (from === undefined || amount === undefined || bearing === undefined || ageMs === undefined) return undefined;
  return { from, amount, bearing, ageMs };
}

function parseDamageDealt(value: unknown): DamageDealt | undefined {
  const source = record(value);
  if (source === undefined) return undefined;
  const to = integer(source.to);
  const amount = finite(source.amount);
  const ageMs = finite(source.ageMs);
  if (to === undefined || amount === undefined || ageMs === undefined) return undefined;
  return { to, amount, ageMs };
}

function parseGunfire(value: unknown): Gunfire | undefined {
  const source = record(value);
  if (source === undefined) return undefined;
  const from = integer(source.from);
  const bearing = finite(source.bearing);
  const dist = finite(source.dist);
  const ageMs = finite(source.ageMs);
  if (from === undefined || bearing === undefined || dist === undefined || ageMs === undefined) return undefined;
  return { from, bearing, dist, ageMs };
}

function parseRejected(value: unknown): RejectedCommand | undefined {
  const source = record(value);
  if (source === undefined) return undefined;
  const reason = text(source.reason);
  const sequence = integer(source.sequence);
  if (reason === undefined || sequence === undefined) return undefined;
  return { reason, sequence };
}

function parseEvents(value: unknown): EventsPart | undefined {
  const source = record(value);
  if (source === undefined) return undefined;
  const dmgTaken = listOf(parseDamageTaken)(source.dmgTaken ?? []);
  const dmgDealt = listOf(parseDamageDealt)(source.dmgDealt ?? []);
  const kills = listOf(integer)(source.kills ?? []);
  const died = boolean(source.died ?? false);
  const shots = integer(source.shots ?? 0);
  const reloadStarted = boolean(source.reloadStarted ?? false);
  const heard = listOf(parseGunfire)(source.heard ?? []);
  const rejected = listOf(parseRejected)(source.rejected ?? []);
  if (dmgTaken === undefined || dmgDealt === undefined || kills === undefined || died === undefined || shots === undefined || shots < 0 || reloadStarted === undefined || heard === undefined || rejected === undefined) return undefined;
  return { dmgTaken, dmgDealt, kills, died, shots, reloadStarted, heard, rejected };
}

function wireValue(value: unknown): string | undefined {
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return text(value);
}

function parseHeldCommand(value: unknown): HeldCommand | undefined {
  const source = record(value);
  if (source === undefined) return undefined;
  const sequence = integer(source.sequence);
  if (sequence === undefined) return undefined;
  const fields: Record<string, string> = {};
  for (const key of COMMAND_KEYS) {
    const raw = source[key];
    if (raw === undefined || raw === null) continue;
    const wire = wireValue(raw);
    if (wire === undefined) return undefined;
    fields[key] = wire;
  }
  return { sequence, fields };
}

export type ObjectiveRole = "none" | "attack" | "defend";
const ROLES: readonly ObjectiveRole[] = ["none", "attack", "defend"];

export interface BombSite {
  readonly label: string;
  readonly pos: Vec3;
  readonly dist: number;
  readonly bearing: number;
  readonly planted: boolean;
  readonly occupied: boolean;
  readonly touching: boolean;
}

export interface ObjectivePart {
  readonly role: ObjectiveRole;
  readonly planted: boolean;
  /** Milliseconds until the planted bomb explodes; -1 when not planted. */
  readonly bombLeftMs: number;
  /** Milliseconds left in the round; -1 when unknown. */
  readonly roundLeftMs: number;
  readonly sites: readonly BombSite[];
}

export const NO_OBJECTIVE: ObjectivePart = { role: "none", planted: false, bombLeftMs: -1, roundLeftMs: -1, sites: [] };

function parseSite(value: unknown): BombSite | undefined {
  const source = record(value);
  if (source === undefined) return undefined;
  const label = typeof source.label === "string" && /^[A-Z?]$/.test(source.label) ? source.label : undefined;
  const pos = vec3(source.pos);
  const dist = finite(source.dist);
  const bearing = finite(source.bearing);
  const planted = boolean(source.planted ?? false);
  const occupied = boolean(source.occupied ?? false);
  const touching = boolean(source.touching ?? false);
  if (label === undefined || pos === undefined || dist === undefined || bearing === undefined || planted === undefined || occupied === undefined || touching === undefined) return undefined;
  return { label, pos, dist, bearing, planted, occupied, touching };
}

/** Absent in recordings made before the objective part existed; those read as no objective. */
function parseObjective(value: unknown): ObjectivePart | undefined {
  if (value === undefined || value === null) return NO_OBJECTIVE;
  const source = record(value);
  if (source === undefined) return undefined;
  const role = oneOf(ROLES)(source.role ?? "none");
  const planted = boolean(source.planted ?? false);
  const bombLeftMs = finite(source.bombLeftMs ?? -1);
  const roundLeftMs = finite(source.roundLeftMs ?? -1);
  const sites = listOf(parseSite)(source.sites ?? []);
  if (role === undefined || planted === undefined || bombLeftMs === undefined || roundLeftMs === undefined || sites === undefined) return undefined;
  return { role, planted, bombLeftMs, roundLeftMs, sites };
}

function aimTarget(value: unknown): number | undefined | Invalid {
  if (value === undefined || value === null) return undefined;
  const id = integer(value);
  if (id === undefined) return INVALID;
  if (id < 0) return undefined;
  return id;
}

function parseAim(value: unknown): AimState | undefined {
  const source = record(value);
  if (source === undefined) return undefined;
  const target = aimTarget(source.target);
  const visible = boolean(source.visible ?? false);
  const errorDeg = finite(source.errorDeg ?? 0);
  const firing = boolean(source.firing ?? false);
  if (target === INVALID || visible === undefined || errorDeg === undefined || firing === undefined) return undefined;
  return { target, visible, errorDeg, firing };
}

function parseNative(value: unknown): NativeState | undefined {
  const source = record(value);
  if (source === undefined) return undefined;
  const stage = integer(source.stage);
  const remainingMs = finite(source.remainingMs);
  if (stage === undefined || remainingMs === undefined) return undefined;
  return { stage, remainingMs };
}

/** Accepts the merged observation record. Returns undefined for anything malformed and never throws. */
export function parseObservation(value: unknown): Observation | undefined {
  const source = record(value);
  if (source === undefined) return undefined;
  const botId = integer(source.botId);
  const sequence = integer(source.sequence);
  const gameTimeMs = integer(source.gameTimeMs);
  const lifeId = integer(source.lifeId);
  const alive = boolean(source.alive);
  const hp = finite(source.hp);
  const pos = vec3(source.pos);
  const vel = vec3(source.vel);
  const speed = finite(source.speed);
  const yaw = finite(source.yaw);
  const pitch = finite(source.pitch);
  const stance = oneOf(STANCES)(source.stance);
  const weapon = text(source.weapon);
  const clip = integer(source.clip);
  const reserve = integer(source.reserve);
  const clipSize = integer(source.clipSize);
  const ads = finite(source.ads);
  const ready = boolean(source.ready);
  const reloading = boolean(source.reloading);
  const grenades = integer(source.grenades);
  const tactical = integer(source.tactical ?? 0) ?? 0;
  const tacticalName = typeof source.tacticalName === "string" ? source.tacticalName : "none";
  const streak = typeof source.streak === "string" ? source.streak : "none";
  const cmd = optional(parseHeldCommand, source.cmd);
  const aim = optional(parseAim, source.aim);
  const enemies = parseEnemies(source.enemies);
  const nav = parseNav(source.nav);
  const events = parseEvents(source.events);
  const native = optional(parseNative, source.native);
  const objective = parseObjective(source.objective);
  const identity = botId === undefined || botId < 0 || botId > 63 || sequence === undefined || sequence < 0 || gameTimeMs === undefined || gameTimeMs < 0 || lifeId === undefined || lifeId < 0;
  const body = alive === undefined || hp === undefined || pos === undefined || vel === undefined || speed === undefined || yaw === undefined || pitch === undefined || stance === undefined;
  const gear = weapon === undefined || clip === undefined || clip < 0 || reserve === undefined || reserve < 0 || clipSize === undefined || clipSize < 0 || ads === undefined || ready === undefined || reloading === undefined || grenades === undefined || grenades < 0;
  const parts = cmd === INVALID || aim === INVALID || enemies === undefined || nav === undefined || events === undefined || native === INVALID || objective === undefined;
  if (identity || body || gear || parts) return undefined;
  return { botId, sequence, gameTimeMs, lifeId, alive, hp, pos, vel, speed, yaw, pitch, stance, weapon, clip, reserve, clipSize, ads, ready, reloading, grenades, tactical, tacticalName, streak, cmd, aim, enemies, nav, events, native, objective };
}
