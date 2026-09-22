"""Leaderboard ingestion and aggregation over a synthetic engine log and mod journal."""

import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory

from leaderboard import JOURNAL_EPOCH, LeaderboardError, LeaderboardStore, Query, clean_name, weapon_label

START = datetime(2026, 9, 20, 18, 0, 0, tzinfo=timezone.utc)


def init_game(clock: str, gametype: str, game_map: str, at: datetime) -> str:
    stamp = at.strftime("%a %b %d %H:%M:%S %Y")
    return f"{clock} InitGame: \\g_gametype\\{gametype}\\mapname\\{game_map}\\g_mapStartTime\\{stamp}\\g_logTimeStampInSeconds\\0"


def kill(clock: str, victim: str, attacker: str, weapon: str = "ak47_mp", mod: str = "MOD_RIFLE_BULLET",
         hitloc: str = "torso_upper", victim_team: str = "", attacker_team: str = "") -> str:
    return f"{clock} K;0;1;{victim_team};{victim};0;2;{attacker_team};{attacker};{weapon};30;{mod};{hitloc}"


def world_kill(clock: str, victim: str, team: str = "") -> str:
    return f"{clock} D;0;0;{team};{victim};;-1;world;;none;13;MOD_FALLING;none".replace(" D;", " K;", 1)


def journal(kind: str, at: datetime, name: str) -> str:
    seconds = int((at - JOURNAL_EPOCH).total_seconds())
    return f"LB1;{seconds};{kind};pb_77489b99a184110c9b55af134d00dfdd;{name}"


class Fixture:
    def __init__(self) -> None:
        self.directory = TemporaryDirectory()
        root = Path(self.directory.name)
        self.game_log = root / "games_mp.log"
        self.journal = root / "events.log"
        self.game_log.write_text("")
        self.journal.write_text("")
        self.store = LeaderboardStore(game_log=self.game_log, journal=self.journal, database=root / "lb.sqlite")

    def append(self, path: Path, *lines: str) -> None:
        with path.open("a") as handle:
            for line in lines:
                handle.write(line + "\n")

    def close(self) -> None:
        self.directory.cleanup()


class IngestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = Fixture()
        self.addCleanup(self.fixture.close)

    def players(self, **query) -> dict[str, dict[str, object]]:
        snapshot = self.fixture.store.snapshot(Query(**query))
        return {str(row["name"]).lower(): row for row in snapshot["players"]}

    def test_kills_deaths_and_wall_clock_follow_the_server_clock(self) -> None:
        # The log clock counts from server start (here 100:00), the InitGame line pins wall time.
        self.fixture.append(
            self.fixture.game_log,
            init_game("100:00", "dm", "mp_shipment", START),
            "100:05 J;0;1;Josh",
            "100:06 J;0;2;^1Oct^7",
            kill("100:30", "Oct", "Josh", weapon="m40a3_mp", mod="MOD_HEAD_SHOT", hitloc="head"),
            kill("101:00", "Josh", "Oct"),
            kill("101:20", "Oct", "Josh", mod="MOD_MELEE"),
            world_kill("101:40", "Oct"),
            "110:00 ExitLevel: executed",
        )
        players = self.players()
        self.assertEqual(players["josh"]["kills"], 2)
        self.assertEqual(players["josh"]["deaths"], 1)
        self.assertEqual(players["josh"]["headshots"], 1)
        self.assertEqual(players["josh"]["knife"], 1)
        self.assertEqual(players["josh"]["kd"], 2.0)
        self.assertEqual(players["oct"]["deaths"], 3)
        self.assertEqual(players["oct"]["suicides"], 1)
        self.assertEqual(players["oct"]["kills"], 1)
        self.assertEqual(players["josh"]["fav_weapon"], "M40A3")
        self.assertEqual(players["josh"]["playtime_s"], 595)  # joined at +5 s, match ended at +600 s
        self.assertEqual(players["josh"]["last_seen"], (START + timedelta(minutes=10)).isoformat().replace("+00:00", "Z"))

    def test_rounds_of_one_match_stay_one_match(self) -> None:
        self.fixture.append(
            self.fixture.game_log,
            init_game("0:00", "sd", "mp_crash", START),
            kill("0:30", "Oct", "Josh", victim_team="axis", attacker_team="allies"),
            init_game("2:00", "sd", "mp_crash", START + timedelta(minutes=2)),
            kill("2:30", "Oct", "Josh", victim_team="axis", attacker_team="allies"),
            "5:00 ExitLevel: executed",
            init_game("5:10", "sd", "mp_crash", START + timedelta(minutes=5, seconds=10)),
            kill("5:30", "Josh", "Oct", victim_team="allies", attacker_team="axis"),
        )
        players = self.players()
        self.assertEqual(players["josh"]["matches"], 2)
        self.assertEqual(players["josh"]["kills"], 2)
        detail = self.fixture.store.player("josh")
        self.assertEqual([entry["rounds"] for entry in detail["recent"]], [1, 2])

    def test_team_kills_and_suicides_never_count_as_kills(self) -> None:
        self.fixture.append(
            self.fixture.game_log,
            init_game("0:00", "war", "mp_crash", START),
            kill("0:30", "Oct", "Josh", victim_team="allies", attacker_team="allies"),
            kill("0:40", "Josh", "Josh", weapon="frag_grenade_mp", mod="MOD_GRENADE_SPLASH"),
            "1:00 ExitLevel: executed",
        )
        players = self.players()
        self.assertEqual(players["josh"]["kills"], 0)
        self.assertEqual(players["josh"]["teamkills"], 1)
        self.assertEqual(players["josh"]["suicides"], 1)
        self.assertEqual(players["josh"]["deaths"], 1)

    def test_journal_winner_decides_the_team_result(self) -> None:
        self.fixture.append(
            self.fixture.game_log,
            init_game("0:00", "war", "mp_crash", START),
            kill("0:30", "Oct", "Josh", victim_team="axis", attacker_team="allies"),
            kill("0:40", "Gen", "Jc", victim_team="axis", attacker_team="allies"),
            "0:50 Q;0;3;Gen",
            "9:00 ExitLevel: executed",
        )
        self.fixture.append(self.fixture.journal, journal("P", START + timedelta(seconds=10), "Josh"),
                            journal("W", START + timedelta(minutes=9, seconds=5), "Josh"))
        players = self.players()
        self.assertEqual((players["josh"]["wins"], players["josh"]["losses"]), (1, 0))
        self.assertEqual((players["jc"]["wins"], players["jc"]["losses"]), (1, 0), "teammate of the recorded winner wins too")
        self.assertEqual((players["oct"]["wins"], players["oct"]["losses"]), (0, 1))
        self.assertEqual((players["gen"]["wins"], players["gen"]["losses"]), (0, 0), "left long before the end")
        self.assertEqual(players["josh"]["win_pct"], 100)

    def test_free_for_all_winner_makes_everyone_else_lose(self) -> None:
        self.fixture.append(
            self.fixture.game_log,
            init_game("0:00", "dm", "mp_shipment", START),
            kill("0:30", "Oct", "Josh"),
            kill("0:35", "Jc", "Josh"),
            "5:00 ExitLevel: executed",
        )
        self.fixture.append(self.fixture.journal, journal("W", START + timedelta(minutes=5), "Josh"))
        players = self.players()
        self.assertEqual(players["josh"]["wins"], 1)
        self.assertEqual(players["oct"]["losses"], 1)
        self.assertEqual(players["jc"]["losses"], 1)

    def test_ingest_is_incremental_and_survives_a_new_store(self) -> None:
        self.fixture.append(self.fixture.game_log, init_game("0:00", "dm", "mp_shipment", START), kill("0:30", "Oct", "Josh"))
        self.assertEqual(self.players()["josh"]["kills"], 1)
        self.fixture.append(self.fixture.game_log, kill("0:40", "Oct", "Josh"))
        self.fixture.store.ingest(force=True)
        self.assertEqual(self.players()["josh"]["kills"], 2)
        again = LeaderboardStore(game_log=self.fixture.game_log, journal=self.fixture.journal, database=self.fixture.store.database)
        rows = again.snapshot()["players"]
        self.assertEqual(rows[0]["kills"], 2, "a fresh store reads the saved database instead of counting twice")

    def test_filters_hidden_players_and_windows(self) -> None:
        old = START - timedelta(days=40)
        self.fixture.append(
            self.fixture.game_log,
            init_game("0:00", "dm", "mp_shipment", old),
            kill("0:30", "Oct", "Josh"),
            "1:00 ExitLevel: executed",
            init_game("1:10", "war", "mp_crash", datetime.now(timezone.utc) - timedelta(hours=1)),
            kill("1:30", "Josh", "Oct", victim_team="allies", attacker_team="axis"),
            kill("1:40", "Josh", "NativeInputCheck", victim_team="allies", attacker_team="axis"),
            "2:00 ExitLevel: executed",
        )
        self.assertNotIn("nativeinputcheck", self.players())
        self.assertIn("nativeinputcheck", self.players(show_hidden=True))
        self.assertEqual(self.players(window="7d")["oct"]["kills"], 1)
        self.assertNotIn("josh", {name for name, row in self.players(window="7d").items() if row["kills"] > 0})
        self.assertEqual(set(self.players(gametype="dm")), {"josh", "oct"})
        self.assertEqual(set(self.players(map="mp_crash")), {"josh", "oct"})
        self.fixture.store.set_hidden("oct", True, "test")
        self.assertNotIn("oct", self.players())
        self.assertEqual(self.players(search="jo").keys(), {"josh"})
        filters = self.fixture.store.filters()
        self.assertEqual({entry["id"] for entry in filters["gametypes"]}, {"dm", "war"})

    def test_scope_lines_give_hardscope_stats(self) -> None:
        self.fixture.append(
            self.fixture.game_log,
            init_game("0:00", "dm", "mp_shipment", START),
            "0:20 ScopeKill;Josh;m40a3_mp;400",
            kill("0:20", "Oct", "Josh", weapon="m40a3_mp"),
            "0:21 Scope;Josh;m40a3_mp;1200;1",
            "0:40 ScopeKill;Josh;m40a3_mp;2600",
            kill("0:40", "Oct", "Josh", weapon="m40a3_mp"),
            "0:41 Scope;Josh;m40a3_mp;3000;1",
            "0:50 Scope;Josh;m40a3_mp;1800;0",
            kill("0:55", "Oct", "Josh", weapon="ak47_mp"),
            "1:00 ExitLevel: executed",
        )
        josh = self.players()["josh"]
        self.assertEqual(josh["kills"], 3)
        self.assertEqual(josh["sniper_kills"], 2)
        self.assertEqual(josh["scope_sessions"], 3)
        self.assertEqual(josh["scope_total_s"], 6.0)
        self.assertEqual(josh["scope_avg_s"], 2.0)
        self.assertEqual(josh["scope_per_kill_s"], 3.0)
        self.assertEqual((josh["scope_kills"], josh["hardscope_kills"], josh["hardscope_pct"]), (2, 1, 50))
        detail = self.fixture.store.player("josh")
        self.assertEqual(detail["sniping"]["hardscope_kills"], 1)
        self.assertIsNone(self.players()["oct"]["scope_avg_s"])

    def test_reset_forgets_history_and_counts_only_new_maps(self) -> None:
        self.fixture.append(
            self.fixture.game_log,
            init_game("0:00", "dm", "mp_shipment", START),
            kill("0:30", "Oct", "Josh"),
            "1:00 ExitLevel: executed",
        )
        self.fixture.store.set_hidden("nativeinputcheck", True, "harness client")
        self.assertEqual(self.players()["josh"]["kills"], 1)
        result = self.fixture.store.reset()
        self.assertIsNotNone(result["trackingSince"])
        snapshot = self.fixture.store.snapshot()
        self.assertEqual(snapshot["players"], [])
        self.assertEqual(snapshot["totalMatches"], 0)
        self.assertEqual(snapshot["trackingSince"], result["trackingSince"])
        # a map that started before the wipe stays forgotten even when the whole log is re-read
        self.fixture.game_log.write_text(self.fixture.game_log.read_text())
        later = datetime.now(timezone.utc) + timedelta(minutes=1)
        self.fixture.append(
            self.fixture.game_log,
            init_game("5:00", "war", "mp_crash", later),
            kill("5:30", "Josh", "Oct", victim_team="allies", attacker_team="axis"),
        )
        self.fixture.store.ingest(force=True)
        players = self.players()
        self.assertEqual(set(players), {"oct", "josh"})
        self.assertEqual(players["oct"]["kills"], 1)
        self.assertEqual(players["josh"]["kills"], 0)
        self.assertIn("nativeinputcheck", {row["key"] for row in self.fixture.store._connection().execute("SELECT key FROM players WHERE hidden = 1")})

    def test_query_validation(self) -> None:
        with self.assertRaises(LeaderboardError):
            Query.from_params({"window": ["yesterday"]})
        with self.assertRaises(LeaderboardError):
            Query.from_params({"sort": ["; drop table"]})
        with self.assertRaises(LeaderboardError):
            Query.from_params({"map": ["mp_crash; --"]})
        query = Query.from_params({"window": ["7d"], "gametype": ["SD"], "q": ["Josh"], "order": ["asc"], "min_matches": ["3"]})
        self.assertEqual((query.window, query.gametype, query.search, query.descending, query.min_matches), ("7d", "sd", "josh", False, 3))

    def test_names_and_weapons(self) -> None:
        self.assertEqual(clean_name("^1Josh^7 \t"), "Josh")
        self.assertEqual(weapon_label("m40a3_acog_mp"), "M40A3 (ACOG)")
        self.assertEqual(weapon_label("knife"), "KNIFE")


if __name__ == "__main__":
    unittest.main()
