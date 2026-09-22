#!/usr/bin/env python3
"""Private Linux Jev bot lab worker. Its stdin accepts only bootstrap/command/stop."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import selectors
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

SOURCE = Path('/opt/cod4/mods/new_experience')
EXECUTABLE = Path('/opt/cod4/cod4x18_dedrun')
BOT_COUNT = 4
MIN_BOT_COUNT = 1
MAX_BOT_COUNT = 8  # the live fixture caps Josh bots at 8; the lab stays bounded by MAX_CLIENTS below
MAX_BW_COUNT = 4
MAX_CLIENTS = 8
SEQUENCE_RESET_GAP = 100  # observation sequences run about five per second; a drop this large is a new client
MAX_LINE = 524288
MAX_WIRE = 200
MAX_SCRIPT = 262144
MAX_PENDING = 64
NATIVE_SERVER_SHA256 = 'cd3c4ce58f25d0611ef6a404dd307adbf99a1d37a60ced6b91bae09aa68e0cd0'
WAR_SOURCE_SHA256 = '88523355213bb0808b6d506e3534a0d7a279af8bd7247f60d20759d37427fe59'
PARTS = ('enemies', 'nav', 'events', 'objective', 'self')
VALUE = re.compile(r'[A-Za-z0-9_.:-]{1,24}')
# PROTOCOL.md command table. Integers carry no leading zeros; l is -360..360.
FIELD_FORMS = {
    't': re.compile(r'-|auto|[0-9]{1,2}'),
    'e': re.compile(r'[fhk]'),
    'g': re.compile(r'n(?:0|[1-9][0-9]{0,2})|hold|cover|glitch|chase[0-9]{1,2}|site[A-Z]'),
    'l': re.compile(r'auto|-?(?:[0-9]|[1-9][0-9]|[12][0-9]{2}|3[0-5][0-9]|360)|e[0-9]{1,2}'),
    's': re.compile(r'stand|crouch|prone|jump'),
    'r': re.compile(r'auto|on|off'),
    'a': re.compile(r'auto|on|off'),
    'w': re.compile(r'keep|reload|plant|defuse|streak|(?:nade|tact)-?[0-9]{1,6}:-?[0-9]{1,6}:-?[0-9]{1,6}'),
}
# Bot Warfare (ineedbots/iw3_bot_warfare, commit 901895a1); byte-identical to
# cod4_ai.bot_warfare_opponent.VENDOR_SHA256. The test suite checks the two tables agree.
BOT_WARFARE_SHA256 = {
    'maps/mp/bots/_bot.gsc': '2b81b898cfc808bb1c03b2ba2bd97e342d399bdfd7377a210ad3770766f8e971',
    'maps/mp/bots/_bot_chat.gsc': '385efafae27d31c3765030292c684bed10d72d2d6ffe6e4e828dbc0d8c134013',
    'maps/mp/bots/_bot_internal.gsc': '7878c8d0b65dfe30423e51430d84c4cde26116fe48edc39c000b670eb0ef74ba',
    'maps/mp/bots/_bot_script.gsc': '218abadebaea828411047f39eb4fab4263a15acbd631854f097c359467e25af0',
    'maps/mp/bots/_bot_utility.gsc': 'c5ce15c6c8c64e4a0df233a7333579bed9248499758381c9cc85a197ea791653',
    'maps/mp/bots/_menu.gsc': 'f2c0b4f5683478016c110a48050428858945b5725f4acf3a9a56e41581dc150c',
    'maps/mp/bots/_wp_editor.gsc': '84cba1597d5080934c873831137f03b1bc48537e9863a641a4c876ac6c0ee823',
    'maps/mp/bots/waypoints/_custom_map.gsc': 'b8bdabd8b749ff72b2ecb9b441116df99a6d9e79288e6e1456510c5a162d6c93',
    'scriptdata/waypoints/mp_shipment_wp.csv': '97e2ae04ab405e6efe5d1f692b11d703fc47e5224e0d576aa3d26dbdf56d3cc6',
    'scripts/mp/bots_adapter_cod4x.gsc': 'd8c0ad872110568e22098c867d688cba2546bff8796f50ddab106d73194790a2',
}
# Waypoint tables for further maps, from the same repository (scriptdata/waypoints at HEAD 2026-09-21).
EXTRA_WAYPOINT_SHA256 = {
    'scriptdata/waypoints/mp_nuketown_wp.csv': '346a8ddde6d15f6c4b5e8c422b560769d18a280e1eb6f2fee3e4ef207605e3f9',
    'scriptdata/waypoints/mp_highrise_wp.csv': 'd1343f6a000d0b3faeee6efb2892e5da43efd5b1e534ea4930646e65f7f1444b',
}
VENDORED_SHA256 = {**BOT_WARFARE_SHA256, **EXTRA_WAYPOINT_SHA256}
BOT_WARFARE_NOTICES = ('LICENSE-NOTICE.md', 'UPSTREAM-RELEASE-README.txt')
BOT_WARFARE_MAIN = 'maps/mp/bots/_bot.gsc'
# Same as cod4_ai.bot_warfare_opponent._PINNED: Bot Warfare only fills dvars that are still
# empty, so jev.cfg sets these before the map loads and its management adds, kicks and
# rebalances nothing.
BOT_WARFARE_PINS = {
    'bots_main': '1', 'bots_main_firstIsHost': '0', 'bots_main_waitForHostTime': '0', 'bots_main_menu': '0',
    'bots_main_debug': '0', 'bots_main_kickBotsAtEnd': '0', 'bots_main_chat': '0',
    'bots_manage_add': '0', 'bots_manage_fill': '0', 'bots_manage_fill_mode': '0', 'bots_manage_fill_watchplayers': '0',
    'bots_manage_fill_kick': '0', 'bots_manage_fill_spec': '0',
    'bots_team': 'autoassign', 'bots_team_amount': '0', 'bots_team_force': '0', 'bots_team_mode': '0',
    'bots_loadout_reasonable': '0', 'bots_loadout_allow_op': '0', 'bots_loadout_rank': '1', 'bots_loadout_prestige': '0',
    'bots_play_move': '1', 'bots_play_knife': '1', 'bots_play_fire': '1', 'bots_play_nade': '1', 'bots_play_obj': '0',
    'bots_play_camp': '1', 'bots_play_jumpdrop': '1', 'bots_play_target_other': '0', 'bots_play_killstreak': '0',
    'bots_play_ads': '1', 'bots_play_aim': '1',
}
# Bot Warfare's bots_skill levels as its menu names them (cod4_ai.bot_warfare_opponent).
DIFFICULTIES = {'too_easy': 1, 'easy': 2, 'easy_medium': 3, 'medium': 4, 'hard': 5, 'very_hard': 6, 'hardest': 7}
ALIASES = {'normal': 'medium', 'veteran': 'hardest'}
WATCHDOG = r'''
import os,signal,sys,time
from pathlib import Path
pid=int(sys.argv[1]);expected=Path(sys.argv[2]);deadline=time.monotonic()+int(sys.argv[3])
def owned():
    try:return (Path('/proc')/str(pid)/'exe').resolve(strict=True)==expected
    except OSError:return False
while owned() and time.monotonic()<deadline:time.sleep(.5)
if owned():
    os.kill(pid,signal.SIGTERM);time.sleep(3)
    if owned():os.kill(pid,signal.SIGKILL)
'''


def emit(value):
    try:
        print(json.dumps(value, separators=(',', ':'), allow_nan=False), flush=True)
    except (BrokenPipeError, OSError):
        pass


def integer(value, minimum, maximum, name):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError('Invalid ' + name)
    return value


def field_value(key, value):
    """One command field against the PROTOCOL.md table; strings only."""
    if type(value) is not str or not VALUE.fullmatch(value) or not FIELD_FORMS[key].fullmatch(value):
        raise ValueError('Invalid command field ' + key)
    return value


def command_wire(message, bot_count=BOT_COUNT):
    """Translate a validated command into one fixed-name dvar assignment."""
    if not isinstance(message, dict) or message.get('type') != 'command':
        raise ValueError('Expected command')
    integer(bot_count, MIN_BOT_COUNT, MAX_BOT_COUNT, 'botCount')
    bot = integer(message.get('botId'), 0, bot_count - 1, 'botId')
    sequence = integer(message.get('sequence'), 0, 2147483647, 'sequence')
    life = integer(message.get('lifeId'), 0, 2147483647, 'lifeId')
    observed = integer(message.get('gameTimeMs'), 0, 2147483647, 'gameTimeMs')
    fields = message.get('fields')
    if not isinstance(fields, dict):
        raise ValueError('Invalid command fields')
    if not set(fields) <= set(FIELD_FORMS):
        raise ValueError('Unknown command key')
    tokens = [str(sequence), str(life), str(observed)]
    tokens += [key + '=' + field_value(key, fields[key]) for key in FIELD_FORMS if key in fields]
    wire = ' '.join(tokens)
    if len(wire.encode()) > MAX_WIRE:
        raise ValueError('Oversize command wire')
    return bot, sequence, 'set jev_cmd_' + str(bot) + ' "' + wire + '"'


def merge_parts(parts):
    """One observation object from its self record plus the enemies, nav, events and objective records."""
    observation = {name: value for name, value in parts['self'].items() if name not in ('part', 'parts')}
    for name in ('enemies', 'nav', 'events', 'objective'):
        if name in parts:
            observation[name] = {key: value for key, value in parts[name].items()
                                 if key not in ('botId', 'sequence', 'part')}
    return observation


class ObservationJoiner:
    """Buffer [jev-observation] parts per (botId, sequence); forward the newest complete one per bot."""

    def __init__(self, bot_count):
        self.bot_count = integer(bot_count, MIN_BOT_COUNT, MAX_BOT_COUNT, 'botCount')
        self.last_forwarded = [0] * self.bot_count
        self.pending = {}

    def add(self, record):
        """Buffer one part. False when it belongs to an observation already superseded."""
        bot = integer(record.get('botId'), 0, self.bot_count - 1, 'observation botId')
        sequence = integer(record.get('sequence'), 1, 2147483647, 'observation sequence')
        part = record.get('part')
        if part not in PARTS:
            raise ValueError('Invalid observation part')
        if part == 'self':
            integer(record.get('parts'), 1, len(PARTS), 'observation parts')
        if sequence <= self.last_forwarded[bot]:
            # A bot re-added after a map change or a restart is a fresh client whose sequence
            # starts over. Late parts of an older observation trail by a few numbers at most.
            if self.last_forwarded[bot] - sequence < SEQUENCE_RESET_GAP:
                return False
            self.last_forwarded[bot] = 0
            self.pending = {key: value for key, value in self.pending.items() if key[0] != bot}
        parts = self.pending.setdefault((bot, sequence), {})
        if part in parts:
            raise ValueError('Duplicate observation part')
        parts[part] = record
        return True

    def complete(self):
        """Merge the newest complete observation per bot; drop older pending ones and count them."""
        newest = {}
        for (bot, sequence), parts in self.pending.items():
            own = parts.get('self')
            if own is None or len(parts) != own['parts']:
                continue
            if sequence > newest.get(bot, (0, None))[0]:
                newest[bot] = (sequence, parts)
        result = []
        forwarded = set()
        for bot in sorted(newest):
            sequence, parts = newest[bot]
            result.append(merge_parts(parts))
            self.last_forwarded[bot] = sequence
            forwarded.add((bot, sequence))
        discarded = 0
        for bot, sequence in list(self.pending):
            if sequence <= self.last_forwarded[bot]:
                del self.pending[bot, sequence]
                if (bot, sequence) not in forwarded:
                    discarded += 1
        while len(self.pending) > MAX_PENDING:
            del self.pending[next(iter(self.pending))]
            discarded += 1
        return result, discarded


def remember_native(event, native_states, bot_count):
    """Keep the plugin's exact per-observation snapshot until its observation is forwarded."""
    bot = integer(event.get('botId'), 0, bot_count - 1, 'native botId')
    sequence = integer(event.get('sequence'), 1, 2147483647, 'native sequence')
    life = integer(event.get('lifeId'), 0, 2147483647, 'native lifeId')
    native = event.get('nativeWeapon')
    if not isinstance(native, dict) or native.get('source') != 'native_player_state':
        raise ValueError('Invalid native observation')
    sprint = event.get('nativeSprint')
    if sprint is not None and (not isinstance(sprint, dict)
            or sprint.get('source') != 'native_player_state'
            or sprint.get('observedAtMs') != native.get('observedAtMs')):
        raise ValueError('Invalid native sprint observation')
    native_states[bot, sequence, life] = (native, sprint)
    while len(native_states) > 64:
        del native_states[next(iter(native_states))]


def attach_native(observation, native_states, require_native):
    """Only the snapshot of the same bot, sequence, life and game time may join."""
    identity = observation['botId'], observation['sequence'], observation.get('lifeId')
    state = native_states.pop(identity, None)
    native, sprint = state if state is not None else (None, None)
    if native is not None and native.get('observedAtMs') == observation.get('gameTimeMs'):
        observation['native'] = dict(native)
        if sprint is not None:
            observation['native']['sprint'] = sprint
    elif require_native and observation.get('alive') and 'native' not in observation:
        raise ValueError('Missing native weapon snapshot for current observation')


def telemetry_messages(lines, joiner, native_states=None, require_native=False):
    """Deliver events before the freshest complete observations in a batch."""
    events = []
    errors = 0
    discarded = 0
    if native_states is None:
        native_states = {}
    for line in lines:
        if line.startswith('[jev-observation]'):
            raw = line.split('[jev-observation]', 1)[1].strip()
            try:
                record = json.loads(raw)
                if not isinstance(record, dict):
                    raise ValueError('Observation is not an object')
                if not joiner.add(record):
                    discarded += 1
            except (ValueError, TypeError):
                errors += 1
                events.append({'type': 'event', 'line': '[lab] invalid observation JSON: ' + raw[:300]})
        elif line.startswith('[jev-event]'):
            raw = line.split('[jev-event]', 1)[1].strip()
            events.append({'type': 'event', 'line': raw})
            try:
                event = json.loads(raw)
                if isinstance(event, dict) and event.get('event') == 'native_weapon':
                    remember_native(event, native_states, joiner.bot_count)
            except (ValueError, TypeError):
                errors += 1
    current, dropped = joiner.complete()
    discarded += dropped
    for observation in current:
        attach_native(observation, native_states, require_native)
    for identity in list(native_states):
        if identity[1] <= joiner.last_forwarded[identity[0]]:
            del native_states[identity]
    return events + [{'type': 'observation', 'observation': item} for item in current], discarded, errors


def isolate_team_balance(source):
    """Disable private-lab auto-balancing without enabling name-based team locks."""
    guard = '\tif( code\\fixedteams::enabled() )'
    if source.count(guard) != 4:
        raise ValueError('Unexpected team-balancing script guards')
    return source.replace(guard, '\tif( code\\fixedteams::enabled() || getDvarInt( "jev_enabled" ) == 1 )')


def capture_reload_ammo(source):
    """Observe ammo before this mod's reload handler clears it; preserve behavior."""
    capture = '\t\tAmmoClip = self GetWeaponAmmoClip( weap );'
    clear = '\t\tself SetWeaponAmmoClip( weap, 0 );'
    anchor = capture + '\n' + clear
    if source.count(anchor) != 1:
        raise ValueError('Unexpected reload ammo capture anchor')
    hook = ('\t\tif( getDvarInt( "jev_enabled" ) == 1 )\n'
            '\t\t{\n'
            '\t\t\tself.jevReloadEventClip = AmmoClip;\n'
            '\t\t\tself.jevReloadEventTime = getTime();\n'
            '\t\t\tself.jevReloadEventWeapon = weap;\n'
            '\t\t}\n')
    return source.replace(anchor, capture + '\n' + hook + clear)


def start_fixture(source):
    """Start the Jev bot after the mod's player init; this copy runs no other fixture."""
    anchor = '\tthread code\\player::init();'
    if source.count(anchor) != 1:
        raise ValueError('Unexpected source initialization anchor')
    source = re.sub(r'(?im)^\s*(?:thread\s+)?code\\(?:_dbots|mw2_soak|mw2_perk_test|mw2_test|mw2_launcher_test|jev_agent|jev_bot)::(?:init|main)\(\);\s*$', '', source)
    # _dBots has a single unbraced developer condition; preserve a valid body.
    source = re.sub(r'(?m)^(\s*if\( getDvarInt\( "developer" \) > 0 \))\s*\n\s*}', r'\1 { }\n}', source)
    return source.replace(anchor, anchor + '\n\tthread code\\jev_bot::main();')


def native_plugin(bootstrap, server_sha):
    """Only accept the private i386 observer for the server ABI it was built for."""
    payload = bootstrap.get('nativePlugin')
    if payload is None:
        return None
    if not isinstance(payload, dict) or server_sha != NATIVE_SERVER_SHA256:
        raise ValueError('Native observation requires the pinned server build')
    data = base64.b64decode(payload.get('data', ''), validate=True)
    if not 100 <= len(data) <= 131072:
        raise ValueError('Invalid native observation plugin size')
    if hashlib.sha256(data).hexdigest() != payload.get('sha256'):
        raise ValueError('Native observation plugin hash mismatch')
    # ELF32, little-endian, current version, ET_DYN and EM_386.
    if data[:7] != b'\x7fELF\x01\x01\x01' or data[16:20] != b'\x03\x00\x03\x00':
        raise ValueError('Native observation requires an i386 shared library')
    return data


def deterministic_initial_spawns(source):
    """Patch only the pinned private copy, preserving the ordinary spawn call."""
    if hashlib.sha256(source.encode()).hexdigest() != WAR_SOURCE_SHA256:
        raise ValueError('Unexpected authored-spawn source hash')
    anchor = '\tself spawn( spawnPoint.origin, spawnPoint.angles );'
    if source.count(anchor) != 1:
        raise ValueError('Unexpected authored-spawn anchor')
    hook = ('\tif ( getDvarInt("jev_enabled") == 1 && getDvarInt("jev_spawn_layout") >= 0 && isDefined(self.jevId) && !isDefined(self.jevInitialSpawnLayoutDone) )\n'
            '\t{\n\t\tspawnPoint = self code\\jev_bot::chooseInitialSpawn();\n'
            '\t\tif ( !isDefined(spawnPoint) ) return;\n'
            '\t\tself.jevInitialSpawnLayoutDone = true;\n\t}\n')
    return source.replace(anchor, hook + anchor)


def script_payload(bootstrap, name):
    """A base64 GSC source with its declared hash."""
    data = base64.b64decode(bootstrap.get(name, ''), validate=True)
    if not data or len(data) > MAX_SCRIPT:
        raise ValueError('Invalid ' + name + ' size')
    if hashlib.sha256(data).hexdigest() != bootstrap.get(name + 'Sha256'):
        raise ValueError(name + ' hash mismatch')
    return data


def bot_warfare_opponents(bootstrap):
    """Decode the vendored Bot Warfare files and refuse any byte that differs from the pinned commit."""
    count = integer(bootstrap.get('bwCount', 0), 0, MAX_BW_COUNT, 'bwCount')
    if count == 0:
        return {'count': 0, 'skill': 0, 'files': {}}
    skill = integer(bootstrap.get('bwSkill'), 1, 7, 'bwSkill')
    payload = bootstrap.get('bwFiles')
    if not isinstance(payload, dict) or set(payload) != set(VENDORED_SHA256) | set(BOT_WARFARE_NOTICES):
        raise ValueError('Bot Warfare files must be exactly the vendored set')
    files = {}
    for name, encoded in payload.items():
        if type(encoded) is not str:
            raise ValueError('Invalid Bot Warfare file encoding: ' + name)
        data = base64.b64decode(encoded, validate=True)
        if not 1 <= len(data) <= 1048576:
            raise ValueError('Invalid Bot Warfare file size: ' + name)
        digest = VENDORED_SHA256.get(name)
        if digest is not None and hashlib.sha256(data).hexdigest() != digest:
            raise ValueError('Bot Warfare file differs from the pinned commit: ' + name)
        files[name] = data
    return {'count': count, 'skill': skill, 'files': files}


def replace_in_function(source, header, before, after):
    """Replace one anchor inside one top-level GSC function; both must be unambiguous."""
    start = source.find('\n' + header)
    if start < 0 or source.find('\n' + header, start + 1) >= 0:
        raise ValueError('Bot Warfare function missing or ambiguous: ' + header)
    end = source.find('\n}', start)
    if end < 0:
        raise ValueError('Bot Warfare function never closes: ' + header)
    body = source[start:end]
    if body.count(before) != 1:
        raise ValueError('Bot Warfare anchor missing or ambiguous in ' + header)
    return source[:start] + body.replace(before, after) + source[end:]


def skip_jev_controlled(source):
    """Bot Warfare must never adopt, damage-track or death-track a Jev-controlled player."""
    newline = '\r\n' if '\r\n' in source else '\n'
    guard = newline.join(('\tif ( !self is_bot() )', '\t{', '\t\treturn;', '\t}'))
    # pers[] survives the round restarts of Search and Destroy; the entity field does not.
    skip = newline.join(('\tif ( !self is_bot() || isDefined( self.jevControlled ) || isDefined( self.pers["jevControlled"] ) )', '\t{', '\t\treturn;', '\t}'))
    source = replace_in_function(source, 'connected()', guard, skip)
    for header in ('onPlayerDamage(', 'onPlayerKilled('):
        source = replace_in_function(source, header, '\tif ( self is_bot() )',
                                     '\tif ( self is_bot() && !isDefined( self.jevControlled ) && !isDefined( self.pers["jevControlled"] ) )')
    return source


SD_DEFUSE_ANCHOR = 'defuseObject.useWeapon = "briefcase_bomb_defuse_mp";'


def expose_defuse_object(mod):
    """The mod keeps the defuse gameobject in a local; the fixture needs it to defuse as a bot."""
    path = mod / 'maps/mp/gametypes/sd.gsx'
    if not path.is_file():
        return
    source = path.read_text(errors='replace')
    if source.count(SD_DEFUSE_ANCHOR) != 1:
        raise ValueError('sd.gsx defuse anchor missing or ambiguous')
    newline = '\r\n' if '\r\n' in source else '\n'
    path.write_text(source.replace(SD_DEFUSE_ANCHOR, SD_DEFUSE_ANCHOR + newline + '\tlevel.sdDefuseObject = defuseObject;'))


BOT_WARFARE_BLOCK_BEGIN = '// JEV_BOT_WARFARE_BEGIN'
BOT_WARFARE_BLOCK_END = '// JEV_BOT_WARFARE_END'
BOT_WARFARE_INIT = (
    'botWarfareInit()\n{\n'
    '\tthread scripts\\mp\\bots_adapter_cod4x::init();\n'
    '\tthread maps\\mp\\bots\\_bot::init();\n'
    '\tthread maps\\mp\\bots\\_bot_chat::init();\n'
    '\tthread maps\\mp\\bots\\_menu::init();\n'
    '\tthread maps\\mp\\bots\\_wp_editor::init();\n'
    '\treturn true;\n}\n'
)


def compose_bot_warfare_fixture(fixture, opponents):
    """GSC resolves referenced scripts at compile time, so the fixture only names Bot Warfare
    scripts when they were copied into the private mod."""
    if not opponents['count']:
        return fixture
    text = fixture.decode()
    begin = text.count(BOT_WARFARE_BLOCK_BEGIN)
    end = text.count(BOT_WARFARE_BLOCK_END)
    if begin != 1 or end != 1:
        raise ValueError('Fixture lacks a single Bot Warfare marker block')
    head, rest = text.split(BOT_WARFARE_BLOCK_BEGIN, 1)
    _stub, tail = rest.split(BOT_WARFARE_BLOCK_END, 1)
    return (head + BOT_WARFARE_BLOCK_BEGIN + '\n' + BOT_WARFARE_INIT + BOT_WARFARE_BLOCK_END + tail).encode()


def stage_bot_warfare(mod, opponents):
    """Copy the pinned Bot Warfare files into this run's private mod and patch its _bot.gsc copy."""
    if opponents['count'] == 0:
        return
    for name, data in opponents['files'].items():
        target = mod / name
        if target.exists():
            raise ValueError('Bot Warfare file collides with the mod: ' + name)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    main = mod / BOT_WARFARE_MAIN
    main.write_bytes(skip_jev_controlled(main.read_bytes().decode()).encode())


def bot_warfare_config(opponents):
    """jev_bw_* for the fixture plus every Bot Warfare pin, all skill dvars at the requested level."""
    config = 'set jev_bw_count ' + str(opponents['count']) + '\nset jev_bw_skill ' + str(opponents['skill']) + '\n'
    if opponents['count'] == 0:
        return config
    skill = str(opponents['skill'])
    pins = {**BOT_WARFARE_PINS, 'bots_skill': skill, 'bots_skill_min': skill, 'bots_skill_max': skill}
    return config + ''.join('set ' + name + ' "' + value + '"\n' for name, value in pins.items())


PASSWORD = re.compile(r'[A-Za-z0-9]{4,24}')


CLASSES = ('assault_mp', 'specops_mp', 'heavygunner_mp', 'demolitions_mp', 'sniper_mp')


def human_join_config(password):
    """A match a human may join: the password gates every join, the client may fetch the small mod files, and kill cams play."""
    if password is None:
        return ''
    return ('set g_password "' + password + '"\nset sv_allowDownload 1\nset sv_wwwDownload 0\n'
            'set scr_game_allowkillcam 1\nset final_killcam 1\n')


SD_CONFIG = '''set scr_sd_timelimit 2.5
set scr_sd_roundlimit 0
set scr_sd_scorelimit 5
set scr_sd_roundswitch 3
set scr_sd_numlives 1
set scr_sd_planttime 5
set scr_sd_defusetime 5
set scr_sd_bombtimer 45
set scr_sd_multibomb 1
set scr_sd_playerrespawndelay 0
set scr_sd_waverespawndelay 0
'''
MAP_NAME = re.compile(r'mp_[a-z0-9_]{1,40}')


def server_config(bot_count, game_mode, layout, seconds, key, plugin, server_sha, opponents, password=None, map_name='mp_shipment', loadout='assault_mp'):
    config = 'set sv_hostname "Jev ' + str(bot_count) + '-bot ' + map_name + ' ' + game_mode + ' lab"\n'
    config += '''set sv_authorizemode -1
set sv_pure 0
set sv_maxclients 8
set sv_master1 ""
set sv_master2 ""
set sv_master3 ""
set sv_master4 ""
set sv_master5 ""
set fs_players 0
set fs_ending 0
set mysql 0
set trueskill 0
set mapvote 0
set dynamic_rotation_enable 0
set final_killcam 0
set scr_game_allowkillcam 0
set old_hardpoints 1
set spawn_protection 0
set scr_enable_spawn_protection 0
set scr_mw2_perks_enabled 0
set scr_mw2_arsenal 0
set scr_throwingknife_enabled 0
set scr_player_forcerespawn 1
set scr_war_playerrespawndelay 1
set scr_war_waverespawndelay 0
set scr_game_playerwaittime 1
set scr_game_matchstarttime 1
set scr_war_timelimit 0
set scr_war_scorelimit 0
set scr_dm_timelimit 0
set scr_dm_scorelimit 0
set scr_dm_playerrespawndelay 1
set jgalbs_fixed_teams 0
set force_autoassign 0
set scr_teambalance 0
set add_bots 0
set developer 1
set developer_script 1
set logfile 2
set jev_enabled 1
set jev_stop 0
'''
    config += 'set jev_bot_count ' + str(bot_count) + '\nset g_gametype ' + game_mode + '\nset jev_class ' + loadout + '\n'
    config += ''.join('set jev_cmd_' + str(bot) + ' ""\n' for bot in range(bot_count))
    if plugin is not None:
        config += ('set jev_native_enabled 1\nset jev_native_server_sha256 "' + server_sha +
                   '"\nloadPlugin jev_observation\n')
    else:
        config += 'set jev_native_enabled 0\n'
    config += 'set jev_spawn_layout ' + str(layout) + '\n'
    config += bot_warfare_config(opponents)
    config += human_join_config(password)
    if game_mode == 'sd':
        config += SD_CONFIG
    config += 'set jev_seconds ' + str(seconds) + '\nset rcon_password "' + key + '"\nmap ' + map_name + '\n'
    return config


def stage(bootstrap):
    seconds = integer(bootstrap.get('seconds'), 1, 3600, 'seconds')
    bot_count = integer(bootstrap.get('botCount', BOT_COUNT), MIN_BOT_COUNT, MAX_BOT_COUNT, 'botCount')
    game_mode = bootstrap.get('gameMode', 'war')
    if game_mode not in ('war', 'dm', 'sd'):
        raise ValueError('Invalid gameMode')
    map_name = bootstrap.get('map', 'mp_shipment')
    if type(map_name) is not str or not MAP_NAME.fullmatch(map_name):
        raise ValueError('Invalid map')
    loadout = bootstrap.get('loadout', 'assault_mp')
    if loadout not in CLASSES:
        raise ValueError('Invalid loadout')
    layout = integer(bootstrap['spawnLayout'], 0, 2, 'spawnLayout') if 'spawnLayout' in bootstrap else -1
    if game_mode != 'war' and layout >= 0:
        raise ValueError('Spawn layout is only supported for war')
    port = integer(bootstrap.get('port'), 1024, 65535, 'port')
    if port in (28960, 28961):
        raise ValueError('Production game ports are prohibited')
    password = bootstrap.get('password')
    if password is not None and (type(password) is not str or not PASSWORD.fullmatch(password)):
        raise ValueError('Invalid password')
    fixture = script_payload(bootstrap, 'fixture')
    waypoints = script_payload(bootstrap, 'waypoints')
    opponents = bot_warfare_opponents(bootstrap)
    if bot_count + opponents['count'] > MAX_CLIENTS:
        raise ValueError('Jev bots plus Bot Warfare bots exceed sv_maxclients')
    server_sha = hashlib.sha256(EXECUTABLE.read_bytes()).hexdigest()
    plugin = native_plugin(bootstrap, server_sha)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.bind(('127.0.0.1', port))
    root = Path(tempfile.mkdtemp(prefix='cod4-jev-', dir='/tmp'))
    root.chmod(0o700)
    mod = root / 'home/mods/jev_test'
    mod.mkdir(parents=True)
    executable = root / 'cod4x18_dedrun'
    shutil.copy2(EXECUTABLE, executable)
    if hashlib.sha256(executable.read_bytes()).hexdigest() != server_sha:
        raise ValueError('Server changed while staging')
    if plugin is not None:
        plugins = root / 'home/plugins'
        plugins.mkdir()
        (plugins / 'jev_observation.so').write_bytes(plugin)
    for path in SOURCE.iterdir():
        if path.is_file() and not path.is_symlink() and path.suffix in ('.ff', '.iwd'):
            shutil.copy2(path, mod / path.name)
    for name in ('code', 'maps'):
        for path in (SOURCE / name).rglob('*'):
            if path.is_symlink():
                raise ValueError('Unexpected symlink in source scripts')
            if path.is_file() and path.suffix in ('.gsc', '.gsx'):
                target = mod / path.relative_to(SOURCE)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, target)
    stage_bot_warfare(mod, opponents)
    init = mod / 'code/init.gsx'
    init.write_text(start_fixture(init.read_text()))
    teams = mod / 'maps/mp/gametypes/_teams.gsx'
    teams.write_text(isolate_team_balance(teams.read_text()))
    player = mod / 'code/player.gsx'
    player.write_text(capture_reload_ammo(player.read_text()))
    if layout >= 0:
        war = mod / 'maps/mp/gametypes/war.gsx'
        # Preserve original CRLF bytes for the pinned source digest.
        war.write_text(deterministic_initial_spawns(war.read_bytes().decode()))
    fixture = compose_bot_warfare_fixture(fixture, opponents)
    if game_mode == 'sd':
        expose_defuse_object(mod)
    (mod / 'code/jev_bot.gsx').write_bytes(fixture)
    (mod / 'code/jev_bot_waypoints.gsx').write_bytes(waypoints)
    key = secrets.token_hex(32)
    keyfile = root / 'rcon.key'
    keyfile.write_text(key)
    keyfile.chmod(0o600)
    cfg = mod / 'jev.cfg'
    cfg.write_text(server_config(bot_count, game_mode, layout, seconds, key, plugin, server_sha, opponents, password, map_name, loadout))
    cfg.chmod(0o600)
    metadata = {'root': str(root), 'port': port, 'seconds': seconds, 'botCount': bot_count, 'gameMode': game_mode, 'map': map_name, 'loadout': loadout,
                'spawnLayout': layout if layout >= 0 else None, 'humanJoin': password is not None,
                'fixtureSha256': hashlib.sha256(fixture).hexdigest(),
                'waypointsSha256': hashlib.sha256(waypoints).hexdigest(),
                'binarySha256': server_sha,
                'nativePluginSha256': hashlib.sha256(plugin).hexdigest() if plugin is not None else None,
                'botWarfare': {'count': opponents['count'], 'skill': opponents['skill']} if opponents['count'] else None}
    (root / 'lab.json').write_text(json.dumps(metadata, indent=2))
    return root, executable, key, metadata


def main():
    process = None
    root = None
    key = ''
    reason = 'error'
    errors = 0
    observations = 0
    coalesced = 0
    submitted = 0
    bot_count = BOT_COUNT
    last_sequences = []
    joiner = None
    native_states = {}
    pending = bytearray()
    log_streams = {'telemetry': {'offset': 0, 'pending': ''}, 'diagnostic': {'offset': 0, 'pending': ''}}
    stopping = False
    selector = selectors.DefaultSelector()

    def interrupted(_signum, _frame):
        nonlocal stopping, reason
        stopping = True
        reason = 'signal'

    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, interrupted)

    def read_logs():
        nonlocal observations, errors, stopping, reason, coalesced
        if root is None or not (root / 'server.log').exists():
            return
        # The fixture closes each telemetry record. Never replay observations
        # from a fallback console file: console output has a separate reader.
        paths = {'telemetry': root / 'home/mods/jev_test/jev_telemetry.jsonl',
                 'diagnostic': root / 'server.log'}
        for kind, path in paths.items():
            if not path.exists():
                continue
            state = log_streams[kind]
            with path.open('rb') as stream:
                stream.seek(state['offset'])
                data = stream.read(1048576)
                state['offset'] = stream.tell()
            lines = (state['pending'] + data.decode(errors='replace')).split('\n')
            state['pending'] = lines.pop()
            if len(state['pending']) > MAX_LINE:
                raise ValueError('Oversize server log line')
            lines = [line.replace(key, '[REDACTED]') for line in lines]
            if kind == 'diagnostic':
                for line in lines:
                    if re.search(r'script (?:compile|runtime) error|unknown function|fatal error|segmentation fault', line, re.I):
                        errors += 1
                        stopping = True
                        reason = 'server-script-error'
                        emit({'type': 'event', 'line': '[server-error] ' + line[:1000]})
                continue
            messages, discarded, malformed = telemetry_messages(lines, joiner, native_states,
                                                               metadata.get('nativePluginSha256') is not None)
            coalesced += discarded
            errors += malformed
            for message in messages:
                emit(message)
                if message['type'] == 'observation':
                    observations += 1
                    continue
                try:
                    event = json.loads(message['line'])
                    if event.get('event') == 'summary':
                        stopping = True
                        reason = 'fixture-' + str(event.get('reason', 'finished'))
                except (ValueError, AttributeError):
                    pass

    try:
        # One bootstrap message precedes the streaming command protocol.
        while b'\n' not in pending:
            chunk = os.read(sys.stdin.fileno(), 65536)
            if not chunk:
                raise ValueError('Missing bootstrap')
            pending.extend(chunk)
            if len(pending) > MAX_LINE * 4:
                raise ValueError('Oversize bootstrap')
        raw, _, tail = pending.partition(b'\n')
        pending = bytearray(tail)
        bootstrap = json.loads(raw)
        if not isinstance(bootstrap, dict) or bootstrap.get('type') != 'bootstrap':
            raise ValueError('Expected bootstrap')
        root, executable, key, metadata = stage(bootstrap)
        bot_count = metadata['botCount']
        last_sequences = [-1] * bot_count
        joiner = ObservationJoiner(bot_count)
        binding = [] if metadata['humanJoin'] else ['+set', 'net_ip', '127.0.0.1', '+set', 'net_ip6', '::1']
        command = [str(executable), '+set', 'dedicated', '1', *binding,
                   '+set', 'net_port', str(metadata['port']), '+set', 'fs_basepath', '/opt/cod4',
                   '+set', 'fs_homepath', str(root / 'home'), '+set', 'fs_game', 'mods/jev_test',
                   '+set', 'r_xassetnum', 'xmodel=1280', '+set', 'sv_maxclients', str(MAX_CLIENTS),
                   '+set', 'developer', '1', '+set', 'developer_script', '1',
                   '+set', 'logfile', '2', '+exec', 'jev.cfg']
        with (root / 'server.log').open('w') as log:
            process = subprocess.Popen(command, cwd=root, stdin=subprocess.DEVNULL,
                                       stdout=log, stderr=log, start_new_session=True)
        (root / 'pid').write_text(str(process.pid))
        subprocess.Popen([sys.executable, '-c', WATCHDOG, str(process.pid), str(executable),
                          str(metadata['seconds'] + 45)], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        emit({'type': 'ready', **metadata, 'pid': process.pid})
        deadline = time.monotonic() + metadata['seconds'] + 40
        selector.register(sys.stdin.fileno(), selectors.EVENT_READ)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as rcon:
            rcon.connect(('127.0.0.1', metadata['port']))
            while not stopping:
                read_logs()
                if process.poll() is not None:
                    reason = 'server-exited'
                    break
                if time.monotonic() >= deadline:
                    reason = 'watchdog'
                    break
                if b'\n' not in pending:
                    if not selector.select(.01):
                        continue
                    chunk = os.read(sys.stdin.fileno(), 65536)
                    if not chunk:
                        reason = 'stdin-eof'
                        break
                    pending.extend(chunk)
                    if len(pending) > MAX_LINE:
                        raise ValueError('Oversize command input')
                while b'\n' in pending:
                    raw, _, tail = pending.partition(b'\n')
                    pending = bytearray(tail)
                    try:
                        message = json.loads(raw)
                        if isinstance(message, dict) and message.get('type') == 'stop':
                            reason = 'requested'
                            stopping = True
                            break
                        bot, sequence, command = command_wire(message, bot_count)
                        if sequence <= last_sequences[bot]:
                            raise ValueError('Non-increasing sequence')
                        rcon.send(b'\xff' * 4 + ('rcon ' + key + ' ' + command).encode())
                        last_sequences[bot] = sequence
                        submitted += 1
                    except (ValueError, TypeError, KeyError) as error:
                        errors += 1
                        emit({'type': 'event', 'line': '[lab] rejected command: ' + str(error)})
    except Exception as error:
        errors += 1
        emit({'type': 'event', 'line': '[lab-error] ' + str(error).replace(key, '[REDACTED]') if key else '[lab-error] ' + str(error)})
    finally:
        selector.close()
        if process is not None and process.poll() is None:
            try:
                owned = (Path('/proc') / str(process.pid) / 'exe').resolve(strict=True) == root / 'cod4x18_dedrun'
            except OSError:
                owned = False
            if owned:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        try:
            read_logs()
        except Exception as error:
            errors += 1
            emit({'type': 'event', 'line': '[lab] final log read failed: ' + str(error)})
        emit({'type': 'done', 'root': str(root) if root else None, 'reason': reason,
              'observations': observations, 'submittedCommands': submitted, 'errors': errors,
              'coalescedObservations': coalesced,
              'serverExitCode': process.poll() if process else None,
              'stopped': process is None or process.poll() is not None})


if __name__ == '__main__':
    main()
