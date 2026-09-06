#!/bin/bash
# Configure the CoD4X server: private, modded, persistent, auto-restarting.
# Run after provision.sh and after game files are in place.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR=/opt/cod4
MOD_DIR="$SERVER_DIR/mods/new_experience"
PRIVATE_ASSET_DIR="${COD4_PRIVATE_ASSET_DIR:-$SERVER_DIR/private-assets}"
GAME_USER=cod4
PASSWORD="${COD4_PASSWORD:?set COD4_PASSWORD}"
HOSTNAME_STR="${COD4_HOSTNAME:-CoD4 Server}"
RCON="${COD4_RCON:?set COD4_RCON}"

# The good maps only, by request. The rest of the stock set loads fine and is
# left out on taste; add a name back here and rerun to have it.
MAPS=(mp_shipment mp_crash mp_vacant)
# Custom maps, installed into usermaps/ by maps.sh. CoD4X only reads usermaps/
# when fs_game is set, which it is - the mod is what makes these loadable at
# all. Only ones actually present go into the rotation: a name the server cannot
# load ends the map with "Error: Could not load ..." and the rotation stalls.
#
# Highrise (mp_highrise) is installed but deliberately not listed. On the
# Rosetta + wined3d client it runs at 21-34 fps with cg at 29-48 ms/frame -
# the whole frame spent in client game code, so nothing in the renderer
# settings touches it. Long sightlines over a few hundred props are more than
# this stack can walk each frame. It comes back if the engine work
# (x87sidecar / DXMT on the 1.8 client) ever lands.
CUSTOM_MAPS=(mp_mw2_rust mp_mw2_term mp_scrapyard)
for m in "${CUSTOM_MAPS[@]}"; do
  if [ -f "$SERVER_DIR/usermaps/$m/$m.ff" ]; then
    MAPS+=("$m")
  else
    echo "warn: $m is not installed (run maps.sh) - leaving it out of the rotation" >&2
  fi
done

# Where clients fetch the custom maps. maps.sh serves the game root over HTTP on
# WWW_PORT (8080, not 80 - see maps.sh for the ISP reason) and the client is
# redirected to $WWW_URL/usermaps/<map>/<file>.
WWW_PORT="${COD4_WWW_PORT:-8080}"
WWW_URL="${COD4_WWW_URL:-http://$(hostname -I | awk '{print $1}'):$WWW_PORT}"

# Free-for-all only. sv_mapRotation carries a gametype forward until the next
# one is named, so dm goes once up front and the maps follow. The mod's mapvote
# (code/mapvote.gsx init) builds its ballot from every mp_ token in this string,
# so each map listed once gives it exactly the six-map ballot mapvote_mapnum
# asks for. When this listed every gametype per map for a gametype vote, the
# ballot carried duplicates.
ROTATION="gametype dm"
for m in "${MAPS[@]}"; do ROTATION+=" map $m"; done

echo "==> writing server.cfg"
cat > "$SERVER_DIR/main/server.cfg" <<EOF
// ---- identity ----
set sv_hostname "$HOSTNAME_STR"
set sv_maxclients 12

// ---- private ----
// g_password gates every join. dedicated 1 also keeps the server off both the
// Activision and CoD4X master lists, so it never appears in a public browser;
// the only way in is knowing the address and the password.
set g_password "$PASSWORD"
set rcon_password "$RCON"
set sv_privateClients 0

// ---- gameplay ----
// Free-for-all only. The gametype vote is off (gametypeVote, in the mod
// config) and the rotation names no other mode, so dm is what the server boots
// into and what it stays on.
set g_gametype dm
set sv_punkbuster 0
set sv_cheats 0

// Everyone brings their own copy of the game, and those copies differ - retail
// vs Steam, different localized iwd sets. sv_pure 1 compares client file
// checksums against the server's and, on a mismatch, stops answering the client
// rather than refusing it: the player reaches CS_CONNECTED, gets no gamestate,
// and is dropped EXE_TIMEDOUT while their screen reads "Server connection timed
// out". The server log says "Bad checksum" and nothing reaches the player.
// g_password is the gate here, so purity buys nothing worth that failure mode.
set sv_pure 0
// Free-for-all to 20 kills. The mod scores a kill at 10 x xp_multi points
// (dm.gsx registerScoreInfo); xp_multi is 1 in the mod config, so a kill is 10
// and 20 kills is 200. Assists add 2 each, so the limit can land a kill early.
set scr_dm_scorelimit 200
set scr_dm_timelimit 20

// ---- authorisation ----
// -1 disables CD-key validation. Clients installed by cod4 setup carry a
// placeholder key that real auth rejects with "Key Code is not valid", and the
// CoD4X auth backend is unreliable regardless. g_password above is the real
// gate, so leaving this out would lock the household out on the next deploy.
set sv_authorizemode "-1"

// ---- network ----
set sv_maxRate 25000
set sv_floodProtect 1

// ---- custom maps, fetched over HTTP ----
// A client missing a map asks the server for it. Left to the game's own UDP
// transfer that runs at a few KB/s and shares the pipe with everyone playing;
// with sv_wwwDownload the server instead hands the client a URL and nginx on
// this box (maps.sh) serves the file at line rate. sv_wwwDlDisconnected 0
// keeps the client's slot through the download so it lands straight in the
// game afterwards rather than reconnecting.
set sv_allowDownload 1
set sv_wwwDownload 1
set sv_wwwBaseURL "$WWW_URL"
set sv_wwwDlDisconnected 0

set sv_mapRotation "$ROTATION"
EOF

# New Experience's tactical nuke uses three radiation shellshock definitions
# from the retail single-player fastfiles. The dedicated-server data set does
# not register those assets automatically. Keep the generated mod.ff beside
# the private server data (never in source control), then install it into the
# mod on every configure run.
echo "==> installing private runtime assets"
if [ ! -f "$PRIVATE_ASSET_DIR/mod.ff" ]; then
  echo "missing private runtime zone: $PRIVATE_ASSET_DIR/mod.ff" >&2
  echo "build it from legally owned retail fastfiles before configuring" >&2
  exit 1
fi
install -o "$GAME_USER" -g "$GAME_USER" -m 0644 \
  "$PRIVATE_ASSET_DIR/mod.ff" "$MOD_DIR/mod.ff"

echo "==> patching the mod"
python3 - "$MOD_DIR" <<'PY'
# The mod is re-fetched from upstream on every provision, so these edits have to
# be reapplied here rather than committed to a fork. All are idempotent.
import pathlib, sys

mod = pathlib.Path(sys.argv[1])

# Seconds of flythrough before the vote opens. Upstream waits 20, which on a
# household server is 20 seconds of nobody doing anything.
PRE_VOTE_WAIT = 6
# Seconds the winning map stays on screen before the level actually changes.
NOTIFY_WAIT = 2

vote = mod / "code/mapvote.gsx"
text = vote.read_text(errors="replace")

# 1. voteLogic counts down the full mapvote_time even when every player has
#    already picked, which on a four-person server is most of the wait.
countdown = "\t\ttime--;\n\t\twait .25;"
early = "\t\ttime--;\n\t\tif( everyoneVoted( players ) )\n\t\t\ttime = 0;\n\t\twait .25;"
quorum = '''
everyoneVoted( players )
{
\t// A player who never picks still holds the vote open for its full length, so
\t// this only short-circuits when the result is already decided. Disconnects
\t// mid-vote leave undefined entries and must not count as abstentions.
\tvoters = 0;
\tfor( i = 0; i < players.size; i++ )
\t{
\t\tplayer = players[ i ];
\t\tif( !isDefined( player ) )
\t\t\tcontinue;
\t\tif( !isDefined( player.votePick ) || player.votePick < 0 )
\t\t\treturn false;
\t\tvoters++;
\t}
\treturn ( voters > 0 );
}
'''
if "everyoneVoted" not in text:
    if countdown not in text:
        sys.exit("mapvote.gsx: voteLogic countdown changed upstream, patch by hand")
    text = text.replace(countdown, early, 1) + quorum
    print("   mapvote.gsx: vote ends as soon as everyone has picked")
else:
    print("   mapvote.gsx: early exit already present")

# 2. The winning map sits on screen for 5 seconds before the level changes.
banner = "\twinningMap.glowColor = ( 1, 0, 0 );\n\t\n\twait 5;"
shortened = banner.replace("wait 5;", "wait %d;" % NOTIFY_WAIT)
if banner in text:
    text = text.replace(banner, shortened, 1)
    print("   mapvote.gsx: winner banner shortened to %ds" % NOTIFY_WAIT)
elif shortened in text:
    print("   mapvote.gsx: winner banner already shortened")
else:
    sys.exit("mapvote.gsx: notifyMap changed upstream, patch by hand")
vote.write_text(text)

# 3. Twenty seconds of end-of-game camera before the vote even opens.
logic = mod / "maps/mp/gametypes/_globallogic.gsx"
text = logic.read_text(errors="replace")
pause = '\twait ( 20 - 2 * ( level.dvar[ "dynamic_rotation_enable" ] & level.dvar[ "mapvote" ] ) );'
trimmed = pause.replace("wait ( 20 -", "wait ( %d -" % PRE_VOTE_WAIT)
if pause in text:
    logic.write_text(text.replace(pause, trimmed, 1))
    print("   _globallogic.gsx: pre-vote pause cut to %ds" % PRE_VOTE_WAIT)
elif trimmed in text:
    print("   _globallogic.gsx: pre-vote pause already cut")
else:
    sys.exit("_globallogic.gsx: post-game pause changed upstream, patch by hand")

# 4. Upstream ties all progression to sv_pure:
#
#         level.rankedMatch = ( getDvarInt( "sv_pure" ) );
#
#    and incRankXP returns immediately when rankedMatch is false. This server
#    runs sv_pure 0 - everyone brings their own copy of the game, and mismatched
#    checksums made the server stop answering clients mid-join - so leaving
#    that line alone silently disables XP, promotions and every unlock. Purity
#    is about file checksums; ranking is not. Decouple them.
import re
logic_path = mod / "maps/mp/gametypes/_globallogic.gsx"
logic_text = logic_path.read_text(errors="replace")
coupled = re.compile(r'level\.rankedMatch\s*=\s*\(\s*getDvarInt\(\s*"sv_pure"\s*\)\s*\);')
if "level.rankedMatch = true;" in logic_text:
    print("   _globallogic.gsx: ranking already decoupled from sv_pure")
elif not coupled.search(logic_text):
    sys.exit("_globallogic.gsx: rankedMatch line changed upstream, patch by hand")
else:
    logic_path.write_text(coupled.sub("level.rankedMatch = true;", logic_text, count=1))
    print("   _globallogic.gsx: ranking no longer switched off by sv_pure 0")

# 5. Upstream awards no XP at all unless it counts two qualifying players, and
#    it only counts a player who already has a class set. On a private
#    three-man server that means kills land and no promotion ever fires - and
#    since unlocks are written during promotions, nothing unlocks either, so
#    players sit at rank 1 with Create a Class greyed out forever. The
#    anti-farming this buys is worthless on a password-gated box.
rank = mod / "maps/mp/gametypes/_rank.gsx"
text = rank.read_text(errors="replace")
gate = '''\tif ( level.teamBased && (!level.playerCount["allies"] || !level.playerCount["axis"]) )
\t\treturn;
\telse if ( !level.teamBased && (level.playerCount["allies"] + level.playerCount["axis"] < 2) )
\t\treturn;
'''
if "playerCount" not in text.split("giveRankXP")[1][:600]:
    print("   _rank.gsx: XP gate already removed")
elif gate not in text:
    sys.exit("_rank.gsx: XP gate changed upstream, patch by hand")
else:
    rank.write_text(text.replace(gate, "", 1))
    print("   _rank.gsx: XP gate removed so kills actually award XP")

# 6. Every death clones the player into a corpse entity and, a moment later,
#    hands that corpse to the engine's ragdoll system. The client then runs an
#    ODE rigid-body simulation for the corpse on its main thread for
#    ragdoll_max_life = 4.5 s. One corpse is cheap. The killcam is not: when it
#    ends, the client calls CG_ResetEntity on every entity in the snapshot, which
#    tears down and *restarts* the ragdoll on every corpse still on the map, so
#    the player who just died spends their first 4.5 s alive simulating up to
#    eight ragdolls at once. On the Rosetta + wined3d stack this is the "five
#    seconds of unbearable frame drop after spawn" that got killcams switched
#    off. Corpses without ragdoll simply hold their death animation, which is
#    how every death on this server looks already once the 4.5 s expire.
#    Gate the hand-off behind scr_ragdoll so new_exp_config.cfg decides.
logic = mod / "maps/mp/gametypes/_globallogic.gsx"
text = logic.read_text(errors="replace")
handoff = '''\tif ( self isOnLadder() || self isMantling() )
\t\tbody startRagDoll();
\t
\tthread delayStartRagdoll( body, sHitLoc, vDir, sWeapon, eInflictor, sMeansOfDeath );
'''
gated_handoff = '''\tif ( getDvarInt( "scr_ragdoll" ) )
\t{
\t\tif ( self isOnLadder() || self isMantling() )
\t\t\tbody startRagDoll();
\t\t
\t\tthread delayStartRagdoll( body, sHitLoc, vDir, sWeapon, eInflictor, sMeansOfDeath );
\t}
'''
if gated_handoff in text:
    print("   _globallogic.gsx: corpse ragdoll already gated behind scr_ragdoll")
elif handoff not in text:
    sys.exit("_globallogic.gsx: corpse ragdoll hand-off changed upstream, patch by hand")
else:
    logic.write_text(text.replace(handoff, gated_handoff, 1))
    print("   _globallogic.gsx: corpse ragdoll gated behind scr_ragdoll")

# 7. The flythrough paces its camera path over the whole post-game period, so
#    it has to be told the period is shorter or it crawls and gets cut off.
ending = mod / "code/ending.gsx"
text = ending.read_text(errors="replace")
budget = "\ttime = 20;"
rebudgeted = "\ttime = %d;" % (PRE_VOTE_WAIT + NOTIFY_WAIT)
if budget in text:
    ending.write_text(text.replace(budget, rebudgeted, 1))
    print("   ending.gsx: camera repaced for the shorter post-game")
elif rebudgeted in text:
    print("   ending.gsx: camera already repaced")
else:
    sys.exit("ending.gsx: flythrough budget changed upstream, patch by hand")
PY

# RCON-backed player administration for the private control panel. Progression
# calls the mod's real promotion/unlock functions, while the session-only admin
# powers remain unreachable from ordinary player chat commands.
python3 "$SCRIPT_DIR/patch-progression.py" "$MOD_DIR"

echo "==> tuning the mod"
CFG="$MOD_DIR/new_exp_config.cfg"
python3 - "$CFG" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text(errors="replace")
wanted = {
    # Score and XP share one table in this mod (registerScoreInfo feeds both),
    # so this scales the scoreboard too: at 100 a kill showed as 1000 points.
    # 1 is the mod's normal - a kill is 10, like stock. Ranking up fast is not
    # what this is for anyway: `cod4 unlock` writes rank 55 and every unlock
    # directly to the profile.
    "xp_multi": "1",
    # Killcams back on (2 Sep). They were switched off on 1 Sep because whoever
    # had just died got ~5 s of single-digit fps on respawn. The killcam was
    # only the trigger: leaving it resets every entity client-side, which
    # restarts the ragdoll on every corpse on the map and runs up to eight
    # rigid-body sims at once for ragdoll_max_life (4.5 s). scr_ragdoll below
    # is what actually fixes it. Read once at map start, so a change lands on
    # the next map.
    "scr_game_allowkillcam": "1",
    "final_killcam": "1",
    # Our own switch, read by the gate patched into _globallogic.gsx above. 0
    # means corpses keep their death animation instead of going to ragdoll, so
    # there is nothing for the killcam exit to re-simulate. Costs nothing
    # visually past 4.5 s after a death, which is when ragdolls freeze anyway.
    "scr_ragdoll": "0",
    # Persists per-player mod settings and TrueSkill only - not rank. CoD4 keeps
    # rank in the client's own mpdata; the server just awards the XP.
    "fs_players": "1",
    "mysql": "0",
    # Only a backstop for someone who never picks: the vote closes the moment
    # everyone has, so this is the worst case rather than the normal one.
    "mapvote": "1", "mapvote_mapnum": "6", "mapvote_time": "12",
    # Maps are voted on; the gametype is not. Free-for-all only, by request -
    # the vote just picks the next map and dm carries over. The pool is pinned
    # to dm as well so that switching the vote back on could not offer a mode
    # the rotation has no entries for.
    "gametypeVote": "0",
    "vote_gametypes": "dm",
    "old_hardpoints": "1",  # killstreak-based rewards rather than a credit shop
    # Field of view. The mod's own default is 2 (cg_fov 80 x cg_fovscale 1.25 =
    # 100 degrees) and cmd_fov 1 lets each player pick 80/90/100 from its menu.
    # Stock CoD4 is 65. On the Rosetta + wined3d client the frame is CPU-bound
    # on what is in view, and at 100 degrees that is roughly three times the
    # scene of 65 - it is where a good part of the missing frame rate went.
    # 0 is the lowest the mod offers (80); cmd_fov 0 stops a stored menu choice
    # from overriding it.
    "cmd_fov": "0",
    "default_fov": "0",
    "spawn_protection": "0",  # instant-kill pace suits three players on small maps
    # CoD4 canon for the stock three - UAV 3, airstrike 5, helicopter 7.
    # The mod's additional rewards ladder above them rather than displacing them.
    "radar": "3", "airstrike": "5", "helicopter": "7",
    "artillery": "9", "agm": "11", "asf": "13", "predator": "15",
    "ac130": "18", "mannedheli": "21", "nuke": "25",
}
for k, v in wanted.items():
    pat = re.compile(rf'^(set {re.escape(k)}\s+)"[^"]*"', re.M)
    if pat.search(t):
        t = pat.sub(rf'\g<1>"{v}"', t)
        continue
    # The stock config ships without a trailing newline, so an unguarded append
    # lands inside the last line's // comment and is silently never parsed.
    if not t.endswith("\n"):
        t += "\n"
    t += f'set {k} "{v}"\n'
p.write_text(t)
print(f"   {len(wanted)} mod settings applied")
PY

echo "==> systemd unit"
cat > /etc/systemd/system/cod4.service <<EOF
[Unit]
Description=Call of Duty 4 dedicated server (CoD4X + New Experience)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$GAME_USER
WorkingDirectory=$SERVER_DIR
ExecStart=$SERVER_DIR/cod4x18_dedrun \\
  +set dedicated 1 \\
  +set sv_maxclients 12 \\
  +set net_port 28961 \\
  +set fs_homepath $SERVER_DIR \\
  +set fs_basepath $SERVER_DIR \\
  +set fs_game mods/new_experience \\
  +exec new_exp_config.cfg \\
  +exec server.cfg \\
  +map mp_shipment
Restart=always
RestartSec=10
# The server is small; keep it from ever starving the box.
MemoryMax=700M
Nice=-5

[Install]
WantedBy=multi-user.target
EOF

chown -R "$GAME_USER:$GAME_USER" "$SERVER_DIR"
# nginx reads through usermaps/ as a member of the game group.
chmod -R g+rX "$SERVER_DIR/usermaps"
systemctl daemon-reload
systemctl enable cod4 >/dev/null 2>&1
echo "==> configured. Start with: systemctl start cod4"
