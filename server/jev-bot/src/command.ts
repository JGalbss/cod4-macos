import type { JevAnswer } from "./jev.ts";
import type { Observation, Stance, Vec3 } from "./observation.ts";
import type { DecisionOptions, EngageOption, MoveOption, PostureOption, WeaponOption } from "./questions.ts";

export type FireMode = "f" | "h" | "k";
export type AutoSwitch = "auto" | "on" | "off";

/** One value per wire key from the PROTOCOL.md table. */
/** Wire stances: the three body positions plus a one-shot jump that lands standing. */
export type WireStance = Stance | "jump";

export interface CommandFields {
  readonly t: string;
  readonly e: FireMode;
  readonly g: string;
  readonly l: string;
  readonly s: WireStance;
  readonly r: AutoSwitch;
  readonly a: AutoSwitch;
  readonly w: string;
}

export interface CommandMessage {
  readonly type: "command";
  readonly botId: number;
  readonly sequence: number;
  readonly lifeId: number;
  readonly gameTimeMs: number;
  readonly fields: CommandFields;
}

export const DEFAULT_FIELDS: CommandFields = { t: "auto", e: "f", g: "hold", l: "auto", s: "stand", r: "auto", a: "auto", w: "keep" };
export const WIRE_VALUE = /^[A-Za-z0-9_.:-]{1,24}$/;

export function nadeValue(target: Vec3): string {
  return `nade${Math.round(target[0])}:${Math.round(target[1])}:${Math.round(target[2])}`;
}

/** No named enemy means "auto": the executor tracks and fires at the nearest visible enemy within one tick. */
export function tactValue(target: Vec3): string {
  return `tact${Math.round(target[0])}:${Math.round(target[1])}:${Math.round(target[2])}`;
}

export function targetValue(enemyId: number | undefined): string {
  return enemyId === undefined ? "auto" : String(enemyId);
}

export function nodeGoal(node: number): string {
  return `n${node}`;
}

export function chaseGoal(enemyId: number): string {
  return `chase${enemyId}`;
}

export function siteGoal(label: string): string {
  return `site${label}`;
}

function chosen<T extends { readonly id: string }>(answers: Readonly<Record<string, JevAnswer>>, name: string, options: readonly T[]): T | undefined {
  const answer = answers[name];
  if (answer === undefined || answer.type !== "choice") return undefined;
  return options.find(option => option.id === answer.choice);
}

function engageFields(option: EngageOption | undefined): Partial<CommandFields> {
  if (option === undefined) return {};
  if (option.kind === "attack") return { t: targetValue(option.enemyId), e: "f" };
  if (option.kind === "knife") return { t: targetValue(option.enemyId), e: "k" };
  if (option.trackId === undefined) return { t: "auto", e: "f" };
  return { t: targetValue(option.trackId), e: "h" };
}

function moveFields(option: MoveOption | undefined): Partial<CommandFields> {
  if (option === undefined) return {};
  if (option.kind === "hold") return { g: "hold" };
  if (option.kind === "advance") return { g: nodeGoal(option.node) };
  if (option.kind === "retreat") return { g: nodeGoal(option.node), s: "stand" };
  if (option.kind === "site") return { g: siteGoal(option.label) };
  if (option.kind === "cover_now") return { g: "cover" };
  if (option.kind === "head_glitch") return { g: "glitch" };
  if (option.kind === "rush") return { g: chaseGoal(option.enemyId) };
  return { g: chaseGoal(option.enemyId) };
}

function postureFields(option: PostureOption | undefined): Partial<CommandFields> {
  if (option === undefined) return {};
  return { s: option.kind };
}

function weaponFields(option: WeaponOption | undefined): Partial<CommandFields> {
  if (option === undefined) return {};
  if (option.kind === "grenade") return { w: nadeValue(option.target) };
  if (option.kind === "tactical") return { w: tactValue(option.target) };
  return { w: option.kind };
}

export interface CommandContext {
  /** An enemy is in view: sprinting would only be a louder way to die. */
  readonly enemyVisible: boolean;
}

/** Between fights the bot sprints wherever it is going; a knife approach overrides movement and posture with a quiet crouch-walk. */
function movementStyle(engage: EngageOption | undefined, move: MoveOption | undefined, context: CommandContext): Partial<CommandFields> {
  if (engage?.kind === "knife") return { g: chaseGoal(engage.enemyId), s: "crouch", r: "off", a: "off" };
  if (move?.kind === "head_glitch") return { s: "crouch", r: "off" };
  if (move?.kind === "rush") return { r: "on", s: "stand" };
  if (move === undefined || move.kind === "hold" || move.kind === "cover_now" || context.enemyVisible) return {};
  return { r: "on" };
}

/** Answers to wire fields. A retreat forces stand, so movement is applied after posture; the movement style comes last. */
export function commandFields(answers: Readonly<Record<string, JevAnswer>>, options: DecisionOptions, context: CommandContext = { enemyVisible: false }): CommandFields {
  const engage = chosen(answers, "engage", options.engage);
  const move = chosen(answers, "move", options.move);
  return {
    ...DEFAULT_FIELDS,
    ...engageFields(engage),
    ...postureFields(chosen(answers, "posture", options.posture)),
    ...moveFields(move),
    ...weaponFields(chosen(answers, "weapon", options.weapon)),
    ...movementStyle(engage, move, context),
  };
}

export function isWireSafe(fields: CommandFields): boolean {
  return Object.values(fields).every(value => WIRE_VALUE.test(value));
}

export function commandMessage(obs: Observation, fields: CommandFields): CommandMessage {
  return { type: "command", botId: obs.botId, sequence: obs.sequence, lifeId: obs.lifeId, gameTimeMs: obs.gameTimeMs, fields };
}
