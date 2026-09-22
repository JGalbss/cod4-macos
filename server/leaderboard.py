"""Persistent, name-keyed leaderboard built from the game server's own log.

Identity is the player name. This server runs without GUIDs (sv_authorizemode -1) and every
office install shares one installation key, so anything keyed by GUID collapses into one player.

Sources, both append-only and owned by the game:
  games_mp.log                   engine log: matches (InitGame/ExitLevel), kills, damage, joins, quits
  ne_db/leaderboard/events.log   mod journal: W (won the match) and P (took part), each with a name

Everything lands in one SQLite file. Ingestion is incremental with a saved byte offset per source,
so history survives controller restarts and the first request after a restart is cheap.
"""

from __future__ import annotations

import re
import sqlite3
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

DEFAULT_GAME_LOG = Path("/opt/cod4/mods/new_experience/games_mp.log")
DEFAULT_JOURNAL = Path("/opt/cod4/mods/new_experience/ne_db/leaderboard/events.log")
DEFAULT_DATABASE = Path("/var/lib/cod4-control/leaderboard.sqlite")

JOURNAL_EPOCH = datetime(2012, 1, 1, tzinfo=timezone.utc)  # getRealTime() counts from here
MAX_BATCH_BYTES = 8 * 1024 * 1024
MAX_LINE_BYTES = 2048
MIN_INGEST_INTERVAL = 2.0
WIN_MATCH_TOLERANCE = 180  # seconds a W record may fall outside its match's log window
LEFT_BEFORE_END_GRACE = 90  # a player who quit this close to the end still takes the loss

WINDOWS: dict[str, int | None] = {"all": None, "24h": 86400, "7d": 7 * 86400, "30d": 30 * 86400, "90d": 90 * 86400}
SORTS = (
    "kills", "deaths", "kd", "headshots", "hs_pct", "wins", "losses", "win_pct", "matches",
    "playtime_s", "best_streak", "kpm", "damage", "knife", "explosive", "suicides", "last_seen", "name",
)
TOKEN_RE = re.compile(r"^[a-z0-9_]{1,40}$")
# Harness clients from the engineering lanes; never real players.
DEFAULT_HIDDEN = {
    "nativeinputcheck", "aimbotdummy", "nativejoininitial", "perf250", "motionprobe", "releasesmoke",
    "progressionsavetest", "nativemover", "levelqueuestress", "visiontrace", "packagedobserver",
}
HARNESS_NAME_RE = re.compile(r"^(admin[a-z]+|native[a-z]+|aimbot[a-z]*|perf[0-9]+|[a-z]*probe|[a-z]*harness[a-z]*|[a-z]*verify|[a-z]*tester)$")
TEAM_MODES = {"war", "sd", "dom", "koth", "dem", "ctf", "kc"}
INDIVIDUAL_MODES = {"dm", "sab", "oitc"}
SUICIDE_MODS = {"MOD_SUICIDE", "MOD_FALLING", "MOD_TRIGGER_HURT"}
EXPLOSIVE_MODS = {"MOD_GRENADE", "MOD_GRENADE_SPLASH", "MOD_PROJECTILE", "MOD_PROJECTILE_SPLASH", "MOD_EXPLOSIVE"}

LINE_RE = re.compile(r"^\s*(\d+):(\d{2})\s(.*)$")
COLOR_RE = re.compile(r"\^[0-9]")

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS sources(name TEXT PRIMARY KEY, offset INTEGER NOT NULL, inode INTEGER NOT NULL, partial TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS matches(
  id INTEGER PRIMARY KEY, started_at INTEGER NOT NULL, ended_at INTEGER, base_at INTEGER NOT NULL, base_offset INTEGER NOT NULL DEFAULT 0,
  gametype TEXT NOT NULL, map TEXT NOT NULL, rounds INTEGER NOT NULL DEFAULT 1, closed INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS matches_started ON matches(started_at);
CREATE TABLE IF NOT EXISTS participation(
  match_id INTEGER NOT NULL, key TEXT NOT NULL, name TEXT NOT NULL,
  kills INTEGER NOT NULL DEFAULT 0, deaths INTEGER NOT NULL DEFAULT 0, headshots INTEGER NOT NULL DEFAULT 0,
  suicides INTEGER NOT NULL DEFAULT 0, teamkills INTEGER NOT NULL DEFAULT 0, knife INTEGER NOT NULL DEFAULT 0,
  explosive INTEGER NOT NULL DEFAULT 0, damage INTEGER NOT NULL DEFAULT 0,
  streak INTEGER NOT NULL DEFAULT 0, best_streak INTEGER NOT NULL DEFAULT 0,
  joined_at INTEGER, left_at INTEGER, seconds INTEGER NOT NULL DEFAULT 0, present INTEGER NOT NULL DEFAULT 1,
  team TEXT NOT NULL DEFAULT '', result TEXT, PRIMARY KEY(match_id, key));
CREATE INDEX IF NOT EXISTS participation_key ON participation(key);
CREATE TABLE IF NOT EXISTS weapon_kills(match_id INTEGER NOT NULL, key TEXT NOT NULL, weapon TEXT NOT NULL, kills INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(match_id, key, weapon));
CREATE TABLE IF NOT EXISTS kill_pairs(killer TEXT NOT NULL, victim TEXT NOT NULL, kills INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(killer, victim));
CREATE TABLE IF NOT EXISTS players(key TEXT PRIMARY KEY, name TEXT NOT NULL, first_seen INTEGER, last_seen INTEGER, hidden INTEGER NOT NULL DEFAULT 0, note TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS journal(id INTEGER PRIMARY KEY, at INTEGER NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL, name TEXT NOT NULL, match_id INTEGER);
"""


class LeaderboardError(RuntimeError):
    """An error whose message is safe to return through the public API."""


@dataclass(frozen=True)
class Query:
    window: str = "all"
    gametype: str = ""
    map: str = ""
    search: str = ""
    sort: str = "kills"
    descending: bool = True
    min_matches: int = 1
    show_hidden: bool = False

    @staticmethod
    def from_params(params: dict[str, list[str]]) -> "Query":
        def first(name: str, default: str = "") -> str:
            values = params.get(name)
            return values[0] if values else default

        window = first("window", "all")
        if window not in WINDOWS:
            raise LeaderboardError("window must be one of " + ", ".join(WINDOWS))
        gametype = first("gametype").lower()
        game_map = first("map").lower()
        for token in (gametype, game_map):
            if token and not TOKEN_RE.fullmatch(token):
                raise LeaderboardError("filters may only contain letters, digits and underscores")
        sort = first("sort", "kills")
        if sort not in SORTS:
            raise LeaderboardError("sort must be one of " + ", ".join(SORTS))
        order = first("order", "desc")
        if order not in ("asc", "desc"):
            raise LeaderboardError("order must be asc or desc")
        raw_minimum = first("min_matches", "1")
        if not re.fullmatch(r"[0-9]{1,4}", raw_minimum):
            raise LeaderboardError("min_matches must be a whole number")
        return Query(
            window=window, gametype=gametype, map=game_map, search=first("q")[:40].strip().lower(),
            sort=sort, descending=order == "desc", min_matches=int(raw_minimum),
            show_hidden=first("hidden", "0") == "1",
        )


def clean_name(raw: str) -> str:
    text = COLOR_RE.sub("", raw).replace("\t", " ").replace("\r", " ").replace("\n", " ")
    text = "".join(char for char in text if char.isprintable()).strip()
    return text[:32] or "unnamed"


def player_key(raw: str) -> str:
    return clean_name(raw).lower()


def iso(seconds: int | None) -> str | None:
    if seconds is None:
        return None
    return datetime.fromtimestamp(seconds, timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def weapon_label(weapon: str) -> str:
    if weapon in ("", "none"):
        return "—"
    name = weapon[:-3] if weapon.endswith("_mp") else weapon
    name = re.sub(r"_(acog|reflex|silencer|gl|grip)$", r" (\1)", name)
    return name.replace("_", " ").upper()


def parse_info_string(text: str) -> dict[str, str]:
    parts = text.split("\\")
    if parts and parts[0] == "":
        parts = parts[1:]
    return {parts[index]: parts[index + 1] for index in range(0, len(parts) - 1, 2)}


def parse_map_start(text: str) -> int | None:
    try:
        return int(datetime.strptime(text, "%a %b %d %H:%M:%S %Y").replace(tzinfo=timezone.utc).timestamp())
    except ValueError:
        return None


def ratio(numerator: int, denominator: int, digits: int = 2) -> float | None:
    if denominator == 0:
        return None
    return round(numerator / denominator, digits)


class LeaderboardStore:
    def __init__(self, *, game_log: Path = DEFAULT_GAME_LOG, journal: Path = DEFAULT_JOURNAL,
                 database: Path | str = DEFAULT_DATABASE):
        self.game_log = Path(game_log)
        self.journal = Path(journal)
        self.database = database
        self._lock = threading.RLock()
        self._db: sqlite3.Connection | None = None
        self._last_ingest = 0.0
        self._warning: str | None = None
        self._thread: threading.Thread | None = None

    # ------------------------------------------------------------------ lifecycle

    def start(self, interval: float = 5.0) -> None:
        """Ingest in the background so requests never wait on a large catch-up."""
        if self._thread is not None:
            return

        def loop() -> None:
            while True:
                try:
                    self.ingest()
                except Exception as error:  # noqa: BLE001 - the panel must keep serving
                    with self._lock:
                        self._warning = f"Leaderboard ingest paused: {error}"
                time.sleep(interval)

        self._thread = threading.Thread(target=loop, name="leaderboard-ingest", daemon=True)
        self._thread.start()

    def _connection(self) -> sqlite3.Connection:
        if self._db is None:
            target = str(self.database)
            if target != ":memory:":
                Path(target).parent.mkdir(parents=True, exist_ok=True)
            self._db = sqlite3.connect(target, check_same_thread=False, isolation_level=None)
            self._db.row_factory = sqlite3.Row
            self._db.execute("PRAGMA journal_mode=WAL")
            self._db.execute("PRAGMA synchronous=NORMAL")
            self._db.executescript(SCHEMA)
        return self._db

    # ------------------------------------------------------------------ ingestion

    def ingest(self, force: bool = False) -> None:
        with self._lock:
            if not force and time.monotonic() - self._last_ingest < MIN_INGEST_INTERVAL:
                return
            db = self._connection()
            db.execute("BEGIN")
            try:
                for line in self._new_lines(db, "game_log", self.game_log):
                    self._game_line(db, line)
                for line in self._new_lines(db, "journal", self.journal):
                    self._journal_line(db, line)
                db.execute("COMMIT")
            except Exception:
                db.execute("ROLLBACK")
                raise
            self._last_ingest = time.monotonic()
            self._warning = None

    def _new_lines(self, db: sqlite3.Connection, name: str, path: Path) -> list[str]:
        try:
            stat = path.stat()
        except FileNotFoundError:
            return []
        row = db.execute("SELECT offset, inode, partial FROM sources WHERE name = ?", (name,)).fetchone()
        offset, partial = (row["offset"], row["partial"]) if row else (0, "")
        if row is None or row["inode"] != stat.st_ino or stat.st_size < offset:
            # A new or truncated file: earlier bytes are gone, so nothing already counted repeats.
            offset, partial = 0, ""
            if name == "game_log":
                db.execute("DELETE FROM meta WHERE key = 'open_match'")
        if stat.st_size == offset:
            if row is None:
                db.execute("INSERT INTO sources(name, offset, inode, partial) VALUES(?, ?, ?, '')", (name, offset, stat.st_ino))
            return []
        with path.open("rb") as source:
            source.seek(offset)
            data = source.read(min(MAX_BATCH_BYTES, stat.st_size - offset))
        text = partial + data.decode("utf-8", errors="replace")
        lines = text.split("\n")
        partial = lines.pop()
        if len(partial) > MAX_LINE_BYTES:
            partial = ""
        db.execute(
            "INSERT INTO sources(name, offset, inode, partial) VALUES(?, ?, ?, ?) "
            "ON CONFLICT(name) DO UPDATE SET offset = excluded.offset, inode = excluded.inode, partial = excluded.partial",
            (name, offset + len(data), stat.st_ino, partial),
        )
        return [line for line in lines if line.strip()]

    # ---- engine log

    def _open_match(self, db: sqlite3.Connection) -> sqlite3.Row | None:
        row = db.execute("SELECT value FROM meta WHERE key = 'open_match'").fetchone()
        if row is None:
            return None
        return db.execute("SELECT * FROM matches WHERE id = ?", (int(row["value"]),)).fetchone()

    def _game_line(self, db: sqlite3.Connection, line: str) -> None:
        found = LINE_RE.match(line)
        if found is None:
            return
        minutes, seconds, body = int(found.group(1)), int(found.group(2)), found.group(3)
        offset = minutes * 60 + seconds
        if body.startswith("InitGame:"):
            self._init_game(db, parse_info_string(body[len("InitGame:"):].strip()), offset)
            return
        match = self._open_match(db)
        if match is None:
            return
        # The log clock counts from server start; the InitGame line pins it to wall-clock time.
        at = match["base_at"] + max(0, offset - match["base_offset"])
        if body.startswith("ExitLevel:"):
            self._close_match(db, match, at)
            return
        fields = body.split(";")
        kind = fields[0]
        if kind == "K" and len(fields) >= 13:
            self._kill(db, match["id"], at, fields)
        elif kind == "D" and len(fields) >= 13:
            self._damage(db, match["id"], at, fields)
        elif kind == "J" and len(fields) >= 4:
            self._join(db, match["id"], at, fields[3])
        elif kind == "Q" and len(fields) >= 4:
            self._quit(db, match["id"], at, fields[3])

    def _init_game(self, db: sqlite3.Connection, info: dict[str, str], offset: int) -> None:
        base_at = parse_map_start(info.get("g_mapStartTime", ""))
        gametype = info.get("g_gametype", "").lower()
        game_map = info.get("mapname", "").lower()
        if base_at is None or not gametype or not game_map:
            return
        current = self._open_match(db)
        if current is not None and not current["closed"] and current["gametype"] == gametype and current["map"] == game_map:
            # A round restart (Search and Destroy rounds, "restart round" from the panel) keeps the match.
            db.execute("UPDATE matches SET rounds = rounds + 1, base_at = ?, base_offset = ? WHERE id = ?", (base_at, offset, current["id"]))
            return
        if current is not None:
            self._close_match(db, current, max(current["started_at"], base_at - 1))
        cursor = db.execute(
            "INSERT INTO matches(started_at, base_at, base_offset, gametype, map) VALUES(?, ?, ?, ?, ?)",
            (base_at, base_at, offset, gametype, game_map),
        )
        db.execute("INSERT INTO meta(key, value) VALUES('open_match', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", (str(cursor.lastrowid),))

    def _close_match(self, db: sqlite3.Connection, match: sqlite3.Row, ended_at: int) -> None:
        if match["closed"]:
            return
        ended_at = max(ended_at, match["started_at"])
        db.execute(
            "UPDATE participation SET seconds = seconds + MAX(0, ? - COALESCE(joined_at, ?)), present = 0, left_at = ? "
            "WHERE match_id = ? AND present = 1",
            (ended_at, ended_at, ended_at, match["id"]),
        )
        db.execute("UPDATE matches SET ended_at = ?, closed = 1 WHERE id = ?", (ended_at, match["id"]))
        db.execute("DELETE FROM meta WHERE key = 'open_match'")
        self._assign_results(db, match["id"])

    def _touch(self, db: sqlite3.Connection, match_id: int, at: int, raw_name: str, team: str = "") -> str:
        """Make sure the player has a row in this match and in the roster; return the key."""
        name = clean_name(raw_name)
        key = name.lower()
        db.execute(
            "INSERT INTO participation(match_id, key, name, joined_at, present) VALUES(?, ?, ?, ?, 1) "
            "ON CONFLICT(match_id, key) DO UPDATE SET name = excluded.name, "
            "joined_at = COALESCE(participation.joined_at, excluded.joined_at), "
            "present = CASE WHEN participation.present = 0 AND participation.left_at IS NOT NULL AND participation.joined_at IS NOT NULL THEN participation.present ELSE 1 END",
            (match_id, key, name, at),
        )
        if team in ("allies", "axis"):
            db.execute("UPDATE participation SET team = ? WHERE match_id = ? AND key = ? AND team != ?", (team, match_id, key, team))
        hidden = 1 if key in DEFAULT_HIDDEN or HARNESS_NAME_RE.fullmatch(key) else 0
        db.execute(
            "INSERT INTO players(key, name, first_seen, last_seen, hidden, note) VALUES(?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(key) DO UPDATE SET name = excluded.name, last_seen = MAX(players.last_seen, excluded.last_seen)",
            (key, name, at, at, hidden, "harness client" if hidden else ""),
        )
        return key

    def _join(self, db: sqlite3.Connection, match_id: int, at: int, raw_name: str) -> None:
        key = self._touch(db, match_id, at, raw_name)
        db.execute(
            "UPDATE participation SET present = 1, joined_at = CASE WHEN present = 0 OR joined_at IS NULL THEN ? ELSE joined_at END "
            "WHERE match_id = ? AND key = ?",
            (at, match_id, key),
        )

    def _quit(self, db: sqlite3.Connection, match_id: int, at: int, raw_name: str) -> None:
        key = self._touch(db, match_id, at, raw_name)
        db.execute(
            "UPDATE participation SET seconds = seconds + MAX(0, ? - COALESCE(joined_at, ?)), present = 0, left_at = ?, streak = 0 "
            "WHERE match_id = ? AND key = ? AND present = 1",
            (at, at, at, match_id, key),
        )

    def _kill(self, db: sqlite3.Connection, match_id: int, at: int, fields: list[str]) -> None:
        victim_team, victim_name = fields[3], fields[4]
        attacker_num, attacker_team, attacker_name = fields[6], fields[7], fields[8]
        weapon, mod, hitloc = fields[9], fields[11], fields[12]
        if not victim_name:
            return
        victim = self._touch(db, match_id, at, victim_name, victim_team)
        db.execute("UPDATE participation SET deaths = deaths + 1, streak = 0 WHERE match_id = ? AND key = ?", (match_id, victim))
        environmental = not attacker_name or attacker_num == "-1" or attacker_name == "world"
        if environmental or mod in SUICIDE_MODS:
            db.execute("UPDATE participation SET suicides = suicides + 1 WHERE match_id = ? AND key = ?", (match_id, victim))
            return
        attacker = self._touch(db, match_id, at, attacker_name, attacker_team)
        if attacker == victim:
            db.execute("UPDATE participation SET suicides = suicides + 1 WHERE match_id = ? AND key = ?", (match_id, victim))
            return
        team_mode = victim_team in ("allies", "axis") and attacker_team in ("allies", "axis")
        if team_mode and victim_team == attacker_team:
            db.execute("UPDATE participation SET teamkills = teamkills + 1 WHERE match_id = ? AND key = ?", (match_id, attacker))
            return
        headshot = 1 if mod == "MOD_HEAD_SHOT" or hitloc == "head" else 0
        knife = 1 if mod == "MOD_MELEE" else 0
        explosive = 1 if mod in EXPLOSIVE_MODS else 0
        db.execute(
            "UPDATE participation SET kills = kills + 1, headshots = headshots + ?, knife = knife + ?, explosive = explosive + ?, "
            "streak = streak + 1, best_streak = MAX(best_streak, streak + 1) WHERE match_id = ? AND key = ?",
            (headshot, knife, explosive, match_id, attacker),
        )
        weapon_key = "knife" if knife else weapon
        db.execute(
            "INSERT INTO weapon_kills(match_id, key, weapon, kills) VALUES(?, ?, ?, 1) "
            "ON CONFLICT(match_id, key, weapon) DO UPDATE SET kills = kills + 1",
            (match_id, attacker, weapon_key),
        )
        db.execute(
            "INSERT INTO kill_pairs(killer, victim, kills) VALUES(?, ?, 1) ON CONFLICT(killer, victim) DO UPDATE SET kills = kills + 1",
            (attacker, victim),
        )

    def _damage(self, db: sqlite3.Connection, match_id: int, at: int, fields: list[str]) -> None:
        victim_team, victim_name = fields[3], fields[4]
        attacker_num, attacker_team, attacker_name = fields[6], fields[7], fields[8]
        if not attacker_name or attacker_num == "-1" or attacker_name == "world" or not victim_name:
            return
        if not re.fullmatch(r"-?[0-9]{1,6}", fields[10]):
            return
        attacker = self._touch(db, match_id, at, attacker_name, attacker_team)
        if attacker == player_key(victim_name):
            return
        if victim_team in ("allies", "axis") and victim_team == attacker_team:
            return
        db.execute("UPDATE participation SET damage = damage + ? WHERE match_id = ? AND key = ?", (max(0, int(fields[10])), match_id, attacker))

    def _assign_results(self, db: sqlite3.Connection, match_id: int) -> None:
        """Spread the journal's winners over the match once it is closed.

        The journal only names players with a valid identity, so in a team mode the one named
        winner decides the result for everyone still on a team at the end. In an individual mode
        every other player present at the end lost. Otherwise only journaled participants take a loss.
        """
        match = db.execute("SELECT * FROM matches WHERE id = ?", (match_id,)).fetchone()
        if match is None or not match["closed"]:
            return
        winners = db.execute("SELECT team FROM participation WHERE match_id = ? AND result = 'win'", (match_id,)).fetchall()
        if not winners:
            return
        at_end = "(left_at IS NULL OR left_at >= ?)"
        cutoff = match["ended_at"] - LEFT_BEFORE_END_GRACE
        teams = {row["team"] for row in winners if row["team"] in ("allies", "axis")}
        if match["gametype"] in TEAM_MODES and len(teams) == 1:
            team = teams.pop()
            db.execute(f"UPDATE participation SET result = 'win' WHERE match_id = ? AND result IS NULL AND team = ? AND {at_end}", (match_id, team, cutoff))
            db.execute(f"UPDATE participation SET result = 'loss' WHERE match_id = ? AND result IS NULL AND team IN ('allies', 'axis') AND team != ? AND {at_end}", (match_id, team, cutoff))
            return
        if match["gametype"] in INDIVIDUAL_MODES:
            db.execute(f"UPDATE participation SET result = 'loss' WHERE match_id = ? AND result IS NULL AND {at_end}", (match_id, cutoff))
            return
        db.execute(
            f"UPDATE participation SET result = 'loss' WHERE match_id = ? AND result IS NULL AND {at_end} "
            "AND key IN (SELECT key FROM journal WHERE match_id = ? AND kind = 'P')",
            (match_id, cutoff, match_id),
        )

    # ---- mod journal

    def _journal_line(self, db: sqlite3.Connection, line: str) -> None:
        parts = line.split(";")
        if len(parts) != 5 or parts[0] != "LB1" or not re.fullmatch(r"[0-9]{1,10}", parts[1]):
            return
        kind, raw_name = parts[2], parts[4]
        if kind not in ("W", "P"):
            return
        at = int((JOURNAL_EPOCH + timedelta(seconds=int(parts[1]))).timestamp())
        name = clean_name(raw_name)
        key = name.lower()
        match = db.execute(
            "SELECT * FROM matches WHERE started_at - ? <= ? AND (ended_at IS NULL OR ended_at + ? >= ?) ORDER BY started_at DESC LIMIT 1",
            (WIN_MATCH_TOLERANCE, at, WIN_MATCH_TOLERANCE, at),
        ).fetchone()
        match_id = match["id"] if match is not None else None
        db.execute("INSERT INTO journal(at, kind, key, name, match_id) VALUES(?, ?, ?, ?, ?)", (at, kind, key, name, match_id))
        if match is None:
            return
        self._touch(db, match["id"], at, name)
        if kind == "W":
            db.execute("UPDATE participation SET result = 'win' WHERE match_id = ? AND key = ?", (match["id"], key))
            self._assign_results(db, match["id"])

    # ------------------------------------------------------------------ roster flags

    def set_hidden(self, key: str, hidden: bool, note: str = "") -> None:
        key = key.lower().strip()
        if not key or len(key) > 32:
            raise LeaderboardError("unknown player")
        with self._lock:
            db = self._connection()
            db.execute(
                "INSERT INTO players(key, name, hidden, note) VALUES(?, ?, ?, ?) "
                "ON CONFLICT(key) DO UPDATE SET hidden = excluded.hidden, note = excluded.note",
                (key, key, 1 if hidden else 0, note if hidden else ""),
            )

    def mark_bot(self, name: str) -> None:
        """Josh bots added from the panel are hidden from the human table."""
        self.set_hidden(player_key(name), True, "bot")

    # ------------------------------------------------------------------ reads

    def _scope(self, query: Query) -> tuple[str, list[object]]:
        clauses, values = [], []
        span = WINDOWS[query.window]
        if span is not None:
            clauses.append("COALESCE(m.ended_at, m.started_at) >= ?")
            values.append(int(time.time()) - span)
        if query.gametype:
            clauses.append("m.gametype = ?")
            values.append(query.gametype)
        if query.map:
            clauses.append("m.map = ?")
            values.append(query.map)
        return (" AND ".join(clauses) if clauses else "1=1"), values

    def snapshot(self, query: Query | None = None) -> dict[str, object]:
        query = query or Query()
        with self._lock:
            try:
                self.ingest()
            except Exception as error:  # noqa: BLE001 - serve the last good state
                self._warning = f"Leaderboard ingest paused: {error}"
            db = self._connection()
            scope, values = self._scope(query)
            rows = db.execute(
                f"""
                SELECT p.key, SUM(p.kills) kills, SUM(p.deaths) deaths, SUM(p.headshots) headshots, SUM(p.suicides) suicides,
                       SUM(p.teamkills) teamkills, SUM(p.knife) knife, SUM(p.explosive) explosive, SUM(p.damage) damage,
                       MAX(p.best_streak) best_streak, SUM(p.seconds) seconds, COUNT(*) matches,
                       SUM(CASE WHEN p.result = 'win' THEN 1 ELSE 0 END) wins, SUM(CASE WHEN p.result = 'loss' THEN 1 ELSE 0 END) losses,
                       MIN(m.started_at) first_at, MAX(COALESCE(m.ended_at, m.started_at)) last_at
                FROM participation p JOIN matches m ON m.id = p.match_id
                WHERE {scope}
                GROUP BY p.key
                """,
                values,
            ).fetchall()
            weapons = self._favourite_weapons(db, scope, values)
            roster = {row["key"]: row for row in db.execute("SELECT * FROM players").fetchall()}
            totals = db.execute(f"SELECT COUNT(*) matches FROM matches m WHERE {scope}", values).fetchone()
            first_match = db.execute("SELECT MIN(started_at) FROM matches").fetchone()[0]
            warning = self._warning
        players = []
        for row in rows:
            player = roster.get(row["key"])
            hidden = bool(player["hidden"]) if player else False
            if hidden and not query.show_hidden:
                continue
            if row["matches"] < query.min_matches:
                continue
            if row["kills"] + row["deaths"] == 0 and not query.show_hidden:
                continue
            name = player["name"] if player else row["key"]
            if query.search and query.search not in name.lower():
                continue
            kills, deaths = row["kills"], row["deaths"]
            decided = row["wins"] + row["losses"]
            players.append({
                "key": row["key"], "name": name, "hidden": hidden, "note": player["note"] if player else "",
                "kills": kills, "deaths": deaths, "kd": ratio(kills, deaths),
                "headshots": row["headshots"], "hs_pct": ratio(100 * row["headshots"], kills, 0),
                "suicides": row["suicides"], "teamkills": row["teamkills"], "knife": row["knife"], "explosive": row["explosive"],
                "damage": row["damage"], "best_streak": row["best_streak"],
                "wins": row["wins"], "losses": row["losses"], "win_pct": ratio(100 * row["wins"], decided, 0),
                "matches": row["matches"], "playtime_s": row["seconds"],
                "kpm": ratio(60 * kills, row["seconds"], 2) if row["seconds"] >= 60 else None,
                "fav_weapon": weapons.get(row["key"], "—"),
                "first_seen": iso(row["first_at"]), "last_seen": iso(row["last_at"]),
            })
        players.sort(key=lambda entry: self._sort_value(entry, query.sort), reverse=query.descending)
        for rank, entry in enumerate(players, 1):
            entry["rank"] = rank
        return {
            "players": players,
            "totalPlayers": len(players),
            "totalMatches": totals["matches"],
            "trackingSince": iso(first_match),
            "updatedAt": iso(int(time.time())),
            "warning": warning,
            "query": {"window": query.window, "gametype": query.gametype, "map": query.map, "q": query.search,
                      "sort": query.sort, "order": "desc" if query.descending else "asc",
                      "min_matches": query.min_matches, "hidden": query.show_hidden},
        }

    @staticmethod
    def _sort_value(entry: dict[str, object], sort: str) -> tuple[object, ...]:
        if sort == "name":
            return (str(entry["name"]).lower(),)
        if sort == "last_seen":
            return (str(entry["last_seen"] or ""),)
        value = entry.get(sort)
        primary = float(value) if isinstance(value, (int, float)) else -1.0
        # Undefined ratios (0 deaths, no decided matches) sink below real numbers; ties break on kills.
        return (primary, float(entry["kills"]))

    def _favourite_weapons(self, db: sqlite3.Connection, scope: str, values: list[object]) -> dict[str, str]:
        rows = db.execute(
            f"""
            SELECT w.key, w.weapon, SUM(w.kills) kills FROM weapon_kills w JOIN matches m ON m.id = w.match_id
            WHERE {scope} GROUP BY w.key, w.weapon ORDER BY kills DESC, (w.weapon = 'knife') ASC, w.weapon ASC
            """,
            values,
        ).fetchall()
        favourites: dict[str, str] = {}
        for row in rows:
            favourites.setdefault(row["key"], weapon_label(row["weapon"]))
        return favourites

    def filters(self) -> dict[str, object]:
        with self._lock:
            db = self._connection()
            gametypes = db.execute("SELECT gametype, COUNT(*) n FROM matches GROUP BY gametype ORDER BY n DESC").fetchall()
            maps = db.execute("SELECT map, COUNT(*) n FROM matches GROUP BY map ORDER BY n DESC").fetchall()
            span = db.execute("SELECT MIN(started_at) first_at, MAX(COALESCE(ended_at, started_at)) last_at FROM matches").fetchone()
        return {
            "windows": list(WINDOWS),
            "gametypes": [{"id": row["gametype"], "matches": row["n"]} for row in gametypes],
            "maps": [{"id": row["map"], "matches": row["n"]} for row in maps],
            "sorts": list(SORTS),
            "firstMatch": iso(span["first_at"]),
            "lastMatch": iso(span["last_at"]),
        }

    def player(self, key: str, query: Query | None = None) -> dict[str, object]:
        query = query or Query()
        key = key.lower().strip()
        if not key or len(key) > 32:
            raise LeaderboardError("unknown player")
        with self._lock:
            db = self._connection()
            roster = db.execute("SELECT * FROM players WHERE key = ?", (key,)).fetchone()
            if roster is None:
                raise LeaderboardError("unknown player")
            scope, values = self._scope(query)
            by_mode = db.execute(
                f"""
                SELECT m.gametype id, COUNT(*) matches, SUM(p.kills) kills, SUM(p.deaths) deaths,
                       SUM(CASE WHEN p.result = 'win' THEN 1 ELSE 0 END) wins, SUM(CASE WHEN p.result = 'loss' THEN 1 ELSE 0 END) losses
                FROM participation p JOIN matches m ON m.id = p.match_id WHERE p.key = ? AND {scope}
                GROUP BY m.gametype ORDER BY matches DESC
                """,
                [key, *values],
            ).fetchall()
            by_map = db.execute(
                f"""
                SELECT m.map id, COUNT(*) matches, SUM(p.kills) kills, SUM(p.deaths) deaths,
                       SUM(CASE WHEN p.result = 'win' THEN 1 ELSE 0 END) wins, SUM(CASE WHEN p.result = 'loss' THEN 1 ELSE 0 END) losses
                FROM participation p JOIN matches m ON m.id = p.match_id WHERE p.key = ? AND {scope}
                GROUP BY m.map ORDER BY matches DESC LIMIT 10
                """,
                [key, *values],
            ).fetchall()
            weapons = db.execute(
                f"""
                SELECT w.weapon, SUM(w.kills) kills FROM weapon_kills w JOIN matches m ON m.id = w.match_id
                WHERE w.key = ? AND {scope} GROUP BY w.weapon ORDER BY kills DESC LIMIT 8
                """,
                [key, *values],
            ).fetchall()
            recent = db.execute(
                f"""
                SELECT m.started_at, m.ended_at, m.gametype, m.map, m.rounds, p.kills, p.deaths, p.headshots, p.best_streak, p.seconds, p.result
                FROM participation p JOIN matches m ON m.id = p.match_id WHERE p.key = ? AND {scope}
                ORDER BY m.started_at DESC LIMIT 15
                """,
                [key, *values],
            ).fetchall()
            nemeses = db.execute(
                "SELECT k.killer key, COALESCE(pl.name, k.killer) name, k.kills FROM kill_pairs k LEFT JOIN players pl ON pl.key = k.killer "
                "WHERE k.victim = ? ORDER BY k.kills DESC LIMIT 3",
                (key,),
            ).fetchall()
            victims = db.execute(
                "SELECT k.victim key, COALESCE(pl.name, k.victim) name, k.kills FROM kill_pairs k LEFT JOIN players pl ON pl.key = k.victim "
                "WHERE k.killer = ? ORDER BY k.kills DESC LIMIT 3",
                (key,),
            ).fetchall()

        def breakdown(rows: list[sqlite3.Row]) -> list[dict[str, object]]:
            return [{"id": row["id"], "matches": row["matches"], "kills": row["kills"], "deaths": row["deaths"],
                     "kd": ratio(row["kills"], row["deaths"]), "wins": row["wins"], "losses": row["losses"]} for row in rows]

        return {
            "key": key, "name": roster["name"], "hidden": bool(roster["hidden"]), "note": roster["note"],
            "firstSeen": iso(roster["first_seen"]), "lastSeen": iso(roster["last_seen"]),
            "byGametype": breakdown(by_mode), "byMap": breakdown(by_map),
            "weapons": [{"weapon": weapon_label(row["weapon"]), "kills": row["kills"]} for row in weapons],
            "nemeses": [{"key": row["key"], "name": row["name"], "kills": row["kills"]} for row in nemeses],
            "victims": [{"key": row["key"], "name": row["name"], "kills": row["kills"]} for row in victims],
            "recent": [{
                "startedAt": iso(row["started_at"]), "endedAt": iso(row["ended_at"]), "gametype": row["gametype"], "map": row["map"],
                "rounds": row["rounds"], "kills": row["kills"], "deaths": row["deaths"], "headshots": row["headshots"],
                "bestStreak": row["best_streak"], "seconds": row["seconds"], "result": row["result"],
            } for row in recent],
        }
