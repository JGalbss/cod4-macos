#!/usr/bin/env python3
"""Summarise one run directory: combat per bot, decision choices per question, latency, tokens, errors.

    python3 tools/decision_summary.py artifacts/jev-bot/<run>
"""
import collections
import json
import statistics
import sys
from pathlib import Path


def load_jsonl(path):
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            yield json.loads(line)
        except json.JSONDecodeError:
            continue


def percentile(values, p):
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round(p * (len(ordered) - 1))))
    return ordered[index]


def goal_bucket(decision, observations):
    """Was the bot chasing something fresh, something stale, holding blind, or walking to a node?"""
    obs = observations.get((decision["botId"], decision["sequence"]))
    goal = decision["fields"]["g"]
    if obs is None:
        return "unmatched"
    visible = {enemy["id"] for enemy in obs["enemies"]["visible"]}
    if goal == "hold":
        return "hold with enemy visible" if visible else "hold with nothing visible"
    if not goal.startswith("chase"):
        return "node with enemy visible" if visible else "node with nothing visible"
    target = int(goal[5:])
    if target in visible:
        return "chase visible"
    remembered = [enemy for enemy in obs["enemies"]["remembered"] if enemy["id"] == target]
    if not remembered:
        return "chase unknown"
    if remembered[0]["ageMs"] <= 3000:
        return "chase seen <=3s ago"
    if remembered[0]["ageMs"] <= 6000:
        return "chase seen 3-6s ago"
    return "chase seen >6s ago"


def main(run):
    run = Path(run)
    metrics = json.loads((run / "combat-metrics.json").read_text())
    print(f"run {run.name}: brain={metrics['brain']} observed {metrics['observedSeconds']}s")
    for bot in metrics["bots"]:
        print(f"  bot {bot['botId']}: {bot['kills']}K/{bot['deaths']}D dmg {bot['damageDealt']}/{bot['damageTaken']} shots {bot['shots']} hits {bot['hits']} dist {bot['distanceUnits']}u decisions/s {bot['decisionsPerSecond']} stale {bot['staleDecisions']} rejected {bot['commandsRejected']}")
    totals = metrics["totals"]
    print(f"  total {totals['kills']}K/{totals['deaths']}D, requests {totals['requests']}, errors {totals['errors']}, input tokens {totals['inputTokens']}")
    failed = [c for c in metrics["checks"] if not c["ok"]]
    print("  checks failed:", [f"{c['name']}: {c['reason']}" for c in failed] or "none")

    observations = {}
    goal_context = collections.Counter()
    choices = collections.defaultdict(collections.Counter)
    kinds = collections.Counter()
    latencies, tokens, confidences = [], [], collections.defaultdict(list)
    errors = collections.Counter()
    rejected = collections.Counter()
    stuck = collections.Counter()
    records = list(load_jsonl(run / "events.jsonl"))
    for record in records:
        if record.get("type") == "observation":
            obs = record["observation"]
            observations[(obs["botId"], obs["sequence"])] = obs
    for record in records:
        kind = record.get("type")
        if kind == "decision":
            goal_context[goal_bucket(record, observations)] += 1
            trace = record.get("trace") or {}
            for question, choice in (trace.get("choices") or {}).items():
                name = choice["choice"]
                kinds[question + ":" + name.split("_")[0]] += 1
                choices[question][name] += 1
                confidences[question].append(choice.get("confidence", 0))
            if trace.get("latencyMs") is not None:
                latencies.append(trace["latencyMs"])
                tokens.append(trace["inputTokens"])
        elif kind == "decision_error":
            errors[record.get("code")] += 1
        elif kind == "event":
            event = record.get("event") or {}
            if event.get("event") == "command_rejected":
                rejected[event.get("reason")] += 1
            if event.get("event") == "stuck":
                stuck[event.get("botId")] += 1
    if latencies:
        print(f"  latency ms p50 {percentile(latencies, .5)} p95 {percentile(latencies, .95)} max {max(latencies)}; input tokens mean {round(statistics.mean(tokens))} max {max(tokens)}")
    print("  errors:", dict(errors) or "none", " rejected:", dict(rejected) or "none", " stuck:", dict(stuck) or "none")
    total_goals = sum(goal_context.values())
    if total_goals:
        print("  movement goal against the observation it came from: " + ", ".join(f"{name} {count / total_goals:.0%}" for name, count in goal_context.most_common()))
    for question, counter in choices.items():
        total = sum(counter.values())
        top = ", ".join(f"{name} {count / total:.0%}" for name, count in counter.most_common(6))
        print(f"  {question} ({total}, mean confidence {statistics.mean(confidences[question]):.2f}): {top}")
    grouped = collections.defaultdict(collections.Counter)
    for key, count in kinds.items():
        question, kind = key.split(":", 1)
        grouped[question][kind] += count
    for question, counter in grouped.items():
        total = sum(counter.values())
        print(f"  {question} by kind: " + ", ".join(f"{kind} {count / total:.0%}" for kind, count in counter.most_common()))


if __name__ == "__main__":
    main(sys.argv[1])
