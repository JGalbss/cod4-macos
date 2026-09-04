#!/usr/bin/env python3
"""Run a command in its own process group and kill the whole group on timeout.

macOS ships no timeout(1), and a game that hangs on a window or a zone load will
otherwise sit there holding memory. Killing the group also catches children.
"""
import os, signal, subprocess, sys, time

timeout = float(sys.argv[1])
cmd = sys.argv[2:]
proc = subprocess.Popen(cmd, start_new_session=True)
deadline = time.time() + timeout
while time.time() < deadline:
    if proc.poll() is not None:
        print(f"[timeboxed] exited {proc.returncode} after {timeout - (deadline - time.time()):.1f}s")
        sys.exit(proc.returncode)
    time.sleep(0.25)

print(f"[timeboxed] still running after {timeout:.0f}s - killing process group")
for sig in (signal.SIGTERM, signal.SIGKILL):
    try:
        os.killpg(os.getpgid(proc.pid), sig)
    except ProcessLookupError:
        break
    try:
        proc.wait(timeout=3)
        break
    except subprocess.TimeoutExpired:
        continue
sys.exit(124)
