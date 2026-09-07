#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h:h}
binary=${KISAK_TEST_BINARY:-${repo_root}/bin/posix/jgalbs cod4}
game_data=${COD4_DATA:-}
artifacts=${KISAK_TEST_ARTIFACT_DIR:-$(mktemp -d /tmp/kisak-smoke-visibility.XXXXXX)}
home_path=${artifacts}/home
log_path=${artifacts}/smoke.log

if [[ -z ${game_data} || ! -d ${game_data} ]]; then
    print -u2 'Set COD4_DATA to the native CoD4 data directory.'
    exit 2
fi
if [[ ! -x ${binary} ]]; then
    print -u2 "Native client is not executable: ${binary}"
    exit 2
fi

mkdir -p ${home_path}

set +e
KISAK_FX_AUTOTEST='props/american_smoke_grenade_mp' \
KISAK_FX_VIS_SELFTEST=1 \
KISAK_METAL_AUTO_JOIN=1 \
KISAK_AUTOCMD='-420,quit' \
${script_dir}/run-timeboxed.py 60 \
    ${binary} \
    +set fs_basepath ${game_data} \
    +set fs_homepath ${home_path} \
    +set developer 1 \
    +set logfile 2 \
    +set r_fullscreen 0 \
    +set r_vsync 0 \
    +set com_maxfps 60 \
    +set g_gametype war \
    +devmap mp_vacant >${log_path} 2>&1
run_result=$?
set -e

failed=0
check()
{
    local description=$1
    shift
    if "$@"; then
        print "PASS  ${description}"
    else
        print "FAIL  ${description}"
        failed=1
    fi
}

check 'client exited cleanly' test ${run_result} -eq 0
check 'retail smoke effect spawned' \
    rg -q "\[fx\] native autotest spawning 'props/american_smoke_grenade_mp'" ${log_path}
check 'slot-zero smoke blocker reduced visibility' \
    rg -q '\[fx-vis-test\] slot=0 blockers=[1-9][0-9]* radius=[1-9][0-9.]* encoded=[0-9]+ trace=0\.' ${log_path}
check 'leaked diagnostic player name migrated to active profile' \
    rg -q 'seta name "josh"' ${home_path}/players/profiles/josh/config_mp.cfg
check 'no native fatal/assert path' \
    zsh -c '! rg -q "\[posix-crash\]|\[assert\]|Error during initialization|Com_Error" "$1"' _ ${log_path}

print "Artifacts: ${artifacts}"
exit ${failed}
