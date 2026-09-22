#!/usr/bin/env python3
"""Fixture-level smoke driver: no Jev. Bot 0 chases and shoots bot 1 while walking a far waypoint;
bot 1 holds and looks around. Verifies the executor, observation join and command wire live.

usage: drive_smoke.py --output DIR [--seconds 60] [--bots 2] [--opponents bot_warfare:medium:1]
"""
import argparse, json, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True)
    parser.add_argument('--seconds', type=int, default=60)
    parser.add_argument('--bots', type=int, default=2)
    parser.add_argument('--game-mode', default='dm')
    parser.add_argument('--opponents')
    parser.add_argument('--port', type=int, default=28986)
    args = parser.parse_args()
    cmd = [sys.executable, str(HERE / 'lab/lab.py'), '--seconds', str(args.seconds), '--bots', str(args.bots),
           '--game-mode', args.game_mode, '--brain', 'scripted', '--output', args.output, '--port', str(args.port)]
    if args.opponents:
        cmd += ['--opponents', args.opponents]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    last_sent = {}
    stats = {'observations': 0, 'commands': 0, 'events': {}, 'errors': []}
    goals = ['n41', 'n12', 'n60', 'n2']
    goal_index = {}
    last_node = {}
    start = time.time()
    try:
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except ValueError:
                continue
            kind = message.get('type')
            if kind == 'event':
                text = message.get('line', '')
                if text.startswith('[server-error]') or 'script runtime error' in text or 'error' in text.lower()[:40]:
                    stats['errors'].append(text[:300])
                try:
                    event = json.loads(text)
                    name = event.get('event')
                    stats['events'][name] = stats['events'].get(name, 0) + 1
                    if name in ('ready', 'summary', 'bot_warfare_ready', 'opponent_ready', 'command_rejected', 'stuck', 'kill', 'death'):
                        print(text[:400], flush=True)
                except ValueError:
                    pass
                continue
            if kind == 'done':
                print('DONE', json.dumps(message)[:600], flush=True)
                break
            if kind != 'observation':
                continue
            obs = message['observation']
            stats['observations'] += 1
            bot = obs['botId']
            last_node[bot] = obs.get('nav', {}).get('node')
            if stats['observations'] <= 2:
                print('OBS', json.dumps(obs)[:900], flush=True)
            now = time.time()
            if now - last_sent.get(bot, 0) < 0.4:
                continue
            fields = {}
            if bot == 0:
                other = 1
                visible = [e for e in obs.get('enemies', {}).get('visible', [])]
                if visible:
                    fields = {'t': str(visible[0]['id']), 'e': 'f', 'g': 'chase' + str(visible[0]['id']), 'a': 'auto'}
                else:
                    remembered = obs.get('enemies', {}).get('remembered', [])
                    if remembered:
                        fields = {'t': str(remembered[0]['id']), 'e': 'f', 'g': 'chase' + str(remembered[0]['id']), 'l': 'e' + str(remembered[0]['id'])}
                    else:
                        # Walk to wherever bot 1 currently stands so the two must meet.
                        target_node = last_node.get(1)
                        goal = 'n' + str(target_node) if target_node is not None else goals[0]
                        fields = {'t': '-', 'g': goal, 'l': 'auto', 'r': 'auto'}
            else:
                fields = {'t': '-', 'g': 'hold', 'l': str((int(now * 40) % 720) - 360), 's': 'stand'}
            command = {'type': 'command', 'botId': bot, 'sequence': obs['sequence'], 'lifeId': obs['lifeId'],
                       'gameTimeMs': obs['gameTimeMs'], 'fields': fields}
            proc.stdin.write(json.dumps(command) + '\n')
            proc.stdin.flush()
            last_sent[bot] = now
            stats['commands'] += 1
    finally:
        try:
            proc.stdin.close()
        except Exception:
            pass
        proc.wait(timeout=120)
    print('STATS', json.dumps(stats)[:1500], flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
