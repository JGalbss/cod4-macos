#!/bin/zsh
set -euo pipefail

stats_script_dir=${0:A:h}
stats_repo_root=${stats_script_dir:h:h}
stats_binary=${KISAK_TEST_BINARY:-${stats_repo_root}/bin/posix/jgalbs cod4}
stats_data=${COD4_DATA:?Set COD4_DATA to the native CoD4 data directory}
stats_artifacts=${KISAK_TEST_ARTIFACT_DIR:-$(mktemp -d /tmp/kisak-native-stats.XXXXXX)}
stats_home=${stats_artifacts}/home
stats_profile=${stats_home}/players/profiles/StatsSaveTest
stats_port=${KISAK_TEST_PORT:-30243}
[[ -d ${stats_data} && -x ${stats_binary} ]]
(( stats_port >= 1024 && stats_port <= 65534 ))
mkdir -p ${stats_profile} ${stats_home}/Mods/stats_save_test
cp ${stats_repo_root}/mac/tests/stats-profile/active.txt ${stats_home}/players/profiles/active.txt
cp ${stats_repo_root}/mac/tests/stats-profile/config.txt ${stats_profile}/config_mp.cfg
(
    cd ${stats_repo_root}/mac/tests/airstrike
    zip -q -r ${stats_home}/Mods/stats_save_test/z_stats_test.iwd maps
)

for stats_phase in 1 2; do
    stats_log=${stats_artifacts}/phase-${stats_phase}.log
    # Phase one reloads stats before the normal autosave deadline, then leaves.
    # Phase two starts a NEW process and checks what the server receives.
    stats_commands='-150,readStats;-400,disconnect;-430,quit'
    [[ ${stats_phase} == 1 ]] || stats_commands='-150,disconnect;-180,quit'
    KISAK_METAL_AUTO_JOIN=1 KISAK_AUTOCMD=${stats_commands} \
    ${stats_script_dir}/run-timeboxed.py 90 ${stats_binary} \
        +set fs_basepath ${stats_data} +set fs_homepath ${stats_home} \
        +set fs_game Mods/stats_save_test +set scr_testStats ${stats_phase} \
        +set developer 1 +set developer_script 1 +set debugStats 1 +set logfile 2 \
        +set net_port ${stats_port} +set r_fullscreen 0 +set r_mode 800x600 \
        +set com_maxfps 60 +set g_gametype war +devmap mp_vacant >${stats_log} 2>&1
    if rg -q '\[posix-crash\]|\[assert\]|Error during initialization|Com_Error|script runtime error' ${stats_log}; then
        print -u2 "FAIL runtime error: ${stats_log}"
        exit 1
    fi
done
rg -q '\[stats\] loaded .* XP=2430 rank=9' ${stats_artifacts}/phase-1.log
rg -q '\[stats-test\] joined XP=2430 rank=9' ${stats_artifacts}/phase-2.log
[[ $(stat -f %z ${stats_profile}/Mods/stats_save_test/mpdata) == 8476 ]]
print 'PASS server-awarded XP survives an immediate reload, leaving, app restart, and rejoining'
print "Artifacts: ${stats_artifacts}"
