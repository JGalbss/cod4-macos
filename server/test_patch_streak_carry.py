import importlib.util
import pathlib
import unittest

SPEC = importlib.util.spec_from_file_location("patch_streak_carry", pathlib.Path(__file__).with_name("patch-streak-carry.py"))
target = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(target)

SAMPLE = """spawnPlayer()
{
\tself.cur_kill_streak = 0;
\tself.cur_death_streak = 0;
}
Callback_PlayerDisconnect()
{
\tself removePlayerOnDisconnect();
}
death()
{
\t\tif ( isPlayer( attacker ) && level.teamBased && ( attacker != self ) && ( self.pers["team"] == attacker.pers["team"] ) )
\t\t{
\t\t\tself.cur_kill_streak = 0;
\t\t}
\t\telse
\t\t{
\t\t\tself.cur_kill_streak = 0;
\t\t\tself.cur_death_streak++;
\t\t}
\t\t\t\t\t\tattacker.cur_kill_streak++;
\t\t\t\t\t\tattacker.cur_kill_streak++;
}
"""


class StreakCarryPatchTests(unittest.TestCase):
    def test_patch_touches_every_site_once_and_is_idempotent(self):
        patched = target.patch(SAMPLE)
        self.assertEqual(patched.count("self carriedStreak()"), 1)
        self.assertEqual(patched.count("storeCarriedStreak();"), 4)
        self.assertEqual(patched.count("self clearCarriedStreak();"), 1)
        self.assertIn("StreakCarry;", patched)
        self.assertIn("carriedStreak()\n{", patched)
        self.assertEqual(target.patch(patched), patched)

    def test_patch_refuses_unexpected_source(self):
        with self.assertRaises(ValueError):
            target.patch(SAMPLE.replace("attacker.cur_kill_streak++;", "attacker.cur_kill_streak += 1;"))


if __name__ == "__main__":
    unittest.main()
