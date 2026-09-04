#!/usr/bin/env python3
import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).with_name("cod4ctl.py")
SPEC = importlib.util.spec_from_file_location("cod4ctl", MODULE_PATH)
assert SPEC and SPEC.loader
cod4ctl = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cod4ctl)


class ParserTests(unittest.TestCase):
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
        self.assertEqual(cod4ctl.validate_message(" hello\nthere "), "hello there")
        self.assertEqual(cod4ctl.validate_slot("3"), 3)
        self.assertEqual(cod4ctl.validate_level("55"), 55)
        with self.assertRaises(cod4ctl.ControlError):
            cod4ctl.validate_level("56")
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

    def test_progression_commands_target_validated_slot(self):
        connection = self.FakeConnection()
        controller = cod4ctl.Controller(connection, ())
        self.assertEqual(controller.player_progression(2, "level", 10), "accepted")
        controller.player_progression(2, "cac")
        controller.player_progression(2, "max")
        self.assertEqual(
            connection.commands,
            ["cmd setlevel:2:10", "cmd unlockcac:2", "cmd maxrank:2"],
        )
        with self.assertRaises(cod4ctl.ControlError):
            controller.player_progression(200, "max")


if __name__ == "__main__":
    unittest.main()
