#!/usr/bin/env python3
"""Query the live CoD4 server for the mod settings the goal requires."""
import re
import socket
import sys
import time
import os
from pathlib import Path

HOST = os.environ.get("COD4_HOST", "127.0.0.1")
PORT = int(os.environ.get("COD4_PORT", "28961"))
password_file = Path(
    os.environ.get("COD4_RCON_FILE", "/etc/cod4-control/rcon_password")
)
if not password_file.is_file():
    raise SystemExit("set COD4_RCON_FILE to the server's local RCON credential file")
rcon = password_file.read_text(encoding="utf-8").strip()


def ask(cmd: str) -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3)
    try:
        s.sendto(b"\xff\xff\xff\xffrcon " + rcon.encode() + b" " + cmd.encode(),
                 (HOST, PORT))
        chunks = b""
        while True:
            try:
                chunks += s.recvfrom(8192)[0]
            except socket.timeout:
                break
        return chunks.decode("utf-8", "replace")
    except Exception as exc:
        return f"ERROR {exc}"
    finally:
        s.close()


WANTED = [
    ("mapvote", "map voting"),
    ("gametypeVote", "gametype voting (0 = free-for-all only)"),
    ("vote_gametypes", "votable gametypes"),
    ("g_gametype", "current gametype"),
    ("sv_mapRotation", "rotation"),
    ("sv_wwwBaseURL", "custom map download URL"),
    ("sv_authorizemode", "CD-key auth (-1 = off)"),
    ("fs_players", "per-player settings and skill"),
    ("old_hardpoints", "killstreak-based hardpoints"),
    ("xp_multi", "XP multiplier (1 = normal scoring)"),
    ("default_fov", "field of view (0 = 80, the mod's floor)"),
    ("cmd_fov", "FOV menu override (0 = off)"),
    ("nuke", "nuke killstreak threshold"),
]

# The rotation is free-for-all only, but anyone with rcon can switch gametype
# from the in-game console (vstr tdm), so war/sd/sab/koth/dom are not drift.
# "gg" is: a vote label that applyGametype turns back into dm, and rotating to
# it aborts the server.
INVALID = {"g_gametype": {"gg"}}

failures = 0
for dvar, label in WANTED:
    raw = ask(dvar)
    value = "no reply"
    for line in raw.splitlines():
        if dvar.lower() in line.lower() and "is:" in line:
            # Format is:  "name" is: "value" default: "value"
            try:
                value = line.split("is:")[1].split("default")[0].strip()
            except IndexError:
                value = line.strip()
            break
    # rcon replies carry a trailing colour code, e.g. "dm^7".
    plain = re.sub(r"\^\d", "", value).strip('" ')
    flag = ""
    if plain in INVALID.get(dvar, set()):
        flag = "  <-- INVALID"
        failures += 1
    print(f"  {label:<32} {dvar:<18} {value}{flag}")
    time.sleep(0.2)

sys.exit(1 if failures else 0)
