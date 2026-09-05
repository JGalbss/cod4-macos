#!/usr/bin/env python3
"""Add server-only player administration commands to New Experience."""

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

		case "adminpower":
			// This command is deliberately not registered with addScriptCommand.
			// It is reachable only through code/rcon_commands.gsx's `cmd` dvar.
			switch( arg )
			{
				case "godmode_on":
					self.pers[ "adminGodmode" ] = true;
					self.health = self.maxhealth;
					self iPrintlnBold( "^2ADMIN GOD MODE: ON" );
					break;

				case "godmode_off":
					self.pers[ "adminGodmode" ] = false;
					self.health = self.maxhealth;
					self iPrintlnBold( "^1ADMIN GOD MODE: OFF" );
					break;

				case "aimbot_on":
					self.pers[ "adminAimbot" ] = true;
					self notify( "admin_aimbot_changed" );
					self thread adminAimbotLoop();
					self iPrintlnBold( "^2ADMIN AIM LOCK: ON ^7- aim or fire to lock a visible target" );
					break;

				case "aimbot_off":
					self.pers[ "adminAimbot" ] = false;
					self notify( "admin_aimbot_changed" );
					self iPrintlnBold( "^1ADMIN AIM LOCK: OFF" );
					break;

				case "wallhack_on":
					self.pers[ "adminWallhack" ] = true;
					self notify( "admin_wallhack_changed" );
					self adminClearWallhackMarkers();
					self setClientDvar( "g_compassShowEnemies", 1 );
					self thread adminWallhackLoop();
					self iPrintlnBold( "^2ADMIN WALL VISION: ON" );
					break;

				case "wallhack_off":
					self.pers[ "adminWallhack" ] = false;
					self notify( "admin_wallhack_changed" );
					self adminClearWallhackMarkers();
					self setClientDvar( "g_compassShowEnemies", 0 );
					self iPrintlnBold( "^1ADMIN WALL VISION: OFF" );
					break;

				default:
					self iPrintlnBold( "^1Unknown admin power" );
					break;
			}
			break;

'''


ADMIN_FUNCTIONS = r'''
// BEGIN JGALBS ADMIN POWERS
adminAimbotLoop()
{
	self endon( "disconnect" );
	self endon( "admin_aimbot_changed" );

	for(;;)
	{
		if( !isDefined( self.pers[ "adminAimbot" ] ) || !self.pers[ "adminAimbot" ] )
			return;

		if( !isAlive( self ) || ( !self aimButtonPressed() && !self attackButtonPressed() ) )
		{
			wait .05;
			continue;
		}

		eye = self getEye();
		forward = anglesToForward( self getPlayerAngles() );
		bestAlignment = -2.0;
		bestTarget = undefined;
		players = level.players;

		for( i = 0; i < players.size; i++ )
		{
			target = players[ i ];
			if( target == self || !isAlive( target ) || target.pers[ "team" ] == "spectator" )
				continue;
			if( level.teamBased && target.pers[ "team" ] == self.pers[ "team" ] )
				continue;

			targetEye = target getEye();
			if( !bulletTracePassed( eye, targetEye, false, self ) )
				continue;

			direction = vectorNormalize( targetEye - eye );
			alignment = vectorDot( forward, direction );
			if( alignment > bestAlignment )
			{
				bestAlignment = alignment;
				bestTarget = target;
			}
		}

		if( isDefined( bestTarget ) )
			self setPlayerAngles( vectorToAngles( bestTarget getEye() - eye ) );

		wait .05;
	}
}

adminWallhackLoop()
{
	self endon( "disconnect" );
	self endon( "admin_wallhack_changed" );
	self.adminWallhackMarkers = [];

	for(;;)
	{
		if( !isDefined( self.pers[ "adminWallhack" ] ) || !self.pers[ "adminWallhack" ] )
			return;

		for( markerIndex = 0; markerIndex < self.adminWallhackMarkers.size; markerIndex++ )
		{
			if( isDefined( self.adminWallhackMarkers[ markerIndex ] ) )
			{
				self.adminWallhackMarkers[ markerIndex ].alpha = 0;
				self.adminWallhackMarkers[ markerIndex ].baseAlpha = 0;
			}
		}

		players = level.players;
		for( i = 0; i < players.size; i++ )
		{
			target = players[ i ];
			if( target == self || target.pers[ "team" ] == "spectator" )
				continue;
			if( level.teamBased && target.pers[ "team" ] == self.pers[ "team" ] )
				continue;

			slot = target getEntityNumber();
			if( !isDefined( self.adminWallhackMarkers[ slot ] ) )
			{
				self.adminWallhackMarkers[ slot ] = newClientHudElem( self );
				self.adminWallhackMarkers[ slot ].archived = false;
				self.adminWallhackMarkers[ slot ].x = target.origin[ 0 ];
				self.adminWallhackMarkers[ slot ].y = target.origin[ 1 ];
				self.adminWallhackMarkers[ slot ].z = target.origin[ 2 ];
				self.adminWallhackMarkers[ slot ].color = ( 1, 0, 0 );
				self.adminWallhackMarkers[ slot ] setShader( "waypoint_kill", 18, 18 );
				self.adminWallhackMarkers[ slot ] setWayPoint( true, "waypoint_kill" );
				self.adminWallhackMarkers[ slot ] setTargetEnt( target );
			}

			if( isAlive( target ) )
			{
				self.adminWallhackMarkers[ slot ].alpha = 1;
				self.adminWallhackMarkers[ slot ].baseAlpha = 1;
			}
		}

		wait .10;
	}
}

adminClearWallhackMarkers()
{
	if( !isDefined( self.adminWallhackMarkers ) )
		return;

	for( i = 0; i < self.adminWallhackMarkers.size; i++ )
	{
		if( isDefined( self.adminWallhackMarkers[ i ] ) )
			self.adminWallhackMarkers[ i ] destroy();
	}
	self.adminWallhackMarkers = undefined;
}
// END JGALBS ADMIN POWERS
'''


def patch(mod_directory: pathlib.Path) -> None:
    script = mod_directory / "code/scriptcommands.gsx"
    text = script.read_text(errors="replace")
    marker = '\t\tcase "fps":'
    if marker not in text:
        raise SystemExit("scriptcommands.gsx: fps command changed upstream")

    existing = re.compile(
        r'\n\t\tcase "(?:setlevel|unlockcac|maxrank|adminpower)":.*?(?=\n\t\tcase "fps":)',
        re.DOTALL,
    )
    cleaned = existing.sub("", text)
    command_block = COMMANDS.strip("\n") + "\n"
    updated = cleaned.replace(marker, command_block + marker, 1)

    helpers = re.compile(
        r'\n*// BEGIN JGALBS ADMIN POWERS\n.*?// END JGALBS ADMIN POWERS\n*',
        re.DOTALL,
    )
    updated = helpers.sub("\n\n", updated)
    helper_marker = "// Built in function is crap"
    if helper_marker not in updated:
        raise SystemExit("scriptcommands.gsx: helper marker changed upstream")
    updated = updated.replace(
        helper_marker, ADMIN_FUNCTIONS.strip("\n") + "\n\n" + helper_marker, 1
    )

    if updated == text:
        print("   scriptcommands.gsx: player administration controls already present")
    else:
        script.write_text(updated)
        print("   scriptcommands.gsx: progression and admin powers added")

    logic = mod_directory / "maps/mp/gametypes/_globallogic.gsx"
    logic_text = logic.read_text(errors="replace")
    godmode_marker = "// jgalbs admin godmode: RCON-granted damage immunity"
    if godmode_marker in logic_text:
        print("   _globallogic.gsx: admin god mode already present")
        return
    damage_handler = re.compile(
        r'(Callback_PlayerDamage\([^\n]+\)\n\{\n)',
    )
    guard = (
        '\t// jgalbs admin godmode: RCON-granted damage immunity\n'
        '\tif( isDefined( self.pers[ "adminGodmode" ] ) && self.pers[ "adminGodmode" ] )\n'
        '\t{\n'
        '\t\tself.health = self.maxhealth;\n'
        '\t\treturn;\n'
        '\t}\n\n'
    )
    logic_updated, count = damage_handler.subn(r"\1" + guard, logic_text, count=1)
    if count != 1:
        raise SystemExit("_globallogic.gsx: player damage callback changed upstream")
    logic.write_text(logic_updated)
    print("   _globallogic.gsx: RCON-granted god mode added")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch-progression.py <new_experience mod directory>")
    patch(pathlib.Path(sys.argv[1]))
