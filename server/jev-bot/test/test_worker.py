#!/usr/bin/env python3
"""Offline checks for the Jev bot lab worker and launcher; never launches a game or SSH."""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[1]
SERVER = PROJECT.parent
VENDOR = SERVER / 'vendor/bot-warfare'
OPPONENT_MODULE = SERVER / 'cod4-ai/cod4_ai/bot_warfare_opponent.py'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


WORKER = load('remote_worker', PROJECT / 'lab/remote_worker.py')
LAUNCHER = load('jev_bot_lab', PROJECT / 'lab/lab.py')


def command(bot=0, **fields):
    return {'type': 'command', 'botId': bot, 'sequence': 8, 'lifeId': 2, 'gameTimeMs': 5000, 'fields': fields}


def part(name, bot=0, sequence=1, **extra):
    record = {'botId': bot, 'sequence': sequence, 'part': name, **extra}
    return '[jev-observation] ' + json.dumps(record)


def observation_lines(bot=0, sequence=1, order=('enemies', 'nav', 'events', 'self'), life=3, game_time=1000):
    payloads = {'enemies': {'visible': [{'id': 2, 'dist': 310}], 'remembered': [], 'team': []},
                'nav': {'node': 27, 'goal': 'n41', 'path': [27, 33, 41]},
                'events': {'kills': [], 'died': False, 'shots': sequence},
                'self': {'parts': 4, 'gameTimeMs': game_time, 'lifeId': life, 'alive': True, 'hp': 100}}
    return [part(name, bot, sequence, **payloads[name]) for name in order]


class JoinerResetTests(unittest.TestCase):
    def test_a_fresh_client_with_a_low_sequence_is_not_stale(self):
        joiner = WORKER.ObservationJoiner(2)
        joiner.last_forwarded[0] = 1542
        self.assertFalse(joiner.add({'botId': 0, 'sequence': 1540, 'part': 'events'}), 'a trailing part of an older observation is still stale')
        self.assertTrue(joiner.add({'botId': 0, 'sequence': 3, 'part': 'events'}), 'a restart of the sequence means a new client')
        self.assertEqual(joiner.last_forwarded[0], 0)
        self.assertTrue(joiner.add({'botId': 0, 'sequence': 4, 'part': 'events'}))


class CommandTests(unittest.TestCase):
    def test_full_command_builds_canonical_wire_in_table_order(self):
        message = command(3, w='keep', a='auto', r='on', s='crouch', l='-90', g='n41', e='f', t='2')
        self.assertEqual(WORKER.command_wire(message, 5),
                         (3, 8, 'set jev_cmd_3 "8 2 5000 t=2 e=f g=n41 l=-90 s=crouch r=on a=auto w=keep"'))

    def test_empty_fields_and_single_bot_are_valid(self):
        self.assertEqual(WORKER.command_wire(command(), 1), (0, 8, 'set jev_cmd_0 "8 2 5000"'))

    def test_accepts_every_documented_value_form(self):
        accepted = {'t': ('-', 'auto', '0', '7'), 'e': ('f', 'h', 'k'), 'g': ('n0', 'n999', 'hold', 'cover', 'glitch', 'chase0', 'chase7', 'siteA', 'siteB'),
                    'l': ('auto', '0', '-360', '360', '-1', '359', 'e0', 'e7'),
                    's': ('stand', 'crouch', 'prone', 'jump'), 'r': ('auto', 'on', 'off'), 'a': ('auto', 'on', 'off'),
                    'w': ('keep', 'reload', 'plant', 'defuse', 'streak', 'nade0:0:0', 'nade-120:340:192', 'nade999999:1:-2', 'tact-120:340:192')}
        for key, values in accepted.items():
            for value in values:
                with self.subTest(key=key, value=value):
                    wire = WORKER.command_wire(command(**{key: value}))[2]
                    self.assertTrue(wire.endswith(' ' + key + '=' + value + '"'))

    def test_rejects_values_outside_the_table(self):
        rejected = {'t': ('100', '-1', 'x', ''), 'e': ('fire', 'F'), 'g': ('n1000', 'n', 'n01', 'chase100', 'chase', 'run'),
                    'l': ('361', '-361', '+5', '090', 'e100', '1.5'), 's': ('sit', 'Stand'), 'r': ('yes',), 'a': ('1',),
                    'w': ('nade1:2', 'nade1:2:3:4', 'nadea:b:c', 'grenade', 'nade1.5:2:3')}
        for key, values in rejected.items():
            for value in values:
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    WORKER.command_wire(command(**{key: value}))

    def test_rejects_unknown_keys_non_string_values_and_injection(self):
        for fields in ({'x': 'hold'}, {'t': 2}, {'t': None}, {'g': 'hold"; quit'}, {'s': 'stand crouch'},
                       {'w': 'keep\n'}, {'l': 'a' * 25}):
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                WORKER.command_wire(command(**fields))
        for message in ({**command(), 'fields': None}, {**command(), 'fields': ['t=2']},
                        {**command(), 'type': 'action'}):
            with self.subTest(message=message), self.assertRaises(ValueError):
                WORKER.command_wire(message)

    def test_rejects_outside_bot_ids_and_bad_identity(self):
        for bot, count in ((4, 4), (5, 5), (1, 1), (-1, 5), (True, 4), (1.0, 4)):
            with self.subTest(bot=bot, count=count), self.assertRaises(ValueError):
                WORKER.command_wire(command(bot), count)
        for count in (0, 9, '4', None):
            with self.subTest(count=count), self.assertRaises(ValueError):
                WORKER.command_wire(command(), count)
        for field, value in (('sequence', -1), ('lifeId', 1.5), ('gameTimeMs', '5000'), ('sequence', 2 ** 31)):
            with self.subTest(field=field), self.assertRaises(ValueError):
                WORKER.command_wire({**command(), field: value})

    def test_oversize_wire_is_rejected(self):
        message = command(t='2', e='f', g='chase7', l='-360', s='crouch', r='auto', a='auto', w='nade-99999:-99999:-9999')
        message.update(sequence=2147483647, lifeId=2147483647, gameTimeMs=2147483647)
        wire = WORKER.command_wire(message)[2].split('"')[1]
        self.assertLessEqual(len(wire.encode()), WORKER.MAX_WIRE)
        with patch.object(WORKER, 'MAX_WIRE', len(wire.encode()) - 1), self.assertRaises(ValueError):
            WORKER.command_wire(message)


class JoinerTests(unittest.TestCase):
    def test_four_parts_join_into_one_observation(self):
        joiner = WORKER.ObservationJoiner(4)
        messages, discarded, errors = WORKER.telemetry_messages(observation_lines(), joiner)
        self.assertEqual((discarded, errors), (0, 0))
        self.assertEqual([message['type'] for message in messages], ['observation'])
        observation = messages[0]['observation']
        self.assertEqual(observation['botId'], 0)
        self.assertEqual(observation['sequence'], 1)
        self.assertEqual((observation['gameTimeMs'], observation['lifeId'], observation['hp']), (1000, 3, 100))
        self.assertNotIn('part', observation)
        self.assertNotIn('parts', observation)
        self.assertEqual(observation['enemies'], {'visible': [{'id': 2, 'dist': 310}], 'remembered': [], 'team': []})
        self.assertEqual(observation['nav'], {'node': 27, 'goal': 'n41', 'path': [27, 33, 41]})
        self.assertEqual(observation['events'], {'kills': [], 'died': False, 'shots': 1})
        self.assertEqual(joiner.last_forwarded, [1, 0, 0, 0])
        self.assertEqual(joiner.pending, {})

    def test_parts_out_of_order_and_across_batches_complete_once(self):
        joiner = WORKER.ObservationJoiner(4)
        lines = observation_lines(order=('self', 'events', 'nav', 'enemies'))
        messages, discarded, errors = WORKER.telemetry_messages(lines[:3], joiner)
        self.assertEqual((messages, discarded, errors), ([], 0, 0))
        self.assertEqual(len(joiner.pending[0, 1]), 3)
        messages, discarded, errors = WORKER.telemetry_messages(lines[3:], joiner)
        self.assertEqual((discarded, errors), (0, 0))
        self.assertEqual([message['type'] for message in messages], ['observation'])
        self.assertEqual(messages[0]['observation']['enemies']['visible'][0]['id'], 2)

    def test_newest_complete_observation_wins_and_older_ones_are_counted(self):
        joiner = WORKER.ObservationJoiner(4)
        lines = observation_lines(sequence=1) + observation_lines(sequence=2) + observation_lines(sequence=3)
        lines += observation_lines(bot=2, sequence=5)
        messages, discarded, errors = WORKER.telemetry_messages(lines, joiner)
        self.assertEqual((discarded, errors), (2, 0))
        self.assertEqual([(m['observation']['botId'], m['observation']['sequence']) for m in messages], [(0, 3), (2, 5)])
        self.assertEqual(joiner.last_forwarded, [3, 0, 5, 0])

    def test_incomplete_older_observation_is_dropped_when_a_newer_one_completes(self):
        joiner = WORKER.ObservationJoiner(4)
        lines = observation_lines(sequence=1)[:3] + observation_lines(sequence=2)
        messages, discarded, errors = WORKER.telemetry_messages(lines, joiner)
        self.assertEqual((discarded, errors), (1, 0))
        self.assertEqual(messages[0]['observation']['sequence'], 2)
        self.assertEqual(joiner.pending, {})
        late = observation_lines(sequence=1)[3:]
        messages, discarded, errors = WORKER.telemetry_messages(late, joiner)
        self.assertEqual((messages, discarded, errors), ([], 1, 0), 'a late part of a superseded observation is discarded')

    def test_incomplete_newer_observation_waits_without_blocking_other_bots(self):
        joiner = WORKER.ObservationJoiner(4)
        lines = observation_lines(bot=1, sequence=7)[:2] + observation_lines(bot=3, sequence=4)
        messages, discarded, errors = WORKER.telemetry_messages(lines, joiner)
        self.assertEqual((discarded, errors), (0, 0))
        self.assertEqual([m['observation']['botId'] for m in messages], [3])
        self.assertEqual(set(joiner.pending), {(1, 7)})

    def test_malformed_duplicate_and_foreign_parts_count_as_errors(self):
        joiner = WORKER.ObservationJoiner(4)
        lines = ['[jev-observation] not json', '[jev-observation] [1, 2]',
                 part('self', parts=4), part('self', parts=4),
                 part('nav', bot=4), part('nav', sequence=0), part('enemies', sequence='1'),
                 part('weather'), part('self', parts=0), part('self', parts=5), part('self')]
        messages, discarded, errors = WORKER.telemetry_messages(lines, joiner)
        self.assertEqual((discarded, errors), (0, 10))
        self.assertTrue(all(message['type'] == 'event' for message in messages))
        self.assertEqual(list(joiner.pending[0, 1]), ['self'])

    def test_events_pass_through_before_observations(self):
        joiner = WORKER.ObservationJoiner(4)
        lines = observation_lines()[:2] + ['[jev-event] ' + json.dumps({'event': 'kill', 'gameTimeMs': 900})]
        lines += observation_lines()[2:] + ['[jev-event] ' + json.dumps({'event': 'summary', 'reason': 'finished'})]
        messages, discarded, errors = WORKER.telemetry_messages(lines, joiner)
        self.assertEqual((discarded, errors), (0, 0))
        self.assertEqual([message['type'] for message in messages], ['event', 'event', 'observation'])
        self.assertEqual(json.loads(messages[0]['line'])['event'], 'kill')

    def test_pending_buffer_is_bounded(self):
        joiner = WORKER.ObservationJoiner(1)
        lines = [part('nav', sequence=sequence) for sequence in range(1, WORKER.MAX_PENDING + 11)]
        _, discarded, errors = WORKER.telemetry_messages(lines, joiner)
        self.assertEqual((discarded, errors), (10, 0))
        self.assertEqual(len(joiner.pending), WORKER.MAX_PENDING)

    def test_native_snapshot_joins_only_the_exact_observation(self):
        native = {'source': 'native_player_state', 'observedAtMs': 1000, 'weaponState': 7}
        sprint = {'source': 'native_player_state', 'observedAtMs': 1000, 'active': True}
        event = {'event': 'native_weapon', 'botId': 0, 'sequence': 1, 'lifeId': 3, 'nativeWeapon': native, 'nativeSprint': sprint}
        joiner = WORKER.ObservationJoiner(4)
        states = {}
        WORKER.telemetry_messages(['[jev-event] ' + json.dumps(event)], joiner, states, True)
        messages, _, errors = WORKER.telemetry_messages(observation_lines(), joiner, states, True)
        self.assertEqual(errors, 0)
        self.assertEqual(messages[-1]['observation']['native'], {**native, 'sprint': sprint})
        self.assertEqual(states, {})
        for field, value in (('lifeId', 4), ('sequence', 2), ('botId', 1)):
            with self.subTest(field=field), self.assertRaises(ValueError):
                WORKER.telemetry_messages(['[jev-event] ' + json.dumps({**event, field: value})] + observation_lines(),
                                          WORKER.ObservationJoiner(4), {}, True)
        with self.assertRaises(ValueError):
            WORKER.telemetry_messages(['[jev-event] ' + json.dumps(event)] + observation_lines(game_time=1050),
                                      WORKER.ObservationJoiner(4), {}, True)

    def test_native_is_optional_without_the_plugin_and_a_fixture_native_field_satisfies_it(self):
        messages, _, errors = WORKER.telemetry_messages(observation_lines(), WORKER.ObservationJoiner(4))
        self.assertEqual(errors, 0)
        self.assertNotIn('native', messages[-1]['observation'])
        lines = observation_lines()[:3] + [part('self', parts=4, gameTimeMs=1000, lifeId=3, alive=True,
                                                native={'stage': 0, 'remainingMs': 0})]
        messages, _, errors = WORKER.telemetry_messages(lines, WORKER.ObservationJoiner(4), {}, True)
        self.assertEqual(errors, 0)
        self.assertEqual(messages[-1]['observation']['native'], {'stage': 0, 'remainingMs': 0})


class BotWarfareTests(unittest.TestCase):
    def test_vendored_tables_match_the_cod4_ai_composer(self):
        opponent = load('bot_warfare_opponent', OPPONENT_MODULE)
        self.assertEqual(WORKER.BOT_WARFARE_SHA256, opponent.VENDOR_SHA256)
        self.assertEqual(WORKER.BOT_WARFARE_PINS, opponent._PINNED)
        self.assertEqual(WORKER.ALIASES, opponent.ALIASES)
        self.assertEqual(WORKER.DIFFICULTIES, {name: skill for name, skill in opponent.DIFFICULTIES.items()
                                               if name not in LAUNCHER.PASSIVE_LEVELS})
        self.assertEqual(set(LAUNCHER.PASSIVE_LEVELS), set(opponent.PASSIVE_PLAY))

    def test_vendored_files_match_their_pins(self):
        files = LAUNCHER.bot_warfare_files()
        self.assertEqual(set(files), set(WORKER.VENDORED_SHA256) | set(WORKER.BOT_WARFARE_NOTICES))
        for name, digest in WORKER.VENDORED_SHA256.items():
            self.assertEqual(hashlib.sha256(base64.b64decode(files[name])).hexdigest(), digest)

    def test_patch_on_the_real_bot_gsc_adds_exactly_three_guards_and_keeps_crlf(self):
        original = (VENDOR / WORKER.BOT_WARFARE_MAIN).read_bytes().decode()
        self.assertNotIn('jevControlled', original)
        self.assertEqual(original.count('\tif ( !self is_bot() )\r\n\t{\r\n\t\treturn;\r\n\t}'), 1)
        self.assertEqual(original.count('\tif ( self is_bot() )'), 2)
        patched = WORKER.skip_jev_controlled(original)
        self.assertEqual(patched.count('isDefined( self.jevControlled )'), 3)
        self.assertEqual(patched.count('isDefined( self.pers["jevControlled"] )'), 3)
        self.assertEqual(patched.count('\tif ( !self is_bot() || isDefined( self.jevControlled ) || isDefined( self.pers["jevControlled"] ) )\r\n\t{\r\n\t\treturn;\r\n\t}'), 1)
        self.assertEqual(patched.count('\tif ( self is_bot() && !isDefined( self.jevControlled ) && !isDefined( self.pers["jevControlled"] ) )'), 2)
        self.assertEqual(patched.count('\tif ( self is_bot() )'), 0)
        self.assertEqual(patched.count('\n'), original.count('\n'))
        self.assertEqual(patched.count('\r\n'), original.count('\r\n'))
        for header in ('\r\nconnected()', '\r\nonPlayerDamage(', '\r\nonPlayerKilled('):
            start = patched.index(header)
            body = patched[start:patched.index('\n}', start)]
            self.assertEqual(body.count('jevControlled'), 2, header)

    def test_patch_refuses_missing_or_ambiguous_anchors(self):
        original = (VENDOR / WORKER.BOT_WARFARE_MAIN).read_bytes().decode()
        guard = '\tif ( !self is_bot() )\r\n\t{\r\n\t\treturn;\r\n\t}'
        for broken in (original.replace(guard, ''), original.replace('\r\nconnected()', '\r\nconnected2()'),
                       original + '\r\nconnected()\r\n{\r\n' + guard + '\r\n}\r\n',
                       original.replace('\r\nonPlayerKilled(', '\r\nonPlayerKilled2('),
                       WORKER.skip_jev_controlled(original)):
            with self.assertRaises(ValueError):
                WORKER.skip_jev_controlled(broken)
        damage = original.index('\r\nonPlayerDamage(')
        doubled = original[:damage] + original[damage:].replace('\tif ( self is_bot() )', '\tif ( self is_bot() )\r\n\tif ( self is_bot() )', 1)
        with self.assertRaises(ValueError):
            WORKER.skip_jev_controlled(doubled)

    def test_patch_works_on_lf_sources_too(self):
        source = 'connected()\n{\n\tif ( !self is_bot() )\n\t{\n\t\treturn;\n\t}\n}\n\n'
        source += 'onPlayerDamage( a )\n{\n\tif ( self is_bot() )\n\t{\n\t}\n}\n\nonPlayerKilled( a )\n{\n\tif ( self is_bot() )\n\t{\n\t}\n}\n'
        patched = WORKER.skip_jev_controlled('\n' + source)
        self.assertEqual(patched.count('jevControlled'), 6)
        self.assertNotIn('\r', patched)

    def test_bootstrap_files_are_hash_checked_and_exactly_the_vendored_set(self):
        files = LAUNCHER.bot_warfare_files()
        good = {'bwCount': 2, 'bwSkill': 4, 'bwFiles': files}
        opponents = WORKER.bot_warfare_opponents(good)
        self.assertEqual((opponents['count'], opponents['skill'], set(opponents['files'])), (2, 4, set(files)))
        self.assertEqual(WORKER.bot_warfare_opponents({}), {'count': 0, 'skill': 0, 'files': {}})
        tampered = dict(files)
        tampered[WORKER.BOT_WARFARE_MAIN] = base64.b64encode(base64.b64decode(files[WORKER.BOT_WARFARE_MAIN]) + b'\r\n').decode()
        missing = dict(files)
        del missing['LICENSE-NOTICE.md']
        extra = {**files, 'maps/mp/bots/_extra.gsc': files[WORKER.BOT_WARFARE_MAIN]}
        cases = [{'bwCount': 5, 'bwSkill': 4, 'bwFiles': files}, {'bwCount': 1, 'bwSkill': 0, 'bwFiles': files},
                 {'bwCount': 1, 'bwSkill': 8, 'bwFiles': files}, {'bwCount': 1, 'bwFiles': files},
                 {'bwCount': 1, 'bwSkill': 4}, {'bwCount': 1, 'bwSkill': 4, 'bwFiles': tampered},
                 {'bwCount': 1, 'bwSkill': 4, 'bwFiles': missing}, {'bwCount': 1, 'bwSkill': 4, 'bwFiles': extra},
                 {'bwCount': 1, 'bwSkill': 4, 'bwFiles': {**files, 'LICENSE-NOTICE.md': 7}},
                 {'bwCount': '1', 'bwSkill': 4, 'bwFiles': files}, {'bwCount': True, 'bwSkill': 4, 'bwFiles': files}]
        for bootstrap in cases:
            with self.subTest(bootstrap={key: value for key, value in bootstrap.items() if key != 'bwFiles'}):
                with self.assertRaises(ValueError):
                    WORKER.bot_warfare_opponents(bootstrap)

    def test_config_pins_every_management_dvar_at_the_requested_skill(self):
        config = WORKER.bot_warfare_config({'count': 3, 'skill': 5, 'files': {}})
        self.assertIn('set jev_bw_count 3\n', config)
        self.assertIn('set jev_bw_skill 5\n', config)
        for name in ('bots_skill', 'bots_skill_min', 'bots_skill_max'):
            self.assertIn('set ' + name + ' "5"\n', config)
        for name, value in WORKER.BOT_WARFARE_PINS.items():
            self.assertIn('set ' + name + ' "' + value + '"\n', config)
        self.assertEqual(WORKER.bot_warfare_config({'count': 0, 'skill': 0, 'files': {}}),
                         'set jev_bw_count 0\nset jev_bw_skill 0\n')


def source_tree(base):
    source = base / 'source'
    (source / 'code').mkdir(parents=True)
    (source / 'maps/mp/gametypes').mkdir(parents=True)
    (source / 'code/init.gsx').write_text('main()\n{\n\tthread code\\player::init();\n\tthread code\\_dbots::init();\n}\n')
    (source / 'code/player.gsx').write_text(
        '\t\tAmmoClip = self GetWeaponAmmoClip( weap );\n\t\tself SetWeaponAmmoClip( weap, 0 );\n')
    (source / 'maps/mp/gametypes/_teams.gsx').write_text('\n'.join(['\tif( code\\fixedteams::enabled() )'] * 4))
    (source / 'maps/mp/gametypes/dm.gsx').write_text('main() { maps\\mp\\gametypes\\_globallogic::StartGameType(); }\n')
    (source / 'mod.ff').write_bytes(b'ff')
    (source / 'skip.txt').write_bytes(b'not copied')
    binary = base / 'server'
    binary.write_bytes(b'not executable; offline staging only')
    return source, binary


def offline_stage(base, bootstrap):
    source, binary = source_tree(base)
    private = base / 'cod4-jev-offline'
    private.mkdir()
    with patch.object(WORKER, 'SOURCE', source), patch.object(WORKER, 'EXECUTABLE', binary), \
            patch.object(WORKER.tempfile, 'mkdtemp', return_value=str(private)), patch.object(WORKER.socket, 'socket'):
        return WORKER.stage(bootstrap)


def scripts_bootstrap(**fields):
    fixture = b'main() { /* jev bot */ }\n// JEV_BOT_WARFARE_BEGIN\nbotWarfareInit() { return false; }\n// JEV_BOT_WARFARE_END\n'
    waypoints = b'jevWaypoints() { return []; }\n'
    return {'type': 'bootstrap', 'seconds': 120, 'port': 28985, 'botCount': 3, 'gameMode': 'dm',
            'fixture': base64.b64encode(fixture).decode(), 'fixtureSha256': hashlib.sha256(fixture).hexdigest(),
            'waypoints': base64.b64encode(waypoints).decode(), 'waypointsSha256': hashlib.sha256(waypoints).hexdigest(),
            **fields}


class StagingTests(unittest.TestCase):
    def test_bounds_precede_staging(self):
        cases = [{'botCount': value} for value in (0, 9, True, '5', None)]
        cases += [{'gameMode': value} for value in ('koth', '', None, 'dm; quit')]
        cases += [{'map': value} for value in ('shipment', 'mp_shipment; quit', 'MP_SHIPMENT', '')]
        cases += [{'gameMode': 'war', 'spawnLayout': 3}, {'gameMode': 'dm', 'spawnLayout': 0}, {'gameMode': 'sd', 'spawnLayout': 0}, {'port': 28960},
                  {'fixtureSha256': '0' * 64}, {'waypoints': ''}, {'bwCount': 1, 'bwSkill': 4},
                  {'botCount': 5, 'bwCount': 4, 'bwSkill': 4, 'bwFiles': LAUNCHER.bot_warfare_files()}]
        for fields in cases:
            with self.subTest(fields={key: value for key, value in fields.items() if key != 'bwFiles'}), \
                    patch.object(WORKER.tempfile, 'mkdtemp') as create:
                with self.assertRaises(ValueError):
                    WORKER.stage(scripts_bootstrap(**fields))
                create.assert_not_called()

    def test_private_copy_carries_both_fixture_files_and_the_command_dvars(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, executable, key, metadata = offline_stage(Path(temporary), scripts_bootstrap())
            mod = root / 'home/mods/jev_test'
            self.assertEqual((mod / 'code/jev_bot.gsx').read_bytes(), b'main() { /* jev bot */ }\n// JEV_BOT_WARFARE_BEGIN\nbotWarfareInit() { return false; }\n// JEV_BOT_WARFARE_END\n')
            self.assertEqual((mod / 'code/jev_bot_waypoints.gsx').read_bytes(), b'jevWaypoints() { return []; }\n')
            init = (mod / 'code/init.gsx').read_text()
            self.assertIn('\tthread code\\player::init();\n\tthread code\\jev_bot::main();', init)
            self.assertNotIn('jev_agent', init)
            self.assertNotIn('_dbots', init)
            self.assertTrue((mod / 'mod.ff').exists())
            self.assertFalse((mod / 'skip.txt').exists())
            self.assertFalse((mod / 'maps/mp/bots').exists())
            config = (mod / 'jev.cfg').read_text()
            for line in ('set jev_bot_count 3', 'set g_gametype dm', 'set jev_enabled 1', 'set jev_stop 0',
                         'set jev_seconds 120', 'set jev_spawn_layout -1', 'set jev_native_enabled 0',
                         'set jev_bw_count 0', 'set jev_bw_skill 0', 'set rcon_password "' + key + '"',
                         'set sv_hostname "Jev 3-bot mp_shipment dm lab"'):
                self.assertIn(line + '\n', config)
            for bot in range(3):
                self.assertIn('set jev_cmd_' + str(bot) + ' ""\n', config)
            self.assertNotIn('set jev_cmd_3', config)
            self.assertNotIn('jev_action', config)
            self.assertNotIn('bots_skill', config)
            self.assertEqual((metadata['botCount'], metadata['gameMode'], metadata['botWarfare']), (3, 'dm', None))
            self.assertEqual(metadata['waypointsSha256'], hashlib.sha256(b'jevWaypoints() { return []; }\n').hexdigest())
            self.assertEqual(json.loads((root / 'lab.json').read_text())['root'], str(root))
            self.assertEqual(oct((root / 'rcon.key').stat().st_mode & 0o777), '0o600')

    def test_bot_warfare_opponents_are_copied_patched_and_pinned(self):
        files = LAUNCHER.bot_warfare_files()
        with tempfile.TemporaryDirectory() as temporary:
            root, _, _, metadata = offline_stage(Path(temporary), scripts_bootstrap(bwCount=2, bwSkill=4, bwFiles=files))
            mod = root / 'home/mods/jev_test'
            for name in [*WORKER.VENDORED_SHA256, *WORKER.BOT_WARFARE_NOTICES]:
                self.assertTrue((mod / name).is_file(), name)
            for name, digest in WORKER.VENDORED_SHA256.items():
                if name != WORKER.BOT_WARFARE_MAIN:
                    self.assertEqual(hashlib.sha256((mod / name).read_bytes()).hexdigest(), digest, name)
            patched = (mod / WORKER.BOT_WARFARE_MAIN).read_bytes()
            self.assertEqual(patched, WORKER.skip_jev_controlled((VENDOR / WORKER.BOT_WARFARE_MAIN).read_bytes().decode()).encode())
            self.assertEqual(patched.count(b'jevControlled'), 6)
            self.assertEqual((VENDOR / WORKER.BOT_WARFARE_MAIN).read_bytes().count(b'jevControlled'), 0)
            config = (mod / 'jev.cfg').read_text()
            for line in ('set jev_bw_count 2', 'set jev_bw_skill 4', 'set bots_skill "4"', 'set bots_skill_min "4"',
                         'set bots_skill_max "4"', 'set bots_manage_add "0"', 'set bots_manage_fill "0"',
                         'set bots_main_menu "0"', 'set bots_team "autoassign"'):
                self.assertIn(line + '\n', config)
            self.assertLess(config.index('set bots_skill "4"'), config.index('map mp_shipment'))
            self.assertEqual(metadata['botWarfare'], {'count': 2, 'skill': 4})

    def test_bot_warfare_copy_refuses_to_overwrite_mod_files(self):
        files = LAUNCHER.bot_warfare_files()
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            original = source_tree
            def colliding(base):
                source, binary = original(base)
                (source / 'maps/mp/bots').mkdir(parents=True)
                (source / 'maps/mp/bots/_bot.gsc').write_text('main() {}\n')
                return source, binary
            with patch.object(sys.modules[__name__], 'source_tree', colliding), self.assertRaises(ValueError):
                offline_stage(base, scripts_bootstrap(bwCount=1, bwSkill=2, bwFiles=files))

    def test_spawn_layout_hook_calls_the_jev_bot_fixture(self):
        anchor = '\tself spawn( spawnPoint.origin, spawnPoint.angles );'
        source = 'onSpawnPlayer()\r\n{\r\n' + anchor + '\r\n}\r\n'
        with patch.object(WORKER, 'WAR_SOURCE_SHA256', hashlib.sha256(source.encode()).hexdigest()):
            changed = WORKER.deterministic_initial_spawns(source)
        self.assertEqual(changed.count(anchor), 1)
        self.assertIn('self code\\jev_bot::chooseInitialSpawn()', changed)
        self.assertNotIn('jev_agent', changed)
        with self.assertRaises(ValueError):
            WORKER.deterministic_initial_spawns(source)


class LauncherTests(unittest.TestCase):
    def test_opponent_argument_parses_levels_and_aliases(self):
        for text, level, skill, count in (('bot_warfare:medium:2', 'medium', 4, 2), ('bot_warfare:normal:1', 'medium', 4, 1),
                                          ('bot_warfare:Very-Hard:4', 'very_hard', 6, 4), ('bot_warfare:veteran:3', 'hardest', 7, 3),
                                          ('bot_warfare:too_easy:1', 'too_easy', 1, 1)):
            with self.subTest(text=text):
                self.assertEqual(LAUNCHER.parse_opponents(text),
                                 {'kind': 'bot_warfare', 'level': level, 'skill': skill, 'count': count})
        for text in ('bot_warfare:medium:0', 'bot_warfare:medium:5', 'bot_warfare:passive_still:1', 'bot_warfare:godlike:1',
                     'pezbot:medium:1', 'bot_warfare:medium', 'bot_warfare:medium:2:3', 'bot_warfare:medium:x'):
            with self.subTest(text=text), self.assertRaises(LAUNCHER.argparse.ArgumentTypeError):
                LAUNCHER.parse_opponents(text)

    def test_bootstrap_round_trips_into_the_worker(self):
        class Args:
            seconds, port, bots, game_mode, spawn_layout = 300, 28985, 2, 'dm', None
        fixture = b'main() {}\n// JEV_BOT_WARFARE_BEGIN\nbotWarfareInit() { return false; }\n// JEV_BOT_WARFARE_END\n'
        waypoints = b'jevWaypoints() {}\n'
        opponents = LAUNCHER.parse_opponents('bot_warfare:hard:3')
        bootstrap = LAUNCHER.build_bootstrap(Args, fixture, waypoints, None, opponents)
        line = json.dumps(bootstrap) + '\n'
        self.assertLess(len(line), WORKER.MAX_LINE * 4)
        decoded = json.loads(line)
        self.assertEqual((decoded['bwCount'], decoded['bwSkill'], set(decoded['bwFiles'])),
                         (3, 5, set(WORKER.VENDORED_SHA256) | set(WORKER.BOT_WARFARE_NOTICES)))
        self.assertNotIn('nativePlugin', decoded)
        self.assertNotIn('spawnLayout', decoded)
        with tempfile.TemporaryDirectory() as temporary:
            root, _, _, metadata = offline_stage(Path(temporary), decoded)
            self.assertEqual((metadata['botCount'], metadata['botWarfare']), (2, {'count': 3, 'skill': 5}))
            staged = (root / 'home/mods/jev_test/code/jev_bot.gsx').read_text()
            self.assertIn('thread maps\\mp\\bots\\_bot::init();', staged)
            self.assertNotIn('return false; }', staged)
            self.assertIn('set bots_skill "5"\n', (root / 'home/mods/jev_test/jev.cfg').read_text())
        plain = LAUNCHER.build_bootstrap(Args, fixture, waypoints, None, None)
        self.assertNotIn('bwCount', plain)
        self.assertEqual(WORKER.bot_warfare_opponents(plain)['count'], 0)

    def test_worker_environment_drops_api_keys(self):
        with patch.dict(LAUNCHER.os.environ, {'TYPESAFE_API_KEY': 'secret', 'OTHER_API_KEY': 'x', 'HOME': '/tmp/h'}):
            environment = LAUNCHER.worker_environment()
        self.assertNotIn('TYPESAFE_API_KEY', environment)
        self.assertNotIn('OTHER_API_KEY', environment)
        self.assertEqual(environment['HOME'], '/tmp/h')

    def test_validate_only_cli_needs_no_ssh(self):
        launcher = PROJECT / 'lab/lab.py'
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / 'test.gsx'
            fixture.write_text('main() {}')
            waypoints = Path(directory) / 'wp.gsx'
            waypoints.write_text('jevWaypoints() {}')
            command = [sys.executable, str(launcher), '--validate-only', '--fixture', str(fixture), '--waypoints', str(waypoints)]
            cases = (([], 4, 'war', None), (['--bots', '1', '--game-mode', 'dm', '--opponents', 'bot_warfare:medium:4'], 1, 'dm', 4),
                     (['--bots', '5', '--brain', 'jev'], 5, 'war', None))
            for flags, count, mode, opponents in cases:
                result = subprocess.run(command + flags, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                checked = json.loads(result.stdout)
                self.assertEqual((checked['botCount'], checked['gameMode']), (count, mode))
                self.assertEqual(checked['opponents'] and checked['opponents']['count'], opponents)
                self.assertEqual(checked['fixtureSha256'], hashlib.sha256(b'main() {}').hexdigest())
            for flags in (['--bots', '9'], ['--bots', '0'], ['--game-mode', 'dm', '--spawn-layout', '0'],
                          ['--opponents', 'bot_warfare:medium:5'], ['--opponents', 'bot_warfare:passive_moving:1'],
                          ['--bots', '5', '--opponents', 'bot_warfare:easy:4'], ['--port', '28960'], ['--brain', 'random']):
                result = subprocess.run(command + flags, capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0, flags)


if __name__ == '__main__':
    unittest.main()


class BotWarfareFixtureComposition(unittest.TestCase):
    def test_stub_kept_without_opponents(self):
        fixture = PROJECT.joinpath('game/jev_bot.gsx').read_bytes()
        self.assertEqual(WORKER.compose_bot_warfare_fixture(fixture, {'count': 0, 'skill': 0}), fixture)

    def test_block_replaced_with_opponents(self):
        fixture = PROJECT.joinpath('game/jev_bot.gsx').read_bytes()
        composed = WORKER.compose_bot_warfare_fixture(fixture, {'count': 2, 'skill': 4}).decode()
        self.assertEqual(composed.count('botWarfareInit()'), 2)  # call site plus definition
        self.assertIn('thread maps\\mp\\bots\\_bot::init();', composed)
        self.assertNotIn('botWarfareInit() { return false; }', composed)
        self.assertEqual(composed.count(WORKER.BOT_WARFARE_BLOCK_BEGIN), 1)

    def test_missing_marker_rejected(self):
        with self.assertRaises(ValueError):
            WORKER.compose_bot_warfare_fixture(b'main() {}', {'count': 1, 'skill': 4})
