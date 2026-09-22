// Jev bot executor fixture. Runs inside the private server copy only.
// Contract: server/jev-bot/PROTOCOL.md. Waypoints: code\jev_bot_waypoints (Bot Warfare data, credited there).
//
// Every 50 ms per bot: perceive, remember, navigate, aim, fire, apply the held command.
// Every 200 ms per bot: publish one observation as four records (enemies, nav, events, self).
// Commands arrive through dvars jev_cmd_<n> and are held until replaced or death.

main()
{
	if (isDefined(level.jevBot)) return;
	if (getDvar("jev_bot_count") == "") setDvar("jev_bot_count", "4");
	if (getDvar("jev_bw_count") == "") setDvar("jev_bw_count", "0");
	if (getDvar("jev_bw_skill") == "") setDvar("jev_bw_skill", "4");
	// Live servers ship this script with jev_enabled 0; the web panel flips it on, mid-map included.
	if (getDvarInt("jev_enabled") != 1)
	{
		level endon("game_ended");
		while (getDvarInt("jev_enabled") != 1) wait 1;
	}
	level.jevBot = spawnStruct();
	s = level.jevBot;
	s.bots = []; s.players = []; s.external = [];
	s.live = getDvarInt("jev_live") == 1;
	s.botCount = getDvarInt("jev_bot_count");
	if (s.live) s.botCount = 0;
	s.bwCount = getDvarInt("jev_bw_count");
	s.bwSkill = getDvarInt("jev_bw_skill");
	s.gameMode = getDvar("g_gametype");
	s.stopped = false; s.started = getTime();
	s.spawns = 0; s.shots = 0; s.deaths = 0; s.kills = 0; s.damageEvents = 0; s.damage = 0;
	s.commands = 0; s.rejected = 0; s.reloads = 0; s.grenadeThrows = 0; s.travel = 0;
	s.native = false;
	s.nextId = 0;
	if (!s.live && (s.botCount < 1 || s.botCount > 5)) { stop("unsupported_bot_count"); return; }
	if (s.bwCount < 0 || s.bwCount > 4) { stop("unsupported_bw_count"); return; }
	if (getDvarInt("jev_native_enabled") == 1)
	{
		info = nativeInfoAdapter();
		if (!isDefined(info) || info.size != 3 || info[0] != 3 || info[1] != 8454161 || info[2] != "cd3c4ce58f25d0611ef6a404dd307adbf99a1d37a60ced6b91bae09aa68e0cd0")
		{ stop("native_adapter_invalid"); return; }
		s.native = true;
		emit("native_ready", "\"version\":" + info[0]);
	}
	if (s.live) s.waypoints = loadWaypointsCsv(getDvar("mapname"));
	else s.waypoints = code\jev_bot_waypoints::jevWaypoints();
	s.sightRows = []; s.blockedLinks = [];
	for (i = 0; i < 8; i++) setDvar("jev_cmd_" + i, "");
	setDvar("jev_stop", "0");
	if (s.live) { setDvar("jev_request", ""); setDvar("jev_request_result", ""); if (getDvar("jev_roster_wanted") == "") setDvar("jev_roster_wanted", ""); thread watchRequests(); }
	if (!isDefined(s.waypoints) || s.waypoints.size < 2) { unsupported("waypoints_unavailable", "no waypoints for " + getDvar("mapname")); return; }
	level thread mapSightDump();
	buildEdgeLengths();
	thread roundEnd();
	thread watchConnections();
	thread watchBomb();
	level endon("game_ended"); level endon("jev_bot_stop");
	if (s.gameMode != "war" && s.gameMode != "dm" && s.gameMode != "sd" && s.gameMode != "dom" && s.gameMode != "koth") { unsupported("unsupported_gametype", "gametype " + s.gameMode + " is not supported"); return; }
	deadline = getTime() + 30000;
	while (!isDefined(game["menu_team"]) && getTime() < deadline) wait .1;
	if (!isDefined(game["menu_team"])) { stop("gametype_not_ready"); return; }
	wait 1;
	if ((s.gameMode != "dm" && !level.teamBased) || (s.gameMode == "dm" && level.teamBased)) { unsupported("gametype_team_mode_mismatch", "gametype " + s.gameMode + " runs with an unexpected team mode"); return; }
	resumed = isDefined(game["jevStarted"]);
	if (resumed)
	{
		// Bots survive a round restart as clients; the connected replay re-adopts them. Give it a moment.
		deadline = getTime() + 15000;
		while (s.bots.size < s.botCount && getTime() < deadline) wait .1;
		emit("resumed", "\"bots\":" + s.bots.size + ",\"externalBots\":" + s.external.size + ",\"elapsedMs\":" + elapsedMs());
	}
	for (i = s.bots.size; i < s.botCount; i++)
	{
		team = "autoassign";
		if (level.teamBased) { team = "allies"; if (i >= int((s.botCount + s.bwCount) / 2)) team = "axis"; }
		// Search and Destroy: the map decides which team attacks; Jev bots take that side so planting gets exercised.
		if (s.gameMode == "sd" && isDefined(game["attackers"])) team = game["attackers"];
		bot = spawnBot(team);
		if (!isDefined(bot)) { stop("bot_spawn_failed"); return; }
	}
	if (s.bwCount > 0 && !resumed && !s.live)
	{
		if (!botWarfareStart()) { stop("bot_warfare_start_failed"); return; }
		for (i = 0; i < s.bwCount; i++)
		{
			team = "autoassign";
			if (level.teamBased) team = "axis";
			if (s.gameMode == "sd" && isDefined(game["defenders"])) team = game["defenders"];
			bot = spawnBotWarfareBot(team);
			if (!isDefined(bot)) { stop("bot_warfare_spawn_failed"); return; }
		}
	}
	deadline = getTime() + 30000;
	while (isDefined(level.inPrematchPeriod) && level.inPrematchPeriod && getTime() < deadline) wait .1;
	if (isDefined(level.inPrematchPeriod) && level.inPrematchPeriod) { stop("prematch_timeout"); return; }
	seconds = getDvarInt("jev_seconds");
	if (seconds < 1 || seconds > 3600) seconds = 60;
	s.readyAt = getTime();
	game["jevStarted"] = true;
	emit("ready", "\"map\":" + jsonString(getDvar("mapname")) + ",\"live\":" + jsonBool(s.live) + ",\"bots\":" + s.bots.size + ",\"botCount\":" + s.bots.size + ",\"externalBots\":" + s.external.size + ",\"gameMode\":" + jsonString(s.gameMode) + ",\"teamBased\":" + jsonBool(level.teamBased) + ",\"durationSeconds\":" + seconds + ",\"observationMs\":200,\"tickMs\":50,\"staleCommandMs\":1200,\"native\":" + jsonBool(s.native) + ",\"waypoints\":" + s.waypoints.size + ",\"roster\":" + roster());
	for (i = 0; i < s.bots.size; i++)
	{
		s.bots[i] thread controls();
		s.bots[i] thread observations();
	}
	if (s.live) thread restoreWantedBots();
	while (s.live || elapsedMs() < seconds * 1000)
	{
		if (getDvarInt("jev_stop") == 1) { stop("requested"); return; }
		if (s.live && getDvarInt("jev_enabled") != 1) { removeRequestedBot("all"); setDvar("jev_roster_wanted", ""); stop("disabled"); return; }
		wait .1;
	}
	stop("duration_elapsed");
}

// A live server may rotate onto a map or mode the bots cannot play. Stay up so panel requests get
// the reason instead of silence; the next map starts fresh. The lab treats the same cases as fatal.
unsupported(reason, message)
{
	s = level.jevBot;
	if (!s.live) { stop(reason); return; }
	s.unsupported = message;
	setDvar("jev_roster", "");
	emit("unsupported", "\"reason\":" + jsonString(reason) + ",\"message\":" + jsonString(message));
	level endon("game_ended");
	while (getDvarInt("jev_enabled") == 1) wait 1;
	setDvar("jev_roster_wanted", "");
	stop("disabled");
}

// ---------------------------------------------------------------- live mode: requests from the web panel

// jev_request carries "add|<team>|<name>" or "remove|<name>" (team: allies, axis, autoassign). The result
// goes to jev_request_result and the roster to jev_roster as "id:name:team" entries.
watchRequests()
{
	level endon("game_ended"); level endon("jev_bot_stop");
	s = level.jevBot;
	for (;;)
	{
		wait .2;
		request = getDvar("jev_request");
		if (request == "") { self publishRoster(); continue; }
		setDvar("jev_request", "");
		parts = strTok(request, "|");
		result = "error: malformed request";
		if (parts.size >= 3 && parts[0] == "add") result = addRequestedBot(parts[1], parts[2]);
		else if (parts.size >= 2 && parts[0] == "remove") result = removeRequestedBot(parts[1]);
		setDvar("jev_request_result", result);
		emit("request", "\"request\":" + jsonString(request) + ",\"result\":" + jsonString(result));
	}
}

addRequestedBot(team, name)
{
	s = level.jevBot;
	if (isDefined(s.unsupported)) return "error: " + s.unsupported;
	self pruneBots();
	if (s.bots.size >= 8) return "error: eight bots is the limit";
	if (team != "allies" && team != "axis" && team != "autoassign") return "error: team must be allies, axis or autoassign";
	if (!level.teamBased) team = "autoassign";
	if (name.size < 1 || name.size > 15) return "error: name must be 1 to 15 characters";
	for (i = 0; i < s.bots.size; i++) if (isDefined(s.bots[i]) && s.bots[i].name == name) return "error: a bot named " + name + " is already playing";
	bot = spawnNamedBot(team, name);
	if (!isDefined(bot)) return "error: the server could not add a client";
	if (isDefined(s.readyAt)) { bot thread controls(); bot thread observations(); }
	rememberWantedBot(team, name);
	self publishRoster();
	return "ok: " + name + " joined " + bot.pers["team"] + " as bot " + bot.jevId;
}

// The engine drops test clients on a map change; the wanted roster in jev_roster_wanted
// ("team:name,...") survives it, and the next map's main() adds them back.
rememberWantedBot(team, name)
{
	entries = wantedBots();
	for (i = 0; i < entries.size; i++) if (entries[i]["name"] == name) return;
	value = getDvar("jev_roster_wanted");
	if (value != "") value += ",";
	setDvar("jev_roster_wanted", value + team + ":" + name);
}

forgetWantedBot(name)
{
	entries = wantedBots();
	value = ""; sep = "";
	for (i = 0; i < entries.size; i++)
	{
		if (name == "all" || entries[i]["name"] == name) continue;
		value += sep + entries[i]["team"] + ":" + entries[i]["name"];
		sep = ",";
	}
	setDvar("jev_roster_wanted", value);
}

wantedBots()
{
	entries = [];
	value = getDvar("jev_roster_wanted");
	if (value == "") return entries;
	parts = strTok(value, ",");
	for (i = 0; i < parts.size; i++)
	{
		pair = strTok(parts[i], ":");
		if (pair.size != 2) continue;
		entry = []; entry["team"] = pair[0]; entry["name"] = pair[1];
		entries[entries.size] = entry;
	}
	return entries;
}

restoreWantedBots()
{
	level endon("game_ended"); level endon("jev_bot_stop");
	s = level.jevBot;
	entries = wantedBots();
	for (i = 0; i < entries.size; i++)
	{
		present = false;
		for (j = 0; j < s.bots.size; j++) if (isDefined(s.bots[j]) && s.bots[j].name == entries[i]["name"]) present = true;
		if (present) continue;
		result = addRequestedBot(entries[i]["team"], entries[i]["name"]);
		emit("bot_restored", "\"name\":" + jsonString(entries[i]["name"]) + ",\"result\":" + jsonString(result));
		wait 1;
	}
}

removeRequestedBot(name)
{
	s = level.jevBot;
	removed = 0;
	for (i = 0; i < s.bots.size; i++)
	{
		bot = s.bots[i];
		if (!isDefined(bot)) continue;
		if (name != "all" && bot.name != name) continue;
		kick(bot getEntityNumber());
		removed++;
	}
	forgetWantedBot(name);
	if (removed == 0) return "error: no bot named " + name;
	wait .5;
	self pruneBots();
	self publishRoster();
	return "ok: removed " + removed;
}

pruneBots()
{
	s = level.jevBot;
	kept = [];
	for (i = 0; i < s.bots.size; i++) if (isDefined(s.bots[i])) kept[kept.size] = s.bots[i];
	s.bots = kept;
}

publishRoster()
{
	s = level.jevBot;
	roster = ""; sep = "";
	for (i = 0; i < s.bots.size; i++)
	{
		bot = s.bots[i];
		if (!isDefined(bot)) continue;
		team = "none"; if (isDefined(bot.pers["team"])) team = bot.pers["team"];
		roster += sep + bot.jevId + ":" + bot.name + ":" + team;
		sep = ",";
	}
	setDvar("jev_roster", roster);
}

// Bot Warfare's waypoint CSV for the running map, read through CoD4x's script file API from
// scriptdata/waypoints/. Line one is the count; each row is "x y z,children,type,...".
loadWaypointsCsv(mapname)
{
	waypoints = [];
	filename = "waypoints/" + mapname + "_wp.csv";
	// Both CoD4x file calls resolve beneath fs_game/ and want the scriptdata/ prefix spelled out.
	if (!fs_testfile("scriptdata/" + filename)) { emit("waypoints_missing", "\"map\":" + jsonString(mapname)); return waypoints; }
	file = fs_fopen("scriptdata/" + filename, "read");
	if (!isDefined(file) || file <= 0) return waypoints;
	countLine = fs_readline(file);
	if (!isDefined(countLine)) { fs_fclose(file); return waypoints; }
	count = int(countLine);
	for (i = 0; i < count; i++)
	{
		row = fs_readline(file);
		if (!isDefined(row)) break;
		cols = strTok(row, ",");
		if (cols.size < 2) break;
		xyz = strTok(cols[0], " ");
		if (xyz.size < 3) break;
		kind = "stand"; if (cols.size >= 3 && cols[2] != "") kind = cols[2];
		waypoints[i] = code\jev_bot_waypoints::jevWaypoint((float(xyz[0]), float(xyz[1]), float(xyz[2])), cols[1], kind);
	}
	fs_fclose(file);
	emit("waypoints_loaded", "\"map\":" + jsonString(mapname) + ",\"count\":" + waypoints.size);
	return waypoints;
}

// ---------------------------------------------------------------- roster

spawnBot(team)
{
	return spawnNamedBot(team, undefined);
}

spawnNamedBot(team, name)
{
	s = level.jevBot;
	if (isDefined(name)) bot = addTestClient(name); else bot = addTestClient();
	if (!isDefined(bot)) return undefined;
	bot.pers["isBot"] = true;
	bot.pers["jevControlled"] = true;
	bot registerPlayer();
	bot adoptAsJevBot(team);
	if (!bot joinTeam(team)) return undefined;
	if (!bot verifyTeam()) return undefined;
	bot releaseAll();
	emit("team_verified", "\"botId\":" + bot.jevId + ",\"team\":" + jsonString(bot.pers["team"]) + ",\"sessionTeam\":" + jsonString(bot.sessionteam));
	return bot;
}

// Everything a Jev bot needs besides its client and team: fields, executor state, watcher threads.
adoptAsJevBot(team)
{
	s = level.jevBot;
	self.jevControlled = true;
	self.jevExpectedTeam = team;
	self.jevSequence = 0; if (isDefined(self.pers["jevSequence"])) self.jevSequence = self.pers["jevSequence"];
	self.jevAccepted = 0; if (isDefined(self.pers["jevAccepted"])) self.jevAccepted = self.pers["jevAccepted"];
	self.jevLastInput = "";
	self.jevObservedSequences = []; self.jevObservedTimes = [];
	self.jevDistance = 0;
	self resetExecutor();
	s.bots[s.bots.size] = self;
	self thread watchSpawns(); self thread watchReloadStart(); self thread watchReload();
	self thread watchWeaponChange(); self thread watchGrenadePullback(); self thread watchGrenadeFire();
}

spawnBotWarfareBot(team)
{
	s = level.jevBot;
	bot = addTestClient(); if (!isDefined(bot)) return undefined;
	// No jevControlled flag: Bot Warfare adopts this client on its connected notify.
	// The mod's connect check kicks stat-less players unless pers["isBot"] is already set.
	bot.pers["isBot"] = true;
	bot.pers["jevExternal"] = true;
	bot registerPlayer();
	bot.jevExternal = true;
	bot.jevExpectedTeam = team;
	s.external[s.external.size] = bot;
	deadline = getTime() + 10000;
	while (!isDefined(bot.pers["team"]) && getTime() < deadline) wait .1;
	bot notify("menuresponse", game["menu_team"], team);
	wait .1;
	bot notify("menuresponse", "changeclass", "assault_mp");
	deadline = getTime() + 10000;
	while (getTime() < deadline && (!isDefined(bot.pers["isBotWarfare"]) || !isDefined(bot.bot))) wait .05;
	if (!isDefined(bot.pers["isBotWarfare"]) || !isDefined(bot.bot)) { emit("bot_warfare_error", "\"reason\":\"bot_not_adopted\",\"botId\":" + bot.jevId); return undefined; }
	deadline = getTime() + 15000;
	while (!active(bot) && getTime() < deadline) wait .1;
	if (!active(bot)) return undefined;
	skill = -1; if (isDefined(bot.pers["bots"]) && isDefined(bot.pers["bots"]["skill"]) && isDefined(bot.pers["bots"]["skill"]["base"])) skill = bot.pers["bots"]["skill"]["base"];
	emit("opponent_ready", "\"botId\":" + bot.jevId + ",\"kind\":\"bot_warfare\",\"name\":" + jsonString(bot.name) + ",\"team\":" + jsonString(bot.pers["team"]) + ",\"botsSkill\":" + skill);
	return bot;
}

// Round restarts wipe entity fields but keep pers[] and the test clients themselves, so identities,
// life and sequence counters live in pers[] and a reconnecting player gets its old id back.
registerPlayer()
{
	s = level.jevBot;
	self.jevId = self allocateId();
	self.pers["jevId"] = self.jevId;
	self.jevLife = 0; if (isDefined(self.pers["jevLife"])) self.jevLife = self.pers["jevLife"];
	self.jevLastShotAt = undefined; self.jevLastShotPos = undefined;
	self.jevTaken = []; self.jevDealt = []; self.jevKills = [];
	s.players[s.players.size] = self;
	self.jevModelReady = false;
	self thread watchModel(); self thread watchDeaths(); self thread watchFire(); self thread watchDamage(); self thread watchPlant();
}

// Ids travel on the wire: the controller commands bots by slot 0..7 and names enemies by id.
// The lab hands ids out in join order. A live server keeps bots in 0..7 and everyone else from 8,
// reusing the lowest free id so an evening of joins and quits never runs the space out.
allocateId()
{
	s = level.jevBot;
	if (!s.live)
	{
		if (isDefined(self.pers["jevId"])) { if (self.pers["jevId"] >= s.nextId) s.nextId = self.pers["jevId"] + 1; return self.pers["jevId"]; }
		id = s.nextId; s.nextId++;
		return id;
	}
	low = 8; high = 8 + 64;
	if (isDefined(self.pers["jevControlled"])) { low = 0; high = 8; }
	taken = []; kept = [];
	for (i = 0; i < s.players.size; i++)
	{
		p = s.players[i];
		if (!isDefined(p) || p == self) continue;
		kept[kept.size] = p;
		taken[p.jevId] = true;
	}
	s.players = kept;
	if (isDefined(self.pers["jevId"]) && self.pers["jevId"] >= low && self.pers["jevId"] < high && !isDefined(taken[self.pers["jevId"]])) return self.pers["jevId"];
	for (id = low; id < high; id++) if (!isDefined(taken[id])) return id;
	return high - 1;
}

joinTeam(team)
{
	deadline = getTime() + 10000;
	while (!isDefined(self.pers["team"]) && getTime() < deadline) wait .1;
	self notify("menuresponse", game["menu_team"], team);
	wait .5;
	self notify("menuresponse", "changeclass", botClass());
	deadline = getTime() + 15000;
	while (!active(self) && getTime() < deadline) wait .1;
	if (!active(self)) return false;
	if ((!level.teamBased || self.jevExpectedTeam == "autoassign") && (self.pers["team"] == "allies" || self.pers["team"] == "axis")) self.jevExpectedTeam = self.pers["team"];
	return true;
}

verifyTeam()
{
	expectedSessionTeam = self.jevExpectedTeam;
	if (!level.teamBased) expectedSessionTeam = "none";
	validFaction = self.pers["team"] == "allies" || self.pers["team"] == "axis";
	if (validFaction && self.pers["team"] == self.jevExpectedTeam && self.sessionteam == expectedSessionTeam) return true;
	emit("team_mismatch", "\"botId\":" + self.jevId + ",\"requestedTeam\":" + jsonString(self.jevExpectedTeam) + ",\"team\":" + jsonString(self.pers["team"]) + ",\"sessionTeam\":" + jsonString(self.sessionteam));
	return false;
}

// A team change by hand ends a lab run; on a live server it only drops that bot.
leaveOnTeamChange()
{
	if (!level.jevBot.live) { stop("team_changed"); return; }
	emit("bot_team_changed", "\"botId\":" + self.jevId + ",\"team\":" + jsonString(self.pers["team"]));
	kick(self getEntityNumber());
}

roster()
{
	s = level.jevBot;
	text = "["; separator = "";
	for (i = 0; i < s.players.size; i++)
	{
		p = s.players[i];
		kind = "jev"; if (isDefined(p.jevExternal)) kind = "bot_warfare";
		text += separator + "{\"botId\":" + p.jevId + ",\"kind\":\"" + kind + "\",\"name\":" + jsonString(p.name) + ",\"team\":" + jsonString(p.pers["team"]) + ",\"sessionTeam\":" + jsonString(p.sessionteam) + "}";
		separator = ",";
	}
	return text + "]";
}

// sessionstate turns "playing" before the player model exists, and getTagOrigin on that window is a
// script runtime error, so a player counts as present only between spawned_player and death.
active(player)
{
	return isDefined(player) && isAlive(player) && isDefined(player.sessionstate) && player.sessionstate == "playing" && isDefined(player.jevModelReady) && player.jevModelReady;
}

watchModel()
{
	self endon("disconnect"); level endon("game_ended"); level endon("jev_bot_stop");
	for (;;)
	{
		self waittill("spawned_player");
		self.jevModelReady = true;
	}
}

isEnemy(other)
{
	if (!isDefined(other) || other == self) return false;
	if (level.teamBased && isDefined(other.pers["team"]) && other.pers["team"] == self.pers["team"]) return false;
	return true;
}

watchConnections()
{
	// Late joiners (humans) become ordinary players: enemies while playing, ignored while
	// spectating, because active() already requires sessionstate "playing".
	level endon("game_ended"); level endon("jev_bot_stop");
	for (;;)
	{
		level waittill("connected", player);
		player sanitizeKillstreakStack();
		if (isDefined(player.jevId)) continue;
		player registerPlayer();
		// After a round restart the engine replays "connected" for every client still on the server.
		if (isDefined(player.pers["jevControlled"]))
		{
			player adoptAsJevBot(player.pers["team"]);
			if (isDefined(level.jevBot.readyAt)) { player thread controls(); player thread observations(); }
			emit("bot_readopted", "\"botId\":" + player.jevId);
		}
		else if (isDefined(player.pers["jevExternal"])) { player.jevExternal = true; level.jevBot.external[level.jevBot.external.size] = player; }
	}
}

// The mod banks killstreaks as structs in pers[]; structs do not survive a round restart, and its
// spawn-time restore() then dereferences a dead entry and kills the server. Drop dead entries first.
sanitizeKillstreakStack()
{
	if (!isDefined(self.pers["killstreakStack"])) return;
	stack = self.pers["killstreakStack"];
	clean = [];
	for (i = 0; i < stack.size; i++)
	{
		entry = stack[i];
		if (!isDefined(entry) || !isDefined(entry.type)) continue;
		clean[clean.size] = entry;
	}
	if (clean.size != stack.size) emit("killstreak_stack_repaired", "\"botId\":" + self.jevId + ",\"dropped\":" + (stack.size - clean.size));
	self.pers["killstreakStack"] = clean;
}

elapsedMs()
{
	s = level.jevBot;
	banked = 0; if (isDefined(game["jevElapsedMs"])) banked = game["jevElapsedMs"];
	if (!isDefined(s.readyAt)) return banked;
	return banked + (getTime() - s.readyAt);
}

// ---------------------------------------------------------------- Bot Warfare opponents

botWarfareStart()
{
	// Pins arrive from jev.cfg before the map loads; Bot Warfare fills only empty dvars.
	if (!botWarfareInit()) { emit("bot_warfare_error", "\"reason\":\"not_composed\""); return false; }
	deadline = getTime() + 15000;
	while ((!isDefined(level.bots) || !isDefined(level.waypoints)) && getTime() < deadline) wait .1;
	if (!isDefined(level.bots) || !isDefined(level.waypoints)) { emit("bot_warfare_error", "\"reason\":\"init_timeout\""); return false; }
	if (level.waypoints.size < 1) { emit("bot_warfare_error", "\"reason\":\"no_waypoints\""); return false; }
	version = "unknown"; if (isDefined(level.bw_version)) version = level.bw_version;
	emit("bot_warfare_ready", "\"version\":" + jsonString(version) + ",\"waypoints\":" + level.waypoints.size + ",\"botsSkill\":" + level.jevBot.bwSkill + ",\"count\":" + level.jevBot.bwCount);
	return true;
}

// ---------------------------------------------------------------- watchers

watchSpawns()
{
	self endon("disconnect"); level endon("game_ended"); level endon("jev_bot_stop");
	for (;;)
	{
		self waittill("spawned_player");
		self.jevLife++; self.pers["jevLife"] = self.jevLife;
		self resetExecutor();
		self releaseAll();
		level.jevBot.spawns++;
		emit("spawn", "\"botId\":" + self.jevId + ",\"lifeId\":" + self.jevLife + ",\"pos\":" + jsonVector(self.origin));
	}
}

watchDeaths()
{
	self endon("disconnect"); level endon("game_ended"); level endon("jev_bot_stop");
	for (;;)
	{
		self waittill("death", attacker);
		self.jevModelReady = false; self.jevUsingZone = false; self.jevUsingStreak = false;
		attackerId = -1;
		if (isDefined(attacker) && isDefined(attacker.jevId)) attackerId = attacker.jevId;
		if (attackerId >= 0 && attackerId != self.jevId) recordKill(attacker, self.jevId);
		self.jevDiedFlag = true;
		if (isDefined(self.jevControlled))
		{
			self.jevCmd = undefined;
			self releaseAll();
			level.jevBot.deaths++;
		}
		emit("death", "\"botId\":" + self.jevId + ",\"lifeId\":" + self.jevLife + ",\"attackerId\":" + attackerId + ",\"pos\":" + jsonVector(self.origin));
	}
}

recordKill(attacker, victimId)
{
	r = spawnStruct(); r.victim = victimId; r.time = getTime();
	attacker.jevKills[attacker.jevKills.size] = r;
	if (isDefined(attacker.jevControlled)) level.jevBot.kills++;
	emit("kill", "\"botId\":" + attacker.jevId + ",\"victimId\":" + victimId);
}

watchFire()
{
	self endon("disconnect"); level endon("game_ended"); level endon("jev_bot_stop");
	for (;;)
	{
		self waittill("weapon_fired");
		self.jevLastShotAt = getTime(); self.jevLastShotPos = self.origin;
		if (!isDefined(self.jevControlled)) continue;
		level.jevBot.shots++; self.jevShotsFired++; self.jevShotsSinceObs++;
		self.jevReloading = false;
	}
}

watchDamage()
{
	self endon("disconnect"); level endon("game_ended"); level endon("jev_bot_stop");
	for (;;)
	{
		self waittill("damage", amount, attacker, direction, point, type);
		if (!isDefined(amount) || amount <= 0) continue;
		attackerId = -1; attackerPos = undefined;
		if (isDefined(attacker) && isDefined(attacker.jevId)) { attackerId = attacker.jevId; attackerPos = attacker.origin; }
		r = spawnStruct(); r.from = attackerId; r.amount = amount; r.time = getTime(); r.pos = attackerPos;
		self.jevTaken[self.jevTaken.size] = r;
		if (attackerId >= 0 && attackerId != self.jevId)
		{
			if (self isEnemy(attacker) && active(attacker)) self senseEnemy(attacker);
			d = spawnStruct(); d.to = self.jevId; d.amount = amount; d.time = getTime();
			attacker.jevDealt[attacker.jevDealt.size] = d;
			if (isDefined(attacker.jevControlled)) { level.jevBot.damageEvents++; level.jevBot.damage += amount; }
		}
		emit("damage", "\"botId\":" + self.jevId + ",\"attackerId\":" + attackerId + ",\"amount\":" + amount);
	}
}

watchReloadStart()
{
	self endon("disconnect"); level endon("game_ended"); level endon("jev_bot_stop");
	for (;;)
	{
		self waittill("reload_start");
		self.jevReloading = true; self.jevReloadStartedAt = getTime(); self.jevReloadStartedFlag = true;
	}
}

watchReload()
{
	self endon("disconnect"); level endon("game_ended"); level endon("jev_bot_stop");
	for (;;)
	{
		self waittill("reload");
		level.jevBot.reloads++;
		self.jevReloading = false;
	}
}

watchWeaponChange()
{
	self endon("disconnect"); level endon("game_ended"); level endon("jev_bot_stop");
	for (;;)
	{
		self waittill("weapon_change");
		self.jevReloading = false;
	}
}

watchGrenadePullback()
{
	self endon("disconnect"); level endon("game_ended"); level endon("jev_bot_stop");
	for (;;)
	{
		self waittill("grenade_pullback", weapon);
		self.jevGrenadeActive = true;
	}
}

watchGrenadeFire()
{
	self endon("disconnect"); level endon("game_ended"); level endon("jev_bot_stop");
	for (;;)
	{
		self waittill("grenade_fire", grenade, weapon);
		self.jevGrenadeActive = false;
		self.jevGrenadeThrowing = false;
		level.jevBot.grenadeThrows++;
		emit("grenade_fire", "\"botId\":" + self.jevId);
	}
}

// ---------------------------------------------------------------- executor state

resetExecutor()
{
	self.jevCmd = undefined;
	self.jevMem = [];
	self.jevHeld = []; self.jevHeld["use"] = false; self.jevUsingStreak = false; self.jevThrowPlan = undefined;
	buttons = strTok("fire;ads;sprint;crouch;prone;frag", ";");
	for (i = 0; i < buttons.size; i++) self.jevHeld[buttons[i]] = false;
	self.jevMoving = false;
	self.jevPath = []; self.jevPathIndex = 0; self.jevPathGoal = ""; self.jevPathAt = 0; self.jevPathNode = -1;
	self.jevPathRemaining = 0; self.jevMoveTarget = undefined;
	self.jevBestRemaining = 999999; self.jevBestRemainingAt = getTime(); self.jevGoalPoint = undefined;
	self.jevStuckLevel = 0; self.jevStuckSince = 0; self.jevProgressPos = self.origin; self.jevProgressAt = getTime(); self.jevProgress = 0;
	self.jevSkipNode = -1; self.jevSkipUntil = 0;
	self.jevFirePressedAt = undefined; self.jevLastPressAt = 0;
	self.jevShotsFired = 0; self.jevShotsSinceObs = 0;
	self.jevReloading = false; self.jevReloadStartedAt = undefined; self.jevReloadStartedFlag = false;
	self.jevReloadPulseAt = 0;
	self.jevGrenadeActive = false; self.jevGrenadeThrowing = false; self.jevGrenadeHoldAt = undefined;
	self.jevDiedFlag = false;
	self.jevAimTarget = -1; self.jevAimVisible = false; self.jevAimError = undefined; self.jevFiring = false;
	self.jevLastObsAt = getTime();
	self.jevLastTargetSeenAt = 0;
	self.jevRejected = [];
	self.jevLastOrigin = undefined;
}

defaultCommand()
{
	c = spawnStruct();
	c.sequence = 0; c.t = -2; c.e = "f"; c.g = "hold"; c.l = "auto"; c.s = "stand"; c.r = "auto"; c.a = "auto"; c.w = "keep";
	return c;
}

controls()
{
	self endon("disconnect"); level endon("game_ended"); level endon("jev_bot_stop");
	for (;;)
	{
		input = getDvar("jev_cmd_" + self.jevId);
		if (input != "" && input != self.jevLastInput)
		{
			self.jevLastInput = input;
			self readCommand(input);
		}
		if (active(self)) self tick();
		wait .05;
	}
}

readCommand(input)
{
	if (input.size > 200) { self rejectCommand("length", 0); return; }
	tokens = strTok(input, " ");
	if (tokens.size < 3 || tokens.size > 12) { self rejectCommand("arity", 0); return; }
	for (i = 0; i < 3; i++) if (!numberToken(tokens[i])) { self rejectCommand("number", 0); return; }
	sequence = int(tokens[0]); life = int(tokens[1]); observed = int(tokens[2]);
	if (sequence < 1 || life < 0 || observed < 0) { self rejectCommand("range", sequence); return; }
	if (sequence <= self.jevAccepted || sequence > self.jevSequence) { self rejectCommand("sequence", sequence); return; }
	if (life != self.jevLife || !active(self)) { self rejectCommand("life", sequence); return; }
	if (observed > getTime() || getTime() - observed >= 1200) { self rejectCommand("stale", sequence); return; }
	slot = sequence % 8;
	if (!isDefined(self.jevObservedSequences[slot]) || self.jevObservedSequences[slot] != sequence || self.jevObservedTimes[slot] != observed) { self rejectCommand("observation", sequence); return; }
	c = self.jevCmd;
	if (!isDefined(c)) c = defaultCommand();
	n = spawnStruct();
	n.t = c.t; n.e = c.e; n.g = c.g; n.l = c.l; n.s = c.s; n.r = c.r; n.a = c.a; n.w = c.w;
	for (i = 3; i < tokens.size; i++)
	{
		pair = strTok(tokens[i], "=");
		if (pair.size != 2 || pair[0].size != 1) { self rejectCommand("pair", sequence); return; }
		key = pair[0]; value = pair[1];
		if (value.size < 1 || value.size > 24) { self rejectCommand("value", sequence); return; }
		if (key == "t") { if (value == "-") n.t = -1; else if (value == "auto") n.t = -2; else if (numberToken(value)) n.t = int(value); else { self rejectCommand("target", sequence); return; } }
		else if (key == "e") { if (value != "f" && value != "h" && value != "k") { self rejectCommand("engage", sequence); return; } n.e = value; }
		else if (key == "g") { if (!validGoal(value)) { self rejectCommand("goal", sequence); return; } n.g = value; }
		else if (key == "l") { if (!validLook(value)) { self rejectCommand("look", sequence); return; } n.l = value; }
		else if (key == "s") { if (value != "stand" && value != "crouch" && value != "prone" && value != "jump") { self rejectCommand("stance", sequence); return; } n.s = value; n.jumped = false; }
		else if (key == "r") { if (value != "auto" && value != "on" && value != "off") { self rejectCommand("sprint", sequence); return; } n.r = value; }
		else if (key == "a") { if (value != "auto" && value != "on" && value != "off") { self rejectCommand("ads", sequence); return; } n.a = value; }
		else if (key == "w") { if (!validWeaponAction(value)) { self rejectCommand("weapon", sequence); return; } n.w = value; }
		else { self rejectCommand("key", sequence); return; }
	}
	if (n.t >= 0 && !isDefined(playerById(n.t))) { self rejectCommand("unknown_target", sequence); return; }
	n.sequence = sequence; n.acceptedAt = getTime();
	self.jevCmd = n; self.jevAccepted = sequence; self.pers["jevAccepted"] = sequence;
	level.jevBot.commands++;
	emit("command_accepted", "\"botId\":" + self.jevId + ",\"sequence\":" + sequence + ",\"lifeId\":" + self.jevLife + ",\"ageMs\":" + (getTime() - observed) + ",\"t\":" + n.t + ",\"e\":\"" + n.e + "\",\"g\":\"" + n.g + "\",\"l\":\"" + n.l + "\",\"s\":\"" + n.s + "\",\"r\":\"" + n.r + "\",\"a\":\"" + n.a + "\",\"w\":\"" + n.w + "\"");
}

rejectCommand(reason, sequence)
{
	level.jevBot.rejected++;
	r = spawnStruct(); r.reason = reason; r.sequence = sequence;
	self.jevRejected[self.jevRejected.size] = r;
	emit("command_rejected", "\"botId\":" + self.jevId + ",\"reason\":" + jsonString(reason) + ",\"sequence\":" + sequence);
}

validGoal(value)
{
	if (value == "hold" || value == "cover" || value == "glitch") return true;
	if (value.size == 5 && getSubStr(value, 0, 4) == "site") return isDefined(zoneByLabel(getSubStr(value, 4, 5)));
	if (value.size >= 2 && getSubStr(value, 0, 1) == "n")
	{
		index = getSubStr(value, 1, value.size);
		return numberToken(index) && int(index) >= 0 && int(index) < level.jevBot.waypoints.size;
	}
	if (value.size >= 6 && getSubStr(value, 0, 5) == "chase") return numberToken(getSubStr(value, 5, value.size));
	return false;
}

validLook(value)
{
	if (value == "auto") return true;
	if (value.size >= 2 && getSubStr(value, 0, 1) == "e") return numberToken(getSubStr(value, 1, value.size));
	return numberToken(value) && float(value) >= -360 && float(value) <= 360;
}

// The class decides which special grenade the bot carries; "tact" throws whichever it has.
grenadeWeapon(kind)
{
	if (kind == "nade") { if (self hasWeapon("frag_grenade_mp")) return "frag_grenade_mp"; return undefined; }
	if (self hasWeapon("flash_grenade_mp")) return "flash_grenade_mp";
	if (self hasWeapon("concussion_grenade_mp")) return "concussion_grenade_mp";
	if (self hasWeapon("smoke_grenade_mp")) return "smoke_grenade_mp";
	return undefined;
}

tacticalCount()
{
	grenade = self grenadeWeapon("tact");
	if (!isDefined(grenade)) return 0;
	return self getWeaponAmmoClip(grenade);
}

tacticalName()
{
	grenade = self grenadeWeapon("tact");
	if (!isDefined(grenade)) return "none";
	return grenade;
}

validWeaponAction(value)
{
	if (value == "keep" || value == "reload" || value == "plant" || value == "defuse" || value == "streak") return true;
	if (value.size > 4 && (getSubStr(value, 0, 4) == "nade" || getSubStr(value, 0, 4) == "tact"))
	{
		parts = strTok(getSubStr(value, 4, value.size), ":");
		if (parts.size != 3) return false;
		for (i = 0; i < 3; i++) if (!numberToken(parts[i])) return false;
		return true;
	}
	return false;
}

numberToken(value)
{
	if (value.size == 0 || value.size > 12) return false;
	digits = 0; points = 0;
	for (i = 0; i < value.size; i++)
	{
		ch = getSubStr(value, i, i + 1);
		if (ch == "-" && i == 0) continue;
		if (ch == ".") { points++; if (points > 1) return false; continue; }
		if (!isSubStr("0123456789", ch)) return false;
		digits++;
	}
	return digits > 0;
}

// Target "auto": the nearest visible enemy, keeping the current one while it stays visible so aim does not flicker.
nearestVisibleEnemy()
{
	if (self.jevAimTarget >= 0)
	{
		m = self.jevMem[self.jevAimTarget];
		p = playerById(self.jevAimTarget);
		if (isDefined(m) && m.visible && m.time > 0 && isDefined(p) && active(p)) return p;
	}
	best = undefined; bestDist = 999999;
	keys = getArrayKeys(self.jevMem);
	for (i = 0; i < keys.size; i++)
	{
		m = self.jevMem[keys[i]];
		if (!isDefined(m) || !m.visible || m.time == 0) continue;
		p = playerById(keys[i]);
		if (!isDefined(p) || !active(p)) continue;
		d = distance(self.origin, p.origin);
		if (d < bestDist) { best = p; bestDist = d; }
	}
	return best;
}

playerById(id)
{
	s = level.jevBot;
	for (i = 0; i < s.players.size; i++) if (isDefined(s.players[i]) && s.players[i].jevId == id) return s.players[i];
	return undefined;
}

// ---------------------------------------------------------------- tick: perceive, aim, move, buttons

tick()
{
	c = self.jevCmd;
	if (!isDefined(c)) { c = defaultCommand(); self.jevCmd = c; }
	now = getTime();
	self updateMemory();
	target = undefined;
	if (c.t >= 0) target = playerById(c.t);
	if (c.t == -2) target = self nearestVisibleEnemy();
	if (isDefined(target) && (!active(target) || !self isEnemy(target))) target = undefined;
	targetVisible = false; aimPoint = undefined;
	if (isDefined(target))
	{
		exposure = self exposureOf(target);
		if (exposure != "none")
		{
			targetVisible = true; self.jevLastTargetSeenAt = now;
			aimPoint = self aimPointFor(target, exposure);
		}
	}
	self.jevAimTarget = -1; if (isDefined(target)) self.jevAimTarget = target.jevId;
	self.jevAimVisible = targetVisible;
	// Grenade throws own the hands until the throw lands.
	if (self grenadeStep(c, target)) { self applyStance(c.s); self movementStep(c, targetVisible); return; }
	if (self useStep(c)) { self applyStance(c.s); return; }
	if (self streakStep(c)) { self applyStance(c.s); return; }
	if (targetVisible) self aimAt(aimPoint, target getVelocity(), 30, 12);
	else self lookIdle(c);
	self fireStep(c, target, targetVisible, aimPoint);
	self adsStep(c, target, targetVisible);
	self reloadStep(c, targetVisible);
	self jumpStep(c);
	self applyStance(c.s);
	self movementStep(c, targetVisible);
	self sprintStep(c, targetVisible);
	self trackProgress();
}

// A scoped rifle only hits from a standstill; the bot plants its feet while a target beyond hip range is in view.
sniperHoldsStill(target, targetVisible)
{
	if (!targetVisible || !isDefined(target)) return false;
	if (!isSniper(self getCurrentWeapon())) return false;
	return distance(self.origin, target.origin) > 250;
}

// ---------------------------------------------------------------- perception

eyePos(player)
{
	if (level.jevBot.native && active(player) && isDefined(player.jevControlled))
	{
		state = nativeStateAdapter(player, player.origin, player getPlayerAngles(), player getCurrentWeapon());
		if (isDefined(state) && state.size > 35 && state[0] >= 3) return state[34];
	}
	height = 60; stance = player getStance();
	if (stance == "crouch") height = 40;
	if (stance == "prone") height = 11;
	return player.origin + (0, 0, height);
}

headPoint(player)
{
	point = player getTagOrigin("j_head");
	if (!isDefined(point)) point = eyePos(player);
	return point;
}

chestPoint(player)
{
	point = player getTagOrigin("j_spine4");
	if (!isDefined(point)) point = player.origin + (0, 0, 45);
	return point;
}

clearTo(eye, point)
{
	return sightTracePassed(eye, point, false, self);
}

inCone(eye, point, halfAngleCos)
{
	angles = self getPlayerAngles();
	forward = anglesToForward(angles);
	return vectorDot(forward, vectorNormalize(point - eye)) >= halfAngleCos;
}

exposureOf(enemy)
{
	// 120 degree cone plus clear sight to head and/or chest. Cone is on the chest.
	eye = self eyePos(self);
	chest = chestPoint(enemy);
	if (!self inCone(eye, chest, .5)) return "none";
	head = self clearTo(eye, headPoint(enemy));
	body = self clearTo(eye, chest);
	if (head && body) return "both";
	if (head) return "head";
	if (body) return "body";
	return "none";
}

aimPointFor(enemy, exposure)
{
	if (exposure == "body") return chestPoint(enemy);
	point = headPoint(enemy);
	// Bias slightly down from the head tag toward the neck for hit-box tolerance.
	return point - (0, 0, 2);
}

updateMemory()
{
	// Refresh visible enemies into memory every tick; the cost is a few traces per enemy.
	s = level.jevBot; now = getTime();
	eye = self eyePos(self);
	for (i = 0; i < s.players.size; i++)
	{
		p = s.players[i];
		if (!isDefined(p) || !self isEnemy(p) || isDefined(p.jevSpectator)) continue;
		id = p.jevId;
		// A dead enemy respawns somewhere else, so its last position is worthless.
		if (!active(p)) { if (isDefined(self.jevMem[id])) { self.jevMem[id].time = 0; self.jevMem[id].visible = false; } continue; }
		exposure = self exposureOf(p);
		m = self.jevMem[id];
		if (!isDefined(m)) { m = spawnStruct(); m.visible = false; m.seenSince = 0; m.time = 0; self.jevMem[id] = m; }
		if (exposure != "none")
		{
			if (!m.visible) m.seenSince = now;
			m.visible = true; m.exposure = exposure; m.pos = p.origin; m.vel = p getVelocity(); m.time = now; m.lost = ""; m.sensed = false;
			continue;
		}
		if (m.visible)
		{
			m.visible = false;
			// Lost while still facing them means they broke line of sight.
			if (self inCone(eye, chestPoint(p), .5)) m.lost = "theirs"; else m.lost = "ours";
		}
		// Ears: footsteps close by, sprinting a little farther, gunfire much farther.
		if (self hears(p)) self senseEnemy(p);
	}
}

lostWord(m)
{
	if (isDefined(m.lost) && m.lost != "") return m.lost;
	return "theirs";
}

// Does the enemy's view point our way (within about 70 degrees)? False means their back is turned.
enemyFacesUs(enemy)
{
	angles = enemy getPlayerAngles();
	forward = anglesToForward((0, angles[1], 0));
	toUs = vectorNormalize((self.origin[0] - enemy.origin[0], self.origin[1] - enemy.origin[1], 0));
	return vectorDot(forward, toUs) > 0.34;
}

hears(enemy)
{
	d = distance(self.origin, enemy.origin);
	if (d < 100) return true;
	speed = length(enemy getVelocity());
	if (speed > 250 && d < 450) return true;
	if (speed > 150 && d < 350) return true;
	if (speed > 60 && d < 180) return true;
	if (isDefined(enemy.jevLastShotAt) && getTime() - enemy.jevLastShotAt < 300 && d < 1200) return true;
	return false;
}

// An unseen enemy gave itself away (sound or a hit): remember where, so the idle look turns there.
senseEnemy(enemy)
{
	// Only Jev-controlled bots keep memory; the damage watcher also runs for humans and opponents.
	if (!isDefined(self.jevControlled) || !isDefined(self.jevMem)) return;
	id = enemy.jevId;
	m = self.jevMem[id];
	if (!isDefined(m)) { m = spawnStruct(); m.visible = false; m.seenSince = 0; m.time = 0; self.jevMem[id] = m; }
	if (m.visible) return;
	// Ears place a sound roughly, not exactly: about 15% of the distance off, and no idea of their speed.
	d = distance(self.origin, enemy.origin);
	spread = d * 0.15;
	m.pos = enemy.origin + (randomFloatRange(0 - spread, spread), randomFloatRange(0 - spread, spread), 0);
	m.vel = (0, 0, 0); m.time = getTime(); m.lost = "theirs"; m.sensed = true;
}

memoryOf(id)
{
	m = self.jevMem[id];
	if (!isDefined(m) || m.time == 0) return undefined;
	return m;
}

predictedPos(m)
{
	dt = (getTime() - m.time) / 1000;
	if (dt > 1.5) dt = 1.5;
	return m.pos + (m.vel[0] * dt, m.vel[1] * dt, 0);
}

freshestMemory(maxAgeMs)
{
	best = undefined; bestTime = 0;
	keys = getArrayKeys(self.jevMem);
	for (i = 0; i < keys.size; i++)
	{
		m = self.jevMem[keys[i]];
		if (m.time == 0 || m.visible || getTime() - m.time > maxAgeMs) continue;
		if (m.time > bestTime) { best = m; bestTime = m.time; }
	}
	return best;
}

// ---------------------------------------------------------------- aim

aimAt(point, targetVelocity, farStep, nearStep)
{
	// Lead: the target's velocity over the next 100 ms.
	point += (targetVelocity[0] * .1, targetVelocity[1] * .1, targetVelocity[2] * .1);
	eye = self eyePos(self);
	desired = vectorToAngles(point - eye);
	self turnToward(desired, farStep, nearStep);
	current = self getPlayerAngles();
	self.jevAimError = angularError(current, desired);
}

turnToward(desired, farStep, nearStep)
{
	current = self getPlayerAngles();
	dYaw = angleDelta(desired[1], current[1]);
	dPitch = angleDelta(desired[0], current[0]);
	worst = abs(dYaw); if (abs(dPitch) > worst) worst = abs(dPitch);
	step = farStep;
	if (worst <= 8) step = nearStep;
	if (worst <= step) { self setPlayerAngles((desired[0], desired[1], 0)); return; }
	scale = step / worst;
	yaw = current[1] + dYaw * scale; pitch = clamp(current[0] + dPitch * scale, -85, 85);
	self setPlayerAngles((pitch, yaw, 0));
}

lookIdle(c)
{
	desired = undefined;
	if (c.l != "auto")
	{
		if (getSubStr(c.l, 0, 1) == "e")
		{
			m = self memoryOf(int(getSubStr(c.l, 1, c.l.size)));
			if (isDefined(m)) desired = vectorToAngles(predictedPos(m) + (0, 0, 50) - self eyePos(self));
		}
		else desired = (0, float(c.l), 0);
	}
	if (!isDefined(desired) && self.jevAimTarget >= 0)
	{
		m = self memoryOf(self.jevAimTarget);
		if (isDefined(m) && getTime() - m.time < 4000) desired = vectorToAngles(predictedPos(m) + (0, 0, 50) - self eyePos(self));
	}
	if (!isDefined(desired))
	{
		m = self freshestMemory(6000);
		if (isDefined(m)) desired = self watchAngleFor(predictedPos(m));
	}
	if (!isDefined(desired) && self.jevMoving && isDefined(self.jevMoveTarget) && distance2D(self.jevMoveTarget, self.origin) > 24)
	{
		ahead = vectorToAngles(self.jevMoveTarget - self.origin);
		desired = (0, ahead[1], 0);
	}
	if (!isDefined(desired)) return;
	self turnToward((angleDelta(desired[0], 0), desired[1], 0), 18, 9);
	self.jevAimError = undefined;
}

angularError(current, desired)
{
	dYaw = angleDelta(desired[1], current[1]);
	dPitch = angleDelta(desired[0], current[0]);
	return sqrt(dYaw * dYaw + dPitch * dPitch);
}

// ---------------------------------------------------------------- fire, ADS, reload, grenade

weaponReady()
{
	if (self.jevReloading || self.jevGrenadeActive || self.jevGrenadeThrowing) return false;
	if (level.jevBot.native)
	{
		state = nativeStateAdapter(self, self.origin, self getPlayerAngles(), self getCurrentWeapon());
		if (isDefined(state) && state.size > 11) return state[4] == 0;
	}
	return true;
}

// jev_class picks the stock class the Jev bots spawn with (assault_mp by default).
botClass()
{
	name = getDvar("jev_class");
	if (name == "") return "assault_mp";
	return name;
}

isSniper(weapon)
{
	return isSubStr(weapon, "m40a3") || isSubStr(weapon, "remington700") || isSubStr(weapon, "barrett") || isSubStr(weapon, "dragunov") || isSubStr(weapon, "m21");
}

fireStep(c, target, targetVisible, aimPoint)
{
	now = getTime();
	if (isDefined(self.jevFirePressedAt) && now - self.jevFirePressedAt >= 60) self hold("fire", "fire", false);
	if (isDefined(self.jevMeleePressedAt) && now - self.jevMeleePressedAt >= 120) self hold("melee", "melee", false);
	if (self.jevHeld["fire"]) { self.jevFiring = true; return; }
	self.jevFiring = false;
	if (!targetVisible || c.e == "h") return;
	// Inside knife range the weapon collides and lowers, so a knife is the only shot that lands; knife mode wants it anyway.
	if (distance(self.origin, target.origin) < 90)
	{
		if (!isDefined(self.jevLastMeleeAt) || now - self.jevLastMeleeAt >= 800) { self hold("melee", "melee", true); self.jevMeleePressedAt = now; self.jevLastMeleeAt = now; }
		return;
	}
	if (c.e == "k") return;
	weapon = self getCurrentWeapon();
	if (weapon == "none" || weapon == "" || self getWeaponAmmoClip(weapon) <= 0) return;
	if (!self weaponReady() || self.jevHeld["sprint"]) return;
	if (now - self.jevLastPressAt < 230) return;
	dist = distance(self eyePos(self), aimPoint);
	tolerance = clamp(700 / dist, 1.5, 6);
	if (isSniper(weapon))
	{
		// Quickscope rhythm: no-scope inside 400u, otherwise fire the moment the scope is most of the way up.
		if (dist > 400 && self playerADS() < 0.6) return;
		tolerance = clamp(400 / dist, 0.8, 3);
	}
	if (!isDefined(self.jevAimError) || self.jevAimError > tolerance) return;
	if (!self clearTo(self eyePos(self), aimPoint)) return;
	self hold("fire", "fire", true);
	self.jevFirePressedAt = now; self.jevLastPressAt = now; self.jevFiring = true;
}

adsStep(c, target, targetVisible)
{
	want = false;
	if (c.a == "on") want = true;
	if (c.a == "auto" && targetVisible && isDefined(target) && distance(self.origin, target.origin) > 260) want = true;
	if (c.a == "auto" && !targetVisible && self.jevHeld["ads"] && getTime() - self.jevLastTargetSeenAt < 1000) want = true;
	// A sniper scopes only with the rifle ready and a target in view, so it drops the scope while the bolt cycles.
	if (c.a == "auto" && isSniper(self getCurrentWeapon())) want = targetVisible && self weaponReady();
	if (self.jevReloading || self.jevGrenadeActive || self.jevGrenadeThrowing || self.jevHeld["sprint"] || c.e == "k") want = false;
	self hold("ads", "ads", want);
	// Held breath removes scope sway, the reason a perfectly aimed sniper shot still misses.
	self hold("breath", "holdbreath", want && targetVisible && isSniper(self getCurrentWeapon()));
}

reloadStep(c, targetVisible)
{
	now = getTime();
	weapon = self getCurrentWeapon();
	if (weapon == "none" || weapon == "") return;
	clip = self getWeaponAmmoClip(weapon); reserve = self getWeaponAmmoStock(weapon);
	if (reserve <= 0 || clip >= weaponClipSize(weapon)) return;
	if (self.jevReloading || self.jevGrenadeActive || self.jevGrenadeThrowing) return;
	want = c.w == "reload" || clip == 0 || (clip <= 9 && !targetVisible);
	if (!want || now - self.jevReloadPulseAt < 400) return;
	self botAction("+reload");
	self.jevReloadPulseAt = now;
	self thread releaseReloadButton();
	if (c.w == "reload") c.w = "keep";
}

releaseReloadButton()
{
	self endon("disconnect");
	wait .05;
	self botAction("-reload");
}

grenadeStep(c, target)
{
	// Returns true while a throw is in progress so aim and trigger stay off.
	now = getTime();
	if (self.jevGrenadeThrowing)
	{
		if (isDefined(self.jevGrenadeHoldAt) && now - self.jevGrenadeHoldAt >= 350 && isDefined(self.jevGrenadeButton) && self.jevHeld[self.jevGrenadeButton]) self hold(self.jevGrenadeButton, self.jevGrenadeButton, false);
		if (now - self.jevGrenadeHoldAt > 2500) { self.jevGrenadeThrowing = false; self.jevGrenadeActive = false; }
		return true;
	}
	if (c.w.size <= 4 || (getSubStr(c.w, 0, 4) != "nade" && getSubStr(c.w, 0, 4) != "tact")) { self.jevThrowPlan = undefined; return false; }
	if (self.jevReloading || self.jevGrenadeActive) return false;
	kind = getSubStr(c.w, 0, 4);
	grenade = self grenadeWeapon(kind);
	if (!isDefined(grenade) || self getWeaponAmmoClip(grenade) <= 0) { c.w = "keep"; return false; }
	self.jevGrenadeButton = "frag"; if (kind == "tact") self.jevGrenadeButton = "smoke";
	parts = strTok(getSubStr(c.w, 4, c.w.size), ":");
	point = (float(parts[0]), float(parts[1]), float(parts[2]));
	plan = self throwPlanFor(point, kind);
	if (!plan.done) return false;
	if (!isDefined(plan.best))
	{
		c.w = "keep"; self.jevThrowPlan = undefined;
		emit("grenade_blocked", "\"botId\":" + self.jevId + ",\"kind\":\"" + kind + "\",\"point\":" + jsonVector(point));
		return false;
	}
	desired = plan.best;
	if (self.jevHeld["fire"]) self hold("fire", "fire", false);
	if (self.jevHeld["ads"]) self hold("ads", "ads", false);
	self turnToward(desired, 30, 12);
	if (angularError(self getPlayerAngles(), desired) > 4) return true;
	self hold(self.jevGrenadeButton, self.jevGrenadeButton, true);
	self.jevGrenadeThrowing = true; self.jevGrenadeHoldAt = now;
	c.w = "keep";
	emit("grenade_throw", "\"botId\":" + self.jevId + ",\"kind\":\"" + kind + "\",\"weapon\":\"" + grenade + "\",\"point\":" + jsonVector(point) + ",\"bounces\":" + plan.bestBounces + ",\"landing\":" + jsonVector(plan.bestLanding) + ",\"errorU\":" + int(plan.bestError));
	self.jevThrowPlan = undefined;
	return true;
}

// Simulated throw: 1000 u/s, gravity 800, 50 ms steps. Walls reflect the grenade (restitution 0.55), floors stop it.
// Returns the rest point, the bounce count, and how far it flew before the first wall hit.
throwLanding(eye, angles, fuse)
{
	vel = anglesToForward(angles) * 1000;
	pos = eye; travelled = 0; bounces = 0; firstHit = 999999; landed = false;
	steps = int(fuse / 0.05);
	for (step = 0; step < steps; step++)
	{
		next = pos + vel * 0.05 + (0, 0, -1);
		vel = vel + (0, 0, -40);
		if (bulletTracePassed(pos, next, false, self)) { travelled += distance(pos, next); pos = next; continue; }
		trace = bulletTrace(pos, next, false, self);
		hit = trace["position"]; normal = trace["normal"];
		travelled += distance(pos, hit);
		if (normal[2] > 0.7) { pos = hit; landed = true; break; }
		if (bounces == 0) firstHit = travelled;
		bounces++;
		if (bounces > 3) { pos = hit; break; }
		vel = (vel - normal * (2 * vectorDot(vel, normal))) * 0.55;
		pos = hit + normal * 2;
	}
	r = spawnStruct(); r.point = pos; r.bounces = bounces; r.firstHit = firstHit; r.travelled = travelled; r.landed = landed;
	return r;
}

// Incremental throw planning: one yaw column per tick across eleven directions and five pitches, so bank
// shots off walls are found without stalling the frame. A throw whose first wall is within 120u or whose
// rest point is within 220u of us is refused: that is the grenade that bounces back into our own feet.
throwPlanFor(point, kind)
{
	if (!isDefined(self.jevThrowPlan) || distance(self.jevThrowPlan.target, point) > 150)
	{
		plan = spawnStruct(); plan.target = point; plan.column = 0; plan.done = false;
		plan.best = undefined; plan.bestError = 999999; plan.bestBounces = 0; plan.bestLanding = point;
		self.jevThrowPlan = plan;
	}
	plan = self.jevThrowPlan;
	if (plan.done) return plan;
	yaws = []; yaws[0] = 0; yaws[1] = 8; yaws[2] = -8; yaws[3] = 16; yaws[4] = -16; yaws[5] = 28; yaws[6] = -28; yaws[7] = 45; yaws[8] = -45; yaws[9] = 70; yaws[10] = -70; yaws[11] = 100; yaws[12] = -100;
	pitches = []; pitches[0] = -2; pitches[1] = -6; pitches[2] = -12; pitches[3] = -20; pitches[4] = -30; pitches[5] = -42; pitches[6] = -55;
	// Frag: 350 ms cook leaves about 3 s of flight. Stun and flash burn about 1.8 s.
	fuse = 3.0; if (kind == "tact") fuse = 1.8;
	accept = 170; if (kind == "tact") accept = 220;
	eye = self eyePos(self);
	toTarget = vectorToAngles(point - eye);
	baseYaw = toTarget[1];
	// Four directions per tick: the whole fan is planned inside 150 ms, well under one decision interval.
	stopColumn = plan.column + 4;
	for (column = plan.column; column < stopColumn && column < yaws.size; column++)
	for (i = 0; i < pitches.size; i++)
	{
		angles = (pitches[i], baseYaw + yaws[column], 0);
		landing = self throwLanding(eye, angles, fuse);
		if (landing.bounces > 0 && landing.firstHit < 120) continue;
		if (distance2D(landing.point, self.origin) < 220) continue;
		// Error is measured in three dimensions: a grenade that goes off high above the target does nothing.
		error = distance(landing.point, point);
		if (!landing.landed) error += 150;
		// Prefer a bank shot that lands closer; a direct throw wins ties.
		if (error < plan.bestError - 20 || (error < plan.bestError && landing.bounces == 0))
		{
			plan.bestError = error; plan.best = angles; plan.bestBounces = landing.bounces; plan.bestLanding = landing.point;
		}
	}
	plan.column = stopColumn;
	if (plan.column >= yaws.size)
	{
		plan.done = true;
		if (plan.bestError > accept) plan.best = undefined;
	}
	return plan;
}

// g=cover: the nearest spot within two steps that the freshest enemy's eyes cannot see and that we can
// walk to in a straight line. Computed once per command, so the bot commits to one piece of cover.
coverPoint(c)
{
	if (isDefined(c.coverPoint)) return c.coverPoint;
	if (isDefined(c.coverSearched) && c.coverSearched) return undefined;
	c.coverSearched = true;
	m = self freshestMemory(6000);
	if (!isDefined(m)) return undefined;
	threatEye = predictedPos(m) + (0, 0, 55);
	best = undefined; bestDist = 999999;
	for (ring = 0; ring < 2; ring++)
	{
		radius = 70 + ring * 70;
		for (k = 0; k < 12; k++)
		{
			dir = anglesToForward((0, k * 30, 0));
			p = self.origin + dir * radius;
			if (!bulletTracePassed(self.origin + (0, 0, 30), p + (0, 0, 30), false, self)) continue;
			floor = bulletTrace(p + (0, 0, 40), p - (0, 0, 90), false, self);
			if (floor["fraction"] >= 1) continue;
			p = floor["position"];
			if (sightTracePassed(threatEye, p + (0, 0, 55), false, undefined)) continue;
			d = distance2D(self.origin, p);
			if (d < bestDist) { best = p; bestDist = d; }
		}
	}
	c.coverPoint = best;
	if (isDefined(best)) emit("cover_dash", "\"botId\":" + self.jevId + ",\"point\":" + jsonVector(best) + ",\"dist\":" + int(bestDist));
	return best;
}

// Where to look for an enemy remembered at `point`: at the point itself when it is in view, otherwise at the
// waypoint we can see that lies nearest to them, which is the corner they will appear from. Staring at a
// body through a wall is how a bot gives itself away as a bot.
watchAngleFor(point)
{
	eye = self eyePos(self);
	if (self clearTo(eye, point + (0, 0, 50))) return vectorToAngles(point + (0, 0, 50) - eye);
	s = level.jevBot;
	myNode = self nearestNode(self.origin);
	if (!isDefined(s.sightRows[myNode])) return vectorToAngles(point + (0, 0, 50) - eye);
	best = undefined; bestDist = 999999;
	for (i = 0; i < s.waypoints.size; i++)
	{
		if (i == myNode || !isSubStr(s.sightRows[myNode], "," + i + ",")) continue;
		d = distance2D(s.waypoints[i].origin, point);
		if (d < bestDist) { bestDist = d; best = s.waypoints[i].origin; }
	}
	if (!isDefined(best)) return vectorToAngles(point + (0, 0, 50) - eye);
	return vectorToAngles(best + (0, 0, 50) - eye);
}

// g=glitch: the nearest spot within two steps where standing eyes see the enemy's position but a crouched
// body does not, the classic head glitch. Computed once per command.
glitchPoint(c)
{
	if (isDefined(c.glitchPoint)) return c.glitchPoint;
	if (isDefined(c.glitchSearched) && c.glitchSearched) return undefined;
	c.glitchSearched = true;
	m = self freshestMemory(10000);
	if (!isDefined(m)) return undefined;
	threat = predictedPos(m) + (0, 0, 45);
	best = undefined; bestDist = 999999;
	for (ring = 0; ring < 3; ring++)
	{
		radius = 60 + ring * 70;
		for (k = 0; k < 12; k++)
		{
			dir = anglesToForward((0, k * 30, 0));
			p = self.origin + dir * radius;
			if (ring > 0 && !bulletTracePassed(self.origin + (0, 0, 30), p + (0, 0, 30), false, self)) continue;
			floor = bulletTrace(p + (0, 0, 40), p - (0, 0, 90), false, self);
			if (floor["fraction"] >= 1) continue;
			p = floor["position"];
			if (!sightTracePassed(p + (0, 0, 46), threat, false, undefined)) continue;
			if (sightTracePassed(p + (0, 0, 24), threat, false, undefined)) continue;
			d = distance2D(self.origin, p);
			if (d < bestDist) { best = p; bestDist = d; }
		}
	}
	c.glitchPoint = best;
	if (isDefined(best)) emit("head_glitch", "\"botId\":" + self.jevId + ",\"point\":" + jsonVector(best) + ",\"dist\":" + int(bestDist));
	return best;
}

// ---------------------------------------------------------------- objectives (Search and Destroy)

bombZones()
{
	if (!isDefined(level.bombZones)) return [];
	return level.bombZones;
}

siteLabel(zone)
{
	if (!isDefined(zone.label) || zone.label.size < 2) return "?";
	return toUpper(getSubStr(zone.label, 1, zone.label.size));
}

zoneByLabel(letter)
{
	zones = bombZones();
	for (i = 0; i < zones.size; i++) if (siteLabel(zones[i]) == letter) return zones[i];
	return undefined;
}

bombPlanted()
{
	return isDefined(level.bombPlanted) && level.bombPlanted;
}

isPlantedZone(zone)
{
	if (!bombPlanted() || !isDefined(level.tickingObject) || !isDefined(zone.visuals) || zone.visuals.size == 0) return false;
	return level.tickingObject == zone.visuals[0];
}

role()
{
	if (level.jevBot.gameMode != "sd") return "none";
	if (!isDefined(game["attackers"]) || !isDefined(self.pers["team"])) return "none";
	if (self.pers["team"] == game["attackers"]) return "attack";
	if (self.pers["team"] == game["defenders"]) return "defend";
	return "none";
}

touchedZone()
{
	zones = bombZones();
	for (i = 0; i < zones.size; i++)
	{
		if (self isTouching(zones[i].trigger)) return zones[i];
		if (bombPlanted() && isDefined(zones[i].bombDefuseTrig) && self isTouching(zones[i].bombDefuseTrig)) return zones[i];
	}
	return undefined;
}

// Someone other than us standing in the zone, the closest thing to "in use" without touching the gameobject internals.
zoneOccupied(zone)
{
	s = level.jevBot;
	for (i = 0; i < s.players.size; i++)
	{
		p = s.players[i];
		if (!isDefined(p) || p == self || !active(p)) continue;
		if (p isTouching(zone.trigger)) return true;
	}
	return false;
}

roundLeftMs()
{
	if (!isDefined(level.startTime)) return -1;
	limit = getDvarFloat("scr_" + level.jevBot.gameMode + "_timelimit");
	if (limit <= 0) return -1;
	return int(limit * 60000) - (getTime() - level.startTime);
}

objectiveJson()
{
	zones = bombZones();
	planted = bombPlanted();
	left = -1;
	if (planted && isDefined(level.jevBot.plantedAt) && isDefined(level.bombTimer)) left = int(level.bombTimer * 1000) - (getTime() - level.jevBot.plantedAt);
	text = "\"role\":\"" + self role() + "\",\"planted\":" + jsonBool(planted) + ",\"bombLeftMs\":" + left + ",\"roundLeftMs\":" + roundLeftMs() + ",\"sites\":[";
	sep = "";
	for (i = 0; i < zones.size; i++)
	{
		zone = zones[i]; o = zone.trigger.origin;
		text += sep + "{\"label\":\"" + siteLabel(zone) + "\",\"pos\":" + jsonVectorRound(o) + ",\"dist\":" + int(distance(self.origin, o));
		text += ",\"bearing\":" + roundTenth(self relativeBearing(o + (0, 0, 40))) + ",\"planted\":" + jsonBool(isPlantedZone(zone));
		text += ",\"occupied\":" + jsonBool(self zoneOccupied(zone)) + ",\"touching\":" + jsonBool(self isTouching(zone.trigger)) + "}";
		sep = ",";
	}
	return text + "]";
}

// Holding the use button in a bomb zone plants (attackers) or defuses (defenders); the hands are busy, so no aim, fire or movement.
useStep(c)
{
	// A hold in progress is finished no matter what the next decision says: letting go of the button
	// or stepping out of the zone throws away the seconds already spent.
	if (isDefined(self.jevUsingZone) && self.jevUsingZone)
	{
		if (self.jevMoving) self stopMotor();
		self.jevMoveTarget = undefined;
		self releaseAttackButtons();
		if (!self.jevHeld["use"]) self hold("use", "activate", true);
		return true;
	}
	wantPlant = c.w == "plant" && self role() == "attack" && !bombPlanted();
	wantDefuse = c.w == "defuse" && self role() == "defend" && bombPlanted();
	if (!wantPlant && !wantDefuse)
	{
		if (c.w == "plant" || c.w == "defuse") c.w = "keep";
		if (self.jevHeld["use"]) self hold("use", "activate", false);
		return false;
	}
	zone = self touchedZone();
	if (!isDefined(zone) || self.jevReloading || self.jevGrenadeThrowing || self teammateUsingZone())
	{
		if (self.jevHeld["use"]) self hold("use", "activate", false);
		return false;
	}
	// A hold that just failed is retried after a second, not every tick.
	if (isDefined(self.jevUseFailedAt) && getTime() - self.jevUseFailedAt < 1000) return false;
	if (self.jevMoving) self stopMotor();
	self.jevMoveTarget = undefined;
	self releaseAttackButtons();
	if (self.jevHeld["sprint"]) self hold("sprint", "sprint", false);
	if (!self.jevHeld["use"])
	{
		self hold("use", "activate", true);
		self.jevUseStartedAt = getTime();
		self.jevUseReportAt = undefined;
		emit(c.w + "_start", "\"botId\":" + self.jevId + ",\"site\":\"" + siteLabel(zone) + "\"");
	}
	if (!isDefined(self.jevUseReportAt) || getTime() - self.jevUseReportAt >= 1000)
	{
		self.jevUseReportAt = getTime();
		// The engine never raises the use trigger's "trigger" event for a test client, so the
		// gameobject never starts its hold. Run the same sequence the gameobject would.
		if (!isDefined(self.jevUsingZone) || !self.jevUsingZone) self thread useObjectDirect(zone, wantDefuse);
		vel = self getVelocity();
		emit("use_progress", "\"botId\":" + self.jevId + ",\"site\":\"" + siteLabel(zone) + "\",\"pressed\":" + jsonBool(self useButtonPressed()) + ",\"touching\":" + jsonBool(self isTouching(zone.trigger)) + ",\"weapon\":" + jsonString(self getCurrentWeapon()) + ",\"stance\":" + jsonString(self getStance()) + ",\"speed\":" + int(length(vel)) + ",\"onGround\":" + jsonBool(self isOnGround()) + ",\"team\":" + jsonString(self.pers["team"]) + ",\"owner\":" + jsonString(zone.ownerTeam) + ",\"interact\":" + jsonString(zone.interactTeam) + ",\"inUse\":" + jsonBool(isDefined(zone.inUse) && zone.inUse) + ",\"heldMs\":" + (getTime() - self.jevUseStartedAt));
	}
	if (getTime() - self.jevUseStartedAt > 9000)
	{
		self hold("use", "activate", false);
		emit(c.w + "_timeout", "\"botId\":" + self.jevId + ",\"site\":\"" + siteLabel(zone) + "\"");
		c.w = "keep";
		return false;
	}
	return true;
}

// Mirrors _gameobjects::useObjectUseThink for one player: begin, hold (weapon switch, 5 s), end, use.
useObjectDirect(zone, defusing)
{
	self endon("death"); self endon("disconnect"); level endon("game_ended"); level endon("jev_bot_stop");
	object = zone;
	if (defusing && isDefined(level.sdDefuseObject)) object = level.sdDefuseObject;
	if (isDefined(object.inUse) && object.inUse) return;
	self.jevUsingZone = true;
	// The button state lands one frame after botAction; the hold loop reads it on entry.
	for (i = 0; i < 6 && !self useButtonPressed(); i++) wait .05;
	if (isDefined(object.onBeginUse)) object [[object.onBeginUse]](self);
	team = self.pers["team"];
	// A test client never completes switchToWeapon, and the hold gives up on the briefcase after
	// 1.5 s. Hold with weapons disabled instead, the path the stock code uses for weaponless objects.
	useWeapon = object.useWeapon;
	object.useWeapon = undefined;
	result = object maps\mp\gametypes\_gameobjects::useHoldThink(self);
	object.useWeapon = useWeapon;
	if (isDefined(object.onEndUse)) object [[object.onEndUse]](team, self, result);
	if (isDefined(result) && result && isDefined(object.onUse)) object [[object.onUse]](self);
	throwing = isDefined(self.throwingGrenade) && self.throwingGrenade;
	emit("use_result", "\"botId\":" + self.jevId + ",\"site\":\"" + siteLabel(zone) + "\",\"ok\":" + jsonBool(isDefined(result) && result) + ",\"pressed\":" + jsonBool(self useButtonPressed()) + ",\"touching\":" + jsonBool(self isTouching(object.trigger)) + ",\"throwing\":" + jsonBool(throwing) + ",\"melee\":" + jsonBool(self meleeButtonPressed()) + ",\"weapon\":" + jsonString(self getCurrentWeapon()) + ",\"progress\":" + int(object.curProgress));
	// A grenade animation that never finished leaves the mod's flag set and rejects every hold; clear it.
	if (throwing && !(isDefined(result) && result)) self.throwingGrenade = false;
	self hold("use", "activate", false);
	self.jevUsingZone = false;
	self.jevUseFailedAt = getTime();
}

// In multi-bomb mode a plant that begins disables the other site's object, so two bots planting at once
// abort each other for the whole round. One planter at a time; the other covers.
teammateUsingZone()
{
	s = level.jevBot;
	for (i = 0; i < s.bots.size; i++)
	{
		p = s.bots[i];
		if (!isDefined(p) || p == self) continue;
		if (isDefined(p.jevUsingZone) && p.jevUsingZone) return true;
	}
	return false;
}

// The stock hold loop aborts while melee, fire or a grenade button is down; a planter has to let go of all of them.
releaseAttackButtons()
{
	if (self.jevHeld["fire"]) self hold("fire", "fire", false);
	if (self.jevHeld["ads"]) self hold("ads", "ads", false);
	if (isDefined(self.jevHeld["melee"]) && self.jevHeld["melee"]) self hold("melee", "melee", false);
	if (isDefined(self.jevHeld["frag"]) && self.jevHeld["frag"]) self hold("frag", "frag", false);
	if (isDefined(self.jevHeld["smoke"]) && self.jevHeld["smoke"]) self hold("smoke", "smoke", false);
	self.jevMeleePressedAt = undefined;
}

watchPlant()
{
	self endon("disconnect"); level endon("game_ended"); level endon("jev_bot_stop");
	for (;;)
	{
		self waittill("bomb_planted");
		emit("plant_done", "\"botId\":" + self.jevId + ",\"pos\":" + jsonVector(self.origin));
	}
}

watchBomb()
{
	level endon("game_ended"); level endon("jev_bot_stop");
	s = level.jevBot; s.wasPlanted = false; s.defusedSeen = false; s.explodedSeen = false;
	for (;;)
	{
		wait .1;
		planted = bombPlanted();
		if (planted && !s.wasPlanted) { s.plantedAt = getTime(); emit("bomb_planted", "\"timerMs\":" + int(level.bombTimer * 1000)); }
		if (isDefined(level.bombDefused) && level.bombDefused && !s.defusedSeen) { s.defusedSeen = true; emit("bomb_defused", "\"ok\":true"); }
		if (isDefined(level.bombExploded) && level.bombExploded && !s.explodedSeen) { s.explodedSeen = true; emit("bomb_exploded", "\"ok\":true"); }
		s.wasPlanted = planted;
	}
}

// ---------------------------------------------------------------- killstreaks (classic hardpoints)

streakItem()
{
	if (!isDefined(self.pers["hardPointItem"])) return "none";
	return self.pers["hardPointItem"];
}

// w=streak: call in the earned UAV, airstrike or helicopter the way a client would: switch to the
// hardpoint weapon, and for the airstrike answer the location prompt with the freshest enemy position.
streakStep(c)
{
	now = getTime();
	if (isDefined(self.jevUsingStreak) && self.jevUsingStreak)
	{
		// A death mid-call ends the thread without clearing the flag; never let that freeze the bot.
		if (isDefined(self.jevStreakStartedAt) && now - self.jevStreakStartedAt > 4000) { self.jevUsingStreak = false; return false; }
		if (self.jevMoving) self stopMotor();
		return true;
	}
	if (c.w != "streak") return false;
	c.w = "keep";
	if (self streakItem() == "none" || self.jevReloading || self.jevGrenadeThrowing) return false;
	if (isControlledStreak(self streakItem())) return false;
	if (isDefined(self.jevStreakStartedAt) && now - self.jevStreakStartedAt < 6000) return false;
	self.jevStreakStartedAt = now;
	self thread useStreak(self streakItem());
	return true;
}

useStreak(item)
{
	self endon("death"); self endon("disconnect"); level endon("game_ended"); level endon("jev_bot_stop");
	self.jevUsingStreak = true;
	if (self.jevHeld["fire"]) self hold("fire", "fire", false);
	if (self.jevHeld["ads"]) self hold("ads", "ads", false);
	if (self.jevMoving) self stopMotor();
	target = undefined;
	m = self freshestMemory(20000);
	if (isDefined(m)) target = predictedPos(m);
	if (!isDefined(target)) target = self.origin + anglesToForward(self getPlayerAngles()) * 600;
	// The mod's inventory activates a hardpoint on weapon_change, which a test client never produces.
	// Call its activate routine directly with the slot weapon it expects (custom streaks all ride the
	// radar slot); it triggers the hardpoint, consumes the entry and restores the stack.
	self thread confirmAirstrike(target);
	ok = self code\killstreak_stack::activate(self code\killstreak_stack::weaponFor(item));
	emit("streak_used", "\"botId\":" + self.jevId + ",\"item\":\"" + item + "\",\"ok\":" + jsonBool(isDefined(ok) && ok) + ",\"target\":" + jsonVector(target));
	self.jevUsingStreak = false;
}

// Location streaks (airstrike, artillery, nuke) wait for the map click a client would send; answer with the
// enemy position twice, once the selector has had time to come up. Nobody listening makes the notify a no-op.
confirmAirstrike(target)
{
	self endon("death"); self endon("disconnect"); level endon("game_ended"); level endon("jev_bot_stop");
	wait .4;
	self notify("confirm_location", target);
	wait .6;
	self notify("confirm_location", target);
}

// Streaks that hand the player's view to a missile, drone or helicopter cannot be flown by the executor yet.
isControlledStreak(item)
{
	return item == "agm_mp" || item == "predator_mp" || item == "mannedheli_mp";
}

// ---------------------------------------------------------------- stance and sprint

applyStance(stance)
{
	self hold("crouch", "gocrouch", stance == "crouch");
	self hold("prone", "goprone", stance == "prone");
}

// s=jump: one jump per command, then stand; the fire control keeps working in the air.
jumpStep(c)
{
	if (c.s != "jump" || (isDefined(c.jumped) && c.jumped)) return;
	c.jumped = true;
	self jump();
}

jump()
{
	now = getTime();
	if (isDefined(self.jevLastJumpAt) && now - self.jevLastJumpAt < 900) return;
	self.jevLastJumpAt = now;
	self botAction("+gostand"); self thread releaseJump();
}

sprintStep(c, targetVisible)
{
	want = false;
	if (c.r == "on") want = true;
	if (c.r == "auto" && !targetVisible && self.jevMoving) want = true;
	if (!self.jevMoving || self.jevReloading || self.jevGrenadeThrowing || self.jevHeld["ads"] || self.jevHeld["fire"] || c.e == "k") want = false;
	if (c.s != "stand") want = false;
	self hold("sprint", "sprint", want);
}

hold(control, button, held)
{
	// Normalise: an && expression yields an int in GSC, and comparing that with an undefined slot is a runtime error.
	if (held) held = true; else held = false;
	if (isDefined(self.jevHeld[control]) && self.jevHeld[control] == held) return;
	self.jevHeld[control] = held;
	if (held) self botAction("+" + button);
	else self botAction("-" + button);
}

releaseAll()
{
	self stopMotor();
	keys = getArrayKeys(self.jevHeld);
	for (i = 0; i < keys.size; i++) self.jevHeld[keys[i]] = false;
	self botAction("-fire"); self botAction("-ads"); self botAction("-sprint");
	self botAction("-gocrouch"); self botAction("-goprone"); self botAction("-frag"); self botAction("-reload"); self botAction("-activate"); self botAction("-melee"); self botAction("-holdbreath");
	self.jevFirePressedAt = undefined;
}

stopMotor()
{
	weapon = self getCurrentWeapon();
	self botStop();
	self.jevMoving = false;
	if (weapon != "none" && weapon != "" && self hasWeapon(weapon)) self botWeapon(weapon);
}

// ---------------------------------------------------------------- navigation

buildEdgeLengths()
{
	s = level.jevBot;
	for (i = 0; i < s.waypoints.size; i++)
	{
		n = s.waypoints[i]; n.lengths = [];
		for (k = 0; k < n.children.size; k++) n.lengths[k] = distance(n.origin, s.waypoints[n.children[k]].origin);
	}
}

nearestNode(pos)
{
	s = level.jevBot;
	best = 0; bestDist = 999999;
	for (i = 0; i < s.waypoints.size; i++)
	{
		d = distanceSquared(pos, s.waypoints[i].origin);
		dz = abs(pos[2] - s.waypoints[i].origin[2]);
		if (dz > 90) d += 100000;
		if (d < bestDist) { bestDist = d; best = i; }
	}
	return best;
}

nearestNodeWithSight(pos)
{
	// A waypoint across a container wall is not a usable path start; prefer one we can trace to.
	s = level.jevBot;
	best = -1; bestDist = 999999;
	for (i = 0; i < s.waypoints.size; i++)
	{
		d = distanceSquared(pos, s.waypoints[i].origin);
		if (d >= bestDist || d > 400 * 400) continue;
		if (!bulletTracePassed(pos + (0, 0, 30), s.waypoints[i].origin + (0, 0, 30), false, self)) continue;
		bestDist = d; best = i;
	}
	if (best < 0) return self nearestNode(pos);
	return best;
}

shortestPath(from, to)
{
	// Dijkstra over 75 nodes; edge cost is 3D length. Returns node ids from `from` to `to`.
	s = level.jevBot; n = s.waypoints.size;
	dist = []; prev = []; done = [];
	for (i = 0; i < n; i++) { dist[i] = 999999999; prev[i] = -1; done[i] = false; }
	dist[from] = 0;
	for (iteration = 0; iteration < n; iteration++)
	{
		u = -1; best = 999999999;
		for (i = 0; i < n; i++) if (!done[i] && dist[i] < best) { best = dist[i]; u = i; }
		if (u < 0 || u == to) break;
		done[u] = true;
		node = s.waypoints[u];
		for (k = 0; k < node.children.size; k++)
		{
			v = node.children[k];
			if (isDefined(s.blockedLinks[u + "-" + v])) continue;
			cost = node.lengths[k];
			if (v == self.jevSkipNode && getTime() < self.jevSkipUntil) cost += 2000;
			if (dist[u] + cost < dist[v]) { dist[v] = dist[u] + cost; prev[v] = u; }
		}
	}
	if (dist[to] >= 999999999) return [];
	reversed = []; cur = to;
	while (cur != -1 && reversed.size < n) { reversed[reversed.size] = cur; cur = prev[cur]; }
	path = [];
	for (i = reversed.size - 1; i >= 0; i--) path[path.size] = reversed[i];
	return path;
}

goalPoint(c)
{
	s = level.jevBot;
	if (c.g == "hold") return undefined;
	if (c.g == "cover") return self coverPoint(c);
	if (c.g == "glitch") return self glitchPoint(c);
	if (c.g.size == 5 && getSubStr(c.g, 0, 4) == "site")
	{
		zone = zoneByLabel(getSubStr(c.g, 4, 5));
		if (!isDefined(zone)) return undefined;
		return zone.trigger.origin;
	}
	if (getSubStr(c.g, 0, 1) == "n") return s.waypoints[int(getSubStr(c.g, 1, c.g.size))].origin;
	id = int(getSubStr(c.g, 5, c.g.size));
	p = playerById(id);
	if (isDefined(p) && active(p) && isDefined(self.jevMem[id]) && self.jevMem[id].visible) return p.origin;
	m = self memoryOf(id);
	if (isDefined(m)) return predictedPos(m);
	return undefined;
}

movementStep(c, targetVisible)
{
	now = getTime();
	goal = goalPoint(c);
	if (!isDefined(goal))
	{
		if (self.jevMoving) self stopMotor();
		self.jevPath = []; self.jevPathGoal = ""; self.jevPathRemaining = 0; self.jevMoveTarget = undefined;
		return;
	}
	goalNode = self nearestNode(goal);
	// A chase goal moves with its target; a moved goal point restarts the stall baseline.
	if (!isDefined(self.jevGoalPoint) || distance2D(goal, self.jevGoalPoint) > 100) { self.jevBestRemaining = 999999; self.jevBestRemainingAt = now; }
	self.jevGoalPoint = goal;
	// Replan only when the goal changed, the path ran out, or we drifted far from the next node.
	// Replanning from the nearest node every second walked the bot back to the node it just left.
	offPath = self.jevPathIndex < self.jevPath.size && distance2D(self.origin, level.jevBot.waypoints[self.jevPath[self.jevPathIndex]].origin) > 420;
	replan = self.jevPathGoal != c.g || self.jevPath.size == 0 || offPath || now - self.jevPathAt > 8000;
	if (replan)
	{
		startNode = self nearestNodeWithSight(self.origin);
		self.jevPath = self shortestPath(startNode, goalNode);
		self.jevPathIndex = 0; self.jevPathAt = now; self.jevPathNode = startNode;
		if (self.jevPathGoal != c.g) { self.jevBestRemaining = 999999; self.jevBestRemainingAt = now; }
		self.jevPathGoal = c.g;
		// Skip a leading node we are already past on the way to the one after it.
		while (self.jevPath.size - self.jevPathIndex >= 2)
		{
			first = level.jevBot.waypoints[self.jevPath[self.jevPathIndex]].origin;
			second = level.jevBot.waypoints[self.jevPath[self.jevPathIndex + 1]].origin;
			if (distance2D(self.origin, second) >= distance2D(first, second)) break;
			self.jevPathIndex++;
		}
	}
	// Advance past nodes we have reached; the final leg goes straight to the goal point.
	passed = false;
	while (self.jevPathIndex < self.jevPath.size && distance2D(self.origin, level.jevBot.waypoints[self.jevPath[self.jevPathIndex]].origin) < 40) { self.jevPathIndex++; passed = true; }
	// Rounding a sharp corner with an enemy known nearby: jump through it so a camper's first burst misses.
	if (passed && self.jevPathIndex < self.jevPath.size && self.jevPathIndex >= 1) self cornerJump(goal);
	moveTarget = goal;
	if (self.jevPathIndex < self.jevPath.size) moveTarget = level.jevBot.waypoints[self.jevPath[self.jevPathIndex]].origin;
	else if (!self clearTo(self.origin + (0, 0, 30), goal + (0, 0, 30)))
	{
		// The path ended at the node nearest a point behind a wall; stop here instead of pushing into the wall.
		if (self.jevMoving) self stopMotor();
		self.jevMoveTarget = undefined;
		self.jevPathRemaining = distance2D(self.origin, goal);
		self.jevBestRemainingAt = now;
		return;
	}
	if (distance2D(self.origin, goal) < 150 && self clearTo(self.origin + (0, 0, 30), goal + (0, 0, 30))) moveTarget = goal;
	self.jevPathRemaining = self pathRemaining(goal);
	if (self.jevPathRemaining < self.jevBestRemaining - 30) { self.jevBestRemaining = self.jevPathRemaining; self.jevBestRemainingAt = now; }
	else if (distance2D(self.origin, goal) < 60) { self.jevBestRemainingAt = now; }
	else if (now - self.jevBestRemainingAt > 3000)
	{
		// Moving without closing on the goal for three seconds: the next link is not walkable.
		if (self.jevPathIndex < self.jevPath.size) { self.jevSkipNode = self.jevPath[self.jevPathIndex]; self.jevSkipUntil = now + 12000; self blockCurrentLink(); }
		self.jevPath = []; self.jevBestRemaining = 999999; self.jevBestRemainingAt = now;
		emit("path_stall", "\"botId\":" + self.jevId + ",\"goal\":\"" + c.g + "\",\"remaining\":" + int(self.jevPathRemaining) + ",\"skip\":" + self.jevSkipNode + ",\"pos\":" + jsonVector(self.origin));
		self botAction("+gostand"); self thread releaseJump();
	}
	if (distance2D(self.origin, goal) < 28)
	{
		if (self.jevMoving) self stopMotor();
		self.jevMoveTarget = undefined;
		return;
	}
	self.jevMoveTarget = moveTarget;
	self botMoveTo(moveTarget);
	self.jevMoving = true;
}

cornerJump(goal)
{
	m = self freshestMemory(15000);
	if (!isDefined(m) || distance2D(predictedPos(m), self.origin) > 900) return;
	prev = level.jevBot.waypoints[self.jevPath[self.jevPathIndex - 1]].origin;
	next = level.jevBot.waypoints[self.jevPath[self.jevPathIndex]].origin;
	incoming = vectorNormalize((prev[0] - self.origin[0], prev[1] - self.origin[1], 0));
	outgoing = vectorNormalize((next[0] - self.origin[0], next[1] - self.origin[1], 0));
	// Straight through: incoming and outgoing point opposite ways (dot near -1); a corner is anything sharper than 110 degrees.
	if (vectorDot(incoming, outgoing) < -0.34) return;
	self jump();
	emit("corner_jump", "\"botId\":" + self.jevId + ",\"pos\":" + jsonVector(self.origin));
}

// A link the bot could not walk (a mantle, a drop, a gap) is struck from the graph for the rest of the
// match, on the server and, through the event, in the controller. Authored waypoints assume a mover
// that can climb; this one cannot, so the graph learns what it can actually do.
blockCurrentLink()
{
	s = level.jevBot;
	if (self.jevPathIndex >= self.jevPath.size) return;
	to = self.jevPath[self.jevPathIndex];
	// The node we set out from: the previous path node, else the node the path was planned from. The
	// nearest node is often the unreachable target itself when the bot is stuck a few steps short of it.
	from = -1;
	if (self.jevPathIndex > 0) from = self.jevPath[self.jevPathIndex - 1];
	else if (isDefined(self.jevPathNode)) from = self.jevPathNode;
	if (from < 0 || from == to) from = self nearestNodeExcept(to);
	if (from < 0 || from == to) return;
	key = from + "-" + to;
	if (isDefined(s.blockedLinks[key])) return;
	s.blockedLinks[key] = true;
	emit("link_blocked", "\"botId\":" + self.jevId + ",\"from\":" + from + ",\"to\":" + to + ",\"pos\":" + jsonVector(self.origin));
}

nearestNodeExcept(skip)
{
	s = level.jevBot; best = -1; bestDist = 999999999;
	for (i = 0; i < s.waypoints.size; i++)
	{
		if (i == skip) continue;
		d = distanceSquared(self.origin, s.waypoints[i].origin);
		if (d < bestDist) { bestDist = d; best = i; }
	}
	return best;
}

onPath(node)
{
	for (i = self.jevPathIndex; i < self.jevPath.size; i++) if (self.jevPath[i] == node) return true;
	return false;
}

pathRemaining(goal)
{
	total = 0; prev = self.origin;
	for (i = self.jevPathIndex; i < self.jevPath.size; i++)
	{
		p = level.jevBot.waypoints[self.jevPath[i]].origin;
		total += distance2D(prev, p); prev = p;
	}
	return total + distance2D(prev, goal);
}

trackProgress()
{
	now = getTime();
	if (now - self.jevProgressAt < 1000) return;
	self.jevProgress = distance2D(self.origin, self.jevProgressPos);
	self.jevProgressPos = self.origin; self.jevProgressAt = now;
	if (isDefined(self.jevLastOrigin)) { travel = distance(self.origin, self.jevLastOrigin); self.jevDistance += travel; level.jevBot.travel += travel; }
	self.jevLastOrigin = self.origin;
	if (!self.jevMoving || !isDefined(self.jevMoveTarget)) { self.jevStuckLevel = 0; return; }
	if (self.jevProgress >= 24) { self.jevStuckLevel = 0; return; }
	self.jevStuckLevel++;
	if (self.jevStuckLevel == 1) { self botAction("+gostand"); self thread releaseJump(); }
	else if (self.jevStuckLevel == 2)
	{
		// Skip the next node for a while and replan through another neighbour.
		if (self.jevPathIndex < self.jevPath.size) { self.jevSkipNode = self.jevPath[self.jevPathIndex]; self.jevSkipUntil = now + 8000; self blockCurrentLink(); }
		self.jevPath = []; self.jevPathGoal = "";
	}
	else if (self.jevStuckLevel >= 3)
	{
		angles = self getPlayerAngles();
		self botMoveTo(self.origin + anglesToRight((0, angles[1], 0)) * 96);
		self.jevStuckLevel = 0;
	}
	emit("stuck", "\"botId\":" + self.jevId + ",\"level\":" + self.jevStuckLevel + ",\"progress\":" + self.jevProgress + ",\"pos\":" + jsonVector(self.origin));
}

releaseJump()
{
	self endon("disconnect");
	wait .1;
	self botAction("-gostand");
}

// ---------------------------------------------------------------- observations

observations()
{
	self endon("disconnect"); level endon("game_ended"); level endon("jev_bot_stop");
	for (;;)
	{
		self observation();
		wait .2;
	}
}

observation()
{
	if (!self verifyTeam()) { self leaveOnTeamChange(); return; }
	now = getTime(); since = self.jevLastObsAt; self.jevLastObsAt = now;
	self.jevSequence++; self.pers["jevSequence"] = self.jevSequence;
	slot = self.jevSequence % 8;
	self.jevObservedSequences[slot] = self.jevSequence;
	self.jevObservedTimes[slot] = now;
	head = "\"botId\":" + self.jevId + ",\"sequence\":" + self.jevSequence;
	publish("[jev-observation] {" + head + ",\"part\":\"enemies\"," + self enemiesJson() + "}");
	publish("[jev-observation] {" + head + ",\"part\":\"nav\"," + self navJson() + "}");
	publish("[jev-observation] {" + head + ",\"part\":\"events\"," + self eventsJson(since, now) + "}");
	publish("[jev-observation] {" + head + ",\"part\":\"objective\"," + self objectiveJson() + "}");
	publish("[jev-observation] {" + head + ",\"part\":\"self\",\"parts\":5,\"gameTimeMs\":" + now + "," + self selfJson() + "}");
	self.jevShotsSinceObs = 0; self.jevReloadStartedFlag = false; self.jevDiedFlag = false;
	self.jevRejected = [];
}

relativeBearing(point)
{
	angles = self getPlayerAngles();
	toPoint = vectorToAngles(point - self eyePos(self));
	return angleDelta(toPoint[1], angles[1]);
}

elevation(point)
{
	toPoint = vectorToAngles(point - self eyePos(self));
	return angleDelta(0, toPoint[0]);
}

enemiesJson()
{
	s = level.jevBot; now = getTime();
	visible = ""; remembered = ""; team = "";
	vsep = ""; rsep = ""; tsep = "";
	for (i = 0; i < s.players.size; i++)
	{
		p = s.players[i];
		if (!isDefined(p) || p == self || isDefined(p.jevSpectator)) continue;
		if (!self isEnemy(p))
		{
			if (!active(p)) continue;
			goal = "none"; if (isDefined(p.jevCmd)) goal = p.jevCmd.g;
			team += tsep + "{\"id\":" + p.jevId + ",\"pos\":" + jsonVectorRound(p.origin) + ",\"hp\":" + p.health + ",\"goal\":\"" + goal + "\",\"planting\":" + jsonBool(isDefined(p.jevUsingZone) && p.jevUsingZone) + "}";
			tsep = ",";
			continue;
		}
		m = self.jevMem[p.jevId];
		if (!isDefined(m) || m.time == 0) continue;
		if (m.visible && active(p))
		{
			visible += vsep + "{\"id\":" + p.jevId + ",\"pos\":" + jsonVectorRound(p.origin) + ",\"vel\":" + jsonVectorRound(p getVelocity());
			visible += ",\"dist\":" + int(distance(self.origin, p.origin)) + ",\"bearing\":" + roundTenth(self relativeBearing(chestPoint(p))) + ",\"elev\":" + roundTenth(self elevation(chestPoint(p)));
			visible += ",\"exposed\":\"" + m.exposure + "\",\"seenMs\":" + (now - m.seenSince) + ",\"facingUs\":" + jsonBool(self enemyFacesUs(p)) + "}";
			vsep = ",";
			continue;
		}
		if (now - m.time > 20000) continue;
		pred = predictedPos(m);
		remembered += rsep + "{\"id\":" + p.jevId + ",\"ageMs\":" + (now - m.time) + ",\"pos\":" + jsonVectorRound(pred) + ",\"vel\":" + jsonVectorRound(m.vel);
		remembered += ",\"bearing\":" + roundTenth(self relativeBearing(pred + (0, 0, 40))) + ",\"dist\":" + int(distance(self.origin, pred)) + ",\"lost\":\"" + lostWord(m) + "\",\"heard\":" + jsonBool(isDefined(m.sensed) && m.sensed) + "}";
		rsep = ",";
	}
	return "\"visible\":[" + visible + "],\"remembered\":[" + remembered + "],\"team\":[" + team + "]";
}

navJson()
{
	c = self.jevCmd; goal = "hold"; if (isDefined(c)) goal = c.g;
	next = -1; if (self.jevPathIndex < self.jevPath.size) next = self.jevPath[self.jevPathIndex];
	path = ""; sep = "";
	for (i = self.jevPathIndex; i < self.jevPath.size && i < self.jevPathIndex + 8; i++) { path += sep + self.jevPath[i]; sep = ","; }
	text = "\"node\":" + self nearestNode(self.origin) + ",\"goal\":\"" + goal + "\",\"next\":" + next + ",\"remaining\":" + int(self.jevPathRemaining);
	text += ",\"progress\":" + int(self.jevProgress) + ",\"stuck\":" + jsonBool(self.jevStuckLevel > 0) + ",\"moving\":" + jsonBool(self.jevMoving) + ",\"sprinting\":" + jsonBool(self.jevHeld["sprint"]) + ",\"path\":[" + path + "]";
	return text;
}

eventsJson(since, now)
{
	s = level.jevBot;
	taken = ""; sep = "";
	kept = [];
	for (i = 0; i < self.jevTaken.size; i++)
	{
		r = self.jevTaken[i];
		if (r.time <= since || now - r.time > 2000) continue;
		kept[kept.size] = r;
		bearing = "null"; if (isDefined(r.pos)) bearing = roundTenth(self relativeBearing(r.pos + (0, 0, 40)));
		taken += sep + "{\"from\":" + r.from + ",\"amount\":" + r.amount + ",\"bearing\":" + bearing + ",\"ageMs\":" + (now - r.time) + "}";
		sep = ",";
	}
	self.jevTaken = kept;
	dealt = ""; sep = ""; kept = [];
	for (i = 0; i < self.jevDealt.size; i++)
	{
		d = self.jevDealt[i];
		if (d.time <= since || now - d.time > 2000) continue;
		kept[kept.size] = d;
		dealt += sep + "{\"to\":" + d.to + ",\"amount\":" + d.amount + ",\"ageMs\":" + (now - d.time) + "}";
		sep = ",";
	}
	self.jevDealt = kept;
	kills = ""; sep = ""; kept = [];
	for (i = 0; i < self.jevKills.size; i++)
	{
		k = self.jevKills[i];
		if (k.time < since) continue;
		kept[kept.size] = k;
		kills += sep + k.victim; sep = ",";
	}
	self.jevKills = kept;
	heard = ""; sep = "";
	for (i = 0; i < s.players.size; i++)
	{
		p = s.players[i];
		if (!isDefined(p) || p == self || !isDefined(p.jevLastShotAt) || p.jevLastShotAt <= since || !isDefined(p.jevLastShotPos)) continue;
		d = distance(self.origin, p.jevLastShotPos);
		if (d > 1400) continue;
		heard += sep + "{\"from\":" + p.jevId + ",\"bearing\":" + roundTenth(self relativeBearing(p.jevLastShotPos + (0, 0, 40))) + ",\"dist\":" + int(d) + ",\"ageMs\":" + (now - p.jevLastShotAt) + ",\"enemy\":" + jsonBool(self isEnemy(p)) + "}";
		sep = ",";
	}
	rejected = ""; sep = "";
	for (i = 0; i < self.jevRejected.size && i < 6; i++)
	{
		rejected += sep + "{\"reason\":\"" + self.jevRejected[i].reason + "\",\"sequence\":" + self.jevRejected[i].sequence + "}";
		sep = ",";
	}
	text = "\"dmgTaken\":[" + taken + "],\"dmgDealt\":[" + dealt + "],\"kills\":[" + kills + "],\"died\":" + jsonBool(self.jevDiedFlag);
	text += ",\"shots\":" + self.jevShotsSinceObs + ",\"reloadStarted\":" + jsonBool(self.jevReloadStartedFlag) + ",\"heard\":[" + heard + "],\"rejected\":[" + rejected + "]";
	return text;
}

selfJson()
{
	angles = self getPlayerAngles();
	alive = active(self); weapon = self getCurrentWeapon();
	clip = 0; reserve = 0; clipSize = 0;
	if (weapon != "none" && weapon != "") { clip = self getWeaponAmmoClip(weapon); reserve = self getWeaponAmmoStock(weapon); clipSize = weaponClipSize(weapon); }
	c = self.jevCmd; if (!isDefined(c)) c = defaultCommand();
	text = "\"lifeId\":" + self.jevLife + ",\"alive\":" + jsonBool(alive) + ",\"hp\":" + self.health + ",\"pos\":" + jsonVectorRound(self.origin) + ",\"vel\":" + jsonVectorRound(self getVelocity());
	text += ",\"speed\":" + int(distance2D(self getVelocity(), (0, 0, 0))) + ",\"yaw\":" + roundTenth(angles[1]) + ",\"pitch\":" + roundTenth(angles[0]) + ",\"stance\":" + jsonString(self getStance());
	text += ",\"weapon\":" + jsonString(weapon) + ",\"clip\":" + clip + ",\"reserve\":" + reserve + ",\"clipSize\":" + clipSize + ",\"ads\":" + roundTenth(self playerADS());
	text += ",\"ready\":" + jsonBool(alive && self weaponReady()) + ",\"reloading\":" + jsonBool(self.jevReloading) + ",\"grenades\":" + self grenadeAmmo() + ",\"tactical\":" + self tacticalCount() + ",\"tacticalName\":\"" + self tacticalName() + "\",\"streak\":\"" + self streakItem() + "\"";
	text += ",\"cmd\":{\"sequence\":" + c.sequence + ",\"t\":" + c.t + ",\"e\":\"" + c.e + "\",\"g\":\"" + c.g + "\",\"l\":\"" + c.l + "\",\"s\":\"" + c.s + "\",\"r\":\"" + c.r + "\",\"a\":\"" + c.a + "\",\"w\":\"" + c.w + "\"}";
	text += ",\"aim\":{\"target\":" + self.jevAimTarget + ",\"visible\":" + jsonBool(self.jevAimVisible) + ",\"errorDeg\":" + jsonRound(self.jevAimError) + ",\"firing\":" + jsonBool(self.jevFiring) + "}";
	if (level.jevBot.native && alive)
	{
		state = nativeStateAdapter(self, self.origin, angles, weapon);
		if (isDefined(state) && state.size > 11) text += ",\"native\":{\"stage\":" + state[4] + ",\"remainingMs\":" + nativeTimer(state[5]) + "}";
	}
	return text;
}

grenadeAmmo()
{
	if (!self hasWeapon("frag_grenade_mp")) return 0;
	return self getWeaponAmmoClip("frag_grenade_mp");
}

nativeTimer(value)
{
	if (value < 0) return "0";
	return "" + value;
}

// ---------------------------------------------------------------- math and json

angleDelta(target, current)
{
	delta = target - current;
	while (delta > 180) delta -= 360;
	while (delta < -180) delta += 360;
	return delta;
}

clamp(value, low, high)
{
	if (value < low) return low;
	if (value > high) return high;
	return value;
}

roundTenth(value)
{
	return int(value * 10) / 10;
}

jsonRound(value)
{
	if (!isDefined(value)) return "null";
	return "" + roundTenth(value);
}

jsonVectorRound(v)
{
	return "[" + int(v[0]) + "," + int(v[1]) + "," + int(v[2]) + "]";
}

jsonVector(v)
{
	return "[" + v[0] + "," + v[1] + "," + v[2] + "]";
}

jsonBool(value)
{
	if (isDefined(value) && value) return "true";
	return "false";
}

jsonString(value)
{
	if (!isDefined(value)) return "null";
	result = "\"";
	for (i = 0; i < value.size; i++)
	{
		ch = getSubStr(value, i, i + 1);
		if (ch == "\"") result += "\\\"";
		else if (ch == "\\") result += "\\\\";
		else if (ch == "\n") result += "\\n";
		else if (ch == "\r") result += "\\r";
		else if (ch == "\t") result += "\\t";
		else result += ch;
	}
	return result + "\"";
}

// Node-to-node sightlines at eye height, one node per frame. The controller turns them into
// cover, flank and open-versus-enclosed knowledge that the waypoint graph alone cannot give.
mapSightDump()
{
	level endon("game_ended"); level endon("jev_bot_stop");
	s = level.jevBot;
	for (i = 0; i < s.waypoints.size; i++)
	{
		sees = ""; sep = "";
		a = s.waypoints[i].origin + (0, 0, 60);
		for (j = 0; j < s.waypoints.size; j++)
		{
			if (j == i) continue;
			if (sightTracePassed(a, s.waypoints[j].origin + (0, 0, 60), false, undefined)) { sees += sep + j; sep = ","; }
		}
		emit("map_sight", "\"node\":" + i + ",\"sees\":[" + sees + "]");
		s.sightRows[i] = "," + sees + ",";
		wait .05;
	}
	emit("map_ready", "\"nodes\":" + s.waypoints.size);
}

emit(kind, fields)
{
	publish("[jev-event] {\"event\":" + jsonString(kind) + ",\"gameTimeMs\":" + getTime() + "," + fields + "}");
}

publish(line)
{
	println(line);
	// Closing each record flushes it; the script filesystem resolves this beneath fs_homepath/fs_game.
	file = openfile("jev_telemetry.jsonl", "append");
	if (file > 0)
	{
		fprintln(file, line);
		closefile(file);
	}
}

roundEnd()
{
	level waittill("game_ended");
	s = level.jevBot;
	game["jevElapsedMs"] = elapsedMs();
	if (s.gameMode != "sd") { stop("round_ended"); return; }
	final = isDefined(level.forcedEnd) && level.forcedEnd;
	roundLimit = getDvarInt("scr_sd_roundlimit");
	played = 0; if (isDefined(game["roundsPlayed"])) played = game["roundsPlayed"];
	if (roundLimit > 0 && played + 1 >= roundLimit) final = true;
	scores = "\"allies\":0,\"axis\":0";
	if (isDefined(game["teamScores"])) scores = "\"allies\":" + game["teamScores"]["allies"] + ",\"axis\":" + game["teamScores"]["axis"];
	team = "none"; if (s.bots.size > 0 && isDefined(s.bots[0].pers["team"])) team = s.bots[0].pers["team"];
	emit("round_end", "\"final\":" + jsonBool(final) + ",\"planted\":" + jsonBool(bombPlanted()) + ",\"team\":" + jsonString(team) + ",\"elapsedMs\":" + game["jevElapsedMs"] + ",\"scores\":{" + scores + "}");
	if (final) stop("match_ended");
	// Otherwise the map restarts, this script dies with it, and the next round's main() resumes the match.
}

stop(reason)
{
	s = level.jevBot;
	if (s.stopped) return;
	s.stopped = true;
	if (s.live) setDvar("jev_roster", "");
	for (i = 0; i < s.bots.size; i++)
	{
		if (!isDefined(s.bots[i])) continue;
		s.bots[i].jevCmd = undefined;
		s.bots[i] releaseAll();
	}
	fields = "\"reason\":" + jsonString(reason) + ",\"spawns\":" + s.spawns + ",\"shots\":" + s.shots + ",\"deaths\":" + s.deaths + ",\"kills\":" + s.kills;
	fields += ",\"damageEvents\":" + s.damageEvents + ",\"damage\":" + s.damage + ",\"reloads\":" + s.reloads + ",\"grenadeThrows\":" + s.grenadeThrows;
	fields += ",\"commands\":" + s.commands + ",\"rejectedCommands\":" + s.rejected + ",\"distanceTravelled\":" + int(s.travel);
	emit("summary", fields);
	level notify("jev_bot_stop");
}

// GSC resolves every referenced script at compile time, so the Bot Warfare starts live in a
// block the worker replaces only when the vendored scripts were copied into the private mod.
// JEV_BOT_WARFARE_BEGIN
botWarfareInit() { return false; }
// JEV_BOT_WARFARE_END

// These harmless stubs keep the default script free of unresolved plugin calls.
// The worker replaces only this unique block when the native plugin is opted in.
// JEV_NATIVE_ADAPTER_BEGIN
nativeInfoAdapter() { return undefined; }
nativeStateAdapter(player, origin, angles, weapon) { return undefined; }
nativeTraceAdapter(player, start, end, standing) { return undefined; }
// JEV_NATIVE_ADAPTER_END
