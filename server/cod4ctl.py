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
from urllib.parse import parse_qs, urlsplit

from leaderboard import LeaderboardError, LeaderboardStore, Query as LeaderboardQuery


PACKET_PREFIX = b"\xff\xff\xff\xff"
MAP_RE = re.compile(r"^[A-Za-z0-9_]+$")
BOT_NAME_RE = re.compile(r"^[A-Za-z0-9_]{1,15}$")
BOT_TEAMS = ("autoassign", "allies", "axis")
BOT_REQUEST_WAIT_SECONDS = 4.0
MODE_ALIASES = {
    "ffa": "dm",
    "dm": "dm",
    "tdm": "war",
    "war": "war",
    "snd": "sd",
    "sd": "sd",
    "sab": "sab",
    "gg": "sab",
    "gungame": "sab",
    "gun-game": "sab",
    "hq": "koth",
    "hp": "koth",
    "hardpoint": "koth",
    "koth": "koth",
    "dom": "dom",
    "dem": "dem",
    "demo": "dem",
    "demolition": "dem",
    "kc": "kc",
    "killconfirmed": "kc",
    "kill-confirmed": "kc",
    "ctf": "ctf",
    "capturetheflag": "ctf",
    "capture-the-flag": "ctf",
    "oitc": "oitc",
    "oneinthechamber": "oitc",
    "one-in-the-chamber": "oitc",
    "inf": "inf",
    "infected": "inf",
}
MODE_LABELS = {
    "dm": "Free for All",
    "war": "Team Deathmatch",
    "sd": "Search and Destroy",
    "sab": "Gun Game",
    "koth": "Hardpoint",
    "dom": "Domination",
    "dem": "Demolition",
    "kc": "Kill Confirmed",
    "ctf": "Capture the Flag",
    "oitc": "One in the Chamber",
    "inf": "Infected",
}
MAP_CATALOG_PATH = Path(__file__).resolve().with_name("community-maps.json")
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
    "scr_sd_scorelimit": ("int", 0, 500),
    "scr_sd_roundlimit": ("int", 0, 12),
    "scr_sd_roundswitch": ("int", 0, 9),
    "scr_sd_timelimit": ("float", 0, 1440),
    "scr_sd_planttime": ("int", 0, 20),
    "scr_sd_defusetime": ("int", 0, 20),
    "scr_sd_bombtimer": ("int", 1, 300),
    "scr_sd_multibomb": ("bool", 0, 1),
    "scr_hardpoint_hilltime": ("int", 10, 300),
    "scr_hardpoint_radius": ("int", 128, 384),
    "scr_hardpoint_starttime": ("int", 0, 10),
    "scr_gungame_kills": ("int", 1, 5),
    "scr_gungame_knifesetback": ("int", 0, 5),
    "scr_gungame_suicidesetback": ("bool", 0, 1),
    "scr_gungame_timelimit": ("float", 0, 1440),
    "scr_dem_timelimit": ("float", 1, 15),
    "scr_dem_bombtimer": ("int", 10, 120),
    "scr_dem_planttime": ("int", 1, 15),
    "scr_dem_defusetime": ("int", 1, 15),
    "scr_dem_extratime": ("int", 0, 300),
    "scr_dem_respawndelay": ("int", 0, 10),
    "scr_kc_scorelimit": ("int", 1, 500),
    "scr_kc_timelimit": ("float", 0, 60),
    "scr_kc_taglife": ("int", 5, 120),
    "scr_kc_respawndelay": ("int", 0, 10),
    "scr_ctf_scorelimit": ("int", 1, 20),
    "scr_ctf_timelimit": ("float", 0, 60),
    "scr_ctf_respawndelay": ("int", 0, 15),
    "scr_ctf_returntime": ("int", 5, 120),
    "scr_oitc_lives": ("int", 1, 9),
    "scr_oitc_roundtime": ("int", 30, 900),
    "scr_oitc_rounds": ("int", 1, 20),
    "scr_oitc_respawndelay": ("int", 0, 10),
    "scr_oitc_countdown": ("int", 1, 15),
    "scr_oitc_intermission": ("int", 2, 15),
    "scr_inf_timelimit": ("float", 1, 15),
    "scr_inf_starttime": ("int", 5, 60),
    "scr_inf_respawndelay": ("int", 0, 10),
}
# These ranges/defaults match the deployed sd.gsx registrations. The round cap
# is separate from rounds to win: leave it at zero for first-to-12 or longer.
SD_DEFAULTS = {"scr_sd_scorelimit": "4", "scr_sd_roundlimit": "0",
               "scr_sd_roundswitch": "3", "scr_sd_timelimit": "2.5",
               "scr_sd_planttime": "5", "scr_sd_defusetime": "5",
               "scr_sd_bombtimer": "45", "scr_sd_multibomb": "0"}
HARDPOINT_DEFAULTS = {"scr_hardpoint_hilltime": "60", "scr_hardpoint_radius": "192", "scr_hardpoint_starttime": "5"}
GUNGAME_DEFAULTS = {"scr_gungame_kills": "1", "scr_gungame_knifesetback": "1",
                    "scr_gungame_suicidesetback": "1", "scr_gungame_timelimit": "10"}
DEMOLITION_DEFAULTS = {"scr_dem_timelimit": "2.5", "scr_dem_bombtimer": "45",
                      "scr_dem_planttime": "5", "scr_dem_defusetime": "5",
                      "scr_dem_extratime": "120", "scr_dem_respawndelay": "2"}
KILL_CONFIRMED_DEFAULTS = {"scr_kc_scorelimit": "65", "scr_kc_timelimit": "10",
                           "scr_kc_taglife": "30", "scr_kc_respawndelay": "0"}
CAPTURE_THE_FLAG_DEFAULTS = {"scr_ctf_scorelimit": "3", "scr_ctf_timelimit": "10",
                           "scr_ctf_respawndelay": "5", "scr_ctf_returntime": "30"}
ONE_IN_THE_CHAMBER_DEFAULTS = {"scr_oitc_lives": "3", "scr_oitc_roundtime": "180",
                               "scr_oitc_rounds": "3", "scr_oitc_respawndelay": "2",
                               "scr_oitc_countdown": "5", "scr_oitc_intermission": "5"}
INFECTED_DEFAULTS = {"scr_inf_timelimit": "3", "scr_inf_starttime": "15",
                     "scr_inf_respawndelay": "1"}
PLAYER_POWERS = {"godmode", "aimbot", "wallhack"}


class ControlError(RuntimeError):
    pass


def load_map_catalog(path: Path | None = None) -> dict[str, dict[str, object]]:
    """Read the same versioned catalog used to package the game's map menu."""
    try:
        content = json.loads((path or MAP_CATALOG_PATH).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ControlError(f"cannot read community map catalog: {exc}") from exc
    if not isinstance(content, dict) or content.get("schema_version") != 1:
        raise ControlError("unsupported community map catalog schema")
    records = content.get("maps")
    if not isinstance(records, list) or not records:
        raise ControlError("community map catalog must contain maps")
    result: dict[str, dict[str, object]] = {}
    seen: set[str] = set()
    for record in records:
        if not isinstance(record, dict):
            raise ControlError("invalid community map record")
        name, label, modes = record.get("id"), record.get("name"), record.get("gametypes")
        if not isinstance(name, str) or not MAP_RE.fullmatch(name):
            raise ControlError("invalid map ID in community catalog")
        if name.lower() in seen:
            raise ControlError(f"duplicate map ID in community catalog: {name}")
        seen.add(name.lower())
        if not isinstance(label, str) or not label.strip() or any(ord(char) < 32 for char in label):
            raise ControlError(f"invalid display name for {name}")
        if not isinstance(modes, list) or not modes or any(not isinstance(mode, str) or mode not in MODE_LABELS for mode in modes):
            raise ControlError(f"invalid game types for {name}")
        supported = list(dict.fromkeys(modes))
        # Team modes use authored TDM spawns and grounded objective locations.
        # Match the native menu without repacking a publisher's map archive.
        if "war" in supported:
            supported.extend(mode for mode in ("dem", "kc", "ctf", "inf") if mode not in supported)
        if "dm" in supported and "oitc" not in supported:
            supported.append("oitc")
        result[name.lower()] = {"name": label.strip(), "gametypes": supported}
        # Retail maps have no community download record or bundled assets.
        if name.lower() == "mp_nuketown":
            for retail_id, label in (("mp_crash", "Crash"), ("mp_vacant", "Vacant"), ("mp_shipment", "Shipment")):
                result[retail_id] = {"name": label, "gametypes": list(MODE_LABELS)}
    for retail_id, label in (("mp_crash", "Crash"), ("mp_vacant", "Vacant"), ("mp_shipment", "Shipment")):
        if retail_id not in result:
            result[retail_id] = {"name": label, "gametypes": list(MODE_LABELS)}
    return result


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
        r"^\s*(\d+)\s+(-?\d+)\s+(\d+|CNCT|PRIM|ZMBI)\s+\S+\s+\S+\s+"
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
        self.leaderboard_store = LeaderboardStore(
            game_log=Path(os.environ.get("COD4_GAME_LOG", "/opt/cod4/mods/new_experience/games_mp.log")),
            journal=Path(os.environ.get("COD4_LEADERBOARD_JOURNAL", "/opt/cod4/mods/new_experience/ne_db/leaderboard/events.log")),
            database=os.environ.get("COD4_LEADERBOARD_DB", "/var/lib/cod4-control/leaderboard.sqlite"),
        )

    def leaderboard(self, params: dict[str, list[str]] | None = None) -> dict[str, object]:
        return self.leaderboard_store.snapshot(LeaderboardQuery.from_params(params or {}))

    def leaderboard_filters(self) -> dict[str, object]:
        return self.leaderboard_store.filters()

    def leaderboard_player(self, params: dict[str, list[str]]) -> dict[str, object]:
        keys = params.get("key") or [""]
        return self.leaderboard_store.player(keys[0], LeaderboardQuery.from_params(params))

    def leaderboard_reset(self) -> str:
        result = self.leaderboard_store.reset()
        return f"Leaderboard wiped; counting starts with the next map (tracking since {result['trackingSince']})"

    def leaderboard_hide(self, key: object, hidden: object) -> str:
        name = str(key or "").strip()
        if not name or len(name) > 32:
            raise ControlError("player key is required")
        flag = hidden is True or hidden in (1, "1", "true")
        self.leaderboard_store.set_hidden(name, flag, "hidden from the panel" if flag else "")
        return f"{name} is now {'hidden from' if flag else 'shown on'} the leaderboard"

    def bots(self) -> dict[str, object]:
        """Josh bots: the Jev-driven bots the fixture in the mod adds on request. Read from the server's dvars."""
        values = parse_dvar_list(self.connection.rcon("dvarlist"))
        roster = []
        for entry in values.get("jev_roster", "").split(","):
            parts = entry.split(":")
            if len(parts) == 3 and parts[0].isdigit():
                roster.append({"id": int(parts[0]), "name": parts[1], "team": parts[2]})
        return {
            "enabled": values.get("jev_enabled", "0") == "1",
            "live": values.get("jev_live", "0") == "1",
            "bots": roster,
            "lastResult": values.get("jev_request_result", ""),
        }

    def set_bots_enabled(self, enabled: object) -> str:
        flag = "1" if enabled is True or enabled in (1, "1", "true") else "0"
        self.connection.rcon("set jev_live 1")
        return self.connection.rcon(f"set jev_enabled {flag}")

    def bot_request(self, action: object, team: object, name: object) -> str:
        """Hand the fixture one request through jev_request and wait for its jev_request_result."""
        if action not in ("add", "remove"):
            raise ControlError("action must be add or remove")
        bot_name = str(name or "").strip()
        if action == "remove" and bot_name == "all":
            request = "remove|all"
        else:
            if not BOT_NAME_RE.fullmatch(bot_name):
                raise ControlError("bot name must be 1 to 15 letters, digits or underscores")
            if action == "add":
                side = str(team or "autoassign")
                if side not in BOT_TEAMS:
                    raise ControlError("team must be autoassign, allies or axis")
                request = f"add|{side}|{bot_name}"
            else:
                request = f"remove|{bot_name}"
        state = self.bots()
        if not state["enabled"]:
            raise ControlError("Josh bots are switched off; enable them first")
        self.connection.rcon('set jev_request_result ""')
        self.connection.rcon(f'set jev_request "{request}"')
        deadline = time.monotonic() + BOT_REQUEST_WAIT_SECONDS
        while time.monotonic() < deadline:
            time.sleep(0.4)
            result = parse_dvar_list(self.connection.rcon("dvarlist")).get("jev_request_result", "")
            if result:
                if result.startswith("error"):
                    raise ControlError(result)
                if action == "add":
                    self.leaderboard_store.mark_bot(bot_name)
                return result
        raise ControlError("the bot script did not answer; is a match running with Josh bots enabled?")

    def dashboard(self) -> dict[str, object]:
        map_catalog = load_map_catalog()
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
            "mapLabel": map_catalog.get(info.get("mapname", ""), {}).get(
                "name", info.get("mapname", "unknown")
            ),
            "mode": info.get("g_gametype", "unknown"),
            "modeLabel": MODE_LABELS.get(info.get("g_gametype", ""), "Unknown"),
            "hostname": info.get("sv_hostname", "CoD4 server"),
            "uptime": info.get("uptime", "unknown"),
            "maxPlayers": int(info.get("sv_maxclients", "0") or 0),
            "maps": self.maps,
            "mapOptions": [
                {"value": name, "label": map_catalog.get(name, {}).get("name", name),
                 "gametypes": map_catalog.get(name, {}).get("gametypes", list(MODE_LABELS))}
                for name in self.maps
            ],
            "modes": [
                {"value": value, "label": label}
                for value, label in MODE_LABELS.items()
            ],
        }

    def player_progression(
        self, slot_value: object, operation: str, level_value: object = None,
        include_locked: object = True,
    ) -> str:
        slot = validate_slot(slot_value)
        commands = {
            "cac": f"cmd unlockcac:{slot}",
            "max": f"cmd maxrank:{slot}",
        }
        if operation == "attachments":
            if type(include_locked) is not bool:
                raise ControlError("includeLocked must be true or false")
            scope = "all" if include_locked else "earned"
            command = f"cmd unlockattachments:{slot}:{scope}"
            confirmation = (
                "Attachment unlocks queued for the selected player. "
                + ("Weapons needed for their attachments are included. " if include_locked
                   else "Only already-unlocked weapons are included. ")
                + "Allow a few seconds, then reopen Create-a-Class. "
                "Rank, camouflages and class choices are preserved. Quit through the menu to save."
            )
        elif operation == "level":
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
        mode_name = normalize_mode(mode) if mode else normalize_mode(
            self.connection.status().get("info", {}).get("g_gametype", ""))
        entry = load_map_catalog().get(map_name.lower())
        if entry and mode_name not in entry["gametypes"]:
            raise ControlError(f"{entry['name']} does not support {MODE_LABELS[mode_name]}")
        output: list[str] = []
        if mode:
            output.append(self.connection.rcon(f"g_gametype {mode_name}"))
        output.append(self.connection.rcon(f"map {map_name}"))
        return "\n".join(part for part in output if part)

    def change_mode(self, mode: str, map_name: str | None = None) -> str:
        # New mode rules/registration need a full map load, including when the
        # caller wants to keep the current map. Validate both before sending.
        if not map_name:
            map_name = self.connection.status().get("info", {}).get("mapname", "")
        return self.change_map(map_name, mode)

    def settings(self) -> dict[str, object]:
        values = parse_dvar_list(self.connection.rcon("dvarlist"))
        rules = {
            mode: {
                "scoreLimit": values.get(f"scr_{mode}_scorelimit", ""),
                "timeLimit": values.get(f"scr_{mode}_timelimit", ""),
            }
            for mode in MODE_LABELS
        }
        # The mode may not have run since startup, so its dvars can be absent.
        if rules["koth"]["scoreLimit"] == "":
            rules["koth"]["scoreLimit"] = "250"
        if rules["koth"]["timeLimit"] == "":
            rules["koth"]["timeLimit"] = "10"
        # Legacy Sabotage score/time values are not Gun Game's ladder rules.
        rules["sab"] = {"scoreLimit": "", "timeLimit": values.get("scr_gungame_timelimit", "10")}
        defaults = (SD_DEFAULTS | HARDPOINT_DEFAULTS | GUNGAME_DEFAULTS | DEMOLITION_DEFAULTS |
                    KILL_CONFIRMED_DEFAULTS | CAPTURE_THE_FLAG_DEFAULTS | ONE_IN_THE_CHAMBER_DEFAULTS | INFECTED_DEFAULTS)
        rules["sd"] = {"scoreLimit": values.get("scr_sd_scorelimit", SD_DEFAULTS["scr_sd_scorelimit"]),
                       "timeLimit": values.get("scr_sd_timelimit", SD_DEFAULTS["scr_sd_timelimit"])}
        rules["dem"] = {"scoreLimit": "2", "timeLimit": values.get("scr_dem_timelimit", "2.5")}
        rules["kc"] = {"scoreLimit": values.get("scr_kc_scorelimit", "65"),
                       "timeLimit": values.get("scr_kc_timelimit", "10")}
        rules["ctf"] = {"scoreLimit": values.get("scr_ctf_scorelimit", "3"),
                        "timeLimit": values.get("scr_ctf_timelimit", "10")}
        rules["oitc"] = {"scoreLimit": "", "timeLimit": ""}
        rules["inf"] = {"scoreLimit": "", "timeLimit": values.get("scr_inf_timelimit", "3")}
        return {
            "values": {name: values.get(name, defaults.get(name, "")) for name in SETTING_SPECS},
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
        # Validate the complete request before sending any RCON mutations.
        commands: list[str] = []
        mode_name = normalize_mode(mode)
        for name, value in requested.items():
            commands.append(f"set {name} {validate_setting(name, value)}")
        score_name = f"scr_{mode_name}_scorelimit"
        time_name = f"scr_{mode_name}_timelimit"
        if score_limit not in (None, ""):
            if mode_name == "inf":
                raise ControlError("Infected ends on survival or conversion; leave score limit blank")
            if mode_name == "oitc":
                raise ControlError("One in the Chamber uses its round count; leave score limit blank")
            if mode_name == "sab":
                raise ControlError("Gun Game ends on completing its 20-tier ladder; leave score limit blank")
            try:
                score = int(str(score_limit))
            except ValueError as exc:
                raise ControlError("score limit must be a whole number") from exc
            maximum = 10000 if mode_name == "koth" else 100000
            if not 0 <= score <= maximum:
                raise ControlError(f"score limit must be between 0 and {maximum}")
            if mode_name == "dem" and score != 2:
                raise ControlError("Demolition uses two round wins; its score limit is fixed at 2")
            if mode_name in ("sd", "kc", "ctf"):
                validate_setting(score_name, score)
            commands.append(f"set {score_name} {score}")
        if time_limit not in (None, ""):
            if mode_name == "oitc":
                raise ControlError("One in the Chamber uses its round timer; leave match time limit blank")
            try:
                minutes = float(str(time_limit))
            except ValueError as exc:
                raise ControlError("time limit must be a number") from exc
            if not 0 <= minutes <= 1440:
                raise ControlError("time limit must be between 0 and 1440 minutes")
            if mode_name in ("sd", "dem", "kc", "ctf", "inf"):
                validate_setting(time_name, minutes)
            if mode_name == "sab":
                commands.append(f"set scr_gungame_timelimit {minutes:g}")
            else:
                commands.append(f"set {time_name} {minutes:g}")
        output = [self.connection.rcon(command) for command in commands]
        if mode_name == "sd" or any(name in SD_DEFAULTS for name in requested):
            output.append("Search and Destroy round limits and round length update during play. Side switching and bomb rules take effect next round. No match restart was performed.")
        if any(name in HARDPOINT_DEFAULTS for name in requested):
            output.append("Hill duration, outdoor size and opening countdown load on the next full map load. Indoor hills retain their full room footprint. No map change or restart was performed.")
        if any(name in GUNGAME_DEFAULTS for name in requested) or mode_name == "sab":
            output.append("Gun Game rules load on the next full map load. No map change or restart was performed.")
        if mode_name in ("dem", "kc", "ctf", "oitc", "inf") or any(name in DEMOLITION_DEFAULTS or name in KILL_CONFIRMED_DEFAULTS or name in CAPTURE_THE_FLAG_DEFAULTS or name in ONE_IN_THE_CHAMBER_DEFAULTS or name in INFECTED_DEFAULTS for name in requested):
            output.append("New mode settings apply on the next full map load.")
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
    .linkbtn{display:inline-block;border:1px solid var(--green);color:var(--green);padding:9px 12px;text-decoration:none;font-size:12px}.linkbtn:hover{background:#44ff8822}
    .leaderboard-head{display:flex;justify-content:space-between;align-items:start;gap:12px}.leaderboard-head button{white-space:nowrap}.leaderboard-scroll{overflow-x:auto}.leaderboard-table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}.leaderboard-table th,.leaderboard-table td{padding:10px 12px;text-align:right;border-bottom:1px solid var(--line2);white-space:nowrap}.leaderboard-table th{color:var(--dim);font-size:10px;text-transform:uppercase;letter-spacing:.08em}.leaderboard-table th:nth-child(2),.leaderboard-table td:nth-child(2){text-align:left;white-space:normal;overflow-wrap:anywhere;min-width:120px}.leaderboard-table td:nth-child(3){color:var(--green);font-weight:bold}.leaderboard-table td:first-child{color:var(--amber);width:40px}.leaderboard-table tbody tr:first-child{background:#09271455}#leaderboard-state{margin:10px 0 0;font-size:11px}
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
  <section class="panel" id="josh-bots"><h2>Josh bots</h2><p class="panel-note">JEV-DRIVEN BOTS ON THE LIVE SERVER. NAME THEM, PICK A TEAM, ADD OR REMOVE. THEY JOIN THE RUNNING MATCH WITHIN A FEW SECONDS.</p>
    <div class="actions"><button class="primary" id="bots-enable">Enable</button><button id="bots-disable">Disable</button><span id="bots-state" class="muted">Loading…</span></div>
    <div class="console-row"><input id="bot-name" autocomplete="off" maxlength="15" placeholder="Bot name (letters, digits, _)"><select id="bot-team"><option value="autoassign">Auto team</option><option value="allies">Allies</option><option value="axis">Axis</option></select><button class="primary" id="bot-add">Add bot</button><button id="bots-remove-all">Remove all</button></div>
    <div id="bots-list" class="muted">No bots.</div>
  </section>
  <section class="panel" id="leaderboard" aria-labelledby="leaderboard-title">
    <div class="leaderboard-head"><div><h2 id="leaderboard-title">Server leaderboard</h2><p class="panel-note" id="leaderboard-since">Top 10 all-time by kills</p></div><div class="actions"><a class="linkbtn" href="/leaderboard">Full leaderboard →</a><button id="leaderboard-refresh" type="button">Refresh</button></div></div>
    <div class="leaderboard-scroll"><table class="leaderboard-table" aria-label="Players ranked by total kills"><thead><tr><th scope="col">#</th><th scope="col">Player</th><th scope="col" aria-sort="descending">Kills ↓</th><th scope="col">Deaths</th><th scope="col">K/D</th><th scope="col">Wins</th></tr></thead><tbody id="leaderboard-rows"></tbody></table></div>
    <p id="leaderboard-state" class="muted" role="status">Loading leaderboard…</p>
  </section>
  <section class="panel"><h2>Game settings</h2><p class="panel-note">Use the mode sections below for extra rules and details on when they take effect.</p>
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
  <section class="panel" id="searchdestroy-settings"><h2>Search and Destroy</h2>
    <p class="panel-note">Set rounds to win for a longer match. Leave maximum total rounds at 0 so it cannot end the match early. These controls always target Search and Destroy.</p>
    <div class="settings-grid">
      <div><label for="scr_sd_scorelimit">Rounds to win (0 = no win target)</label><input id="scr_sd_scorelimit" data-searchdestroy-setting type="number" min="0" max="500" value="4"></div>
      <div><label for="scr_sd_roundlimit">Maximum total rounds (0 = no cap)</label><input id="scr_sd_roundlimit" data-searchdestroy-setting type="number" min="0" max="12" value="0"></div>
      <div><label for="scr_sd_roundswitch">Switch sides every N rounds (0 = never)</label><input id="scr_sd_roundswitch" data-searchdestroy-setting type="number" min="0" max="9" value="3"></div>
      <div><label for="scr_sd_timelimit">Round length in minutes (0 = unlimited)</label><input id="scr_sd_timelimit" data-searchdestroy-setting type="number" min="0" max="1440" step="0.25" value="2.5"></div>
      <div><label for="scr_sd_bombtimer">Bomb fuse (seconds)</label><input id="scr_sd_bombtimer" data-searchdestroy-setting type="number" min="1" max="300" value="45"></div>
      <div><label for="scr_sd_planttime">Plant time (seconds)</label><input id="scr_sd_planttime" data-searchdestroy-setting type="number" min="0" max="20" value="5"></div>
      <div><label for="scr_sd_defusetime">Defuse time (seconds)</label><input id="scr_sd_defusetime" data-searchdestroy-setting type="number" min="0" max="20" value="5"></div>
      <div><label class="toggle"><input id="scr_sd_multibomb" data-searchdestroy-setting type="checkbox"> Every attacker starts with a bomb</label></div>
    </div>
    <p class="panel-note">Round limits and round length update during play. Side switching and bomb rules take effect next round. Applying does not restart the match.</p>
    <div class="actions"><button class="primary" id="apply-searchdestroy" disabled>Apply Search and Destroy settings</button><button id="searchdestroy-long-match" disabled>Fill first to 12</button><button id="searchdestroy-defaults" disabled>Fill standard defaults</button><span id="searchdestroy-state" class="muted" role="status">Loading…</span></div>
  </section>
  <section class="panel" id="hardpoint-settings"><h2>Hardpoint</h2>
    <p class="panel-note">These controls always target Hardpoint, even while another mode is running. Score/time limits apply live during Hardpoint. Hill size, duration and start countdown load on the next full map load; they never resize or rotate the current hill mid-fight. Values survive map changes, not a server-process restart.</p>
    <div class="settings-grid">
      <div><label for="hp-score-limit">Hardpoint score limit (0 = unlimited)</label><input id="hp-score-limit" type="number" min="0" max="10000" value="250"></div>
      <div><label for="hp-time-limit">Hardpoint match minutes (0 = unlimited)</label><input id="hp-time-limit" type="number" min="0" max="1440" step="0.5" value="10"></div>
      <div><label for="scr_hardpoint_hilltime">Hill duration (seconds)</label><input id="scr_hardpoint_hilltime" data-hardpoint-setting type="number" min="10" max="300" value="60"></div>
      <div><label for="scr_hardpoint_radius">Outdoor maximum half-width (game units)</label><input id="scr_hardpoint_radius" data-hardpoint-setting type="number" min="128" max="384" value="192"></div>
      <div><label for="scr_hardpoint_starttime">Opening countdown (seconds; 0 = immediate)</label><input id="scr_hardpoint_starttime" data-hardpoint-setting type="number" min="0" max="10" value="5"></div>
    </div>
    <p class="panel-note">Indoor hills cover the authored room, including space behind furniture. Outdoor hills use floor/wall-checked rectangles; this size is their maximum, not an indoor radius. Native client 0.2.14+ is required for visible ground boundaries. Changes here never restart a match; load a map through Match control when ready.</p>
    <div class="actions"><button class="primary" id="apply-hardpoint" disabled>Apply Hardpoint settings</button><button id="hardpoint-defaults" disabled>Fill standard defaults</button><span id="hardpoint-state" class="muted">Loading…</span></div>
  </section>
  <section>
    <div class="panel" id="gungame-settings"><h2>Gun Game</h2>
      <p class="panel-note">Free-for-all. Pistols → shotguns → SMGs → rifles → LMGs → snipers → RPG → knife finish. 20 fixed tiers, animated weapon swaps, no class perks or killstreaks. Melee sets the victim back; it only advances the attacker on the final knife tier.</p>
      <div class="settings-grid">
        <div><label for="scr_gungame_kills">Kills per gun (final knife always 1)</label><input id="scr_gungame_kills" data-gungame-setting type="number" min="1" max="5" value="1"></div>
        <div><label for="scr_gungame_knifesetback">Knife setback (weapon tiers)</label><input id="scr_gungame_knifesetback" data-gungame-setting type="number" min="0" max="5" value="1"></div>
        <div><label for="scr_gungame_timelimit">Gun Game match minutes (0 = unlimited)</label><input id="scr_gungame_timelimit" data-gungame-setting type="number" min="0" max="1440" step="0.5" value="10"></div>
        <div><label class="toggle"><input id="scr_gungame_suicidesetback" data-gungame-setting type="checkbox" checked> Suicide / world death loses one tier</label></div>
      </div>
      <p class="panel-note">All Gun Game rules load next map; applying does not interrupt the current match. Tiers survive death and reconnect within this map, never alter your saved rank/classes, and reset on a new map or restart. The final tier uses an empty pistol for CoD4's normal knife attack.</p>
      <div class="actions"><button class="primary" id="apply-gungame" disabled>Apply Gun Game settings</button><button id="gungame-defaults" disabled>Fill Gun Game defaults</button><span id="gungame-state" class="muted">Loading…</span></div>
    </div>
  </section>
  <section class="panel" id="demolition-settings"><h2>Demolition</h2>
    <p class="panel-note">Destroy both sites or defend until time expires. Teams switch sides after round one; a 1–1 tie goes to a neutral-site decider. First team to two round wins takes the match. Settings load on the next full map load.</p>
    <div class="settings-grid">
      <div><label for="scr_dem_timelimit">Round minutes</label><input id="scr_dem_timelimit" data-demolition-setting type="number" min="1" max="15" step="0.5" value="2.5"></div>
      <div><label for="scr_dem_bombtimer">Bomb fuse (seconds)</label><input id="scr_dem_bombtimer" data-demolition-setting type="number" min="10" max="120" value="45"></div>
      <div><label for="scr_dem_planttime">Plant time (seconds)</label><input id="scr_dem_planttime" data-demolition-setting type="number" min="1" max="15" value="5"></div>
      <div><label for="scr_dem_defusetime">Defuse time (seconds)</label><input id="scr_dem_defusetime" data-demolition-setting type="number" min="1" max="15" value="5"></div>
      <div><label for="scr_dem_extratime">Time added after first site (seconds)</label><input id="scr_dem_extratime" data-demolition-setting type="number" min="0" max="300" value="120"></div>
      <div><label for="scr_dem_respawndelay">Respawn delay (seconds)</label><input id="scr_dem_respawndelay" data-demolition-setting type="number" min="0" max="10" value="2"></div>
    </div>
    <div class="actions"><button class="primary" id="apply-demolition" disabled>Apply Demolition settings</button><button id="demolition-defaults" disabled>Fill Demolition defaults</button><span id="demolition-state" class="muted">Loading…</span></div>
  </section>
  <section class="panel" id="killconfirmed-settings"><h2>Kill Confirmed</h2>
    <p class="panel-note">Collect enemy tags to score; collect friendly tags to deny the enemy. Unclaimed tags expire. Settings load on the next full map load.</p>
    <div class="settings-grid">
      <div><label for="scr_kc_scorelimit">Confirmed kills to win</label><input id="scr_kc_scorelimit" data-killconfirmed-setting type="number" min="1" max="500" value="65"></div>
      <div><label for="scr_kc_timelimit">Match minutes (0 = unlimited)</label><input id="scr_kc_timelimit" data-killconfirmed-setting type="number" min="0" max="60" step="0.5" value="10"></div>
      <div><label for="scr_kc_taglife">Tag lifetime (seconds)</label><input id="scr_kc_taglife" data-killconfirmed-setting type="number" min="5" max="120" value="30"></div>
      <div><label for="scr_kc_respawndelay">Respawn delay (seconds)</label><input id="scr_kc_respawndelay" data-killconfirmed-setting type="number" min="0" max="10" value="0"></div>
    </div>
    <div class="actions"><button class="primary" id="apply-killconfirmed" disabled>Apply Kill Confirmed settings</button><button id="killconfirmed-defaults" disabled>Fill Kill Confirmed defaults</button><span id="killconfirmed-state" class="muted">Loading…</span></div>
  </section>
  <section class="panel" id="capturetheflag-settings"><h2>Capture the Flag</h2>
    <p class="panel-note">Bring the enemy flag to your base while your own flag is home. Touch a dropped friendly flag to return it. Settings load on the next full map load.</p>
    <div class="settings-grid">
      <div><label for="scr_ctf_scorelimit">Captures to win</label><input id="scr_ctf_scorelimit" data-capturetheflag-setting type="number" min="1" max="20" value="3"></div>
      <div><label for="scr_ctf_timelimit">Match minutes (0 = unlimited)</label><input id="scr_ctf_timelimit" data-capturetheflag-setting type="number" min="0" max="60" step="0.5" value="10"></div>
      <div><label for="scr_ctf_returntime">Dropped flag return (seconds)</label><input id="scr_ctf_returntime" data-capturetheflag-setting type="number" min="5" max="120" value="30"></div>
      <div><label for="scr_ctf_respawndelay">Respawn delay (seconds)</label><input id="scr_ctf_respawndelay" data-capturetheflag-setting type="number" min="0" max="15" value="5"></div>
    </div>
    <div class="actions"><button class="primary" id="apply-capturetheflag" disabled>Apply Capture the Flag settings</button><button id="capturetheflag-defaults" disabled>Fill Capture the Flag defaults</button><span id="capturetheflag-state" class="muted">Loading…</span></div>
  </section>
  <section class="panel" id="oneinthechamber-settings"><h2>One in the Chamber</h2>
    <p class="panel-note">A pistol, one bullet and limited lives. Pistol and knife hits are lethal; a kill earns a bullet. The last survivor wins the round. New arrivals wait for the next round. Settings load on the next full map load.</p>
    <div class="settings-grid">
      <div><label for="scr_oitc_lives">Lives per round</label><input id="scr_oitc_lives" data-oneinthechamber-setting type="number" min="1" max="9" value="3"></div>
      <div><label for="scr_oitc_roundtime">Round timer (seconds)</label><input id="scr_oitc_roundtime" data-oneinthechamber-setting type="number" min="30" max="900" value="180"></div>
      <div><label for="scr_oitc_rounds">Rounds per match</label><input id="scr_oitc_rounds" data-oneinthechamber-setting type="number" min="1" max="20" value="3"></div>
      <div><label for="scr_oitc_respawndelay">Respawn delay (seconds)</label><input id="scr_oitc_respawndelay" data-oneinthechamber-setting type="number" min="0" max="10" value="2"></div>
      <div><label for="scr_oitc_countdown">Opening countdown (seconds)</label><input id="scr_oitc_countdown" data-oneinthechamber-setting type="number" min="1" max="15" value="5"></div>
      <div><label for="scr_oitc_intermission">Between rounds (seconds)</label><input id="scr_oitc_intermission" data-oneinthechamber-setting type="number" min="2" max="15" value="5"></div>
    </div>
    <div class="actions"><button class="primary" id="apply-oneinthechamber" disabled>Apply One in the Chamber settings</button><button id="oneinthechamber-defaults" disabled>Fill One in the Chamber defaults</button><span id="oneinthechamber-state" class="muted">Loading…</span></div>
  </section>
  <section class="panel" id="infected-settings"><h2>Infected</h2>
    <p class="panel-note">Survive until time expires. After the opening countdown, one player becomes infected; killed survivors join the infected team. Infected players use a knife. At least two ready players are needed to start. Settings load on the next full map load.</p>
    <div class="settings-grid">
      <div><label for="scr_inf_timelimit">Survival time (minutes)</label><input id="scr_inf_timelimit" data-infected-setting type="number" min="1" max="15" step="0.5" value="3"></div>
      <div><label for="scr_inf_starttime">Opening countdown (seconds)</label><input id="scr_inf_starttime" data-infected-setting type="number" min="5" max="60" value="15"></div>
      <div><label for="scr_inf_respawndelay">Respawn delay (seconds)</label><input id="scr_inf_respawndelay" data-infected-setting type="number" min="0" max="10" value="1"></div>
    </div>
    <div class="actions"><button class="primary" id="apply-infected" disabled>Apply Infected settings</button><button id="infected-defaults" disabled>Fill Infected defaults</button><span id="infected-state" class="muted">Loading…</span></div>
  </section>
  <section class="cols">
    <div class="panel"><h2>Broadcast</h2><p class="panel-note">SEND A SERVER MESSAGE TO ALL ACTIVE CLIENTS.</p><div class="console-row"><input id="message" maxlength="300" placeholder="SERVER RESTARTS IN 5 MINUTES"><button id="announce">TX</button></div></div>
    <div class="panel"><h2>Player operations</h2><p class="panel-note">PROGRESSION USES THE MOD'S REAL PROMOTION PATH AND IS RATE-LIMITED TO PREVENT RELIABLE-COMMAND OVERFLOW. A FULL 1 → 55 RUN TAKES ABOUT 42 SECONDS; THE PLAYER CAN KEEP PLAYING, THEN MUST QUIT THROUGH THE MENU TO SAVE.</p>
      <div class="admin-grid"><div><label for="player-slot">Target client</label><select id="player-slot"><option value="">NO ACTIVE CLIENTS</option></select></div><div><label for="level-target">Target level</label><input id="level-target" type="number" min="1" max="55" value="55"></div></div>
      <div class="actions progress-actions"><button class="primary" id="level-player">Level up</button><button id="unlock-cac">Unlock CAC</button><button id="max-player">Max + repair</button><button class="danger" id="kick">Kick</button></div>
      <div class="actions"><button class="primary" id="unlock-attachments" disabled>Unlock all weapon attachments</button><label class="toggle"><input id="attachments-include-locked" type="checkbox" checked> Include locked weapons</label></div>
      <p class="panel-note">Grants attachments to the selected player in a few seconds while preserving rank, camouflages and class choices. Reopen Create-a-Class afterward, and quit through the game menu to save.</p>
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
const playerActionIds=['level-player','unlock-cac','max-player','unlock-attachments','kick','godmode-on','godmode-off','aimbot-on','aimbot-off','wallhack-on','wallhack-off'];
async function api(path,body){const options=body?{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf},body:JSON.stringify(body)}:{};const response=await fetch(path,options);const data=await response.json();if(!response.ok)throw new Error(data.error||response.statusText);return data}
function option(select,value,label){const node=document.createElement('option');node.value=value;node.textContent=label;select.append(node)}
function syncPlayerControls(){const disabled=!$('player-slot').value;playerActionIds.forEach(id=>$(id).disabled=disabled)}
function render(data){latest=data;$('health').textContent=`LINK UP // ${data.hostname} // ${data.server}`;$('health').className='live';$('current-map').textContent=data.mapLabel||data.map;$('current-mode').textContent=data.modeLabel;$('player-count').textContent=`${data.players.length} / ${data.maxPlayers}`;$('uptime').textContent=data.uptime;
  if(!$('mode').options.length){data.modes.forEach(mode=>option($('mode'),mode.value,mode.label));$('mode').value=data.mode}
  renderMapChoices();
  const list=$('players');list.replaceChildren();if(!data.players.length){const item=document.createElement('li');item.className='muted';item.textContent='NO CLIENTS CONNECTED';list.append(item)}else data.players.forEach(player=>{const item=document.createElement('li');const slot=document.createElement('span');slot.className='slot';slot.textContent=player.slot===null?'[--]':`[${String(player.slot).padStart(2,'0')}]`;const name=document.createElement('span');name.textContent=player.name;const score=document.createElement('span');score.textContent=`${player.score} ${data.mode==='sab'?'progress':'XP'}`;const ping=document.createElement('span');ping.className='muted';ping.textContent=`${player.ping}ms`;item.append(slot,name,score,ping);list.append(item)});
  const target=$('player-slot'),selected=target.value;target.replaceChildren();const controllable=data.players.filter(player=>player.slot!==null);if(!controllable.length)option(target,'','NO ACTIVE CLIENTS');else{option(target,'','SELECT TARGET // REQUIRED');controllable.forEach(player=>option(target,String(player.slot),`[${player.slot}] ${player.name}`))}if([...target.options].some(node=>node.value===selected))target.value=selected;syncPlayerControls()}
function renderMapChoices(){
  if(!latest)return;
  const select=$('map'),selected=select.value,mode=$('mode').value;
  const all=latest.mapOptions||latest.maps.map(value=>({value,label:value}));
  const choices=all.filter(entry=>!entry.gametypes||entry.gametypes.includes(mode));
  if(choices.length!==select.options.length||choices.some((entry,index)=>select.options[index].value!==entry.value||select.options[index].textContent!==entry.label)){
    select.replaceChildren();choices.forEach(entry=>option(select,entry.value,entry.label));
    const available=choices.map(entry=>entry.value);
    select.value=available.includes(selected)?selected:available.includes(latest.map)?latest.map:available[0]||'';
  }
  $('apply').disabled=!choices.length;
}
function renderSettings(data){settingsData=data;for(const [name,value] of Object.entries(data.values)){const node=$(name);if(!node)continue;if(node.type==='checkbox')node.checked=value==='1';else node.value=value}renderRules();$('hp-score-limit').value=data.rules.koth.scoreLimit;$('hp-time-limit').value=data.rules.koth.timeLimit;$('settings-state').textContent='Settings loaded';$('settings-state').className='muted';$('searchdestroy-long-match').disabled=false;for(const mode of ['searchdestroy','hardpoint','gungame','demolition','killconfirmed','capturetheflag','oneinthechamber','infected']){$(mode+'-state').textContent='Settings loaded';$(mode+'-state').className='muted';$('apply-'+mode).disabled=false;$(mode+'-defaults').disabled=false}}
function renderRules(){
  if(!settingsData)return;
  const mode=$('mode').value,rule=settingsData.rules[mode];
  const score=$('score-limit'),minutes=$('time-limit');
  score.min=(mode==='kc'||mode==='ctf')?'1':'0';
  score.max=({sd:'500',koth:'10000',kc:'500',ctf:'20'})[mode]||'100000';
  document.querySelector('label[for="score-limit"]').textContent=mode==='sd'?'Rounds to win':'Score limit';
  document.querySelector('label[for="time-limit"]').textContent=mode==='sd'?'Round length (minutes)':'Time limit (minutes)';
  minutes.step=mode==='sd'?'0.25':'0.5';
  score.disabled=['sab','dem','oitc','inf'].includes(mode);
  score.placeholder=({sab:'Complete the 20-tier ladder',dem:'Win two rounds',oitc:'Use rounds below',inf:'Survive or convert all players'})[mode]||'';
  minutes.min=(mode==='dem'||mode==='inf')?'1':'0';
  minutes.max=({dem:'15',kc:'60',ctf:'60',inf:'15'})[mode]||'1440';
  minutes.disabled=mode==='oitc';
  minutes.placeholder=mode==='oitc'?'Use round timer below':'';
  if(rule){score.value=rule.scoreLimit;minutes.value=rule.timeLimit}
}
async function refresh(){try{render(await api('/api/status'))}catch(error){$('health').textContent=error.message;$('health').className='error'}try{renderBots(await api('/api/bots'))}catch(error){$('bots-state').textContent=error.message}}
let leaderboardBusy=false;
function renderLeaderboard(data){
  const rows=data.players.slice(0,10).map(player=>{const row=document.createElement('tr');const kd=player.deaths===0?(player.kills>0?'∞':'—'):Number(player.kd).toFixed(2);for(const value of [player.rank,player.name,player.kills,player.deaths,kd,player.wins]){const cell=document.createElement('td');cell.textContent=String(value);row.appendChild(cell)}return row});
  $('leaderboard-rows').replaceChildren(...rows);
  const since=data.trackingSince?new Date(data.trackingSince).toLocaleDateString(undefined,{month:'short',day:'numeric',year:'numeric'}):null;
  $('leaderboard-since').textContent=(since?'Tracking since '+since+' · ':'')+'Top 10 by kills · every player, every match · full table on the leaderboard page';
  $('leaderboard-state').textContent=data.warning||(rows.length?(data.totalPlayers>rows.length?'Top '+rows.length+' of '+data.totalPlayers+' players · ':'')+'Updates every 10 seconds.': 'No stats yet. Join a match to start climbing the leaderboard.');
  $('leaderboard-state').className=data.warning?'warn':'muted';
}
async function refreshLeaderboard(){if(leaderboardBusy)return;leaderboardBusy=true;$('leaderboard-refresh').disabled=true;try{renderLeaderboard(await api('/api/leaderboard'))}catch(error){$('leaderboard-state').textContent='Leaderboard unavailable. '+error.message;$('leaderboard-state').className='error'}finally{leaderboardBusy=false;$('leaderboard-refresh').disabled=false}}
$('leaderboard-refresh').onclick=refreshLeaderboard;
refreshLeaderboard();setInterval(refreshLeaderboard,10000);
function renderBots(state){$('bots-state').textContent=(state.enabled?'ON':'OFF')+(state.lastResult?' · '+state.lastResult:'');const list=$('bots-list');if(!state.bots.length){list.textContent='No bots.';return}list.innerHTML='';for(const bot of state.bots){const row=document.createElement('div');row.className='console-row';const label=document.createElement('span');label.textContent=bot.name+' · '+bot.team+' · bot '+bot.id;const remove=document.createElement('button');remove.textContent='Remove';remove.onclick=()=>action('/api/bots',{action:'remove',name:bot.name}).then(refresh);row.append(label,remove);list.append(row)}}
$('bots-enable').onclick=()=>action('/api/bots',{action:'enable'}).then(refresh);$('bots-disable').onclick=()=>action('/api/bots',{action:'disable'}).then(refresh);$('bot-add').onclick=()=>action('/api/bots',{action:'add',team:$('bot-team').value,name:$('bot-name').value}).then(refresh);$('bots-remove-all').onclick=()=>action('/api/bots',{action:'remove',name:'all'}).then(refresh);
async function refreshSettings(){try{renderSettings(await api('/api/settings'))}catch(error){for(const id of ['settings-state','searchdestroy-state','hardpoint-state','gungame-state','demolition-state','killconfirmed-state','capturetheflag-state','oneinthechamber-state','infected-state']){$(id).textContent=error.message;$(id).className='error'}}}
async function action(path,body){try{$('output').textContent='Running…';const data=await api(path,body);$('output').textContent=data.output||'OK';setTimeout(refresh,900)}catch(error){$('output').textContent=`Error: ${error.message}`}}
function playerAction(operation){return action('/api/progression',{slot:$('player-slot').value,operation,level:$('level-target').value})}
$('unlock-attachments').onclick=()=>action('/api/progression',{slot:$('player-slot').value,operation:'attachments',includeLocked:$('attachments-include-locked').checked});
function powerAction(power,state){return action('/api/power',{slot:$('player-slot').value,power,state})}
function hardpointDefaults(){for(const [name,value] of Object.entries({'hp-score-limit':250,'hp-time-limit':10,'scr_hardpoint_hilltime':60,'scr_hardpoint_radius':192,'scr_hardpoint_starttime':5}))$(name).value=value;$('hardpoint-state').textContent='Defaults filled — press Apply to send';$('hardpoint-state').className='muted'}
$('hardpoint-defaults').onclick=hardpointDefaults;
const searchDestroyDefaults=__SD_DEFAULTS_JSON__;
$('searchdestroy-defaults').onclick=()=>{
  for(const [key,value] of Object.entries(searchDestroyDefaults)){const node=$(key);if(node.type==='checkbox')node.checked=value==='1';else node.value=value}
  $('searchdestroy-state').textContent='Defaults filled — press Apply to save';$('searchdestroy-state').className='muted';
};
$('searchdestroy-long-match').onclick=()=>{
  $('scr_sd_scorelimit').value=12;$('scr_sd_roundlimit').value=0;
  $('searchdestroy-state').textContent='First to 12 filled, with no total-round cap — press Apply to save';$('searchdestroy-state').className='muted';
};
$('apply-searchdestroy').onclick=async()=>{
  const nodes=[...document.querySelectorAll('[data-searchdestroy-setting]')];
  if(nodes.some(node=>!node.reportValidity()||(node.type!=='checkbox'&&node.value===''))){$('searchdestroy-state').textContent='Enter valid values for every Search and Destroy control';$('searchdestroy-state').className='error';return}
  const values={};nodes.forEach(node=>values[node.id]=node.type==='checkbox'?node.checked:node.value);
  $('apply-searchdestroy').disabled=true;$('searchdestroy-state').textContent='Applying…';$('searchdestroy-state').className='muted';
  try{
    const data=await api('/api/settings',{settings:values,mode:'sd'});
    $('output').textContent=data.output;await refreshSettings();
    $('searchdestroy-state').textContent='Saved. Round limits and length update during play; side switching and bomb rules start next round.';
  }catch(error){$('searchdestroy-state').textContent=error.message;$('searchdestroy-state').className='error'}
  finally{$('apply-searchdestroy').disabled=false}
};
for(const [name,mode,defaults] of [
  ['demolition','dem',{scr_dem_timelimit:2.5,scr_dem_bombtimer:45,scr_dem_planttime:5,scr_dem_defusetime:5,scr_dem_extratime:120,scr_dem_respawndelay:2}],
  ['killconfirmed','kc',{scr_kc_scorelimit:65,scr_kc_timelimit:10,scr_kc_taglife:30,scr_kc_respawndelay:0}],
  ['capturetheflag','ctf',{scr_ctf_scorelimit:3,scr_ctf_timelimit:10,scr_ctf_returntime:30,scr_ctf_respawndelay:5}],
  ['oneinthechamber','oitc',{scr_oitc_lives:3,scr_oitc_roundtime:180,scr_oitc_rounds:3,scr_oitc_respawndelay:2,scr_oitc_countdown:5,scr_oitc_intermission:5}],
  ['infected','inf',{scr_inf_timelimit:3,scr_inf_starttime:15,scr_inf_respawndelay:1}]
]){
  $(name+'-defaults').onclick=()=>{for(const [key,value] of Object.entries(defaults))$(key).value=value;$(name+'-state').textContent='Defaults filled — press Apply to send';$(name+'-state').className='muted'};
  $('apply-'+name).onclick=async()=>{const nodes=[...document.querySelectorAll('[data-'+name+'-setting]')];if(nodes.some(node=>!node.reportValidity()||node.value==='')){$(name+'-state').textContent='Enter valid values for every control';return}const values={};nodes.forEach(node=>values[node.id]=node.value);$('apply-'+name).disabled=true;try{const data=await api('/api/settings',{settings:values,mode});$('output').textContent=data.output;await refreshSettings();$(name+'-state').textContent='Applied for the next full map load.'}catch(error){$(name+'-state').textContent=error.message;$(name+'-state').className='error'}finally{$('apply-'+name).disabled=false}};
}
$('gungame-defaults').onclick=()=>{for(const [key,value] of Object.entries({scr_gungame_kills:1,scr_gungame_knifesetback:1,scr_gungame_suicidesetback:1,scr_gungame_timelimit:10})){if($(key).type==='checkbox')$(key).checked=!!value;else $(key).value=value}$('gungame-state').textContent='Defaults filled — press Apply to send';$('gungame-state').className='muted'};
$('apply-gungame').onclick=async()=>{const nodes=[...document.querySelectorAll('[data-gungame-setting]')];if(nodes.some(node=>!node.reportValidity()||(node.type!=='checkbox'&&node.value===''))){$('gungame-state').textContent='Enter valid values for all Gun Game controls';return}const values={};nodes.forEach(node=>values[node.id]=node.type==='checkbox'?node.checked:node.value);$('apply-gungame').disabled=true;try{const data=await api('/api/settings',{settings:values,mode:'gungame'});$('output').textContent=data.output;await refreshSettings();$('gungame-state').textContent='Applied for next map load. No restart performed.'}catch(error){$('gungame-state').textContent=error.message;$('gungame-state').className='error'}finally{$('apply-gungame').disabled=false}};
$('apply-hardpoint').onclick=async()=>{const nodes=[...document.querySelectorAll('[data-hardpoint-setting]'),$('hp-score-limit'),$('hp-time-limit')];if(nodes.some(node=>!node.reportValidity()||node.value==='')){$('hardpoint-state').textContent='Enter valid values for all Hardpoint controls';return}const values={};document.querySelectorAll('[data-hardpoint-setting]').forEach(node=>values[node.id]=node.value);$('apply-hardpoint').disabled=true;$('hardpoint-state').textContent='Applying…';try{const data=await api('/api/settings',{settings:values,mode:'hardpoint',scoreLimit:$('hp-score-limit').value,timeLimit:$('hp-time-limit').value});$('output').textContent=data.output||'Hardpoint settings applied.';await refreshSettings();$('hardpoint-state').textContent='Applied. Hill geometry/timing load on next full map load; no restart performed.'}catch(error){$('hardpoint-state').textContent=error.message;$('hardpoint-state').className='error'}finally{$('apply-hardpoint').disabled=false}};
$('apply').onclick=()=>action('/api/match',{map:$('map').value,mode:$('mode').value});$('restart').onclick=()=>action('/api/restart',{});$('rotate').onclick=()=>action('/api/rotate',{});$('mode').onchange=()=>{renderRules();renderMapChoices()};$('player-slot').onchange=syncPlayerControls;
$('apply-settings').onclick=async()=>{const values={};document.querySelectorAll('[data-setting]').forEach(node=>values[node.id]=node.type==='checkbox'?node.checked:node.value);$('settings-state').textContent='Applying…';try{const data=await api('/api/settings',{settings:values,mode:$('mode').value,scoreLimit:$('score-limit').value,timeLimit:$('time-limit').value});$('output').textContent=data.output||'Settings applied.';$('settings-state').textContent='Applied';await refreshSettings()}catch(error){$('settings-state').textContent=error.message;$('settings-state').className='error'}};
$('announce').onclick=()=>action('/api/say',{message:$('message').value});$('level-player').onclick=()=>playerAction('level');$('unlock-cac').onclick=()=>playerAction('cac');$('max-player').onclick=()=>playerAction('max');$('kick').onclick=()=>action('/api/kick',{slot:$('player-slot').value});['godmode','aimbot','wallhack'].forEach(power=>{ $(power+'-on').onclick=()=>powerAction(power,'on');$(power+'-off').onclick=()=>powerAction(power,'off')});$('send').onclick=()=>action('/api/command',{command:$('command').value});$('command').onkeydown=event=>{if(event.key==='Enter')$('send').click()};$('message').onkeydown=event=>{if(event.key==='Enter')$('announce').click()};refresh().then(refreshSettings);setInterval(refresh,5000);
</script></body></html>""".replace("__SD_DEFAULTS_JSON__", json.dumps(SD_DEFAULTS))


LEADERBOARD_PAGE = r"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="csrf-token" content="__CSRF__">
  <title>jgalbs CoD4 leaderboard</title>
  <style>
    :root{color-scheme:dark;--bg:#010403;--panel:#030806;--line:#174a2b;--line2:#0b2817;--ink:#b8f7cb;--green:#44ff88;--dim:#5d8c6b;--amber:#ffbd3e;--bad:#ff5364}
    *{box-sizing:border-box}html{background:var(--bg)}body{margin:0;color:var(--ink);font:13px/1.45 ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;background:repeating-linear-gradient(0deg,#0000 0,#0000 3px,#0b1b1022 4px),var(--bg)}
    main{width:min(1500px,100%);min-height:100vh;margin:0 auto;padding:18px;border-left:1px solid var(--line2);border-right:1px solid var(--line2)}
    .top{display:flex;gap:18px;align-items:center;justify-content:space-between;border:1px solid var(--line);padding:12px 14px;background:#020704;flex-wrap:wrap}.eyebrow{color:var(--dim);font-size:10px;text-transform:uppercase;letter-spacing:.12em}h1{margin:2px 0 0;font-size:20px;letter-spacing:.06em}h2{margin:0 0 8px;font-size:13px;text-transform:uppercase;letter-spacing:.1em;color:var(--green)}
    a{color:var(--green)}.muted{color:var(--dim)}.warn{color:var(--amber)}.error{color:var(--bad)}
    .panel{border:1px solid var(--line);background:#020704;padding:12px 14px;margin-top:10px}
    select,input,button{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;border-radius:0;border:1px solid var(--line);padding:8px 10px;background:#010403;color:var(--ink)}select:focus,input:focus{border-color:var(--green);outline:none;box-shadow:0 0 0 1px #44ff8833}button{cursor:pointer}button:hover{border-color:var(--green)}button.primary{background:var(--green);color:#01110a;font-weight:700}button:disabled{opacity:.5;cursor:default}
    .filters{display:grid;grid-template-columns:minmax(160px,1.4fr) repeat(3,minmax(120px,1fr)) 110px auto auto;gap:8px;align-items:end}.filters label{display:block;color:var(--dim);font-size:10px;text-transform:uppercase;letter-spacing:.1em;margin-bottom:4px}.filters input,.filters select{width:100%}.toggle{display:flex;gap:6px;align-items:center;padding:8px 0;white-space:nowrap}.toggle input{width:auto}
    .summary{display:flex;gap:18px;flex-wrap:wrap;margin-top:8px;color:var(--dim);font-size:11px}.summary b{color:var(--ink);font-weight:600}
    .scroll{overflow-x:auto}table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums;white-space:nowrap}th,td{padding:7px 9px;border-bottom:1px solid var(--line2);text-align:right}th:nth-child(2),td:nth-child(2){text-align:left}th{color:var(--dim);font-size:10px;text-transform:uppercase;letter-spacing:.08em;cursor:pointer;user-select:none;position:sticky;top:0;background:#020704}th:hover{color:var(--ink)}th.active{color:var(--green)}
    tbody tr{cursor:pointer}tbody tr:hover{background:#0b2817}tbody tr.selected{background:#0f3a22}tbody tr.hidden-player{opacity:.55}td.name{font-weight:600;color:#e5ffee}.rank{color:var(--dim)}
    .detail-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:14px}.detail-grid table{font-size:12px}.detail-grid th{cursor:default}.detail-head{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap}
    .win{color:var(--green)}.loss{color:var(--bad)}.tie{color:var(--dim)}button.danger{border-color:var(--bad);color:var(--bad)}
    @media(max-width:900px){.filters{grid-template-columns:1fr 1fr}}
  </style>
</head>
<body><main>
  <div class="top"><div><div class="eyebrow">Galbreath Bros // every player, every match</div><h1>COD4 / LEADERBOARD</h1></div><div><a href="/">← control panel</a></div></div>
  <section class="panel">
    <div class="filters">
      <div><label for="q">Search player</label><input id="q" autocomplete="off" placeholder="name…"></div>
      <div><label for="window">Time</label><select id="window"><option value="all">All time</option><option value="24h">Last 24 hours</option><option value="7d">Last 7 days</option><option value="30d">Last 30 days</option><option value="90d">Last 90 days</option></select></div>
      <div><label for="gametype">Mode</label><select id="gametype"><option value="">All modes</option></select></div>
      <div><label for="map">Map</label><select id="map"><option value="">All maps</option></select></div>
      <div><label for="min_matches">Min matches</label><input id="min_matches" type="number" min="0" max="9999" value="1"></div>
      <label class="toggle"><input id="hidden" type="checkbox"> Show bots &amp; test clients</label>
      <div><button id="refresh" type="button">Refresh</button> <button id="wipe" type="button" class="danger" title="Forget all stats and start counting with the next map">Wipe</button></div>
    </div>
    <div class="summary" id="summary">Loading…</div>
  </section>
  <section class="panel">
    <div class="scroll"><table id="board"><thead><tr id="head"></tr></thead><tbody id="rows"></tbody></table></div>
    <p id="state" class="muted" role="status">Loading leaderboard…</p>
  </section>
  <section class="panel" id="detail" hidden>
    <div class="detail-head"><div><h2 id="detail-name">Player</h2><div class="muted" id="detail-meta"></div></div><div><button id="detail-hide" type="button">Hide from leaderboard</button> <button id="detail-close" type="button">Close</button></div></div>
    <div class="detail-grid" id="detail-grid"></div>
  </section>
</main>
<script>
const csrf=document.querySelector('meta[name="csrf-token"]').content;
const $=id=>document.getElementById(id);
const COLUMNS=[
  {key:'rank',label:'#',sort:null,fmt:r=>r.rank,cls:'rank'},
  {key:'name',label:'Player',sort:'name',fmt:r=>r.name,cls:'name'},
  {key:'kills',label:'Kills',sort:'kills',fmt:r=>r.kills},
  {key:'deaths',label:'Deaths',sort:'deaths',fmt:r=>r.deaths},
  {key:'kd',label:'K/D',sort:'kd',fmt:r=>ratio(r.kd,r.kills,r.deaths)},
  {key:'headshots',label:'HS',sort:'headshots',fmt:r=>r.headshots},
  {key:'hs_pct',label:'HS %',sort:'hs_pct',fmt:r=>pct(r.hs_pct)},
  {key:'best_streak',label:'Streak',sort:'best_streak',fmt:r=>r.best_streak},
  {key:'wins',label:'Wins',sort:'wins',fmt:r=>r.wins},
  {key:'losses',label:'Losses',sort:'losses',fmt:r=>r.losses},
  {key:'win_pct',label:'Win %',sort:'win_pct',fmt:r=>pct(r.win_pct)},
  {key:'matches',label:'Matches',sort:'matches',fmt:r=>r.matches},
  {key:'playtime_s',label:'Time',sort:'playtime_s',fmt:r=>duration(r.playtime_s)},
  {key:'kpm',label:'K/min',sort:'kpm',fmt:r=>r.kpm===null?'—':r.kpm.toFixed(2)},
  {key:'knife',label:'Knife',sort:'knife',fmt:r=>r.knife},
  {key:'explosive',label:'Nades',sort:'explosive',fmt:r=>r.explosive},
  {key:'damage',label:'Damage',sort:'damage',fmt:r=>r.damage},
  {key:'sniper_kills',label:'Sniper K',sort:'sniper_kills',fmt:r=>r.sniper_kills},
  {key:'scope_avg_s',label:'Scope avg',sort:'scope_avg_s',fmt:r=>r.scope_avg_s===null?'—':r.scope_avg_s.toFixed(2)+'s',title:()=>'Average time the scope stays up per scope-in'},
  {key:'scope_per_kill_s',label:'Scope/kill',sort:'scope_per_kill_s',fmt:r=>r.scope_per_kill_s===null?'—':r.scope_per_kill_s.toFixed(1)+'s',title:()=>'Total scoped seconds per sniper kill; lower means quicker scopes'},
  {key:'hardscope_pct',label:'Hardscope',sort:'hardscope_pct',fmt:r=>pct(r.hardscope_pct),title:()=>'Sniper kills taken after holding the scope fully in for 2 s or longer'},
  {key:'fav_weapon',label:'Fav weapon',sort:null,fmt:r=>r.fav_weapon},
  {key:'last_seen',label:'Last seen',sort:'last_seen',fmt:r=>ago(r.last_seen),title:r=>r.last_seen?new Date(r.last_seen).toLocaleString():''}
];
const state={sort:'kills',order:'desc',selected:null};
function ratio(value,kills,deaths){if(value===null)return kills>0&&deaths===0?'∞':'—';return Number(value).toFixed(2)}
function pct(value){return value===null?'—':Math.round(value)+'%'}
function duration(seconds){if(!seconds)return '0m';const h=Math.floor(seconds/3600),m=Math.round((seconds%3600)/60);return h?`${h}h ${m}m`:`${m}m`}
function ago(iso){if(!iso)return '—';const s=(Date.now()-new Date(iso).getTime())/1000;if(s<90)return 'just now';if(s<5400)return Math.round(s/60)+' min ago';if(s<172800)return Math.round(s/3600)+' h ago';return Math.round(s/86400)+' d ago'}
async function api(path,body){const options=body?{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf},body:JSON.stringify(body)}:{};const response=await fetch(path,options);const data=await response.json();if(!response.ok)throw new Error(data.error||response.statusText);return data}
function params(){const p=new URLSearchParams();p.set('window',$('window').value);if($('gametype').value)p.set('gametype',$('gametype').value);if($('map').value)p.set('map',$('map').value);if($('q').value.trim())p.set('q',$('q').value.trim());p.set('min_matches',$('min_matches').value||'0');if($('hidden').checked)p.set('hidden','1');p.set('sort',state.sort);p.set('order',state.order);return p}
function restore(){const p=new URLSearchParams(location.search);for(const id of ['window','gametype','map','q','min_matches']){if(p.has(id))$(id).value=p.get(id)}if(p.get('hidden')==='1')$('hidden').checked=true;if(p.has('sort'))state.sort=p.get('sort');if(p.has('order'))state.order=p.get('order');if(p.has('player'))state.selected=p.get('player')}
function renderHead(){const head=$('head');head.replaceChildren();for(const col of COLUMNS){const th=document.createElement('th');th.textContent=col.label+(col.sort===state.sort?(state.order==='desc'?' ↓':' ↑'):'');if(col.sort===state.sort)th.className='active';if(col.sort)th.onclick=()=>{if(state.sort===col.sort)state.order=state.order==='desc'?'asc':'desc';else{state.sort=col.sort;state.order=col.sort==='name'?'asc':'desc'}load()};else th.style.cursor='default';head.append(th)}}
function renderRows(data){const body=$('rows');body.replaceChildren();for(const row of data.players){const tr=document.createElement('tr');if(row.hidden)tr.className='hidden-player';if(row.key===state.selected)tr.classList.add('selected');for(const col of COLUMNS){const td=document.createElement('td');td.textContent=String(col.fmt(row));if(col.cls)td.className=col.cls;if(col.title)td.title=col.title(row);tr.append(td)}tr.onclick=()=>select(row.key);body.append(tr)}}
async function load(){const p=params();history.replaceState(null,'','/leaderboard?'+p.toString()+(state.selected?'&player='+encodeURIComponent(state.selected):''));renderHead();try{const data=await api('/api/leaderboard?'+p.toString());renderRows(data);const since=data.trackingSince?new Date(data.trackingSince).toLocaleDateString(undefined,{month:'short',day:'numeric',year:'numeric'}):'—';$('summary').innerHTML=`<span><b>${data.totalPlayers}</b> players</span><span><b>${data.totalMatches}</b> matches in view</span><span>tracking since <b>${since}</b></span><span>wins and losses count completed matches with a recorded winner</span>`;$('state').textContent=data.warning||(data.players.length?'Click a player for details. Click a column to sort. Refreshes every 15 s.':'No players match these filters.');$('state').className=data.warning?'warn':'muted'}catch(error){$('state').textContent='Leaderboard unavailable. '+error.message;$('state').className='error'}}
async function loadFilters(){try{const f=await api('/api/leaderboard/filters');const keep={gametype:$('gametype').value,map:$('map').value};for(const g of f.gametypes){const o=document.createElement('option');o.value=g.id;o.textContent=`${g.id} (${g.matches})`;$('gametype').append(o)}for(const m of f.maps){const o=document.createElement('option');o.value=m.id;o.textContent=`${m.id.replace(/^mp_/,'')} (${m.matches})`;$('map').append(o)}$('gametype').value=keep.gametype;$('map').value=keep.map}catch(error){$('state').textContent=error.message}}
function table(title,columns,rows,fmt){const wrap=document.createElement('div');const h=document.createElement('h2');h.textContent=title;wrap.append(h);if(!rows.length){const p=document.createElement('div');p.className='muted';p.textContent='Nothing yet.';wrap.append(p);return wrap}const t=document.createElement('table');const tr=document.createElement('tr');for(const c of columns){const th=document.createElement('th');th.textContent=c;tr.append(th)}const thead=document.createElement('thead');thead.append(tr);t.append(thead);const tb=document.createElement('tbody');for(const row of rows){const r=document.createElement('tr');r.style.cursor='default';for(const cell of fmt(row)){const td=document.createElement('td');if(typeof cell==='object'){td.textContent=cell.text;td.className=cell.cls}else td.textContent=String(cell);r.append(td)}tb.append(r)}t.append(tb);wrap.append(t);return wrap}
function result(value){if(value==='win')return{text:'W',cls:'win'};if(value==='loss')return{text:'L',cls:'loss'};return{text:'—',cls:'tie'}}
async function select(key){state.selected=key;document.querySelectorAll('#rows tr').forEach(tr=>tr.classList.remove('selected'));try{const p=params();p.set('key',key);const d=await api('/api/leaderboard/player?'+p.toString());$('detail').hidden=false;$('detail-name').textContent=d.name+(d.hidden?' (hidden: '+(d.note||'bot')+')':'');$('detail-meta').textContent=`first seen ${d.firstSeen?new Date(d.firstSeen).toLocaleDateString():'—'} · last seen ${d.lastSeen?new Date(d.lastSeen).toLocaleString():'—'} · filters above apply to the breakdowns`;$('detail-hide').textContent=d.hidden?'Show on leaderboard':'Hide from leaderboard';$('detail-hide').onclick=async()=>{try{await api('/api/leaderboard/hide',{key:d.key,hidden:!d.hidden});await load();await select(d.key)}catch(error){$('state').textContent=error.message;$('state').className='error'}};const grid=$('detail-grid');grid.replaceChildren(
  table('By mode',['Mode','Matches','K','D','K/D','W','L'],d.byGametype,r=>[r.id,r.matches,r.kills,r.deaths,ratio(r.kd,r.kills,r.deaths),r.wins,r.losses]),
  table('By map',['Map','Matches','K','D','K/D','W','L'],d.byMap,r=>[r.id.replace(/^mp_/,''),r.matches,r.kills,r.deaths,ratio(r.kd,r.kills,r.deaths),r.wins,r.losses]),
  table('Weapons',['Weapon','Kills'],d.weapons,r=>[r.weapon,r.kills]),
  table('Sniping',['Stat','Value'],d.sniping?[['Sniper kills',d.sniping.sniper_kills],['Scope-ins',d.sniping.scope_sessions],['Total scoped',duration(Math.round(d.sniping.scope_total_s))],['Avg scope hold',d.sniping.scope_avg_s===null?'—':d.sniping.scope_avg_s.toFixed(2)+' s'],['Scope time per sniper kill',d.sniping.scope_per_kill_s===null?'—':d.sniping.scope_per_kill_s.toFixed(1)+' s'],['Kills while scoped',d.sniping.scope_kills],['Hardscope kills (≥2 s fully scoped)',d.sniping.hardscope_kills+' ('+pct(d.sniping.hardscope_pct)+')']]:[],r=>[r[0],r[1]]),
  table('Nemesis (killed you most, all time)',['Player','Kills'],d.nemeses,r=>[r.name,r.kills]),
  table('Favourite victim (all time)',['Player','Kills'],d.victims,r=>[r.name,r.kills]),
  table('Recent matches',['When','Map','Mode','K','D','HS','Streak','Time','Result'],d.recent,r=>[new Date(r.startedAt).toLocaleString(undefined,{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'}),r.map.replace(/^mp_/,''),r.gametype+(r.rounds>1?' ×'+r.rounds:''),r.kills,r.deaths,r.headshots,r.bestStreak,duration(r.seconds),result(r.result)]));
  $('detail').scrollIntoView({behavior:'smooth',block:'nearest'});history.replaceState(null,'','/leaderboard?'+params().toString()+'&player='+encodeURIComponent(key))}catch(error){$('state').textContent=error.message;$('state').className='error'}}
$('detail-close').onclick=()=>{$('detail').hidden=true;state.selected=null;history.replaceState(null,'','/leaderboard?'+params().toString())};
for(const id of ['window','gametype','map','hidden'])$(id).onchange=load;
$('min_matches').onchange=load;let typing=null;$('q').oninput=()=>{clearTimeout(typing);typing=setTimeout(load,250)};$('refresh').onclick=load;
$('wipe').onclick=async()=>{if(!confirm('Wipe every stat and start the leaderboard from the next map? This cannot be undone.'))return;try{const r=await api('/api/leaderboard/reset',{confirm:'wipe'});$('state').textContent=r.output;$('state').className='warn';$('detail').hidden=true;state.selected=null;await load()}catch(error){$('state').textContent=error.message;$('state').className='error'}};
restore();loadFilters().then(load).then(()=>{if(state.selected)select(state.selected)});setInterval(load,15000);
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

        def _page(self, template: str) -> None:
            payload = template.replace("__CSRF__", csrf_token).encode()
            self.send_response(HTTPStatus.OK)
            self._headers("text/html; charset=utf-8", len(payload))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self) -> None:
            try:
                url = urlsplit(self.path)
                params = parse_qs(url.query, keep_blank_values=False, max_num_fields=20)
                if url.path == "/":
                    self._page(WEB_PAGE)
                elif url.path == "/leaderboard":
                    self._page(LEADERBOARD_PAGE)
                elif url.path == "/api/status":
                    self._json(controller.dashboard())
                elif url.path == "/api/settings":
                    self._json(controller.settings())
                elif url.path == "/api/leaderboard":
                    self._json(controller.leaderboard(params))
                elif url.path == "/api/leaderboard/filters":
                    self._json(controller.leaderboard_filters())
                elif url.path == "/api/leaderboard/player":
                    self._json(controller.leaderboard_player(params))
                elif url.path == "/api/bots":
                    self._json(controller.bots())
                elif url.path == "/api/health":
                    self._json({"ok": True})
                else:
                    self._json({"error": "not found"}, HTTPStatus.NOT_FOUND)
            except (ControlError, OSError, LeaderboardError, ValueError) as exc:
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
                        body.get("includeLocked", True),
                    )
                elif self.path == "/api/power":
                    output = controller.player_power(
                        body.get("slot"),
                        body.get("power"),
                        body.get("state"),
                    )
                elif self.path == "/api/command":
                    output = controller.connection.rcon(validate_web_command(str(body.get("command", ""))))
                elif self.path == "/api/bots":
                    action = str(body.get("action", ""))
                    if action in ("enable", "disable"):
                        output = controller.set_bots_enabled(action == "enable")
                    else:
                        output = controller.bot_request(action, body.get("team"), body.get("name"))
                elif self.path == "/api/leaderboard/hide":
                    output = controller.leaderboard_hide(body.get("key"), body.get("hidden"))
                elif self.path == "/api/leaderboard/reset":
                    if body.get("confirm") != "wipe":
                        raise ControlError("send confirm: wipe to reset the leaderboard")
                    output = controller.leaderboard_reset()
                else:
                    self._json({"error": "not found"}, HTTPStatus.NOT_FOUND)
                    return
                self._json({"ok": True, "output": output or "Command accepted."})
            except (ControlError, OSError, LeaderboardError) as exc:
                self._json({"error": str(exc)}, HTTPStatus.BAD_REQUEST)

    return Handler


def maps_from_environment() -> tuple[str, ...]:
    configured = os.environ.get("COD4_MAPS", "")
    if not configured:
        return tuple(load_map_catalog())
    maps = tuple(dict.fromkeys(validate_map(value.strip()) for value in configured.split(",") if value.strip()))
    return maps or tuple(load_map_catalog())


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
    hp = sub.add_parser("hardpoint", help="show or configure Hardpoint without changing the map")
    hp.add_argument("--score-limit")
    hp.add_argument("--time-limit", help="match minutes; 0 disables the limit")
    hp.add_argument("--hill-seconds", help="10–300 seconds; next full map load")
    hp.add_argument("--start-seconds", help="0–10 second opening countdown; next full map load")
    hp.add_argument("--radius", help="128–384 game units; outdoor maximum half-width, next full map load; indoor rooms unchanged")
    gg = sub.add_parser("gungame", help="show or configure Gun Game for the next map load")
    gg.add_argument("--kills-per-gun")
    gg.add_argument("--knife-setback")
    gg.add_argument("--suicide-setback", choices=("0", "1"))
    gg.add_argument("--time-limit")
    dem = sub.add_parser("demolition", help="show or configure Demolition for the next map load")
    dem.add_argument("--round-minutes")
    dem.add_argument("--bomb-seconds")
    dem.add_argument("--plant-seconds")
    dem.add_argument("--defuse-seconds")
    dem.add_argument("--extra-seconds")
    dem.add_argument("--respawn-seconds")
    kc = sub.add_parser("killconfirmed", help="show or configure Kill Confirmed for the next map load")
    kc.add_argument("--score-limit")
    kc.add_argument("--time-limit")
    kc.add_argument("--tag-seconds")
    kc.add_argument("--respawn-seconds")
    ctf = sub.add_parser("capturetheflag", help="show or configure Capture the Flag for the next map load")
    ctf.add_argument("--score-limit")
    ctf.add_argument("--time-limit")
    ctf.add_argument("--return-seconds")
    ctf.add_argument("--respawn-seconds")
    oitc = sub.add_parser("oneinthechamber", help="show or configure One in the Chamber for the next map load")
    oitc.add_argument("--lives")
    oitc.add_argument("--round-seconds")
    oitc.add_argument("--rounds")
    oitc.add_argument("--respawn-seconds")
    oitc.add_argument("--countdown-seconds")
    oitc.add_argument("--intermission-seconds")
    inf = sub.add_parser("infected", help="show or configure Infected for the next map load")
    inf.add_argument("--time-limit")
    inf.add_argument("--countdown-seconds")
    inf.add_argument("--respawn-seconds")
    sub.add_parser("players", help="show the server's detailed status output")
    map_cmd = sub.add_parser("map", help="change map immediately")
    map_cmd.add_argument("name")
    map_cmd.add_argument("--mode")
    mode = sub.add_parser("mode", help="change mode and load the full map")
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
    sub.add_parser("leaderboard-reset", help="wipe the leaderboard and start counting with the next map (run as the service user)")
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
        if args.action == "web":
            controller.leaderboard_store.start()
        if args.action == "status":
            print_dashboard(controller.dashboard(), args.json)
        elif args.action == "settings":
            print(json.dumps(controller.settings(), indent=2))
        elif args.action == "leaderboard-reset":
            print(controller.leaderboard_reset())
        elif args.action == "hardpoint":
            requested = {}
            if args.start_seconds is not None:
                requested["scr_hardpoint_starttime"] = args.start_seconds
            if args.hill_seconds is not None:
                requested["scr_hardpoint_hilltime"] = args.hill_seconds
            if args.radius is not None:
                requested["scr_hardpoint_radius"] = args.radius
            if requested or args.score_limit is not None or args.time_limit is not None:
                print(controller.apply_settings(requested, "hardpoint", args.score_limit, args.time_limit))
            else:
                settings = controller.settings()
                print(json.dumps({"rules": settings["rules"]["koth"], "hillSettings": {
                    key: settings["values"][key] for key in HARDPOINT_DEFAULTS}}, indent=2))
        elif args.action == "gungame":
            requested = {key: value for key, value in {
                "scr_gungame_kills": args.kills_per_gun,
                "scr_gungame_knifesetback": args.knife_setback,
                "scr_gungame_suicidesetback": args.suicide_setback,
                "scr_gungame_timelimit": args.time_limit,
            }.items() if value is not None}
            if requested:
                print(controller.apply_settings(requested, "gungame", None, None))
            else:
                settings = controller.settings()
                print(json.dumps({key: settings["values"][key] for key in GUNGAME_DEFAULTS}, indent=2))
        elif args.action in ("demolition", "killconfirmed", "capturetheflag", "oneinthechamber", "infected"):
            if args.action == "demolition":
                mode_name, defaults = "dem", DEMOLITION_DEFAULTS
                candidates = {"scr_dem_timelimit": args.round_minutes,
                              "scr_dem_bombtimer": args.bomb_seconds,
                              "scr_dem_planttime": args.plant_seconds,
                              "scr_dem_defusetime": args.defuse_seconds,
                              "scr_dem_extratime": args.extra_seconds,
                              "scr_dem_respawndelay": args.respawn_seconds}
            elif args.action == "killconfirmed":
                mode_name, defaults = "kc", KILL_CONFIRMED_DEFAULTS
                candidates = {"scr_kc_scorelimit": args.score_limit,
                              "scr_kc_timelimit": args.time_limit,
                              "scr_kc_taglife": args.tag_seconds,
                              "scr_kc_respawndelay": args.respawn_seconds}
            elif args.action == "capturetheflag":
                mode_name, defaults = "ctf", CAPTURE_THE_FLAG_DEFAULTS
                candidates = {"scr_ctf_scorelimit": args.score_limit,
                              "scr_ctf_timelimit": args.time_limit,
                              "scr_ctf_returntime": args.return_seconds,
                              "scr_ctf_respawndelay": args.respawn_seconds}
            elif args.action == "oneinthechamber":
                mode_name, defaults = "oitc", ONE_IN_THE_CHAMBER_DEFAULTS
                candidates = {"scr_oitc_lives": args.lives,
                              "scr_oitc_roundtime": args.round_seconds,
                              "scr_oitc_rounds": args.rounds,
                              "scr_oitc_respawndelay": args.respawn_seconds,
                              "scr_oitc_countdown": args.countdown_seconds,
                              "scr_oitc_intermission": args.intermission_seconds}
            else:
                mode_name, defaults = "inf", INFECTED_DEFAULTS
                candidates = {"scr_inf_timelimit": args.time_limit,
                              "scr_inf_starttime": args.countdown_seconds,
                              "scr_inf_respawndelay": args.respawn_seconds}
            requested = {key: value for key, value in candidates.items() if value is not None}
            if requested:
                print(controller.apply_settings(requested, mode_name, None, None))
            else:
                settings = controller.settings()
                print(json.dumps({key: settings["values"][key] for key in defaults}, indent=2))
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
