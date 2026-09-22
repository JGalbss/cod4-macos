#!/usr/bin/env python3
"""Let a kill streak survive Search and Destroy round restarts.

The mod zeroes cur_kill_streak on every spawn, and a Search and Destroy round restart
respawns everyone, so a 4-streak at the end of round 1 was worth nothing in round 2.
This patch keeps the streak of a player who is still alive when the round ends:

  - every increment stores the streak in game["carriedStreak"][<client slot>]
    (game[] survives map_restart and is fresh on a new map, so a new match starts at 0);
  - a death clears it, a disconnect clears the slot, and spawnPlayer restores it,
    logging "StreakCarry;<name>;<streak>" to the game log when it carries a streak.

Apply to the mod's maps/mp/gametypes/_globallogic.gsx:

    python3 patch-streak-carry.py /opt/cod4/mods/new_experience/maps/mp/gametypes/_globallogic.gsx

The patch is idempotent. Reward kills counting toward the next streak is a dvar, not a
patch: set hardpoint_streak "1" in new_exp_config.cfg.
"""
import sys
from pathlib import Path

MARKER = 'game["carriedStreak"]'

SPAWN_OLD = "\tself.cur_kill_streak = 0;\n\tself.cur_death_streak = 0;\n"
SPAWN_NEW = (
    "\tself.cur_kill_streak = self carriedStreak();\n"
    '\tif ( self.cur_kill_streak > 0 ) logPrint( "StreakCarry;" + self.name + ";" + self.cur_kill_streak + "\\n" );\n'
    "\tself.cur_death_streak = 0;\n"
)
TEAMKILL_RESET_OLD = (
    "\t\tif ( isPlayer( attacker ) && level.teamBased && ( attacker != self ) && ( self.pers[\"team\"] == attacker.pers[\"team\"] ) )\n"
    "\t\t{\n"
    "\t\t\tself.cur_kill_streak = 0;\n"
    "\t\t}\n"
)
TEAMKILL_RESET_NEW = (
    "\t\tif ( isPlayer( attacker ) && level.teamBased && ( attacker != self ) && ( self.pers[\"team\"] == attacker.pers[\"team\"] ) )\n"
    "\t\t{\n"
    "\t\t\tself.cur_kill_streak = 0;\n"
    "\t\t\tself storeCarriedStreak();\n"
    "\t\t}\n"
)
DEATH_RESET_OLD = (
    "\t\t\tself.cur_kill_streak = 0;\n"
    "\t\t\tself.cur_death_streak++;\n"
)
DEATH_RESET_NEW = (
    "\t\t\tself.cur_kill_streak = 0;\n"
    "\t\t\tself storeCarriedStreak();\n"
    "\t\t\tself.cur_death_streak++;\n"
)
INCREMENT_OLD = "\t\t\t\t\t\tattacker.cur_kill_streak++;\n"
INCREMENT_NEW = "\t\t\t\t\t\tattacker.cur_kill_streak++;\n\t\t\t\t\t\tattacker storeCarriedStreak();\n"
DISCONNECT_OLD = "Callback_PlayerDisconnect()\n{\n\tself removePlayerOnDisconnect();\n"
DISCONNECT_NEW = "Callback_PlayerDisconnect()\n{\n\tself removePlayerOnDisconnect();\n\tself clearCarriedStreak();\n"
HELPERS = '''
// A kill streak lives in game[] under the client slot so it survives a Search and Destroy
// round restart (game[] does) and starts over on a new map (game[] does not). A death or a
// disconnect clears the slot.
carriedStreak()
{
	if ( !isDefined( game["carriedStreak"] ) ) game["carriedStreak"] = [];
	slot = self getEntityNumber();
	if ( !isDefined( game["carriedStreak"][slot] ) ) return 0;
	return game["carriedStreak"][slot];
}

storeCarriedStreak()
{
	if ( !isDefined( game["carriedStreak"] ) ) game["carriedStreak"] = [];
	game["carriedStreak"][self getEntityNumber()] = self.cur_kill_streak;
}

clearCarriedStreak()
{
	if ( !isDefined( game["carriedStreak"] ) ) return;
	game["carriedStreak"][self getEntityNumber()] = 0;
}
'''


def patch(source: str) -> str:
    if MARKER in source:
        return source
    for old, new, count in (
        (SPAWN_OLD, SPAWN_NEW, 1),
        (TEAMKILL_RESET_OLD, TEAMKILL_RESET_NEW, 1),
        (DEATH_RESET_OLD, DEATH_RESET_NEW, 1),
        (INCREMENT_OLD, INCREMENT_NEW, 2),
        (DISCONNECT_OLD, DISCONNECT_NEW, 1),
    ):
        if source.count(old) != count:
            raise ValueError(f"expected {count} match(es) for {old.strip().splitlines()[0]!r}, found {source.count(old)}")
        source = source.replace(old, new)
    return source.rstrip("\n") + "\n" + HELPERS


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__)
        return 2
    path = Path(argv[1])
    original = path.read_text(errors="replace")
    patched = patch(original)
    if patched == original:
        print(f"{path}: already patched")
        return 0
    backup = path.with_suffix(path.suffix + ".before-streak-carry")
    if not backup.exists():
        backup.write_text(original)
    path.write_text(patched)
    print(f"{path}: patched (backup {backup.name})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
