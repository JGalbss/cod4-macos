#!/usr/bin/env python3
"""Worker for a live server: tail its telemetry, join observation parts, forward them on stdout,
and turn controller commands from stdin into rcon dvar sets. No staging, no server process of its
own; it stops when stdin closes.

    python3 live_worker.py --telemetry /opt/cod4/mods/new_experience/jev_telemetry.jsonl \
        --port 28961 --rcon-password-file /etc/cod4-control/rcon_password
"""
import argparse
import json
import os
import selectors
import signal
import socket
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from remote_worker import MAX_BOT_COUNT, MAX_LINE, ObservationJoiner, command_wire, emit, telemetry_messages  # noqa: E402

LIVE_BOT_COUNT = 8
POLL_SECONDS = 0.02


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--telemetry', type=Path, required=True)
    parser.add_argument('--port', type=int, default=28961)
    parser.add_argument('--rcon-password-file', type=Path, required=True)
    args = parser.parse_args()
    key = args.rcon_password_file.read_text().strip()
    if not key:
        raise SystemExit('empty rcon password file')

    stopping = False
    reason = 'stdin-closed'

    def interrupted(_signum, _frame):
        nonlocal stopping, reason
        stopping = True
        reason = 'signal'

    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, interrupted)

    joiner = ObservationJoiner(LIVE_BOT_COUNT)
    native_states = {}
    # Start at the end of the file: history belongs to earlier matches.
    offset = args.telemetry.stat().st_size if args.telemetry.exists() else 0
    pending_text = ''
    pending = bytearray()
    observations = 0
    submitted = 0
    errors = 0
    selector = selectors.DefaultSelector()
    selector.register(sys.stdin.fileno(), selectors.EVENT_READ)

    def read_telemetry():
        nonlocal offset, pending_text, observations, errors
        if not args.telemetry.exists():
            return
        size = args.telemetry.stat().st_size
        if size < offset:
            offset = 0  # the server rotated or truncated the file
        with args.telemetry.open('rb') as stream:
            stream.seek(offset)
            data = stream.read(1048576)
            offset = stream.tell()
        if not data:
            return
        lines = (pending_text + data.decode(errors='replace')).split('\n')
        pending_text = lines.pop()
        if len(pending_text) > MAX_LINE:
            pending_text = ''
        lines = [line.replace(key, '[REDACTED]') for line in lines]
        messages, _discarded, malformed = telemetry_messages(lines, joiner, native_states, False)
        errors += malformed
        for message in messages:
            emit(message)
            if message['type'] == 'observation':
                observations += 1

    emit({'type': 'ready', 'live': True, 'port': args.port, 'telemetry': str(args.telemetry), 'botCount': LIVE_BOT_COUNT})
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as rcon:
        rcon.connect(('127.0.0.1', args.port))
        while not stopping:
            read_telemetry()
            if b'\n' not in pending:
                if not selector.select(POLL_SECONDS):
                    continue
                chunk = os.read(sys.stdin.fileno(), 65536)
                if not chunk:
                    break
                pending.extend(chunk)
                if len(pending) > MAX_LINE * 4:
                    emit({'type': 'error', 'reason': 'oversize-command-stream'})
                    break
            while b'\n' in pending and not stopping:
                raw, _, tail = pending.partition(b'\n')
                pending = bytearray(tail)
                if not raw.strip():
                    continue
                try:
                    message = json.loads(raw)
                except ValueError:
                    errors += 1
                    continue
                if not isinstance(message, dict):
                    continue
                if message.get('type') == 'stop':
                    stopping = True
                    reason = 'requested'
                    break
                try:
                    _bot, _sequence, command = command_wire(message, LIVE_BOT_COUNT)
                except ValueError as error:
                    emit({'type': 'event', 'line': '[lab] rejected command: ' + str(error)})
                    continue
                rcon.send(b'\xff' * 4 + ('rcon ' + key + ' ' + command).encode())
                submitted += 1
    emit({'type': 'done', 'reason': reason, 'observations': observations, 'submittedCommands': submitted, 'errors': errors, 'live': True})
    return 0


if __name__ == '__main__':
    sys.exit(main())
