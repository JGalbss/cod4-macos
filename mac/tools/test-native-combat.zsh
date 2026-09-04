#!/bin/zsh

set -eu

combat_script_dir=${0:A:h}
combat_repo_root=${combat_script_dir:h:h}
combat_binary=${KISAK_TEST_BINARY:-${combat_repo_root}/bin/posix/jgalbs cod4}
combat_data=${COD4_DATA:-}
combat_port=${KISAK_TEST_PORT:-30100}
combat_cycles=${KISAK_TEST_CYCLES:-1}
combat_artifacts=${KISAK_TEST_ARTIFACT_DIR:-$(mktemp -d /tmp/kisak-native-combat.XXXXXX)}
combat_host_home=${combat_artifacts}/host-home
combat_guest_home=${combat_artifacts}/guest-home
combat_host_log=${combat_artifacts}/host.log
combat_guest_log=${combat_artifacts}/guest.log
combat_victim_ppm=${combat_artifacts}/victim-killcam.ppm
combat_victim_png=${combat_artifacts}/victim-killcam.png
combat_host_pid=
combat_guest_pid=

if [[ -z ${combat_data} ]]; then
    print -u2 "Set COD4_DATA to the native CoD4 data directory."
    exit 2
fi
if [[ ! -x ${combat_binary} ]]; then
    print -u2 "Native client is not executable: ${combat_binary}"
    exit 2
fi
if [[ ! -d ${combat_data} ]]; then
    print -u2 "CoD4 data directory does not exist: ${combat_data}"
    exit 2
fi
if (( combat_port < 1024 || combat_port > 65534 )); then
    print -u2 "KISAK_TEST_PORT must be between 1024 and 65534."
    exit 2
fi
if (( combat_cycles < 1 || combat_cycles > 50 )); then
    print -u2 "KISAK_TEST_CYCLES must be between 1 and 50."
    exit 2
fi

mkdir -p ${combat_host_home} ${combat_guest_home}

# A stock M16 burst does not always apply identical hit-location damage, so
# each lifecycle uses four short, real mouse-button taps followed by a normal
# reload. The 600-frame spacing covers the stock killcam and automatic respawn
# before both players are put back on the deterministic sightline.
combat_host_commands=
combat_guest_commands=
combat_fire_keys=
for (( combat_cycle = 0; combat_cycle < combat_cycles; ++combat_cycle )); do
    combat_base_frame=$((100 + combat_cycle * 600))
    combat_separator=
    if (( combat_cycle )); then
        combat_separator=';'
    fi
    combat_host_commands+="${combat_separator}-${combat_base_frame},setviewpos 1408 248 72 180 0"
    combat_guest_commands+="${combat_separator}-${combat_base_frame},setviewpos 1280 248 72 0 0"
    combat_fire_keys+="${combat_separator}200,-$((combat_base_frame + 40)),3;200,-$((combat_base_frame + 100)),3;200,-$((combat_base_frame + 160)),3;200,-$((combat_base_frame + 220)),3;114,-$((combat_base_frame + 280)),3"
done
combat_host_quit_frame=$((combat_cycles * 600 + 300))
combat_guest_quit_frame=$((combat_host_quit_frame - 100))
combat_host_commands+=";-${combat_host_quit_frame},quit"
combat_guest_commands+=";-${combat_guest_quit_frame},quit"

cleanup_native_combat()
{
    if [[ -n ${combat_guest_pid} ]] && kill -0 ${combat_guest_pid} 2>/dev/null; then
        kill ${combat_guest_pid} 2>/dev/null || true
    fi
    if [[ -n ${combat_host_pid} ]] && kill -0 ${combat_host_pid} 2>/dev/null; then
        kill ${combat_host_pid} 2>/dev/null || true
    fi
}
trap cleanup_native_combat EXIT INT TERM

KISAK_WINDOW_X=0 \
KISAK_WINDOW_Y=60 \
KISAK_COMBAT_TRACE=1 \
KISAK_GAMEPLAY_TRACE=1 \
KISAK_METAL_AUTO_JOIN=1 \
KISAK_AUTOCMD=${combat_host_commands} \
KISAK_AUTOKEY=${combat_fire_keys} \
${combat_binary} \
    +set fs_basepath ${combat_data} \
    +set fs_homepath ${combat_host_home} \
    +set net_port ${combat_port} \
    +set name NativeShooter \
    +set developer 1 \
    +set logfile 2 \
    +set g_log combat.log \
    +set r_fullscreen 0 \
    +set r_vsync 0 \
    +set com_maxfps 60 \
    +set g_gametype war \
    +devmap mp_vacant >${combat_host_log} 2>&1 &
combat_host_pid=$!

sleep 2

KISAK_WINDOW_X=650 \
KISAK_WINDOW_Y=60 \
KISAK_GAMEPLAY_TRACE=1 \
KISAK_METAL_AUTO_JOIN=1 \
KISAK_METAL_DUMP=${combat_victim_ppm} \
KISAK_METAL_DUMP_FRAME=-350 \
KISAK_AUTOCMD=${combat_guest_commands} \
${combat_binary} \
    +set fs_basepath ${combat_data} \
    +set fs_homepath ${combat_guest_home} \
    +set net_port $((combat_port + 1)) \
    +set name NativeVictim \
    +set developer 1 \
    +set r_fullscreen 0 \
    +set r_vsync 0 \
    +set com_maxfps 60 \
    +connect 127.0.0.1:${combat_port} >${combat_guest_log} 2>&1 &
combat_guest_pid=$!

set +e
wait ${combat_guest_pid}
combat_guest_rc=$?
wait ${combat_host_pid}
combat_host_rc=$?
set -e
combat_guest_pid=
combat_host_pid=

combat_failed=0
check_native_combat()
{
    local description=$1
    shift
    if "$@"; then
        print "PASS  ${description}"
    else
        print "FAIL  ${description}"
        combat_failed=1
    fi
}

check_native_combat "host exited cleanly" test ${combat_host_rc} -eq 0
check_native_combat "victim exited cleanly" test ${combat_guest_rc} -eq 0
check_native_combat "real bullet damage reached zero health" \
    awk -v want=${combat_cycles} '/\[combat-test\] damage target=1 attacker=0 .*health=[0-9]+->0/{++count} END { exit count < want }' ${combat_host_log}
check_native_combat "authoritative death callback ran for every cycle" \
    awk -v want=${combat_cycles} '/\[combat-test\] death victim=1 attacker=0/{++count} END { exit count < want }' ${combat_host_log}
check_native_combat "attacker score updated" \
    rg -q "\\[combat-test\\] state client=0 .*score=$((combat_cycles * 10))" ${combat_host_log}
check_native_combat "victim entered every killcam" \
    awk -v want=${combat_cycles} '/\[gameplay\] killcam entered: .*target=0/{++count} END { exit count < want }' ${combat_guest_log}
check_native_combat "victim exited every killcam" \
    awk -v want=${combat_cycles} '/\[gameplay\] killcam exited:/{++count} END { exit count < want }' ${combat_guest_log}
check_native_combat "victim respawned at full health after every death" \
    awk -v want=${combat_cycles} '/\[combat-test\] death victim=1/{dead=1; next} dead && /\[combat-test\] state client=1 connected=2 session=0 pm=0 health=100/{++respawns; dead=0} END { exit respawns < want }' ${combat_host_log}
check_native_combat "no native fatal/assert path" \
    zsh -c '! rg -q "\\[posix-crash\\]|FX sprite-list corruption|\\[assert\\]" "$1" "$2"' _ ${combat_host_log} ${combat_guest_log}
check_native_combat "killcam player-name substitution resolved" \
    zsh -c '! rg -q "unresolved translated message|Killed by &&1" "$1"' _ ${combat_guest_log}
check_native_combat "killcam frame captured" test -s ${combat_victim_ppm}

if [[ -s ${combat_victim_ppm} ]] && command -v sips >/dev/null; then
    sips -s format png ${combat_victim_ppm} --out ${combat_victim_png} >/dev/null
fi

print "Artifacts: ${combat_artifacts}"
if (( combat_failed )); then
    exit 1
fi
