import { NO_OBJECTIVE, type EventsPart, type NavPart, type Observation, type RememberedEnemy, type VisibleEnemy } from "../src/observation.ts";

export const EMPTY_EVENTS: EventsPart = { dmgTaken: [], dmgDealt: [], kills: [], died: false, shots: 0, reloadStarted: false, heard: [], rejected: [] };

/** Bot at waypoint 27 (northwest of center) facing north. */
const BASE: Observation = {
  botId: 0,
  sequence: 41,
  gameTimeMs: 184_250,
  lifeId: 3,
  alive: true,
  hp: 100,
  pos: [-185.7, 460.1, 192.1],
  vel: [0, 180, 0],
  speed: 180,
  yaw: 90,
  pitch: -2,
  stance: "stand",
  weapon: "m16_gl_mp",
  clip: 24,
  reserve: 90,
  clipSize: 30,
  ads: 0,
  ready: true,
  reloading: false,
  grenades: 1,
  tactical: 1,
  tacticalName: "flash_grenade_mp",
  streak: "none",
  cmd: undefined,
  aim: undefined,
  enemies: { visible: [], remembered: [], team: [] },
  nav: { node: 27, goal: "n0", next: 0, remaining: 192, progress: 54, stuck: false, moving: true, sprinting: false, path: [27, 0] },
  events: EMPTY_EVENTS,
  native: undefined,
  objective: NO_OBJECTIVE,
};

export function sampleObservation(overrides: Partial<Observation> = {}): Observation {
  return { ...BASE, ...overrides };
}

export function nav(overrides: Partial<NavPart> = {}): NavPart {
  return { ...BASE.nav, ...overrides };
}

export function events(overrides: Partial<EventsPart> = {}): EventsPart {
  return { ...EMPTY_EVENTS, ...overrides };
}

/** Enemy at waypoint 6, east of the bot, walking toward it. */
export function visibleEnemy(overrides: Partial<VisibleEnemy> = {}): VisibleEnemy {
  return { id: 2, pos: [450.1, 385.7, 192], vel: [-150, 0, 0], dist: 640, bearing: -83, elev: 0, exposed: "both", seenMs: 800, facingUs: true, ...overrides };
}

export function rememberedEnemy(overrides: Partial<RememberedEnemy> = {}): RememberedEnemy {
  return { id: 1, ageMs: 4500, pos: [401.8, 57.6, 192], vel: [-100, 0, 0], bearing: -55, dist: 720, lost: "theirs", ...overrides };
}

/** The merged record exactly as PROTOCOL.md illustrates the four parts. */
export function protocolExample(): Record<string, unknown> {
  return {
    botId: 0,
    sequence: 41,
    gameTimeMs: 184250,
    lifeId: 3,
    alive: true,
    hp: 100,
    pos: [-120, 340, 192],
    vel: [0, 180, 0],
    speed: 180,
    yaw: 90,
    pitch: -2,
    stance: "stand",
    weapon: "m16_gl_mp",
    clip: 24,
    reserve: 90,
    clipSize: 30,
    ads: 0,
    ready: true,
    reloading: false,
    grenades: 1,
  tactical: 1,
  tacticalName: "flash_grenade_mp",
    cmd: { sequence: 39, t: 2, e: "f", g: "n41", l: "auto", s: "stand", r: "auto", a: "auto", w: "keep" },
    aim: { target: 2, visible: true, errorDeg: 3.2, firing: true },
    native: { stage: 0, remainingMs: 0 },
    enemies: {
      botId: 0,
      sequence: 41,
      part: "enemies",
      visible: [{ id: 2, pos: [180, 640, 192], vel: [-40, -160, 0], dist: 310, bearing: -12, elev: 1, exposed: "both", seenMs: 800 }],
      remembered: [{ id: 1, ageMs: 4500, pos: [220, 610, 192], vel: [-30, 0, 0], bearing: 40, dist: 480, lost: "theirs" }],
      team: [{ id: 3, pos: [0, 0, 192], hp: 70 }],
    },
    nav: { botId: 0, sequence: 41, part: "nav", node: 27, goal: "n41", next: 33, remaining: 220, progress: 54, stuck: false, moving: true, sprinting: false, path: [27, 33, 41] },
    events: {
      botId: 0,
      sequence: 41,
      part: "events",
      dmgTaken: [{ from: 2, amount: 35, bearing: 150, ageMs: 300 }],
      dmgDealt: [{ to: 2, amount: 40, ageMs: 100 }],
      kills: [2],
      died: false,
      shots: 3,
      reloadStarted: false,
      heard: [{ from: 1, bearing: 150, dist: 400, ageMs: 500 }],
      rejected: [{ reason: "stale", sequence: 39 }],
    },
  };
}
