import assert from "node:assert/strict";
import test from "node:test";
import { distance2d, graphCenter, loadWaypoints, nearestNode, parseWaypoints, shortestPath } from "../src/waypoints.ts";

const graph = loadWaypoints();

test("loads all 75 Shipment waypoints with in-range directed links", () => {
  assert.equal(graph.nodes.length, 75);
  graph.nodes.forEach((node, index) => {
    assert.equal(node.index, index);
    for (const child of node.children) assert.ok(child >= 0 && child < 75);
  });
  assert.deepEqual(graph.nodes[0].children, [6, 19, 3, 27, 57]);
  assert.equal(graph.nodes[37].kind, "claymore");
  assert.deepEqual(graph.nodes[41].children, [9]);
});

test("A* finds a path at least as long as the straight line and follows links", () => {
  const path = shortestPath(graph, 27, 9);
  assert.ok(path !== undefined);
  assert.equal(path.nodes[0], 27);
  assert.equal(path.nodes.at(-1), 9);
  assert.ok(path.units >= distance2d(graph.nodes[27].pos, graph.nodes[9].pos));
  path.nodes.slice(0, -1).forEach((node, position) => assert.ok(graph.nodes[node].children.includes(path.nodes[position + 1])));
  assert.deepEqual(shortestPath(graph, 5, 5), { nodes: [5], units: 0 });
  assert.equal(shortestPath(graph, 0, 99), undefined);
});

test("nearest node and centre", () => {
  assert.equal(nearestNode(graph, [-185, 460, 192]), 27);
  const center = graphCenter(graph);
  assert.ok(Math.abs(center[0]) < 20);
  assert.ok(center[1] > 50 && center[1] < 90);
});

test("the parser rejects out-of-order or dangling links", () => {
  assert.throws(() => parseWaypoints('w[1] = jevWaypoint((0, 0, 0), "", "stand");'), /out of order/);
  assert.throws(() => parseWaypoints('w[0] = jevWaypoint((0, 0, 0), "7", "stand");'), /outside/);
  assert.throws(() => parseWaypoints("nothing here"), /no jevWaypoint/);
});
