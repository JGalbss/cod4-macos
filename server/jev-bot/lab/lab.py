#!/usr/bin/env python3
"""Stream observations and commands between a local controller and a private SSH Jev bot lab."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import selectors
import shlex
import signal
import subprocess
import sys
import time
from remote_worker import (ALIASES, BOT_WARFARE_NOTICES, VENDORED_SHA256, DIFFICULTIES, MAX_BOT_COUNT,
                           MAX_BW_COUNT, MAX_CLIENTS, MIN_BOT_COUNT)

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent
REPO = PROJECT.parents[1]
VENDOR = PROJECT.parent / 'vendor/bot-warfare'
OPPONENT = re.compile(r'bot_warfare:([A-Za-z_ -]+):([0-9]+)')
# cod4_ai.bot_warfare_opponent's curriculum levels; they need bots_play_* switches this lab does not pin.
PASSIVE_LEVELS = ('passive_still', 'passive_moving')
ARTIFACTS = ('stream.jsonl', 'actions.jsonl', 'ssh.log', 'lab.json', 'done.json', 'server.log', 'qconsole.log',
             'telemetry.jsonl')


def parse_opponents(text):
    """bot_warfare:<level>:<count> as the worker's bwSkill and bwCount."""
    match = OPPONENT.fullmatch(text)
    if match is None:
        raise argparse.ArgumentTypeError('expected bot_warfare:<level>:<count>')
    key = match.group(1).strip().lower().replace('-', '_').replace(' ', '_')
    level = ALIASES.get(key, key)
    if level in PASSIVE_LEVELS:
        raise argparse.ArgumentTypeError('passive Bot Warfare levels are not supported by this lab')
    if level not in DIFFICULTIES:
        raise argparse.ArgumentTypeError('unknown Bot Warfare level; use one of ' + ', '.join([*DIFFICULTIES, *ALIASES]))
    count = int(match.group(2))
    if not 1 <= count <= MAX_BW_COUNT:
        raise argparse.ArgumentTypeError('Bot Warfare count must be 1..' + str(MAX_BW_COUNT))
    return {'kind': 'bot_warfare', 'level': level, 'skill': DIFFICULTIES[level], 'count': count}


def bot_warfare_files(vendor=VENDOR):
    """Base64 of the vendored files; refused when any pinned byte differs from the commit."""
    files = {}
    for name in [*VENDORED_SHA256, *BOT_WARFARE_NOTICES]:
        path = vendor / name
        if path.is_symlink() or not path.is_file():
            raise ValueError('Vendored Bot Warfare file missing: ' + name)
        data = path.read_bytes()
        digest = VENDORED_SHA256.get(name)
        if digest is not None and hashlib.sha256(data).hexdigest() != digest:
            raise ValueError('Vendored Bot Warfare file differs from the pinned commit: ' + name)
        files[name] = base64.b64encode(data).decode()
    return files


def native_plugin_payload(path):
    plugin = path.read_bytes()
    if not 100 <= len(plugin) <= 131072:
        raise ValueError('native observation plugin must be 100-131072 bytes')
    if plugin[:7] != b'\x7fELF\x01\x01\x01' or plugin[16:20] != b'\x03\x00\x03\x00':
        raise ValueError('native observation requires an i386 shared library')
    return {'data': base64.b64encode(plugin).decode(), 'sha256': hashlib.sha256(plugin).hexdigest()}


def build_bootstrap(args, fixture, waypoints, plugin_payload, opponents, vendor=VENDOR):
    """The one bootstrap line the worker stages from; scripts and vendored files travel as base64."""
    bootstrap = {'type': 'bootstrap', 'seconds': args.seconds, 'port': args.port,
                 'botCount': args.bots, 'gameMode': args.game_mode,
                 'fixture': base64.b64encode(fixture).decode(), 'fixtureSha256': hashlib.sha256(fixture).hexdigest(),
                 'waypoints': base64.b64encode(waypoints).decode(),
                 'waypointsSha256': hashlib.sha256(waypoints).hexdigest()}
    if plugin_payload:
        bootstrap['nativePlugin'] = plugin_payload
    if args.spawn_layout is not None:
        bootstrap['spawnLayout'] = args.spawn_layout
    if opponents:
        bootstrap.update(bwCount=opponents['count'], bwSkill=opponents['skill'], bwFiles=bot_warfare_files(vendor))
    if getattr(args, 'public', None):
        bootstrap['password'] = args.public
    bootstrap['map'] = getattr(args, 'map', 'mp_shipment')
    bootstrap['loadout'] = getattr(args, 'loadout', 'assault') + '_mp'
    return bootstrap


def worker_environment():
    """The API key belongs to the controller only; no *_API_KEY reaches ssh or the worker."""
    return {name: value for name, value in os.environ.items() if not name.endswith('_API_KEY')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=int, default=60)
    parser.add_argument('--bots', type=int, choices=range(MIN_BOT_COUNT, MAX_BOT_COUNT + 1), default=4)
    parser.add_argument('--game-mode', choices=('war', 'dm', 'sd', 'dom', 'koth'), default='war')
    parser.add_argument('--map', default='mp_shipment', help='Map to load; its waypoints must be passed with --waypoints')
    parser.add_argument('--loadout', choices=('assault', 'specops', 'heavygunner', 'demolitions', 'sniper'), default='assault', help='Stock class the Jev bots spawn with')
    parser.add_argument('--port', type=int, default=28985)
    parser.add_argument('--ssh', default='root@159.65.37.227')
    parser.add_argument('--fixture', type=Path, default=PROJECT / 'game/jev_bot.gsx')
    parser.add_argument('--waypoints', type=Path, default=PROJECT / 'game/jev_bot_waypoints.gsx')
    parser.add_argument('--native-plugin', type=Path, help='Private i386 observation plugin; optional')
    parser.add_argument('--spawn-layout', type=int, choices=range(3), help='Deterministic initial authored team spawn layout; optional')
    parser.add_argument('--opponents', type=parse_opponents, help='bot_warfare:<level>:<count>; optional')
    parser.add_argument('--brain', choices=('scripted', 'jev'), default='scripted', help='Label only; brains live in the controller')
    parser.add_argument('--public', metavar='PASSWORD', help='Let a human join: bind all interfaces and gate joins with this game password; the port must be open in the host firewall')
    parser.add_argument('--validate-only', action='store_true', help='Check local inputs without SSH or game launch')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 3600:
        parser.error('--seconds must be between 1 and 3600')
    if not 1024 <= args.port <= 65535 or args.port in (28960, 28961):
        parser.error('use a non-production port')
    if args.game_mode != 'war' and args.spawn_layout is not None:
        parser.error('--spawn-layout is only supported for war')
    opponents = args.opponents
    if opponents and args.bots + opponents['count'] > MAX_CLIENTS:
        parser.error('--bots plus Bot Warfare count must not exceed ' + str(MAX_CLIENTS))
    fixture = args.fixture.read_bytes()
    waypoints = args.waypoints.read_bytes()
    plugin_payload = None
    if args.native_plugin:
        try:
            plugin_payload = native_plugin_payload(args.native_plugin)
        except ValueError as error:
            parser.error(str(error))
    try:
        bootstrap = build_bootstrap(args, fixture, waypoints, plugin_payload, opponents)
    except ValueError as error:
        parser.error(str(error))
    if args.validate_only:
        print(json.dumps({'valid': True, 'fixtureSha256': bootstrap['fixtureSha256'],
                          'waypointsSha256': bootstrap['waypointsSha256'],
                          'botCount': args.bots, 'gameMode': args.game_mode, 'brain': args.brain,
                          'spawnLayout': args.spawn_layout, 'opponents': opponents,
                          'nativePluginSha256': plugin_payload['sha256'] if plugin_payload else None}))
        return 0
    output = args.output or REPO / 'artifacts/jev-bot' / (time.strftime('%Y%m%d-%H%M%S-') + secrets.token_hex(3))
    output.mkdir(parents=True, exist_ok=True)
    for name in ARTIFACTS:
        if (output / name).exists():
            parser.error('output already contains a lab artifact: ' + name)
    source = (HERE / 'remote_worker.py').read_text()
    command = ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
               # Tolerate link stalls of up to two minutes: a dropped session ends the match and
               # orphans the server until its watchdog fires.
               '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=8', args.ssh,
               'python3 -u -c ' + shlex.quote(source)]
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               env=worker_environment())
    process.stdin.write((json.dumps(bootstrap) + '\n').encode())
    process.stdin.flush()
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, 'output')
    selector.register(process.stderr, selectors.EVENT_READ, 'error')
    selector.register(sys.stdin.fileno(), selectors.EVENT_READ, 'input')
    buffers = {'input': bytearray(), 'output': bytearray()}
    stopping = False
    done = None
    stop_sent = False
    deadline = time.monotonic() + args.seconds + 70

    def interrupted(_signum, _frame):
        nonlocal stopping
        stopping = True

    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, interrupted)

    def stop():
        nonlocal stop_sent
        if not stop_sent:
            stop_sent = True
            try:
                process.stdin.write(b'{"type":"stop"}\n')
                process.stdin.flush()
                process.stdin.close()
            except (OSError, BrokenPipeError):
                pass

    def collect_server_log(message):
        root = message.get('root')
        if not isinstance(root, str) or not re.fullmatch(r'/tmp/cod4-jev-[a-zA-Z0-9_]+', root):
            return
        remote = '''from pathlib import Path
import base64,json,sys
p=Path(sys.argv[1]); key=(p/'rcon.key').read_text().strip().encode()
paths={'server.log':p/'server.log','qconsole.log':p/'home/mods/jev_test/qconsole.log',
       'telemetry.jsonl':p/'home/mods/jev_test/jev_telemetry.jsonl'}
result={}; total=0
for name,path in paths.items():
    if not path.exists():continue
    assert path.is_file() and not path.is_symlink()
    data=path.read_bytes(); total+=len(data); assert total<=33554432
    result[name]=base64.b64encode(data.replace(key,b'[REDACTED]')).decode()
print(json.dumps(result))
'''
        result = subprocess.run(['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', args.ssh,
                                 'python3 -c ' + shlex.quote(remote) + ' ' + shlex.quote(root)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15, env=worker_environment())
        if result.returncode == 0:
            logs = json.loads(result.stdout)
            fields = {'server.log': 'serverLog', 'qconsole.log': 'consoleLog', 'telemetry.jsonl': 'telemetryLog'}
            if not isinstance(logs, dict) or not set(logs).issubset(fields):
                raise ValueError('Invalid lab log archive')
            for name, data in logs.items():
                path = output / name
                path.write_bytes(base64.b64decode(data, validate=True))
                message[fields[name]] = str(path.resolve())
            message['telemetrySource'] = 'jev_telemetry.jsonl'
        else:
            message['serverLogError'] = 'Could not collect private server log'

    with (output / 'stream.jsonl').open('w') as stream, (output / 'actions.jsonl').open('w') as actions, (output / 'ssh.log').open('wb') as errors:
        try:
            while time.monotonic() < deadline:
                if stopping:
                    stop()
                events = selector.select(.2)
                for event, _ in events:
                    kind = event.data
                    fd = event.fd
                    chunk = os.read(fd, 65536)
                    if not chunk:
                        selector.unregister(event.fileobj)
                        if kind == 'input':
                            stopping = True
                            stop()
                        continue
                    if kind == 'error':
                        errors.write(chunk)
                        errors.flush()
                        sys.stderr.buffer.write(chunk)
                        sys.stderr.buffer.flush()
                        continue
                    buffers[kind].extend(chunk)
                    if len(buffers[kind]) > 1048576:
                        raise ValueError('Oversize streaming line')
                    while b'\n' in buffers[kind]:
                        raw, _, tail = buffers[kind].partition(b'\n')
                        buffers[kind] = bytearray(tail)
                        if not raw.strip():
                            continue
                        message = json.loads(raw)
                        if kind == 'input':
                            if not isinstance(message, dict) or message.get('type') not in ('command', 'stop'):
                                raise ValueError('Expected command or stop')
                            actions.write(json.dumps(message) + '\n')
                            actions.flush()
                            if message['type'] == 'stop':
                                stopping = True
                                stop()
                            elif not stop_sent:
                                process.stdin.write(raw + b'\n')
                                process.stdin.flush()
                        else:
                            if message.get('type') == 'ready':
                                message['output'] = str(output.resolve())
                                message['brain'] = args.brain
                                message['opponents'] = opponents
                                (output / 'lab.json').write_text(json.dumps(message, indent=2))
                            if message.get('type') == 'done':
                                done = message
                                try:
                                    collect_server_log(message)
                                except (OSError, ValueError, subprocess.TimeoutExpired):
                                    message['serverLogError'] = 'Private server log collection timed out'
                                (output / 'done.json').write_text(json.dumps(message, indent=2))
                            line = json.dumps(message, separators=(',', ':'))
                            stream.write(line + '\n')
                            stream.flush()
                            try:
                                print(line, flush=True)
                            except BrokenPipeError:
                                stopping = True
                                stop()
                if process.poll() is not None and not any(key.data == 'output' for key in selector.get_map().values()):
                    break
        finally:
            stop()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            selector.close()
    if done is None:
        result = {'type': 'done', 'reason': 'ssh-ended-without-cleanup-receipt', 'sshExitCode': process.returncode,
                  'stopped': False, 'output': str(output.resolve()), 'watchdogSeconds': args.seconds + 45}
        (output / 'done.json').write_text(json.dumps(result, indent=2))
        print(json.dumps(result), flush=True)
        return 1
    return 0 if done.get('stopped') and done.get('errors') == 0 else 1


if __name__ == '__main__':
    raise SystemExit(main())
