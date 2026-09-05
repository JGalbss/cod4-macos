#!/bin/zsh

set -eu

airstrike_script_dir=${0:A:h}
airstrike_repo_root=${airstrike_script_dir:h:h}
airstrike_binary=${KISAK_TEST_BINARY:-${airstrike_repo_root}/bin/posix/jgalbs cod4}
airstrike_data=${COD4_DATA:-}
airstrike_port=${KISAK_TEST_PORT:-30226}
airstrike_artifacts=${KISAK_TEST_ARTIFACT_DIR:-$(mktemp -d /tmp/kisak-native-airstrike.XXXXXX)}
airstrike_home=${airstrike_artifacts}/home
airstrike_mod_dir=${airstrike_home}/Mods/airstrike_test
airstrike_log=${airstrike_artifacts}/airstrike.log
airstrike_ppm=${airstrike_artifacts}/airstrike.ppm
airstrike_png=${airstrike_artifacts}/airstrike.png

if [[ -z ${airstrike_data} || ! -d ${airstrike_data} ]]; then
    print -u2 "Set COD4_DATA to the native CoD4 data directory."
    exit 2
fi
if [[ ! -x ${airstrike_binary} ]]; then
    print -u2 "Native client is not executable: ${airstrike_binary}"
    exit 2
fi
if (( airstrike_port < 1024 || airstrike_port > 65534 )); then
    print -u2 "KISAK_TEST_PORT must be between 1024 and 65534."
    exit 2
fi

mkdir -p ${airstrike_mod_dir}
(
    cd ${airstrike_repo_root}/mac/tests/airstrike
    zip -q -r ${airstrike_mod_dir}/z_airstrike_test.iwd maps
)

set +e
KISAK_WINDOW_X=20 \
KISAK_WINDOW_Y=60 \
KISAK_METAL_AUTO_JOIN=1 \
KISAK_AIRSTRIKE_TRACE=1 \
KISAK_METAL_DUMP=${airstrike_ppm} \
KISAK_METAL_DUMP_FRAME=-700 \
KISAK_AUTOKEY='54,-120,3;200,-210,3' \
KISAK_AUTOCMD='-900,quit' \
${airstrike_script_dir}/run-timeboxed.py 100 \
    ${airstrike_binary} \
    +set fs_basepath ${airstrike_data} \
    +set fs_homepath ${airstrike_home} \
    +set fs_game Mods/airstrike_test \
    +set developer 1 \
    +set developer_script 1 \
    +set logfile 2 \
    +set net_port ${airstrike_port} \
    +set name AirstrikeTest \
    +set r_fullscreen 0 \
    +set r_vsync 0 \
    +set com_maxfps 60 \
    +set g_gametype war \
    +devmap mp_vacant >${airstrike_log} 2>&1
airstrike_rc=$?
set -e

airstrike_failed=0
check_native_airstrike()
{
    local description=$1
    shift
    if "$@"; then
        print "PASS  ${description}"
    else
        print "FAIL  ${description}"
        airstrike_failed=1
    fi
}

check_native_airstrike "client exited cleanly" test ${airstrike_rc} -eq 0
check_native_airstrike "stock airstrike event resolved its entity tag" \
    rg -q "\[airstrike-test\] bolted effect='explosions/clusterbomb'.*spawned=1" ${airstrike_log}
check_native_airstrike "cluster bomb parent effect entered the FX system" \
    rg -q "\[airstrike-test\] spawned effect='explosions/clusterbomb'.*count=1" ${airstrike_log}
check_native_airstrike "projectile impacts spawned the explosion child effect" \
    rg -q "\[airstrike-test\] spawned effect='explosions/clusterbomb_exp'.*count=10" ${airstrike_log}
check_native_airstrike "airstrike frame captured" test -s ${airstrike_ppm}
check_native_airstrike "no native fatal/assert path" \
    zsh -c '! rg -q "\[posix-crash\]|FX sprite-list corruption|\[assert\]|Error during initialization|Com_Error" "$1"' _ ${airstrike_log}

if [[ -s ${airstrike_ppm} ]] && command -v sips >/dev/null; then
    sips -s format png ${airstrike_ppm} --out ${airstrike_png} >/dev/null
fi

print "Artifacts: ${airstrike_artifacts}"
exit ${airstrike_failed}
