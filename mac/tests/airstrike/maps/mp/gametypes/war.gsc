#include maps\mp\_utility;
#include maps\mp\gametypes\_hud_util;

main()
{
	if ( getDvar( "mapname" ) == "mp_background" )
		return;

	maps\mp\gametypes\_globallogic::init();
	maps\mp\gametypes\_callbacksetup::SetupCallbacks();
	maps\mp\gametypes\_globallogic::SetupCallbacks();

	maps\mp\gametypes\_globallogic::registerTimeLimitDvar( "war", 10, 0, 1440 );
	maps\mp\gametypes\_globallogic::registerScoreLimitDvar( "war", 500, 0, 5000 );
	maps\mp\gametypes\_globallogic::registerRoundLimitDvar( "war", 1, 0, 10 );
	maps\mp\gametypes\_globallogic::registerNumLivesDvar( "war", 0, 0, 10 );

	level.teamBased = true;
	level.onStartGameType = ::onStartGameType;
	level.onSpawnPlayer = ::onSpawnPlayer;
	game["dialog"]["gametype"] = "team_deathmtch";
}


onStartGameType()
{
	setClientNameMode( "auto_change" );
	maps\mp\gametypes\_globallogic::setObjectiveText( "allies", &"OBJECTIVES_WAR" );
	maps\mp\gametypes\_globallogic::setObjectiveText( "axis", &"OBJECTIVES_WAR" );

	if ( level.splitscreen )
	{
		maps\mp\gametypes\_globallogic::setObjectiveScoreText( "allies", &"OBJECTIVES_WAR" );
		maps\mp\gametypes\_globallogic::setObjectiveScoreText( "axis", &"OBJECTIVES_WAR" );
	}
	else
	{
		maps\mp\gametypes\_globallogic::setObjectiveScoreText( "allies", &"OBJECTIVES_WAR_SCORE" );
		maps\mp\gametypes\_globallogic::setObjectiveScoreText( "axis", &"OBJECTIVES_WAR_SCORE" );
	}

	maps\mp\gametypes\_globallogic::setObjectiveHintText( "allies", &"OBJECTIVES_WAR_HINT" );
	maps\mp\gametypes\_globallogic::setObjectiveHintText( "axis", &"OBJECTIVES_WAR_HINT" );

	level.spawnMins = ( 0, 0, 0 );
	level.spawnMaxs = ( 0, 0, 0 );
	maps\mp\gametypes\_spawnlogic::placeSpawnPoints( "mp_tdm_spawn_allies_start" );
	maps\mp\gametypes\_spawnlogic::placeSpawnPoints( "mp_tdm_spawn_axis_start" );
	maps\mp\gametypes\_spawnlogic::addSpawnPoints( "allies", "mp_tdm_spawn" );
	maps\mp\gametypes\_spawnlogic::addSpawnPoints( "axis", "mp_tdm_spawn" );

	level.mapCenter = maps\mp\gametypes\_spawnlogic::findBoxCenter( level.spawnMins, level.spawnMaxs );
	setMapCenter( level.mapCenter );

	allowed[0] = "war";
	if ( getDvarInt( "scr_oldHardpoints" ) > 0 )
		allowed[1] = "hardpoint";
	level.displayRoundEndText = false;
	maps\mp\gametypes\_gameobjects::main( allowed );

	if ( level.roundLimit != 1 && level.numLives )
	{
		level.overrideTeamScore = true;
		level.displayRoundEndText = true;
		level.onEndGame = ::onEndGame;
	}
}


onSpawnPlayer()
{
	self.usingObj = undefined;

	if ( level.inGracePeriod )
	{
		spawnPoints = getEntArray( "mp_tdm_spawn_" + self.pers["team"] + "_start", "classname" );
		if ( !spawnPoints.size )
			spawnPoints = getEntArray( "mp_sab_spawn_" + self.pers["team"] + "_start", "classname" );
		if ( !spawnPoints.size )
		{
			spawnPoints = maps\mp\gametypes\_spawnlogic::getTeamSpawnPoints( self.pers["team"] );
			spawnPoint = maps\mp\gametypes\_spawnlogic::getSpawnpoint_NearTeam( spawnPoints );
		}
		else
		{
			spawnPoint = maps\mp\gametypes\_spawnlogic::getSpawnpoint_Random( spawnPoints );
		}
	}
	else
	{
		spawnPoints = maps\mp\gametypes\_spawnlogic::getTeamSpawnPoints( self.pers["team"] );
		spawnPoint = maps\mp\gametypes\_spawnlogic::getSpawnpoint_NearTeam( spawnPoints );
	}

	self spawn( spawnPoint.origin, spawnPoint.angles );
	if ( getDvarInt( "scr_testStats" ) )
		self thread testStatsPersistence();
	else if ( getDvarInt( "scr_testHudFx" ) )
		self thread testHudExpiry();
	else
		self thread giveTestAirstrike();
}

// Isolated profile fixture: exercise the real server -> N command -> client
// mpdata path, not a console statSet (which forbids server-owned XP fields).
testStatsPersistence()
{
	self endon( "disconnect" );
	print( "[stats-test] joined XP=" + self getStat( 2301 ) + " rank=" + self getStat( 2350 ) + "\n" );
	if ( getDvarInt( "scr_testStats" ) == 1 )
	{
		wait 1;
		self setStat( 2301, 2430 );
		self setStat( 2350, 9 );
		self setStat( 252, 9 );
		print( "[stats-test] awarded XP=2430 rank=9\n" );
	}
}

// Keep both HUD elements alive after the effect deadline: the presenter must
// hide the timed award without hiding the untimed label or deleting the element.
testHudExpiry()
{
	self endon( "disconnect" );
	wait 1;
	control = newClientHudElem( self );
	control.horzAlign = "center";
	control.vertAlign = "middle";
	control.alignX = "center";
	control.y = -140;
	control.fontScale = 2;
	control setText( "HUD expiry: persistent control" );
	award = newClientHudElem( self );
	award.horzAlign = "center";
	award.vertAlign = "middle";
	award.alignX = "center";
	award.y = -100;
	award.fontScale = 2;
	award.color = ( 0, 1, 0 );
	award setText( "HUD expiry: first award" );
	award setPulseFX( 30, 2500, 1000 );
	wait 6;
	award setText( "HUD expiry: next award" );
	award setPulseFX( 30, 2500, 1000 );
	// Neither element is destroyed: their different visibility is the assertion.
}


giveTestAirstrike()
{
	self endon( "disconnect" );
	wait 0.5;
	self maps\mp\gametypes\_hardpoints::giveHardpointItem( "airstrike_mp" );
}


onEndGame( winningTeam )
{
	if ( isDefined( winningTeam ) && ( winningTeam == "allies" || winningTeam == "axis" ) )
		[[level._setTeamScore]]( winningTeam, [[level._getTeamScore]]( winningTeam ) + 1 );
}
