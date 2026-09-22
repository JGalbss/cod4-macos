// Private, server-owned event journal. Each operation completes without yielding.
// getRealTime() is seconds since 2012-01-01 UTC, not the Unix epoch.
init()
{
	setDvar("cod4_leaderboard_version","1");
	level.leaderboardWinsCommitted = false;
	// game survives round restarts; a full map load starts a fresh match ledger.
	if ( !isDefined(game["leaderboardParticipants"]) ) game["leaderboardParticipants"] = [];
	if ( !isDefined(game["leaderboardPresenceWritten"]) ) game["leaderboardPresenceWritten"] = [];
	if ( !isDefined(game["leaderboardWriteFailureReported"]) ) game["leaderboardWriteFailureReported"] = false;
}

sanitizeName( name )
{
	if ( !isDefined(name) || !isString(name) || name == "" ) return "Player";
	clean = "";
	for ( i=0; i<name.size && i<64; i++ )
	{
		character = name[i];
		if ( character == ";" || character == "\r" || character == "\n" || character == "\t" ) character = " ";
		clean += character;
	}
	return clean;
}

validIdentityKey( key )
{
	if ( !isDefined(key) || !isString(key) ) return false;
	if ( key.size > 3 && key.size <= 35 && getSubStr(key,0,3) == "nm_" ) return true;
	if ( key.size == 35 && getSubStr(key,0,3) == "pb_" )
	{
		fallback = code\killstreak_loadout::identityKey("0",getSubStr(key,3));
		return isDefined(fallback) && fallback == key;
	}
	return code\killstreak_loadout::safeGuid(key);
}

identity()
{
	if ( !isDefined(self) || !isPlayer(self) || !isDefined(self.pers) ) return undefined;
	// Test clients count only while an operator rehearses with leaderboard_count_bots 1.
	if ( getDvarInt("leaderboard_count_bots") != 1 )
	{
		if ( isDefined(self.pers["isBot"]) ) return undefined;
		// CoD4X sets the literal userinfo ip "bot" for native test clients.
		if ( self getUserinfo("ip") == "bot" ) return undefined;
	}
	// This server has no GUIDs and every install shares one pbguid, so a GUID key merges everyone
	// into one player. The name is the identity here and in the control panel's leaderboard.
	return nameKey(self.name);
}
nameKey( name )
{
	if ( !isDefined(name) || !isString(name) ) return undefined;
	plain = "";
	for ( i=0; i<name.size && plain.size<32; i++ )
	{
		character = name[i];
		if ( character == "^" && i+1 < name.size && isSubStr("0123456789", name[i+1]) ) { i++; continue; }
		plain += character;
	}
	plain = toLower(plain);
	key = "";
	for ( i=0; i<plain.size; i++ )
	{
		if ( isSubStr("abcdefghijklmnopqrstuvwxyz0123456789_", plain[i]) ) key += plain[i];
		else key += "_";
	}
	if ( key.size < 1 ) return undefined;
	return "nm_" + key;
}

reportWriteFailure()
{
	if ( isDefined(game["leaderboardWriteFailureReported"]) && game["leaderboardWriteFailureReported"] ) return;
	game["leaderboardWriteFailureReported"] = true;
	println("[leaderboard] Journal write failed; gameplay continues.");
}

appendEvent( event, key, name )
{
	if ( !isDefined(event) || (event != "K" && event != "D" && event != "W" && event != "P") ) return false;
	if ( !validIdentityKey(key) ) return false;
	line = "LB1;"+getRealTime()+";"+event+";"+key+";"+sanitizeName(name);
	handle = FS_FOpen("./ne_db/leaderboard/events.log","append");
	if ( !isDefined(handle) || handle <= 0 )
	{
		reportWriteFailure();
		return false;
	}
	written = FS_WriteLine(handle,line);
	FS_FClose(handle);
	if ( !isDefined(written) || !written )
	{
		reportWriteFailure();
		return false;
	}
	return true;
}

record( event )
{
	key = self identity();
	if ( !isDefined(key) ) return false;
	return appendEvent(event,key,self.name);
}

onSpawn()
{
	if ( !isDefined(game["state"]) || game["state"] != "playing" ) return;
	key = self identity();
	if ( !isDefined(key) ) return;
	if ( !isDefined(self.pers["team"]) || (self.pers["team"] != "allies" && self.pers["team"] != "axis") ) return;
	if ( !isDefined(self.hasSpawned) || !self.hasSpawned || self.sessionteam == "spectator" ) return;
	game["leaderboardParticipants"][key] = true;
	if ( isDefined(game["leaderboardPresenceWritten"][key]) ) return;
	if ( appendEvent("P",key,self.name) ) game["leaderboardPresenceWritten"][key] = true;
}

snapshotWinners( winner )
{
	records = [];
	if ( isDefined(level.hostForcedEnd) && level.hostForcedEnd ) return records;
	if ( !isDefined(winner) ) return records;
	individual = isPlayer(winner);
	if ( !individual && winner != "allies" && winner != "axis" ) return records;
	seen = [];
	for ( i=0; i<level.players.size; i++ )
	{
		player = level.players[i];
		key = player identity();
		if ( !isDefined(key) || isDefined(seen[key]) ) continue;
		if ( !isDefined(game["leaderboardParticipants"][key]) ) continue;
		if ( !isDefined(player.pers["team"]) || (player.pers["team"] != "allies" && player.pers["team"] != "axis") ) continue;
		if ( player.sessionteam == "spectator" ) continue;
		if ( individual )
		{
			if ( player != winner ) continue;
		}
		else if ( player.pers["team"] != winner ) continue;
		entry = spawnStruct();
		entry.key = key;
		entry.name = sanitizeName(player.name);
		records[records.size] = entry;
		seen[key] = true;
	}
	return records;
}

commitWinners( records )
{
	if ( isDefined(level.leaderboardWinsCommitted) && level.leaderboardWinsCommitted ) return;
	level.leaderboardWinsCommitted = true;
	if ( isDefined(level.hostForcedEnd) && level.hostForcedEnd ) return;
	if ( !isDefined(records) || !isArray(records) ) return;
	seen = [];
	for ( i=0; i<records.size; i++ )
	{
		entry = records[i];
		if ( !isDefined(entry) || !isDefined(entry.key) || !validIdentityKey(entry.key) ) continue;
		if ( isDefined(seen[entry.key]) ) continue;
		seen[entry.key] = true;
		appendEvent("W",entry.key,entry.name);
	}
}
