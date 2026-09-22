#!/usr/bin/env python3
"""Paired evaluation: the same match settings for each brain, matches run one after another
(the host holds one private server at a time), then one table from combat-metrics.json.

    TYPESAFE_API_KEY=... python3 tools/matched_eval.py --tag eval1 --matches 3 --seconds 300 \
        --opponents bot_warfare:medium:2 --brains jev scripted

Re-running with the same --tag skips matches whose combat-metrics.json already exists, so an
interrupted evaluation resumes. --report-only prints the table without running anything.
"""
import argparse
import json
import statistics
import subprocess
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
ARTIFACTS = PROJECT.parents[1] / "artifacts" / "jev-bot"


def run_match(brain, index, args):
    output = ARTIFACTS / f"{args.tag}-{brain}-{index:02d}"
    if (output / "combat-metrics.json").exists():
        print(f"[skip] {output.name} exists", flush=True)
        return output
    command = ["npm", "start", "--", "--brain", brain, "--bots", str(args.bots), "--game-mode", "dm", "--opponents", args.opponents,
               "--seconds", str(args.seconds), "--output", str(output)]
    print(f"[run] {output.name}: {' '.join(command[3:])}", flush=True)
    completed = subprocess.run(command, cwd=PROJECT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    tail = [line for line in completed.stdout.splitlines() if line.startswith("{")][-1:]
    print(f"[done] {output.name} exit {completed.returncode} {tail[0][:200] if tail else ''}", flush=True)
    return output


def load(output):
    path = output / "combat-metrics.json"
    if not path.exists():
        return None
    return json.loads(path.read_text())


def row(metrics):
    totals = metrics["totals"]
    kd = totals["kills"] / totals["deaths"] if totals["deaths"] else float(totals["kills"])
    failed = [c["name"] for c in metrics["checks"] if not c["ok"]]
    cadence = min((b["decisionsPerSecond"] or 0) for b in metrics["bots"]) if metrics["bots"] else 0
    tokens = totals["inputTokens"] / totals["requests"] if totals["requests"] else 0
    return {"kills": totals["kills"], "deaths": totals["deaths"], "kd": kd, "dmg": totals["damageDealt"], "taken": totals["damageTaken"],
            "shots": totals["shots"], "hits": totals["hits"], "cadence": cadence, "errors": totals["errors"], "requests": totals["requests"],
            "tokens": tokens, "p95": totals["requestLatencyMs"]["p95"], "failed": failed}


def report(args):
    print(f"\n{'run':28} {'K':>3} {'D':>3} {'K/D':>5} {'dmg':>5} {'taken':>5} {'shots':>5} {'hits':>4} {'dec/s':>5} {'err':>4} {'req':>4} {'tok':>5} {'p95':>4}  failed checks")
    summary = {}
    for brain in args.brains:
        rows = []
        for index in range(1, args.matches + 1):
            output = ARTIFACTS / f"{args.tag}-{brain}-{index:02d}"
            metrics = load(output)
            if metrics is None:
                print(f"{output.name:28} (missing)")
                continue
            r = row(metrics)
            rows.append(r)
            print(f"{output.name:28} {r['kills']:>3} {r['deaths']:>3} {r['kd']:>5.2f} {r['dmg']:>5} {r['taken']:>5} {r['shots']:>5} {r['hits']:>4} {r['cadence']:>5.2f} {r['errors']:>4} {r['requests']:>4} {r['tokens']:>5.0f} {str(r['p95'] or '-'):>4}  {', '.join(r['failed']) or '-'}")
        if rows:
            kills = sum(r["kills"] for r in rows)
            deaths = sum(r["deaths"] for r in rows)
            summary[brain] = {"matches": len(rows), "kills": kills, "deaths": deaths, "kd": kills / deaths if deaths else float(kills),
                              "mean_kd": statistics.mean(r["kd"] for r in rows), "errors": sum(r["errors"] for r in rows), "requests": sum(r["requests"] for r in rows)}
    print()
    for brain, s in summary.items():
        rate = f"{s['errors'] / s['requests']:.2%}" if s["requests"] else "n/a"
        print(f"{brain:9} {s['matches']} matches: {s['kills']}K/{s['deaths']}D pooled K/D {s['kd']:.2f}, mean per-match K/D {s['mean_kd']:.2f}, request errors {rate}")
    (ARTIFACTS / f"{args.tag}-summary.json").write_text(json.dumps(summary, indent=2))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--matches", type=int, default=3)
    parser.add_argument("--seconds", type=int, default=300)
    parser.add_argument("--bots", type=int, default=2)
    parser.add_argument("--opponents", default="bot_warfare:medium:2")
    parser.add_argument("--brains", nargs="+", default=["jev", "scripted"])
    parser.add_argument("--report-only", action="store_true")
    args = parser.parse_args()
    if not args.report_only:
        for index in range(1, args.matches + 1):
            for brain in args.brains:
                run_match(brain, index, args)
    report(args)


if __name__ == "__main__":
    sys.exit(main())
