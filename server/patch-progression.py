#!/usr/bin/env python3
"""Add server-only progression commands to the New Experience mod."""

from __future__ import annotations

import pathlib
import re
import sys


COMMANDS = r'''
		case "setlevel":
			if( !isInt( arg ) )
			{
				self iPrintlnBold( "^1Level must be a number" );
				break;
			}
			wantedLevel = int( arg );
			if( wantedLevel < 1 || wantedLevel > ( level.maxRank + 1 ) )
			{
				self iPrintlnBold( "^1Level is out of range" );
				break;
			}
			wantedRank = wantedLevel - 1;
			if( wantedRank <= self.pers[ "rank" ] )
			{
				self iPrintlnBold( "^3Already at or above level " + wantedLevel );
				break;
			}
			targetXp = maps\mp\gametypes\_rank::getRankInfoMinXP( wantedRank );
			self maps\mp\gametypes\_persistence::statSet( "rankxp", targetXp );
			self.pers[ "rankxp" ] = targetXp;
			if( self maps\mp\gametypes\_rank::updateRank() )
				self thread maps\mp\gametypes\_rank::updateRankAnnounceHUD();
			self iPrintlnBold( "^2Level set to " + wantedLevel + " - quit through the menu to save" );
			break;

		case "unlockcac":
			// feature_cac normally lands during promotion. Stat 200 is the
			// engine's actual Create-a-Class gate, so repair it even when the
			// feature stat says it was already awarded.
			self setStat( 200, 1 );
			self maps\mp\gametypes\_rank::unlockFeature( "feature_cac" );
			self iPrintlnBold( "^2Create-a-Class unlocked - quit through the menu to save" );
			break;

		case "maxrank":
			// Replay every promotion from rank zero. Merely setting rankxp on a
			// player who already displays 55 skips updateRank and leaves broken
			// unlock stats (including Create-a-Class) broken.
			maxXp = maps\mp\gametypes\_rank::getRankInfoMaxXP( level.maxRank );
			self maps\mp\gametypes\_persistence::statSet( "rankxp", maxXp );
			self maps\mp\gametypes\_persistence::statSet( "rank", 0 );
			self.pers[ "rankxp" ] = maxXp;
			self.pers[ "rank" ] = 0;
			self maps\mp\gametypes\_rank::updateRank();
			self setStat( 200, 1 );
			self iPrintlnBold( "^2Max rank + unlocks repaired - quit through the menu to save" );
			break;

'''


def patch(mod_directory: pathlib.Path) -> None:
    script = mod_directory / "code/scriptcommands.gsx"
    text = script.read_text(errors="replace")
    marker = '\t\tcase "fps":'
    if marker not in text:
        raise SystemExit("scriptcommands.gsx: fps command changed upstream")

    existing = re.compile(
        r'\n\t\tcase "(?:setlevel|unlockcac|maxrank)":.*?(?=\n\t\tcase "fps":)',
        re.DOTALL,
    )
    cleaned = existing.sub("", text)
    command_block = COMMANDS.strip("\n") + "\n"
    updated = cleaned.replace(marker, command_block + marker, 1)
    if updated == text:
        print("   scriptcommands.gsx: progression controls already present")
        return
    script.write_text(updated)
    print("   scriptcommands.gsx: level, Create-a-Class and max-rank repair added")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch-progression.py <new_experience mod directory>")
    patch(pathlib.Path(sys.argv[1]))
