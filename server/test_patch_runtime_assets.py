#!/usr/bin/env python3
import importlib.util
import pathlib
import tempfile
import unittest


MODULE_PATH = pathlib.Path(__file__).with_name("patch-runtime-assets.py")
SPEC = importlib.util.spec_from_file_location("patch_runtime_assets", MODULE_PATH)
assert SPEC and SPEC.loader
patch_runtime_assets = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(patch_runtime_assets)


class RuntimeAssetPatchTests(unittest.TestCase):
    def test_radiation_assets_are_replaced_idempotently(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            mod = pathlib.Path(temporary_directory)
            code = mod / "code"
            code.mkdir()
            init = code / "init.gsx"
            nuke = code / "nuke.gsx"
            init.write_text("fx_cache()\n{\n" + patch_runtime_assets.RADIATION_PRECACHES + "\n}\n")
            nuke.write_text(
                'player shellshock( "radiation_high", 4 );\n'
                'player shellshock( "radiation_med", 2 );\n'
            )

            patch_runtime_assets.patch(mod)
            first_init = init.read_text()
            first_nuke = nuke.read_text()
            patch_runtime_assets.patch(mod)

            self.assertEqual(init.read_text(), first_init)
            self.assertEqual(nuke.read_text(), first_nuke)
            self.assertNotIn("radiation_", first_init + first_nuke)
            self.assertEqual(first_init.count('PreCacheShellShock( "default" )'), 1)
            self.assertEqual(first_nuke.count('shellshock( "default"'), 2)


if __name__ == "__main__":
    unittest.main()
