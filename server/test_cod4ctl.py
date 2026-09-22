#!/usr/bin/env python3
import importlib.util
import pathlib
import json
import os
import tempfile
import unittest
from unittest import mock


MODULE_PATH = pathlib.Path(__file__).with_name("cod4ctl.py")
SPEC = importlib.util.spec_from_file_location("cod4ctl", MODULE_PATH)
assert SPEC and SPEC.loader
cod4ctl = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cod4ctl)


class ParserTests(unittest.TestCase):
    def test_shared_map_catalog_labels_and_complete_default_list(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "community-maps.json"
            records = [{"id": "mp_nuketown", "name": "Nuketown", "gametypes": ["dm", "sab"]}]
            records.extend({"id": f"mp_fixture_{index}", "name": f"Map {index}", "gametypes": ["dm", "war"]}
                           for index in range(17))
            path.write_text(json.dumps({"schema_version": 1, "maps": records}))
            with mock.patch.object(cod4ctl, "MAP_CATALOG_PATH", path), mock.patch.dict(os.environ, {}, clear=True):
                catalog = cod4ctl.load_map_catalog()
                self.assertEqual(len(catalog), 21)
                self.assertEqual(list(catalog)[:2], ["mp_nuketown", "mp_crash"])
                self.assertEqual(catalog["mp_fixture_16"]["name"], "Map 16")
                self.assertEqual(cod4ctl.maps_from_environment(), tuple(catalog))
                os.environ["COD4_MAPS"] = "mp_fixture_16,mp_crash,mp_fixture_16,mp_custom"
                self.assertEqual(cod4ctl.maps_from_environment(), ("mp_fixture_16", "mp_crash", "mp_custom"))
                connection = mock.Mock(host="localhost", port=28961)
                connection.status.return_value = {"info": {"mapname": "mp_fixture_16", "g_gametype": "dm"}, "players": []}
                connection.rcon.return_value = ""
                dashboard = cod4ctl.Controller(connection, cod4ctl.maps_from_environment()).dashboard()
                self.assertEqual(dashboard["map"], "mp_fixture_16")
                self.assertEqual(dashboard["mapLabel"], "Map 16")
                self.assertEqual(dashboard["mapOptions"][0], {"value": "mp_fixture_16", "label": "Map 16", "gametypes": ["dm", "war", "dem", "kc", "ctf", "inf", "oitc"]})
                self.assertEqual(dashboard["mapOptions"][-1]["label"], "mp_custom")

    def test_map_catalog_rejects_invalid_or_duplicate_data(self):
        valid = {"id": "mp_test", "name": "Test", "gametypes": ["dm"]}
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "maps.json"
            cases = [None, {"schema_version": 2, "maps": [valid]}, {"schema_version": 1, "maps": []}]
            for patch in ({"id": "mp_test;quit"}, {"name": ""}, {"gametypes": [{}]}, {"gametypes": ["bad"]}):
                cases.append({"schema_version": 1, "maps": [{**valid, **patch}]})
            cases.append({"schema_version": 1, "maps": [valid, {**valid, "id": "MP_TEST"}]})
            for data in cases:
                with self.subTest(data=data):
                    path.write_text(json.dumps(data))
                    with self.assertRaises(cod4ctl.ControlError):
                        cod4ctl.load_map_catalog(path)

    def test_info_and_status(self):
        packet = (
            cod4ctl.PACKET_PREFIX
            + b"statusResponse\n\\sv_hostname\\Test\\mapname\\mp_crash"
            + b"\\g_gametype\\war\\sv_maxclients\\12\\uptime\\2 hours\n"
            + b'10 42 "Player One"\n-1 999 "Player Two"\n'
        )
        status = cod4ctl.parse_status_response([packet])
        self.assertEqual(status["info"]["mapname"], "mp_crash")
        self.assertEqual(status["players"][0]["name"], "Player One")
        self.assertEqual(status["players"][1]["score"], -1)

    def test_dvar_list_parser(self):
        output = '''
Displaying all cvars
        scr_game_allowkillcam "1"
S       g_speed "190"
  S A   scr_hardcore "0"
'''
        self.assertEqual(
            cod4ctl.parse_dvar_list(output),
            {
                "scr_game_allowkillcam": "1",
                "g_speed": "190",
                "scr_hardcore": "0",
            },
        )

    def test_rcon_status_player_parser(self):
        output = '''
num score ping playerid            steamid           name                             lastmsg address                                              qport rate
--- ----- ---- ------------------- ----------------- -------------------------------- ------- ---------------------------------------------------- ----- -----
  0    20   45 1234567890123456789                 0 Player One                            50 192.0.2.1:28960                                     1234 25000
  7    -5 CNCT 9876543210987654321                 0 ^2Other Player                         0 198.51.100.2:30000                                  4321 25000
'''
        self.assertEqual(
            cod4ctl.parse_rcon_players(output),
            [
                {"slot": 0, "score": 20, "ping": 45, "name": "Player One"},
                {"slot": 7, "score": -5, "ping": "CNCT", "name": "^2Other Player"},
            ],
        )

    def test_web_console_guards_secrets_and_multiple_commands(self):
        for command in (
            "rcon_password",
            "set rcon_password nope",
            "dvarlist *password*",
            "status; quit",
            "killserver",
        ):
            with self.subTest(command=command):
                with self.assertRaises(cod4ctl.ControlError):
                    cod4ctl.validate_web_command(command)
        self.assertEqual(cod4ctl.validate_web_command("/status"), "status")

    def test_setting_validation(self):
        self.assertEqual(cod4ctl.validate_setting("scr_hardcore", True), "1")
        self.assertEqual(cod4ctl.validate_setting("g_speed", "250"), "250")
        self.assertEqual(cod4ctl.validate_setting("xp_multi", "2.5"), "2.5")
        with self.assertRaises(cod4ctl.ControlError):
            cod4ctl.validate_setting("g_speed", "9999")
        with self.assertRaises(cod4ctl.ControlError):
            cod4ctl.validate_setting("rcon_password", "nope")

    def test_map_mode_message_and_slot_validation(self):
        self.assertEqual(cod4ctl.validate_map("mp_mw2_rust"), "mp_mw2_rust")
        self.assertEqual(cod4ctl.normalize_mode("tdm"), "war")
        for mode in ("hp", "hardpoint", "koth", "hq"):
            self.assertEqual(cod4ctl.normalize_mode(mode), "koth")
        self.assertEqual(cod4ctl.MODE_LABELS["koth"], "Hardpoint")
        self.assertEqual(cod4ctl.validate_message(" hello\nthere "), "hello there")
        self.assertEqual(cod4ctl.validate_slot("3"), 3)
        self.assertEqual(cod4ctl.validate_level("55"), 55)
        self.assertEqual(cod4ctl.validate_player_power("AIMBOT"), "aimbot")
        self.assertEqual(cod4ctl.validate_toggle("on"), "on")
        with self.assertRaises(cod4ctl.ControlError):
            cod4ctl.validate_level("56")
        with self.assertRaises(cod4ctl.ControlError):
            cod4ctl.validate_player_power("noclip;quit")
        with self.assertRaises(cod4ctl.ControlError):
            cod4ctl.validate_toggle("toggle")
        for value in ("mp-crash", "../main", "mp_crash;quit"):
            with self.assertRaises(cod4ctl.ControlError):
                cod4ctl.validate_map(value)


class ControllerTests(unittest.TestCase):
    class FakeConnection:
        def __init__(self):
            self.commands = []

        def rcon(self, command):
            self.commands.append(command)
            return "accepted"

    def test_hardpoint_settings_no_implicit_mode_change_or_restart(self):
        connection = self.FakeConnection()
        controller = cod4ctl.Controller(connection, ())
        result = controller.apply_settings({"scr_hardpoint_hilltime": "45", "scr_hardpoint_radius": "160", "scr_hardpoint_starttime": "0"}, "hardpoint", "250", "10")
        self.assertEqual(connection.commands, ["set scr_hardpoint_hilltime 45", "set scr_hardpoint_radius 160", "set scr_hardpoint_starttime 0", "set scr_koth_scorelimit 250", "set scr_koth_timelimit 10"])
        self.assertIn("next full map load", result)

    def test_invalid_request_never_partially_applies(self):
        for settings, mode, score, minutes in (
            ({"scr_hardpoint_hilltime": 45, "scr_hardpoint_radius": 1000}, "hp", "250", "10"),
            ({"scr_hardpoint_hilltime": 45, "scr_hardpoint_starttime": 11}, "hp", "250", "10"),
            ({"scr_hardpoint_hilltime": 45}, "bad-mode", "250", "10"),
            ({"scr_hardpoint_hilltime": 45}, "hp", "10001", "10"),
            ({"scr_hardpoint_hilltime": 45}, "hp", "250", "nan"),
            ({"scr_hardpoint_hilltime": "10;quit"}, "hp", "250", "10"),
        ):
            connection = self.FakeConnection()
            controller = cod4ctl.Controller(connection, ())
            with self.assertRaises(cod4ctl.ControlError):
                controller.apply_settings(settings, mode, score, minutes)
            self.assertEqual(connection.commands, [])

    def test_hardpoint_defaults_before_first_map_and_existing_values(self):
        connection = self.FakeConnection()
        controller = cod4ctl.Controller(connection, ())
        settings = controller.settings()
        self.assertEqual(settings["rules"]["koth"], {"scoreLimit": "250", "timeLimit": "10"})
        self.assertEqual(settings["values"]["scr_hardpoint_hilltime"], "60")
        self.assertEqual(settings["values"]["scr_hardpoint_radius"], "192")
        self.assertEqual(settings["values"]["scr_hardpoint_starttime"], "5")
        connection.rcon = lambda command: 'scr_koth_scorelimit "0"\nscr_koth_timelimit "20"\nscr_hardpoint_hilltime "90"\nscr_hardpoint_radius "192"\n'
        settings = controller.settings()
        self.assertEqual(settings["rules"]["koth"]["scoreLimit"], "0")
        self.assertEqual(settings["values"]["scr_hardpoint_hilltime"], "90")
        self.assertEqual(settings["values"]["scr_hardpoint_radius"], "192")

    def test_hardpoint_limits_and_cli(self):
        for key, low, high in (("scr_hardpoint_hilltime", 10, 300), ("scr_hardpoint_radius", 128, 384), ("scr_hardpoint_starttime", 0, 10)):
            for value in (low, high):
                self.assertEqual(cod4ctl.validate_setting(key, value), str(value))
            for value in (low-1, high+1, low+.5, "nan", "inf"):
                with self.assertRaises(cod4ctl.ControlError):
                    cod4ctl.validate_setting(key, value)
        args = cod4ctl.build_parser().parse_args(["hardpoint", "--hill-seconds", "60", "--radius", "128", "--start-seconds", "0"])
        self.assertEqual(args.action, "hardpoint")
        self.assertEqual(args.hill_seconds, "60")
        self.assertEqual(args.start_seconds, "0")

    def test_progression_commands_target_validated_slot(self):
        connection = self.FakeConnection()
        controller = cod4ctl.Controller(connection, ())
        self.assertEqual(
            controller.player_progression(2, "level", 10),
            "Level 10 queued safely. Promotions are rate-limited; level 1 to 55 "
            "takes about 42 seconds.\naccepted",
        )
        controller.player_progression(2, "cac")
        self.assertEqual(
            controller.player_progression(2, "max"),
            "Max-rank repair queued safely. Every unlock tier will be replayed in "
            "about 42 seconds.\naccepted",
        )
        self.assertEqual(
            connection.commands,
            ["cmd setlevel:2:10", "cmd unlockcac:2", "cmd maxrank:2"],
        )
        with self.assertRaises(cod4ctl.ControlError):
            controller.player_progression(200, "max")

    def test_gungame_labels_defaults_and_cli(self):
        for alias in ("gg", "gungame", "gun-game", "sab"):
            self.assertEqual(cod4ctl.normalize_mode(alias), "sab")
        self.assertEqual(cod4ctl.MODE_LABELS["sab"], "Gun Game")
        connection = self.FakeConnection()
        controller = cod4ctl.Controller(connection, ())
        connection.rcon = lambda command: 'scr_sab_scorelimit "1"\nscr_sab_timelimit "20"'
        settings = controller.settings()
        self.assertEqual(settings["rules"]["sab"], {"scoreLimit": "", "timeLimit": "10"})
        self.assertEqual(settings["values"]["scr_gungame_knifesetback"], "1")
        args = cod4ctl.build_parser().parse_args(["gungame", "--kills-per-gun", "2", "--knife-setback", "1"])
        self.assertEqual(args.kills_per_gun, "2")

    def test_gungame_changes_are_validated_and_next_map_only(self):
        connection = self.FakeConnection()
        controller = cod4ctl.Controller(connection, ())
        output = controller.apply_settings({"scr_gungame_kills": 2, "scr_gungame_knifesetback": 1}, "gg", None, 12)
        self.assertEqual(connection.commands, ["set scr_gungame_kills 2", "set scr_gungame_knifesetback 1", "set scr_gungame_timelimit 12"])
        self.assertIn("next full map load", output)
        for values, score in (({"scr_gungame_kills": 0}, None), ({"scr_gungame_kills": 2, "scr_gungame_knifesetback": 6}, None), ({"scr_gungame_kills": 2}, 20)):
            connection.commands.clear()
            with self.assertRaises(cod4ctl.ControlError):
                controller.apply_settings(values, "gg", score, None)
            self.assertEqual(connection.commands, [])

    def test_gungame_rule_limits(self):
        for key, low, high in (("scr_gungame_kills", 1, 5), ("scr_gungame_knifesetback", 0, 5)):
            for value in (low, high):
                self.assertEqual(cod4ctl.validate_setting(key, value), str(value))
            for value in (low-1, high+1, low+.5, "nan", "1;quit"):
                with self.assertRaises(cod4ctl.ControlError):
                    cod4ctl.validate_setting(key, value)
        for value in (-1, 1441, "nan", "inf"):
            with self.assertRaises(cod4ctl.ControlError):
                cod4ctl.validate_setting("scr_gungame_timelimit", value)

    def test_player_power_commands_are_allowlisted(self):
        connection = self.FakeConnection()
        controller = cod4ctl.Controller(connection, ())
        controller.player_power(3, "godmode", "on")
        controller.player_power(3, "aimbot", "off")
        controller.player_power(3, "wallhack", "on")
        self.assertEqual(
            connection.commands,
            [
                "cmd adminpower:3:godmode_on",
                "cmd adminpower:3:aimbot_off",
                "cmd adminpower:3:wallhack_on",
            ],
        )
        with self.assertRaises(cod4ctl.ControlError):
            controller.player_power(3, "godmode;quit", "on")


if __name__ == "__main__":
    unittest.main()
