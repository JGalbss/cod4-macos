import type { Vec3 } from "./observation.ts";
import { graphCenter, nearestNode, type WaypointGraph } from "./waypoints.ts";
import { compassWord } from "./phrases.ts";

/** Radius around the graph centre that reads as "center". */
const CENTER_RADIUS_UNITS = 220;
/** Beyond this offset on an axis a node sits on the edge of the yard; on both axes it is a corner. */
const EDGE_OFFSET_UNITS = 450;
const HYPHENATED: Readonly<Record<string, string>> = { northeast: "north-east", northwest: "north-west", southeast: "south-east", southwest: "south-west" };

export interface MapSightRecord {
  readonly node: number;
  readonly sees: readonly number[];
}

/**
 * What the waypoint graph cannot say: which nodes see which, learned from the server's eye-height
 * sightline traces at match start. Everything degrades to compass words until records arrive.
 */
export class MapKnowledge {
  readonly #graph: WaypointGraph;
  readonly #center: Vec3;
  readonly #sees = new Map<number, Set<number>>();
  readonly #seenBy = new Map<number, number>();
  readonly #blocked = new Set<string>();

  constructor(graph: WaypointGraph) {
    this.#graph = graph;
    this.#center = graphCenter(graph);
  }

  learn(record: MapSightRecord): void {
    const targets = new Set(record.sees.filter(node => node >= 0 && node < this.#graph.nodes.length && node !== record.node));
    this.#sees.set(record.node, targets);
    for (const node of targets) this.#seenBy.set(node, (this.#seenBy.get(node) ?? 0) + 1);
  }

  /** A directed link the executor could not walk; routes stop using it. */
  blockLink(from: number, to: number): void {
    this.#blocked.add(`${from}-${to}`);
  }

  get blockedLinks(): ReadonlySet<string> {
    return this.#blocked;
  }

  /** True once the server has reported sightlines for every node. */
  get ready(): boolean {
    return this.#sees.size >= this.#graph.nodes.length;
  }

  get learnedNodes(): number {
    return this.#sees.size;
  }

  sees(from: number, node: number): boolean {
    return this.#sees.get(from)?.has(node) ?? false;
  }

  /** How many nodes have a sightline onto this one; high means open ground. */
  openness(node: number): number {
    return this.#seenBy.get(node) ?? 0;
  }

  nodeAt(pos: Vec3): number {
    return nearestNode(this.#graph, pos);
  }

  /** "north-west corner (enclosed)", "center (open)", "east edge (covered)". */
  describe(node: number): string {
    const pos = this.#graph.nodes[node]?.pos;
    if (pos === undefined) return `node ${node}`;
    const place = this.#place(pos);
    if (!this.ready) return place;
    return `${place} (${this.#coverWord(node)})`;
  }

  /** Relation of a node to an enemy's expected node, for option criteria. */
  relation(node: number, enemyNode: number): string {
    if (!this.ready) return "";
    if (this.sees(node, enemyNode)) return "sees the enemy's expected position";
    return "hidden from the enemy's expected position";
  }

  /** Nodes with no sightline from the enemy's node; the shelter a bot retreats to. */
  hiddenFrom(enemyNode: number): number[] {
    if (!this.ready) return [];
    return this.#graph.nodes.map(node => node.index).filter(node => node !== enemyNode && !this.sees(enemyNode, node));
  }

  /** Nodes that see the enemy's node; the ground a bot attacks from. */
  seeing(enemyNode: number): number[] {
    if (!this.ready) return [];
    return this.#graph.nodes.map(node => node.index).filter(node => node !== enemyNode && this.sees(node, enemyNode));
  }

  #place(pos: Vec3): string {
    const dx = pos[0] - this.#center[0];
    const dy = pos[1] - this.#center[1];
    if (Math.hypot(dx, dy) < CENTER_RADIUS_UNITS) return "center";
    const sector = HYPHENATED[compassWord(dx, dy)] ?? compassWord(dx, dy);
    if (Math.abs(dx) > EDGE_OFFSET_UNITS && Math.abs(dy) > EDGE_OFFSET_UNITS) return `${sector} corner`;
    if (Math.abs(dx) > EDGE_OFFSET_UNITS || Math.abs(dy) > EDGE_OFFSET_UNITS) return `${sector} edge`;
    return `${sector} lane`;
  }

  #coverWord(node: number): string {
    const counts = this.#graph.nodes.map(entry => this.openness(entry.index)).sort((a, b) => a - b);
    const low = counts[Math.floor(counts.length / 3)] ?? 0;
    const high = counts[Math.floor((counts.length * 2) / 3)] ?? 0;
    const seen = this.openness(node);
    if (seen <= low) return "enclosed";
    if (seen >= high) return "open";
    return "covered";
  }
}
