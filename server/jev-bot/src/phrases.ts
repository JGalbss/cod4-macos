/** Short human phrases for the Jev state. Yaw 0 points +x (east) and 90 points +y (north). */
import type { Exposure, SightLoss, Vec3 } from "./observation.ts";

const COMPASS = ["east", "northeast", "north", "northwest", "west", "southwest", "south", "southeast"];
const STILL_UNITS_PER_SECOND = 20;
const CENTER_RADIUS_UNITS = 220;
const EXPOSURE_PHRASES: Readonly<Record<Exposure, string>> = { both: "head and body exposed", head: "head only", body: "body only", none: "not exposed" };
const LOSS_PHRASES: Readonly<Record<SightLoss, string>> = { ours: "you turned away", theirs: "they broke away" };

export function compassWord(dx: number, dy: number): string {
  const angle = (Math.atan2(dy, dx) * 180) / Math.PI;
  const sector = ((Math.round(angle / 45) % 8) + 8) % 8;
  return COMPASS[sector];
}

export function areaName(pos: Vec3, center: Vec3): string {
  const dx = pos[0] - center[0];
  const dy = pos[1] - center[1];
  if (Math.hypot(dx, dy) < CENTER_RADIUS_UNITS) return "center";
  return compassWord(dx, dy);
}

/** "still" or "north 180u/s". */
export function motionPhrase(vel: Vec3): string {
  const speed = Math.hypot(vel[0], vel[1]);
  if (speed < STILL_UNITS_PER_SECOND) return "still";
  return `${compassWord(vel[0], vel[1])} ${Math.round(speed)}u/s`;
}

/** Enemy motion seen from the bot: toward you, away from you, or crossing left/right. */
export function relativeMotionPhrase(enemyPos: Vec3, enemyVel: Vec3, selfPos: Vec3, yawDeg: number): string {
  const speed = Math.hypot(enemyVel[0], enemyVel[1]);
  if (speed < STILL_UNITS_PER_SECOND) return "still";
  const toSelf = [selfPos[0] - enemyPos[0], selfPos[1] - enemyPos[1]];
  const range = Math.hypot(toSelf[0], toSelf[1]);
  if (range < 1) return "on top of you";
  const closing = (enemyVel[0] * toSelf[0] + enemyVel[1] * toSelf[1]) / range;
  if (Math.abs(closing) >= speed * 0.7) return closing > 0 ? "toward you" : "away from you";
  const yaw = (yawDeg * Math.PI) / 180;
  const leftward = enemyVel[0] * -Math.sin(yaw) + enemyVel[1] * Math.cos(yaw);
  return leftward > 0 ? "crossing left" : "crossing right";
}

export function exposurePhrase(exposed: Exposure): string {
  return EXPOSURE_PHRASES[exposed];
}

export function lossPhrase(lost: SightLoss): string {
  return LOSS_PHRASES[lost];
}

/** Bearing from the bot to a world point, degrees, positive left. */
export function bearingTo(selfPos: Vec3, yawDeg: number, target: Vec3): number {
  const angle = (Math.atan2(target[1] - selfPos[1], target[0] - selfPos[0]) * 180) / Math.PI;
  return Math.round(normalizeDegrees(angle - yawDeg));
}

export function normalizeDegrees(value: number): number {
  return ((((value + 180) % 360) + 360) % 360) - 180;
}

export function seconds(ms: number): number {
  return Math.round(ms / 100) / 10;
}

/** "m16_gl_mp" -> "M16". */
export function weaponName(raw: string): string {
  return raw.replace(/_mp$/, "").replace(/_gl$/, "").toUpperCase();
}
