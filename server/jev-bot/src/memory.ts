import type { Observation, SightLoss, Vec3 } from "./observation.ts";
import type { CommandFields } from "./command.ts";

export interface NodeVisit {
  readonly node: number;
  readonly lastVisitMs: number;
  readonly visits: number;
}

export interface Sighting {
  readonly id: number;
  readonly pos: Vec3;
  readonly vel: Vec3;
  readonly seenAtMs: number;
  readonly visible: boolean;
  readonly lost: SightLoss | undefined;
}

export interface DamageMemory {
  readonly from: number;
  readonly amount: number;
  readonly bearing: number;
  readonly atMs: number;
}

export interface GunfireMemory {
  readonly from: number;
  readonly bearing: number;
  readonly dist: number;
  readonly atMs: number;
}

export interface CommandMemory {
  readonly gameTimeMs: number;
  readonly sequence: number;
  readonly fields: CommandFields;
}

export interface Tally {
  readonly kills: number;
  readonly deaths: number;
  readonly shots: number;
  readonly hits: number;
  readonly damageDealt: number;
  readonly damageTaken: number;
}

interface Stamped {
  readonly atMs: number;
  readonly amount: number;
}

export const ROLLING_WINDOW_MS = 10_000;
export const SIGHTING_MEMORY_MS = 15_000;
export const DEATH_MEMORY_MS = 60_000;

interface DealtDamage {
  readonly atMs: number;
  readonly amount: number;
  readonly to: number;
}

export interface DeathPosition {
  readonly atMs: number;
  readonly pos: Vec3;
}
export const PREDICTION_HORIZON_MS = 1_500;
const COMMAND_HISTORY = 8;

const EMPTY_TALLY: Tally = { kills: 0, deaths: 0, shots: 0, hits: 0, damageDealt: 0, damageTaken: 0 };

function within<T extends { readonly atMs: number }>(entries: readonly T[], nowMs: number, windowMs: number): T[] {
  return entries.filter(entry => nowMs - entry.atMs <= windowMs && entry.atMs <= nowMs);
}

function sum(entries: readonly Stamped[]): number {
  return entries.reduce((total, entry) => total + entry.amount, 0);
}

/** Where the enemy is expected now, extrapolating its last velocity for at most three seconds. */
export function predictedPosition(sighting: Sighting, nowMs: number): Vec3 {
  const ageS = Math.min(Math.max(nowMs - sighting.seenAtMs, 0), PREDICTION_HORIZON_MS) / 1000;
  return [sighting.pos[0] + sighting.vel[0] * ageS, sighting.pos[1] + sighting.vel[1] * ageS, sighting.pos[2] + sighting.vel[2] * ageS];
}

/** Everything one bot has learned across the match. Time always comes from observations. */
export class BotMemory {
  readonly #visits = new Map<number, NodeVisit>();
  readonly #sightings = new Map<number, Sighting>();
  #damage: DamageMemory[] = [];
  #gunfire: GunfireMemory[] = [];
  #kills: Stamped[] = [];
  #deaths: Stamped[] = [];
  #deathPositions: DeathPosition[] = [];
  #shots: Stamped[] = [];
  #hits: Stamped[] = [];
  #dealt: DealtDamage[] = [];
  #commands: CommandMemory[] = [];
  #totals: Tally = EMPTY_TALLY;
  #lastNode: number | undefined;
  #nowMs = 0;

  get nowMs(): number {
    return this.#nowMs;
  }

  observe(obs: Observation): void {
    this.#nowMs = Math.max(this.#nowMs, obs.gameTimeMs);
    this.#recordVisit(obs);
    this.#recordSightings(obs);
    this.#recordEvents(obs);
    this.#prune();
  }

  recordCommand(command: CommandMemory): void {
    this.#commands = [...this.#commands, command].slice(-COMMAND_HISTORY);
  }

  visit(node: number): NodeVisit | undefined {
    return this.#visits.get(node);
  }

  visits(): readonly NodeVisit[] {
    return [...this.#visits.values()];
  }

  /** Freshest first; visible enemies are freshest by definition. */
  sightings(): readonly Sighting[] {
    return [...this.#sightings.values()].sort((a, b) => b.seenAtMs - a.seenAtMs);
  }

  sighting(id: number): Sighting | undefined {
    return this.#sightings.get(id);
  }

  freshestEnemy(): Sighting | undefined {
    return this.sightings()[0];
  }

  /** Where this bot died recently, newest first; the places worth avoiding or approaching differently. */
  recentDeaths(windowMs: number = DEATH_MEMORY_MS): readonly DeathPosition[] {
    return this.#deathPositions.filter(death => this.#nowMs - death.atMs <= windowMs).sort((a, b) => b.atMs - a.atMs);
  }

  damageTaken(windowMs: number): readonly DamageMemory[] {
    return within(this.#damage, this.#nowMs, windowMs).sort((a, b) => b.atMs - a.atMs);
  }

  gunfireHeard(windowMs: number): readonly GunfireMemory[] {
    return within(this.#gunfire, this.#nowMs, windowMs).sort((a, b) => b.atMs - a.atMs);
  }

  /** Damage we landed on one enemy within the window; a hurt enemy is one worth rushing. */
  damageDealtTo(id: number, windowMs: number): number {
    return within(this.#dealt, this.#nowMs, windowMs).filter(hit => hit.to === id).reduce((total, hit) => total + hit.amount, 0);
  }

  /** Has this enemy hurt us or fired near us recently? */
  attackedBy(id: number, windowMs: number): boolean {
    return this.damageTaken(windowMs).some(hit => hit.from === id) || this.gunfireHeard(windowMs).some(shot => shot.from === id);
  }

  tally(windowMs: number = ROLLING_WINDOW_MS): Tally {
    const now = this.#nowMs;
    return {
      kills: sum(within(this.#kills, now, windowMs)),
      deaths: sum(within(this.#deaths, now, windowMs)),
      shots: sum(within(this.#shots, now, windowMs)),
      hits: sum(within(this.#hits, now, windowMs)),
      damageDealt: sum(within(this.#dealt, now, windowMs)),
      damageTaken: sum(within(this.#damage, now, windowMs)),
    };
  }

  totals(): Tally {
    return this.#totals;
  }

  recentCommands(): readonly CommandMemory[] {
    return this.#commands;
  }

  #recordVisit(obs: Observation): void {
    if (!obs.alive) return;
    const node = obs.nav.node;
    const previous = this.#visits.get(node);
    const arrived = this.#lastNode !== node;
    const visits = (previous?.visits ?? 0) + (arrived ? 1 : 0);
    this.#visits.set(node, { node, lastVisitMs: obs.gameTimeMs, visits });
    this.#lastNode = node;
  }

  #recordSightings(obs: Observation): void {
    const now = obs.gameTimeMs;
    const visibleIds = new Set(obs.enemies.visible.map(enemy => enemy.id));
    for (const enemy of obs.enemies.visible) {
      this.#sightings.set(enemy.id, { id: enemy.id, pos: enemy.pos, vel: enemy.vel, seenAtMs: now, visible: true, lost: undefined });
    }
    for (const enemy of obs.enemies.remembered) {
      const seenAtMs = now - enemy.ageMs;
      const known = this.#sightings.get(enemy.id);
      if (known !== undefined && known.seenAtMs > seenAtMs) continue;
      this.#sightings.set(enemy.id, { id: enemy.id, pos: enemy.pos, vel: enemy.vel, seenAtMs, visible: false, lost: enemy.lost });
    }
    for (const [id, sighting] of this.#sightings) {
      if (sighting.visible && !visibleIds.has(id)) this.#sightings.set(id, { ...sighting, visible: false });
    }
    // The fixture is the authority on who is still worth remembering: it drops an enemy the moment
    // they die, whoever killed them. A sighting it no longer reports would send the bot to a ghost.
    const reported = new Set([...visibleIds, ...obs.enemies.remembered.map(enemy => enemy.id)]);
    for (const id of this.#sightings.keys()) {
      if (!reported.has(id)) this.#sightings.delete(id);
    }
  }

  #recordEvents(obs: Observation): void {
    const now = obs.gameTimeMs;
    const events = obs.events;
    this.#damage.push(...events.dmgTaken.map(hit => ({ from: hit.from, amount: hit.amount, bearing: hit.bearing, atMs: now - hit.ageMs })));
    this.#gunfire.push(...events.heard.map(shot => ({ from: shot.from, bearing: shot.bearing, dist: shot.dist, atMs: now - shot.ageMs })));
    this.#kills.push(...events.kills.map(() => ({ atMs: now, amount: 1 })));
    for (const id of events.kills) this.#sightings.delete(id);
    if (events.died) {
      this.#deaths.push({ atMs: now, amount: 1 });
      this.#deathPositions.push({ atMs: now, pos: obs.pos });
    }
    if (events.shots > 0) this.#shots.push({ atMs: now, amount: events.shots });
    this.#hits.push(...events.dmgDealt.map(hit => ({ atMs: now - hit.ageMs, amount: 1 })));
    this.#dealt.push(...events.dmgDealt.map(hit => ({ atMs: now - hit.ageMs, amount: hit.amount, to: hit.to })));
    const taken = events.dmgTaken.reduce((total, hit) => total + hit.amount, 0);
    const dealt = events.dmgDealt.reduce((total, hit) => total + hit.amount, 0);
    const deaths = events.died ? 1 : 0;
    this.#totals = {
      kills: this.#totals.kills + events.kills.length,
      deaths: this.#totals.deaths + deaths,
      shots: this.#totals.shots + events.shots,
      hits: this.#totals.hits + events.dmgDealt.length,
      damageDealt: this.#totals.damageDealt + dealt,
      damageTaken: this.#totals.damageTaken + taken,
    };
  }

  #prune(): void {
    const now = this.#nowMs;
    this.#damage = within(this.#damage, now, ROLLING_WINDOW_MS);
    this.#gunfire = within(this.#gunfire, now, ROLLING_WINDOW_MS);
    this.#kills = within(this.#kills, now, ROLLING_WINDOW_MS);
    this.#deaths = within(this.#deaths, now, ROLLING_WINDOW_MS);
    this.#deathPositions = this.#deathPositions.filter(death => now - death.atMs <= DEATH_MEMORY_MS);
    this.#shots = within(this.#shots, now, ROLLING_WINDOW_MS);
    this.#hits = within(this.#hits, now, ROLLING_WINDOW_MS);
    this.#dealt = within(this.#dealt, now, ROLLING_WINDOW_MS);
    for (const [id, sighting] of this.#sightings) {
      if (now - sighting.seenAtMs > SIGHTING_MEMORY_MS) this.#sightings.delete(id);
    }
  }
}
