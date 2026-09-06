#!/usr/bin/env python3
import importlib.util
import pathlib
import tempfile
import unittest


MODULE_PATH = pathlib.Path(__file__).with_name("patch-progression.py")
SPEC = importlib.util.spec_from_file_location("patch_progression", MODULE_PATH)
assert SPEC and SPEC.loader
patch_progression = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(patch_progression)


class ProgressionPatchTests(unittest.TestCase):
    def test_bulk_progression_is_rate_limited_and_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            mod = pathlib.Path(temporary_directory)
            script = mod / "code/scriptcommands.gsx"
            logic = mod / "maps/mp/gametypes/_globallogic.gsx"
            script.parent.mkdir(parents=True)
            logic.parent.mkdir(parents=True)
            script.write_text(
                '''main()\n{\n\t\tcase "setlevel":\n\t\t\tbreak;\n'''
                '''\t\tcase "unlockcac":\n\t\t\tbreak;\n'''
                '''\t\tcase "maxrank":\n\t\t\tbreak;\n'''
                '''\t\tcase "adminpower":\n\t\t\tbreak;\n'''
                '''\t\tcase "fps":\n\t\t\tbreak;\n}\n'''
                '''\n// BEGIN JGALBS ADMIN POWERS\noldHelper() {}\n'''
                '''// END JGALBS ADMIN POWERS\n\n// Built in function is crap\n'''
            )
            logic.write_text(
                "Callback_PlayerDamage( eInflictor, eAttacker, iDamage )\n{\n}\n"
            )

            patch_progression.patch(mod)
            first_script = script.read_text()
            first_logic = logic.read_text()
            patch_progression.patch(mod)

            self.assertEqual(script.read_text(), first_script)
            self.assertEqual(logic.read_text(), first_logic)
            self.assertIn(
                'self thread adminQueueLevel( wantedRank, false );', first_script
            )
            self.assertIn(
                'self thread adminQueueLevel( level.maxRank, true );', first_script
            )
            self.assertIn('self endon( "admin_progression_changed" );', first_script)
            self.assertIn("wait .75;", first_script)
            self.assertEqual(first_script.count("adminQueueLevel( wantedRank"), 2)
            self.assertIn("jgalbs admin godmode", first_logic)


if __name__ == "__main__":
    unittest.main()
