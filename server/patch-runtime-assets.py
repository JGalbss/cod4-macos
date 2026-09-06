#!/usr/bin/env python3
"""Keep New Experience on multiplayer-owned runtime assets."""

from __future__ import annotations

import pathlib
import sys


RADIATION_PRECACHES = """\
\tPreCacheShellShock( "radiation_low" );
\tPreCacheShellShock( "radiation_med" );
\tPreCacheShellShock( "radiation_high" );"""

STOCK_PRECACHE = """\
\t// jgalbs: use an already-owned multiplayer shellshock for the nuke. A
\t// private mod.ff here becomes a mandatory client download and breaks older
\t// native clients before they can enter the match.
\tPreCacheShellShock( "default" );"""


def patch(mod_directory: pathlib.Path) -> None:
    init = mod_directory / "code/init.gsx"
    init_text = init.read_text(errors="replace")
    if RADIATION_PRECACHES in init_text:
        init.write_text(init_text.replace(RADIATION_PRECACHES, STOCK_PRECACHE, 1))
        print("   init.gsx: nuke shellshock moved to stock multiplayer asset")
    elif STOCK_PRECACHE in init_text:
        print("   init.gsx: stock nuke shellshock already selected")
    else:
        raise SystemExit("init.gsx: radiation precache block changed upstream")

    nuke = mod_directory / "code/nuke.gsx"
    nuke_text = nuke.read_text(errors="replace")
    replacements = 0
    for old in ('"radiation_high"', '"radiation_med"'):
        replacements += nuke_text.count(old)
        nuke_text = nuke_text.replace(old, '"default"')
    if replacements:
        nuke.write_text(nuke_text)
        print(f"   nuke.gsx: replaced {replacements} private shellshock reference(s)")
    elif 'player shellshock( "default"' in nuke_text:
        print("   nuke.gsx: stock shellshock references already present")
    else:
        raise SystemExit("nuke.gsx: radiation shellshock calls changed upstream")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} MOD_DIRECTORY")
    patch(pathlib.Path(sys.argv[1]))
