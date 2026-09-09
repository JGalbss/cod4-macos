#!/bin/zsh
set -euo pipefail

hud_script_dir=${0:A:h}
hud_repo_root=${hud_script_dir:h:h}
hud_binary=${KISAK_TEST_BINARY:-${hud_repo_root}/bin/posix/jgalbs cod4}
hud_data=${COD4_DATA:?Set COD4_DATA to the native CoD4 data directory}
hud_artifacts=${KISAK_TEST_ARTIFACT_DIR:-$(mktemp -d /tmp/kisak-native-hud-expiry.XXXXXX)}
hud_home=${hud_artifacts}/home
hud_log=${hud_artifacts}/hud.log
hud_port=${KISAK_TEST_PORT:-30236}
[[ -d ${hud_data} && -x ${hud_binary} ]]
(( hud_port >= 1024 && hud_port <= 65534 ))
mkdir -p ${hud_home}/Mods/hud_expiry_test
(
    cd ${hud_repo_root}/mac/tests/airstrike
    zip -q -r ${hud_home}/Mods/hud_expiry_test/z_hud_expiry_test.iwd maps
)

KISAK_WINDOW_X=20 KISAK_WINDOW_Y=60 \
KISAK_METAL_AUTO_JOIN=1 KISAK_HUD_FX_TRACE=1 \
KISAK_METAL_DUMP=${hud_artifacts}/expired.ppm \
KISAK_METAL_DUMP_FRAME=-800 KISAK_AUTOCMD='-900,quit' \
${hud_script_dir}/run-timeboxed.py 100 ${hud_binary} \
    +set fs_basepath ${hud_data} +set fs_homepath ${hud_home} \
    +set fs_game Mods/hud_expiry_test +set scr_testHudFx 1 \
    +set developer 1 +set developer_script 1 +set logfile 2 \
    +set net_port ${hud_port} +set name HudExpiryTest \
    +set r_fullscreen 0 +set r_vsync 0 +set com_maxfps 60 \
    +set g_gametype war +devmap mp_vacant >${hud_log} 2>&1

for hud_award in first next; do
    for hud_phase in visible fading expired; do
        rg -q "\[hud-fx\] phase=${hud_phase} .*text='HUD expiry: ${hud_award} award'" ${hud_log}
        print "PASS  ${hud_award} award ${hud_phase}"
    done
done
if rg -q '\[posix-crash\]|\[assert\]|Error during initialization|Com_Error|script runtime error' ${hud_log}; then
    print -u2 "FAIL  runtime error; see ${hud_log}"
    exit 1
fi
[[ -s ${hud_artifacts}/expired.ppm ]]
sips -s format png ${hud_artifacts}/expired.ppm --out ${hud_artifacts}/expired.png >/dev/null
print 'PASS  native client exited cleanly and captured the expired state'
print "Artifacts: ${hud_artifacts}"
