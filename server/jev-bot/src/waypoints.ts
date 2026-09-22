import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { Vec3 } from "./observation.ts";

export interface Waypoint {
  readonly index: number;
  readonly pos: Vec3;
  /** Directed links, as Bot Warfare authored them. */
  readonly children: readonly number[];
  readonly kind: string;
}

export interface WaypointGraph {
  readonly nodes: readonly Waypoint[];
}

export interface Path {
  readonly nodes: readonly number[];
  readonly units: number;
}

export const WAYPOINTS_FILE = resolve(dirname(fileURLToPath(import.meta.url)), "../game/jev_bot_waypoints.gsx");

const WAYPOINT_LINE = /^\s*w\[(\d+)\] = jevWaypoint\(\((-?[\d.]+), (-?[\d.]+), (-?[\d.]+)\), "([^"]*)", "([^"]*)"\);\s*$/;

export function distance2d(a: Vec3, b: Vec3): number {
  return Math.hypot(a[0] - b[0], a[1] - b[1]);
}

function parseLine(line: string): Waypoint | undefined {
  const match = WAYPOINT_LINE.exec(line);
  if (match === null) return undefined;
  const [, index, x, y, z, children, kind] = match;
  const links = children.trim() === "" ? [] : children.trim().split(/\s+/).map(Number);
  return { index: Number(index), pos: [Number(x), Number(y), Number(z)], children: links, kind };
}

/** Reads the generated GSC table so the fixture and the controller share one graph. Throws on a malformed file. */
export function parseWaypoints(source: string): WaypointGraph {
  const nodes = source.split("\n").map(parseLine).flatMap(node => (node === undefined ? [] : [node]));
  if (nodes.length === 0) throw new Error("Waypoint file holds no jevWaypoint lines");
  nodes.forEach((node, position) => {
    if (node.index !== position) throw new Error(`Waypoint ${node.index} is out of order at line position ${position}`);
    for (const child of node.children) {
      if (!Number.isInteger(child) || child < 0 || child >= nodes.length) throw new Error(`Waypoint ${node.index} links to ${child} outside 0..${nodes.length - 1}`);
    }
  });
  return { nodes };
}

/** Bot Warfare's CSV: line one is the count, each row "x y z,children,type,...". Same format the fixture reads at runtime. */
export function parseWaypointsCsv(text: string): WaypointGraph {
  const lines = text.split(/\r?\n/).map(line => line.trim()).filter(line => line.length > 0);
  const count = Number(lines[0]);
  if (!Number.isInteger(count) || count < 0) throw new Error("waypoint CSV must start with a count");
  const nodes: Waypoint[] = lines.slice(1, 1 + count).map((row, index) => {
    const cols = row.split(",");
    const [x, y, z] = (cols[0] ?? "").trim().split(/\s+/).map(Number);
    const children = (cols[1] ?? "").trim() === "" ? [] : cols[1].trim().split(/\s+/).map(Number);
    if ([x, y, z, ...children].some(value => !Number.isFinite(value))) throw new Error(`waypoint ${index} is malformed`);
    return { index, pos: [x, y, z] as Vec3, children: children.filter(child => child >= 0 && child < count), kind: (cols[2] ?? "stand").trim() || "stand" };
  });
  if (nodes.length !== count) throw new Error(`expected ${count} waypoints, found ${nodes.length}`);
  return { nodes };
}

export function loadWaypoints(file: string = WAYPOINTS_FILE): WaypointGraph {
  return parseWaypoints(readFileSync(file, "utf8"));
}

/** Middle of the waypoint bounding box, the reference for area names. */
export function graphCenter(graph: WaypointGraph): Vec3 {
  const xs = graph.nodes.map(node => node.pos[0]);
  const ys = graph.nodes.map(node => node.pos[1]);
  const zs = graph.nodes.map(node => node.pos[2]);
  return [(Math.min(...xs) + Math.max(...xs)) / 2, (Math.min(...ys) + Math.max(...ys)) / 2, (Math.min(...zs) + Math.max(...zs)) / 2];
}

export function nearestNode(graph: WaypointGraph, pos: Vec3): number {
  return graph.nodes.reduce((best, node) => (distance2d(node.pos, pos) < distance2d(graph.nodes[best].pos, pos) ? node.index : best), 0);
}

function edgeUnits(graph: WaypointGraph, from: number, to: number): number {
  return distance2d(graph.nodes[from].pos, graph.nodes[to].pos);
}

function walkBack(cameFrom: ReadonlyMap<number, number>, goal: number): number[] {
  const nodes = [goal];
  let cursor = goal;
  while (cameFrom.has(cursor)) {
    cursor = cameFrom.get(cursor) ?? cursor;
    nodes.unshift(cursor);
  }
  return nodes;
}

function popNearest(open: number[], score: ReadonlyMap<number, number>): number {
  const best = open.reduce((low, node, position) => ((score.get(node) ?? Infinity) < (score.get(open[low]) ?? Infinity) ? position : low), 0);
  return open.splice(best, 1)[0];
}

/** A* over directed links with straight-line heuristic. Undefined when the goal is unreachable. */
export function shortestPath(graph: WaypointGraph, from: number, to: number, blocked: ReadonlySet<string> = new Set()): Path | undefined {
  if (graph.nodes[from] === undefined || graph.nodes[to] === undefined) return undefined;
  if (from === to) return { nodes: [from], units: 0 };
  const goal = graph.nodes[to].pos;
  const walked = new Map<number, number>([[from, 0]]);
  const estimated = new Map<number, number>([[from, distance2d(graph.nodes[from].pos, goal)]]);
  const cameFrom = new Map<number, number>();
  const open = [from];
  const closed = new Set<number>();
  while (open.length > 0) {
    const current = popNearest(open, estimated);
    if (current === to) return { nodes: walkBack(cameFrom, to), units: walked.get(to) ?? 0 };
    closed.add(current);
    const soFar = walked.get(current) ?? Infinity;
    for (const child of graph.nodes[current].children) {
      if (closed.has(child) || blocked.has(`${current}-${child}`)) continue;
      const tentative = soFar + edgeUnits(graph, current, child);
      if (tentative >= (walked.get(child) ?? Infinity)) continue;
      cameFrom.set(child, current);
      walked.set(child, tentative);
      estimated.set(child, tentative + distance2d(graph.nodes[child].pos, goal));
      if (!open.includes(child)) open.push(child);
    }
  }
  return undefined;
}
