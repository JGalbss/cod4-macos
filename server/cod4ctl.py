#!/usr/bin/env python3
"""Small CoD4 RCON control plane: CLI, interactive console, and web UI."""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import socket
import sys
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit


PACKET_PREFIX = b"\xff\xff\xff\xff"
MAP_RE = re.compile(r"^[A-Za-z0-9_]+$")
MODE_ALIASES = {
    "ffa": "dm",
    "dm": "dm",
    "tdm": "war",
    "war": "war",
    "snd": "sd",
    "sd": "sd",
    "sab": "sab",
    "hq": "koth",
    "koth": "koth",
    "dom": "dom",
}
MODE_LABELS = {
    "dm": "Free for All",
    "war": "Team Deathmatch",
    "sd": "Search and Destroy",
    "sab": "Sabotage",
    "koth": "Headquarters",
    "dom": "Domination",
}
DEFAULT_MAPS = (
    "mp_shipment",
    "mp_crash",
    "mp_vacant",
    "mp_mw2_rust",
    "mp_mw2_term",
    "mp_highrise",
    "mp_mw2_boneyard",
    "mp_scrapyard",
)
SETTING_SPECS: dict[str, tuple[str, float, float]] = {
    "scr_game_allowkillcam": ("bool", 0, 1),
    "scr_game_onlyheadshots": ("bool", 0, 1),
    "scr_hardcore": ("bool", 0, 1),
    "scr_oldschool": ("bool", 0, 1),
    "g_allowVote": ("bool", 0, 1),
    "scr_teambalance": ("bool", 0, 1),
    "mapvote": ("bool", 0, 1),
    "scr_team_fftype": ("int", 0, 3),
    "scr_player_maxhealth": ("int", 1, 1000),
    "scr_player_healthregentime": ("float", 0, 120),
    "g_speed": ("int", 50, 1000),
    "g_gravity": ("int", 50, 2000),
    "jump_height": ("int", 0, 1000),
    "xp_multi": ("float", 0.1, 1000),
    "mapvote_time": ("int", 5, 120),
}
PLAYER_POWERS = {"godmode", "aimbot", "wallhack"}


class ControlError(RuntimeError):
    pass


def _decode(packet: bytes) -> str:
    if packet.startswith(PACKET_PREFIX):
        packet = packet[4:]
    if packet.startswith(b"print\n"):
        packet = packet[6:]
    return packet.decode("utf-8", "replace").replace("\x00", "")


def parse_info_string(value: str) -> dict[str, str]:
    fields = value.strip().split("\\")
    if fields and fields[0] == "":
        fields = fields[1:]
    return dict(zip(fields[0::2], fields[1::2]))


def parse_status_response(packets: list[bytes]) -> dict[str, object]:
    if not packets:
        raise ControlError("server did not answer")
    text = "".join(_decode(packet) for packet in packets)
    if text.startswith("statusResponse\n"):
        text = text.removeprefix("statusResponse\n")
    lines = text.splitlines()
    if not lines:
        raise ControlError("server returned an empty status")
    info = parse_info_string(lines[0])
    players: list[dict[str, object]] = []
    for line in lines[1:]:
        match = re.match(r'^\s*(-?\d+)\s+(-?\d+)\s+"(.*)"\s*$', line)
        if match:
            players.append(
                {
                    "score": int(match.group(1)),
                    "ping": int(match.group(2)),
                    "name": match.group(3),
                }
            )
    return {"online": True, "info": info, "players": players}


def parse_rcon_players(output: str) -> list[dict[str, object]]:
    """Parse the slot-bearing rows from CoD4X's RCON status command."""
    players: list[dict[str, object]] = []
    pattern = re.compile(
        r"^\s*(\d+)\s+(-?\d+)\s+(\d+|CNCT|ZMBI)\s+\S+\s+\S+\s+"
        r"(.+?)\s+\d+\s+\S+\s+\d+\s+\d+\s*$"
    )
    for line in output.splitlines():
        match = pattern.match(line)
        if not match:
            continue
        ping_text = match.group(3)
        players.append(
            {
                "slot": int(match.group(1)),
                "score": int(match.group(2)),
                "ping": int(ping_text) if ping_text.isdigit() else ping_text,
                "name": match.group(4).strip(),
            }
        )
    return players


def plain_player_name(value: str) -> str:
    return re.sub(r"\^[0-9]", "", value)


def validate_map(name: str) -> str:
    if not MAP_RE.fullmatch(name):
        raise ControlError("map names may contain only letters, numbers, and underscores")
    return name


def normalize_mode(value: str) -> str:
    try:
        return MODE_ALIASES[value.lower()]
    except KeyError as exc:
        choices = ", ".join(sorted(MODE_ALIASES))
        raise ControlError(f"unknown mode {value!r}; choose one of: {choices}") from exc


def validate_web_command(command: str) -> str:
    command = command.strip().removeprefix("/")
    if not command:
        raise ControlError("command is empty")
    if len(command.encode()) > 512:
        raise ControlError("command is longer than 512 bytes")
    if any(char in command for char in ("\n", "\r", ";")):
        raise ControlError("web console accepts one command at a time")
    words = command.lower().split()
    if words[0] in {"quit", "killserver"}:
        raise ControlError("stopping the server is disabled in the web console")
    if any("password" in word for word in words):
        raise ControlError("reading or changing passwords is disabled in the web console")
    return command


def validate_message(message: str) -> str:
    message = " ".join(message.split())
    if not message:
        raise ControlError("announcement is empty")
    if len(message.encode()) > 300:
        raise ControlError("announcement is longer than 300 bytes")
    return message


def validate_slot(value: object) -> int:
    try:
        slot = int(str(value))
    except ValueError as exc:
        raise ControlError("client slot must be a whole number") from exc
    if not 0 <= slot <= 127:
        raise ControlError("client slot must be between 0 and 127")
    return slot


def validate_level(value: object) -> int:
    try:
        level = int(str(value))
    except ValueError as exc:
        raise ControlError("level must be a whole number") from exc
    if not 1 <= level <= 55:
        raise ControlError("level must be between 1 and 55")
    return level


def validate_player_power(value: object) -> str:
    power = str(value).lower()
    if power not in PLAYER_POWERS:
        raise ControlError("unknown player power")
    return power


def validate_toggle(value: object) -> str:
    state = str(value).lower()
    if state not in {"on", "off"}:
        raise ControlError("player power state must be on or off")
    return state


def parse_dvar_list(output: str) -> dict[str, str]:
    values: dict[str, str] = {}
    pattern = re.compile(
        r'^\s*(?:[A-Z]+\s+)*([A-Za-z_][A-Za-z0-9_]*)\s+"([^"]*)"\s*$'
    )
    for line in output.splitlines():
        match = pattern.match(line)
        if match:
            values[match.group(1)] = match.group(2)
    return values


def validate_setting(name: str, value: object) -> str:
    if name not in SETTING_SPECS:
        raise ControlError(f"setting {name!r} is not editable in the dashboard")
    kind, minimum, maximum = SETTING_SPECS[name]
    if kind == "bool":
        if value is True or value in (1, "1"):
            return "1"
        if value is False or value in (0, "0"):
            return "0"
        raise ControlError(f"{name} must be on or off")
    try:
        number = float(str(value))
    except ValueError as exc:
        raise ControlError(f"{name} must be a number") from exc
    if not minimum <= number <= maximum:
        raise ControlError(f"{name} must be between {minimum:g} and {maximum:g}")
    if kind == "int":
        if not number.is_integer():
            raise ControlError(f"{name} must be a whole number")
        return str(int(number))
    return f"{number:g}"


def load_password(explicit_path: str | None = None) -> str:
    direct = os.environ.get("COD4_RCON_PASSWORD", "").strip()
    if direct:
        return direct
    candidates = [
        explicit_path,
        os.environ.get("COD4_RCON_FILE"),
        "/etc/cod4-control/rcon_password",
        str(Path.home() / ".cod4-mac/config/rcon_password"),
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            password = Path(candidate).read_text(encoding="utf-8").strip()
            if password:
                return password
    raise ControlError(
        "RCON password not found; set COD4_RCON_FILE or create "
        "~/.cod4-mac/config/rcon_password"
    )


class Cod4Connection:
    """Serializes RCON because the CoD4 server accepts one command per 500 ms."""

    def __init__(self, host: str, port: int, password: str):
        self.host = host
        self.port = port
        self.password = password
        self._lock = threading.Lock()
        self._last_rcon = 0.0

    def _exchange(self, payload: bytes, timeout: float = 2.0) -> list[bytes]:
        packets: list[bytes] = []
        address = socket.getaddrinfo(
            self.host, self.port, type=socket.SOCK_DGRAM
        )[0][4]
        family = socket.AF_INET6 if len(address) == 4 else socket.AF_INET
        with socket.socket(family, socket.SOCK_DGRAM) as sock:
            sock.settimeout(timeout)
            sock.sendto(PACKET_PREFIX + payload, address)
            while True:
                try:
                    packet, _ = sock.recvfrom(65535)
                    packets.append(packet)
                    sock.settimeout(0.18)
                except socket.timeout:
                    break
        return packets

    def status(self) -> dict[str, object]:
        return parse_status_response(self._exchange(b"getstatus", timeout=1.2))

    def rcon(self, command: str) -> str:
        command = command.strip()
        if not command:
            raise ControlError("RCON command is empty")
        if len(command.encode()) > 900:
            raise ControlError("RCON command is longer than 900 bytes")
        with self._lock:
            delay = 0.55 - (time.monotonic() - self._last_rcon)
            if delay > 0:
                time.sleep(delay)
            payload = b"rcon " + self.password.encode() + b" " + command.encode()
            packets = self._exchange(payload)
            self._last_rcon = time.monotonic()
        if not packets:
            raise ControlError("server did not answer RCON (check password and address)")
        output = "".join(_decode(packet) for packet in packets).strip()
        if "Invalid password" in output:
            raise ControlError("server rejected the RCON password")
        return output


class Controller:
    def __init__(self, connection: Cod4Connection, maps: tuple[str, ...]):
        self.connection = connection
        self.maps = maps

    def dashboard(self) -> dict[str, object]:
        status = self.connection.status()
        info = status["info"]
        assert isinstance(info, dict)
        public_players = status["players"]
        assert isinstance(public_players, list)
        try:
            admin_players = parse_rcon_players(self.connection.rcon("status"))
        except ControlError:
            admin_players = []
        slots_by_name: dict[str, list[int]] = {}
        for player in admin_players:
            slots_by_name.setdefault(plain_player_name(str(player["name"])), []).append(
                int(player["slot"])
            )
        for player in public_players:
            assert isinstance(player, dict)
            slots = slots_by_name.get(plain_player_name(str(player.get("name", ""))), [])
            player["slot"] = slots.pop(0) if slots else None
        return {
            **status,
            "server": f"{self.connection.host}:{self.connection.port}",
            "map": info.get("mapname", "unknown"),
            "mode": info.get("g_gametype", "unknown"),
            "modeLabel": MODE_LABELS.get(info.get("g_gametype", ""), "Unknown"),
            "hostname": info.get("sv_hostname", "CoD4 server"),
            "uptime": info.get("uptime", "unknown"),
            "maxPlayers": int(info.get("sv_maxclients", "0") or 0),
            "maps": self.maps,
            "modes": [
                {"value": value, "label": label}
                for value, label in MODE_LABELS.items()
            ],
        }

    def player_progression(
        self, slot_value: object, operation: str, level_value: object = None
    ) -> str:
        slot = validate_slot(slot_value)
        commands = {
            "cac": f"cmd unlockcac:{slot}",
            "max": f"cmd maxrank:{slot}",
        }
        if operation == "level":
            target_level = validate_level(level_value)
            command = f"cmd setlevel:{slot}:{target_level}"
            confirmation = (
                f"Level {target_level} queued safely. Promotions are rate-limited; "
                "level 1 to 55 takes about 42 seconds."
            )
        else:
            try:
                command = commands[operation]
            except KeyError as exc:
                raise ControlError("unknown progression operation") from exc
            confirmation = {
                "cac": "Create-a-Class repair applied.",
                "max": (
                    "Max-rank repair queued safely. Every unlock tier will be replayed "
                    "in about 42 seconds."
                ),
            }[operation]
        output = self.connection.rcon(command)
        return "\n".join(part for part in (confirmation, output) if part)

    def player_power(self, slot_value: object, power_value: object, state_value: object) -> str:
        slot = validate_slot(slot_value)
        power = validate_player_power(power_value)
        state = validate_toggle(state_value)
        return self.connection.rcon(f"cmd adminpower:{slot}:{power}_{state}")

    def change_map(self, map_name: str, mode: str | None = None) -> str:
        map_name = validate_map(map_name)
        output: list[str] = []
        if mode:
            output.append(self.connection.rcon(f"g_gametype {normalize_mode(mode)}"))
        output.append(self.connection.rcon(f"map {map_name}"))
        return "\n".join(part for part in output if part)

    def change_mode(self, mode: str, map_name: str | None = None) -> str:
        mode = normalize_mode(mode)
        output = self.connection.rcon(f"g_gametype {mode}")
        if map_name:
            followup = self.connection.rcon(f"map {validate_map(map_name)}")
        else:
            followup = self.connection.rcon("map_restart")
        return "\n".join(part for part in (output, followup) if part)

    def settings(self) -> dict[str, object]:
        values = parse_dvar_list(self.connection.rcon("dvarlist"))
        rules = {
            mode: {
                "scoreLimit": values.get(f"scr_{mode}_scorelimit", ""),
                "timeLimit": values.get(f"scr_{mode}_timelimit", ""),
            }
            for mode in MODE_LABELS
        }
        return {
            "values": {name: values.get(name, "") for name in SETTING_SPECS},
            "rules": rules,
        }

    def apply_settings(
        self,
        requested: object,
        mode: str,
        score_limit: object,
        time_limit: object,
    ) -> str:
        if not isinstance(requested, dict):
            raise ControlError("settings must be an object")
        if not requested:
            if score_limit in (None, "") and time_limit in (None, ""):
                raise ControlError("no settings were supplied")
        output: list[str] = []
        for name, value in requested.items():
            output.append(self.connection.rcon(f"{name} {validate_setting(name, value)}"))
        mode_name = normalize_mode(mode)
        score_name = f"scr_{mode_name}_scorelimit"
        time_name = f"scr_{mode_name}_timelimit"
        if score_limit not in (None, ""):
            try:
                score = int(str(score_limit))
            except ValueError as exc:
                raise ControlError("score limit must be a whole number") from exc
            if not 0 <= score <= 100000:
                raise ControlError("score limit must be between 0 and 100000")
            output.append(self.connection.rcon(f"{score_name} {score}"))
        if time_limit not in (None, ""):
            try:
                minutes = float(str(time_limit))
            except ValueError as exc:
                raise ControlError("time limit must be a number") from exc
            if not 0 <= minutes <= 1440:
                raise ControlError("time limit must be between 0 and 1440 minutes")
            output.append(self.connection.rcon(f"{time_name} {minutes:g}"))
        return "\n".join(part for part in output if part)


WEB_PAGE = r"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="csrf-token" content="__CSRF__">
  <title>jgalbs CoD4 control</title>
  <style>
    :root{color-scheme:dark;--bg:#010403;--panel:#030806;--line:#174a2b;--line2:#0b2817;--ink:#b8f7cb;--green:#44ff88;--dim:#5d8c6b;--amber:#ffbd3e;--bad:#ff5364}
    *{box-sizing:border-box}html{background:var(--bg)}body{margin:0;color:var(--ink);font:13px/1.45 ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;background:repeating-linear-gradient(0deg,#0000 0,#0000 3px,#0b1b1022 4px),var(--bg)}body:before{content:"";position:fixed;inset:0;pointer-events:none;background:linear-gradient(90deg,#0f02 1px,transparent 1px);background-size:80px 100%;opacity:.2}
    main{width:min(1220px,100%);min-height:100vh;margin:0 auto;padding:18px;border-left:1px solid var(--line2);border-right:1px solid var(--line2)}.top{display:flex;gap:18px;align-items:center;justify-content:space-between;border:1px solid var(--line);padding:12px 14px;background:#020704}.eyebrow{color:var(--dim);text-transform:uppercase;letter-spacing:.16em;font-size:10px}h1{color:var(--green);font:700 20px/1 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.1em;margin:6px 0 0;text-transform:uppercase;text-shadow:0 0 14px #44ff8855}h1:before{content:"> "}.live{color:var(--green)}
    .grid{display:grid;grid-template-columns:repeat(4,1fr);gap:0;margin:10px 0;border:1px solid var(--line)}.card{background:#020704;padding:11px 13px;border-right:1px solid var(--line2)}.card:last-child{border-right:0}.label{color:var(--dim);font-size:10px;text-transform:uppercase;letter-spacing:.14em}.label:before{content:"// "}.value{color:var(--green);font-weight:700;font-size:15px;margin-top:4px;overflow-wrap:anywhere}.cols{display:grid;grid-template-columns:1fr 1fr;gap:10px}.panel{position:relative;margin-top:10px;background:var(--panel);border:1px solid var(--line);padding:14px}.cols .panel{margin-top:0}.panel:after{content:"";position:absolute;right:-1px;top:-1px;width:10px;height:10px;border-top:1px solid var(--green);border-right:1px solid var(--green)}.panel h2{color:var(--green);font:700 13px/1.2 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.12em;text-transform:uppercase;margin:0 0 7px}.panel h2:before{content:"[ "}.panel h2:after{content:" ]"}.panel-note{color:var(--dim);margin:0 0 12px;font-size:11px}label{display:block;color:var(--dim);margin:9px 0 4px;text-transform:uppercase;font-size:10px;letter-spacing:.08em}
    select,input,button{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;border-radius:0;border:1px solid var(--line);padding:9px 10px;background:#010403;color:var(--ink)}select,input{width:100%;outline:none}select:focus,input:focus{border-color:var(--green);box-shadow:0 0 0 1px #44ff8833}button{cursor:pointer;color:var(--green);font-weight:700;text-transform:uppercase;letter-spacing:.06em}button:before{content:"["}button:after{content:"]"}button:hover{background:#092714;border-color:var(--green)}button.primary{background:#0b351b;color:#8affad;border-color:var(--green)}button.danger{color:var(--bad);border-color:#67242b}button:disabled{cursor:not-allowed;color:#31533b;border-color:#15291b;background:#010403}.actions{display:flex;align-items:center;gap:7px;flex-wrap:wrap;margin-top:12px}.settings-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:6px 12px}.toggle{display:flex;align-items:center;gap:8px;margin:9px 0;color:var(--ink);text-transform:uppercase}.toggle input{width:15px;height:15px;accent-color:var(--green)}.console-row{display:flex;gap:7px}.console-row input,.console-row select{flex:1}.console-row button{width:auto}code{color:var(--amber)}pre{min-height:180px;max-height:420px;overflow:auto;white-space:pre-wrap;background:#000201;border:1px solid var(--line2);padding:12px;color:var(--green);text-shadow:0 0 8px #44ff8833}pre:before{content:"root@cod4-server:~# ";color:var(--amber)}.players{list-style:none;padding:0;margin:0}.players li{display:grid;grid-template-columns:52px 1fr auto auto;gap:10px;padding:8px 0;border-bottom:1px dashed var(--line2)}.slot{color:var(--amber)}.muted{color:var(--dim)}.error{color:var(--bad)}#settings-state{font-size:11px;text-transform:uppercase}.admin-grid{display:grid;grid-template-columns:1.4fr .6fr;gap:10px}.progress-actions{margin-top:10px}.power-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-top:13px;padding-top:11px;border-top:1px dashed var(--line2)}.power{border:1px solid var(--line2);padding:8px;background:#010403}.power-name{display:block;color:var(--amber);font-size:10px;letter-spacing:.1em;margin-bottom:7px}.power .actions{margin:0;gap:5px}.power button{flex:1;padding:7px 4px;font-size:10px}.warn{color:var(--amber)}
    @media(max-width:840px){.settings-grid{grid-template-columns:1fr 1fr}}@media(max-width:760px){main{padding:8px}.grid{grid-template-columns:1fr 1fr}.card:nth-child(2){border-right:0}.card:nth-child(-n+2){border-bottom:1px solid var(--line2)}.cols{grid-template-columns:1fr}.top{align-items:start;flex-direction:column}.players li{grid-template-columns:38px minmax(60px,1fr) auto auto;gap:6px;font-size:11px}}@media(max-width:560px){.power-grid{grid-template-columns:1fr}}@media(max-width:480px){.settings-grid,.admin-grid{grid-template-columns:1fr}}
  </style>
</head>
<body><main>
  <div class="top"><div><div class="eyebrow">SSH tunnel // authenticated operator session</div><h1>COD4 / REMOTE OPS</h1></div><div id="health" class="muted">LINK NEGOTIATING...</div></div>
  <section class="grid">
    <div class="card"><div class="label">Map</div><div class="value" id="current-map">—</div></div>
    <div class="card"><div class="label">Mode</div><div class="value" id="current-mode">—</div></div>
    <div class="card"><div class="label">Players</div><div class="value" id="player-count">—</div></div>
    <div class="card"><div class="label">Uptime</div><div class="value" id="uptime">—</div></div>
  </section>
  <section class="cols">
    <div class="panel"><h2>Match control</h2>
      <label for="map">Map</label><select id="map"></select>
      <label for="mode">Game mode</label><select id="mode"></select>
      <div class="actions"><button class="primary" id="apply">Apply map + mode</button><button id="restart">Restart round</button><button id="rotate">Next rotation</button></div>
    </div>
    <div class="panel"><h2>Active clients</h2><ul class="players" id="players"><li class="muted">NO CLIENTS CONNECTED</li></ul></div>
  </section>
  <section class="panel"><h2>Live game settings</h2><p class="panel-note">Changes apply now. Use the console below for any dvar that is not listed.</p>
    <div class="settings-grid">
      <div><label for="score-limit">Score limit</label><input id="score-limit" type="number" min="0" max="100000"></div>
      <div><label for="time-limit">Time limit (minutes)</label><input id="time-limit" type="number" min="0" max="1440" step="0.5"></div>
      <div><label for="scr_team_fftype">Friendly fire</label><select id="scr_team_fftype" data-setting><option value="0">Off</option><option value="1">Shared</option><option value="2">Reflect</option><option value="3">On</option></select></div>
      <div><label for="scr_player_maxhealth">Max health</label><input id="scr_player_maxhealth" data-setting type="number" min="1" max="1000"></div>
      <div><label for="scr_player_healthregentime">Health regen seconds</label><input id="scr_player_healthregentime" data-setting type="number" min="0" max="120" step="0.1"></div>
      <div><label for="g_speed">Movement speed</label><input id="g_speed" data-setting type="number" min="50" max="1000"></div>
      <div><label for="g_gravity">Gravity</label><input id="g_gravity" data-setting type="number" min="50" max="2000"></div>
      <div><label for="jump_height">Jump height</label><input id="jump_height" data-setting type="number" min="0" max="1000"></div>
      <div><label for="xp_multi">XP multiplier</label><input id="xp_multi" data-setting type="number" min="0.1" max="1000" step="0.1"></div>
      <div><label for="mapvote_time">Map vote seconds</label><input id="mapvote_time" data-setting type="number" min="5" max="120"></div>
      <div>
        <label class="toggle"><input id="scr_game_allowkillcam" data-setting type="checkbox"> Killcam</label>
        <label class="toggle"><input id="scr_game_onlyheadshots" data-setting type="checkbox"> Headshots only</label>
      </div>
      <div>
        <label class="toggle"><input id="scr_hardcore" data-setting type="checkbox"> Hardcore</label>
        <label class="toggle"><input id="scr_oldschool" data-setting type="checkbox"> Old school</label>
      </div>
      <div>
        <label class="toggle"><input id="g_allowVote" data-setting type="checkbox"> Allow votes</label>
        <label class="toggle"><input id="scr_teambalance" data-setting type="checkbox"> Team balance</label>
      </div>
      <div><label class="toggle"><input id="mapvote" data-setting type="checkbox"> End-of-map vote</label></div>
    </div>
    <div class="actions"><button class="primary" id="apply-settings">Apply game settings</button><span id="settings-state" class="muted">Loading…</span></div>
  </section>
  <section class="cols">
    <div class="panel"><h2>Broadcast</h2><p class="panel-note">SEND A SERVER MESSAGE TO ALL ACTIVE CLIENTS.</p><div class="console-row"><input id="message" maxlength="300" placeholder="SERVER RESTARTS IN 5 MINUTES"><button id="announce">TX</button></div></div>
    <div class="panel"><h2>Player operations</h2><p class="panel-note">PROGRESSION USES THE MOD'S REAL PROMOTION PATH AND IS RATE-LIMITED TO PREVENT RELIABLE-COMMAND OVERFLOW. A FULL 1 → 55 RUN TAKES ABOUT 42 SECONDS; THE PLAYER CAN KEEP PLAYING, THEN MUST QUIT THROUGH THE MENU TO SAVE.</p>
      <div class="admin-grid"><div><label for="player-slot">Target client</label><select id="player-slot"><option value="">NO ACTIVE CLIENTS</option></select></div><div><label for="level-target">Target level</label><input id="level-target" type="number" min="1" max="55" value="55"></div></div>
      <div class="actions progress-actions"><button class="primary" id="level-player">Level up</button><button id="unlock-cac">Unlock CAC</button><button id="max-player">Max + repair</button><button class="danger" id="kick">Kick</button></div>
      <div class="power-grid">
        <div class="power"><span class="power-name">GODMODE // DAMAGE NULL</span><div class="actions"><button class="primary" id="godmode-on">Grant</button><button class="danger" id="godmode-off">Revoke</button></div></div>
        <div class="power"><span class="power-name">AIMBOT // ADS LOCK</span><div class="actions"><button class="primary" id="aimbot-on">Grant</button><button class="danger" id="aimbot-off">Revoke</button></div></div>
        <div class="power"><span class="power-name">WALLHACK // ENEMY ESP</span><div class="actions"><button class="primary" id="wallhack-on">Grant</button><button class="danger" id="wallhack-off">Revoke</button></div></div>
      </div>
    </div>
  </section>
  <section class="panel console"><h2>Server console</h2>
    <div class="console-row"><input id="command" autocomplete="off" placeholder="status, say hello, scr_dm_scorelimit 300"><button id="send">Run</button></div>
    <pre id="output">Ready.</pre>
  </section>
</main>
<script>
const csrf=document.querySelector('meta[name="csrf-token"]').content;
const $=id=>document.getElementById(id);let latest=null,settingsData=null;
const playerActionIds=['level-player','unlock-cac','max-player','kick','godmode-on','godmode-off','aimbot-on','aimbot-off','wallhack-on','wallhack-off'];
async function api(path,body){const options=body?{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf},body:JSON.stringify(body)}:{};const response=await fetch(path,options);const data=await response.json();if(!response.ok)throw new Error(data.error||response.statusText);return data}
function option(select,value,label){const node=document.createElement('option');node.value=value;node.textContent=label;select.append(node)}
function syncPlayerControls(){const disabled=!$('player-slot').value;playerActionIds.forEach(id=>$(id).disabled=disabled)}
function render(data){latest=data;$('health').textContent=`LINK UP // ${data.hostname} // ${data.server}`;$('health').className='live';$('current-map').textContent=data.map;$('current-mode').textContent=data.modeLabel;$('player-count').textContent=`${data.players.length} / ${data.maxPlayers}`;$('uptime').textContent=data.uptime;
  if(!$('map').options.length){data.maps.forEach(name=>option($('map'),name,name));data.modes.forEach(mode=>option($('mode'),mode.value,mode.label));$('map').value=data.map;$('mode').value=data.mode}
  const list=$('players');list.replaceChildren();if(!data.players.length){const item=document.createElement('li');item.className='muted';item.textContent='NO CLIENTS CONNECTED';list.append(item)}else data.players.forEach(player=>{const item=document.createElement('li');const slot=document.createElement('span');slot.className='slot';slot.textContent=player.slot===null?'[--]':`[${String(player.slot).padStart(2,'0')}]`;const name=document.createElement('span');name.textContent=player.name;const score=document.createElement('span');score.textContent=`${player.score} XP`;const ping=document.createElement('span');ping.className='muted';ping.textContent=`${player.ping}ms`;item.append(slot,name,score,ping);list.append(item)});
  const target=$('player-slot'),selected=target.value;target.replaceChildren();const controllable=data.players.filter(player=>player.slot!==null);if(!controllable.length)option(target,'','NO ACTIVE CLIENTS');else{option(target,'','SELECT TARGET // REQUIRED');controllable.forEach(player=>option(target,String(player.slot),`[${player.slot}] ${player.name}`))}if([...target.options].some(node=>node.value===selected))target.value=selected;syncPlayerControls()}
function renderSettings(data){settingsData=data;for(const [name,value] of Object.entries(data.values)){const node=$(name);if(!node)continue;if(node.type==='checkbox')node.checked=value==='1';else node.value=value}renderRules();$('settings-state').textContent='Settings loaded';$('settings-state').className='muted'}
function renderRules(){if(!settingsData)return;const rule=settingsData.rules[$('mode').value];if(rule){$('score-limit').value=rule.scoreLimit;$('time-limit').value=rule.timeLimit}}
async function refresh(){try{render(await api('/api/status'))}catch(error){$('health').textContent=error.message;$('health').className='error'}}
async function refreshSettings(){try{renderSettings(await api('/api/settings'))}catch(error){$('settings-state').textContent=error.message;$('settings-state').className='error'}}
async function action(path,body){try{$('output').textContent='Running…';const data=await api(path,body);$('output').textContent=data.output||'OK';setTimeout(refresh,900)}catch(error){$('output').textContent=`Error: ${error.message}`}}
function playerAction(operation){return action('/api/progression',{slot:$('player-slot').value,operation,level:$('level-target').value})}
function powerAction(power,state){return action('/api/power',{slot:$('player-slot').value,power,state})}
$('apply').onclick=()=>action('/api/match',{map:$('map').value,mode:$('mode').value});$('restart').onclick=()=>action('/api/restart',{});$('rotate').onclick=()=>action('/api/rotate',{});$('mode').onchange=renderRules;$('player-slot').onchange=syncPlayerControls;
$('apply-settings').onclick=async()=>{const values={};document.querySelectorAll('[data-setting]').forEach(node=>values[node.id]=node.type==='checkbox'?node.checked:node.value);$('settings-state').textContent='Applying…';try{const data=await api('/api/settings',{settings:values,mode:$('mode').value,scoreLimit:$('score-limit').value,timeLimit:$('time-limit').value});$('output').textContent=data.output||'Settings applied.';$('settings-state').textContent='Applied';await refreshSettings()}catch(error){$('settings-state').textContent=error.message;$('settings-state').className='error'}};
$('announce').onclick=()=>action('/api/say',{message:$('message').value});$('level-player').onclick=()=>playerAction('level');$('unlock-cac').onclick=()=>playerAction('cac');$('max-player').onclick=()=>playerAction('max');$('kick').onclick=()=>action('/api/kick',{slot:$('player-slot').value});['godmode','aimbot','wallhack'].forEach(power=>{ $(power+'-on').onclick=()=>powerAction(power,'on');$(power+'-off').onclick=()=>powerAction(power,'off')});$('send').onclick=()=>action('/api/command',{command:$('command').value});$('command').onkeydown=event=>{if(event.key==='Enter')$('send').click()};$('message').onkeydown=event=>{if(event.key==='Enter')$('announce').click()};refresh().then(refreshSettings);setInterval(refresh,5000);
</script></body></html>"""


def make_handler(controller: Controller, csrf_token: str):
    class Handler(BaseHTTPRequestHandler):
        server_version = "cod4-control/1"

        def log_message(self, fmt: str, *args: object) -> None:
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

        def _headers(self, content_type: str, length: int) -> None:
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(length))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; frame-ancestors 'none'")

        def _json(self, value: object, status: HTTPStatus = HTTPStatus.OK) -> None:
            payload = json.dumps(value).encode()
            self.send_response(status)
            self._headers("application/json; charset=utf-8", len(payload))
            self.end_headers()
            self.wfile.write(payload)

        def _body(self) -> dict[str, object]:
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError as exc:
                raise ControlError("invalid content length") from exc
            if length < 0 or length > 65536:
                raise ControlError("request body is too large")
            try:
                value = json.loads(self.rfile.read(length) or b"{}")
            except json.JSONDecodeError as exc:
                raise ControlError("request body is not valid JSON") from exc
            if not isinstance(value, dict):
                raise ControlError("request body must be an object")
            return value

        def _check_post(self) -> None:
            if self.headers.get("X-CSRF-Token") != csrf_token:
                raise ControlError("invalid CSRF token; refresh the page")
            origin = self.headers.get("Origin")
            host = self.headers.get("Host")
            if origin and urlsplit(origin).netloc != host:
                raise ControlError("cross-origin requests are not allowed")

        def do_GET(self) -> None:
            try:
                if self.path == "/":
                    payload = WEB_PAGE.replace("__CSRF__", csrf_token).encode()
                    self.send_response(HTTPStatus.OK)
                    self._headers("text/html; charset=utf-8", len(payload))
                    self.end_headers()
                    self.wfile.write(payload)
                elif self.path == "/api/status":
                    self._json(controller.dashboard())
                elif self.path == "/api/settings":
                    self._json(controller.settings())
                elif self.path == "/api/health":
                    self._json({"ok": True})
                else:
                    self._json({"error": "not found"}, HTTPStatus.NOT_FOUND)
            except (ControlError, OSError) as exc:
                self._json({"error": str(exc)}, HTTPStatus.BAD_GATEWAY)

        def do_POST(self) -> None:
            try:
                self._check_post()
                body = self._body()
                if self.path == "/api/match":
                    output = controller.change_map(str(body.get("map", "")), str(body.get("mode", "")))
                elif self.path == "/api/restart":
                    output = controller.connection.rcon("map_restart")
                elif self.path == "/api/rotate":
                    output = controller.connection.rcon("map_rotate")
                elif self.path == "/api/settings":
                    output = controller.apply_settings(
                        body.get("settings"),
                        str(body.get("mode", "")),
                        body.get("scoreLimit"),
                        body.get("timeLimit"),
                    )
                elif self.path == "/api/say":
                    output = controller.connection.rcon(
                        "say " + validate_message(str(body.get("message", "")))
                    )
                elif self.path == "/api/kick":
                    output = controller.connection.rcon(
                        f"clientkick {validate_slot(body.get('slot'))}"
                    )
                elif self.path == "/api/progression":
                    output = controller.player_progression(
                        body.get("slot"),
                        str(body.get("operation", "")),
                        body.get("level"),
                    )
                elif self.path == "/api/power":
                    output = controller.player_power(
                        body.get("slot"),
                        body.get("power"),
                        body.get("state"),
                    )
                elif self.path == "/api/command":
                    output = controller.connection.rcon(validate_web_command(str(body.get("command", ""))))
                else:
                    self._json({"error": "not found"}, HTTPStatus.NOT_FOUND)
                    return
                self._json({"ok": True, "output": output or "Command accepted."})
            except (ControlError, OSError) as exc:
                self._json({"error": str(exc)}, HTTPStatus.BAD_REQUEST)

    return Handler


def maps_from_environment() -> tuple[str, ...]:
    configured = os.environ.get("COD4_MAPS", "")
    if not configured:
        return DEFAULT_MAPS
    maps = tuple(validate_map(value.strip()) for value in configured.split(",") if value.strip())
    return maps or DEFAULT_MAPS


def print_dashboard(status: dict[str, object], as_json: bool) -> None:
    if as_json:
        print(json.dumps(status, indent=2))
        return
    players = status["players"]
    assert isinstance(players, list)
    print(f"{status['hostname']} ({status['server']})")
    print(f"map: {status['map']}   mode: {status['mode']} ({status['modeLabel']})")
    print(f"players: {len(players)}/{status['maxPlayers']}   uptime: {status['uptime']}")
    for player in players:
        assert isinstance(player, dict)
        print(f"  {player['score']:>4}  {player['ping']:>4} ms  {player['name']}")


def interactive(controller: Controller) -> None:
    print("CoD4 console. Use :status, :map NAME, :mode MODE, :quit; other input is RCON.")
    while True:
        try:
            command = input("cod4> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return
        try:
            if not command:
                continue
            if command in {":quit", ":exit"}:
                return
            if command == ":status":
                print_dashboard(controller.dashboard(), False)
            elif command.startswith(":map "):
                print(controller.change_map(command.split(maxsplit=1)[1]))
            elif command.startswith(":mode "):
                print(controller.change_mode(command.split(maxsplit=1)[1]))
            else:
                print(controller.connection.rcon(command.removeprefix("/")))
        except (ControlError, OSError) as exc:
            print(f"error: {exc}", file=sys.stderr)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="cod4ctl", description=__doc__)
    parser.add_argument("--host", default=os.environ.get("COD4_HOST", "159.65.37.227"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("COD4_PORT", "28961")))
    parser.add_argument("--password-file")
    sub = parser.add_subparsers(dest="action", required=True)
    status = sub.add_parser("status", help="show live map, mode, and players")
    status.add_argument("--json", action="store_true")
    sub.add_parser("settings", help="show dashboard-editable game settings as JSON")
    sub.add_parser("players", help="show the server's detailed status output")
    map_cmd = sub.add_parser("map", help="change map immediately")
    map_cmd.add_argument("name")
    map_cmd.add_argument("--mode")
    mode = sub.add_parser("mode", help="change mode and restart the round")
    mode.add_argument("name")
    mode.add_argument("--map")
    sub.add_parser("restart", help="restart the current round")
    sub.add_parser("rotate", help="advance the configured rotation")
    kick = sub.add_parser("kick", help="kick a client slot")
    kick.add_argument("slot", type=int)
    level = sub.add_parser("level", help="raise a client to a level from 1 to 55")
    level.add_argument("slot", type=int)
    level.add_argument("level", type=int)
    unlock_cac = sub.add_parser("unlock-cac", help="repair Create-a-Class for a client")
    unlock_cac.add_argument("slot", type=int)
    max_rank = sub.add_parser("max-rank", help="set rank 55 and replay every unlock")
    max_rank.add_argument("slot", type=int)
    power = sub.add_parser("power", help="grant or revoke a per-player admin power")
    power.add_argument("slot", type=int)
    power.add_argument("power", choices=sorted(PLAYER_POWERS))
    power.add_argument("state", choices=("on", "off"))
    say = sub.add_parser("say", help="send a server message")
    say.add_argument("message", nargs="+")
    raw = sub.add_parser("raw", help="send an arbitrary RCON command")
    raw.add_argument("command", nargs=argparse.REMAINDER)
    sub.add_parser("console", help="open an interactive RCON console")
    web = sub.add_parser("web", help="serve the private web panel")
    web.add_argument("--listen", default=os.environ.get("COD4_CONTROL_LISTEN", "127.0.0.1"))
    web.add_argument("--web-port", type=int, default=int(os.environ.get("COD4_CONTROL_PORT", "8787")))
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        password = load_password(args.password_file)
        controller = Controller(
            Cod4Connection(args.host, args.port, password), maps_from_environment()
        )
        if args.action == "status":
            print_dashboard(controller.dashboard(), args.json)
        elif args.action == "settings":
            print(json.dumps(controller.settings(), indent=2))
        elif args.action == "players":
            print(controller.connection.rcon("status"))
        elif args.action == "map":
            print(controller.change_map(args.name, args.mode))
        elif args.action == "mode":
            print(controller.change_mode(args.name, args.map))
        elif args.action == "restart":
            print(controller.connection.rcon("map_restart"))
        elif args.action == "rotate":
            print(controller.connection.rcon("map_rotate"))
        elif args.action == "kick":
            print(controller.connection.rcon(f"clientkick {validate_slot(args.slot)}"))
        elif args.action == "level":
            print(controller.player_progression(args.slot, "level", args.level))
        elif args.action == "unlock-cac":
            print(controller.player_progression(args.slot, "cac"))
        elif args.action == "max-rank":
            print(controller.player_progression(args.slot, "max"))
        elif args.action == "power":
            print(controller.player_power(args.slot, args.power, args.state))
        elif args.action == "say":
            print(controller.connection.rcon("say " + validate_message(" ".join(args.message))))
        elif args.action == "raw":
            if not args.command:
                raise ControlError("raw requires a command")
            print(controller.connection.rcon(" ".join(args.command).removeprefix("/")))
        elif args.action == "console":
            interactive(controller)
        elif args.action == "web":
            if args.listen not in {"127.0.0.1", "::1", "localhost"}:
                raise ControlError("the web panel must listen on loopback; use an SSH tunnel")
            server = ThreadingHTTPServer(
                (args.listen, args.web_port), make_handler(controller, secrets.token_urlsafe(32))
            )
            print(f"CoD4 control panel: http://{args.listen}:{args.web_port}")
            try:
                server.serve_forever()
            except KeyboardInterrupt:
                pass
            finally:
                server.server_close()
        return 0
    except (ControlError, OSError) as exc:
        print(f"cod4ctl: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
