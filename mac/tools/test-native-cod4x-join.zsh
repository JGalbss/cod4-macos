#!/bin/zsh

set -eu

join_script_dir=${0:A:h}
join_repo_root=${join_script_dir:h:h}
join_binary=${KISAK_TEST_BINARY:-${join_repo_root}/bin/posix/jgalbs cod4}
join_data=${COD4_DATA:-}
join_server=${KISAK_TEST_SERVER:-}
join_password=${KISAK_TEST_PASSWORD:-}
join_artifacts=${KISAK_TEST_ARTIFACT_DIR:-$(mktemp -d /tmp/kisak-native-cod4x-join.XXXXXX)}
join_home=${join_artifacts}/home
join_log=${join_artifacts}/client.log

if [[ -z ${join_data} || ! -d ${join_data} ]]; then
    print -u2 "Set COD4_DATA to the native CoD4 data directory."
    exit 2
fi
if [[ -z ${join_server} ]]; then
    print -u2 "Set KISAK_TEST_SERVER to a CoD4x host:port."
    exit 2
fi
if [[ ! -x ${join_binary} ]]; then
    print -u2 "Native client is not executable: ${join_binary}"
    exit 2
fi

mkdir -p ${join_home}

# Exercise a post-join name change when the server permits it. The release
# gate relies on the authoritative client records in the initial gamestate;
# public servers may suppress or defer a live rename update.
set +e
KISAK_METAL_AUTO_JOIN=1 \
KISAK_AUTOCMD='-120,name NativeJoinUpdated;-480,quit' \
${join_script_dir}/run-timeboxed.py 90 \
    ${join_binary} \
    +set fs_basepath ${join_data} \
    +set fs_homepath ${join_home} \
    +set name NativeJoinInitial \
    +set password "${join_password}" \
    +set developer 1 \
    +set r_fullscreen 0 \
    +set r_vsync 0 \
    +set com_maxfps 60 \
    +connect ${join_server} >${join_log} 2>&1
join_rc=$?
set -e

join_failed=0
check_native_join()
{
    local description=$1
    shift
    if "$@"; then
        print "PASS  ${description}"
    else
        print "FAIL  ${description}"
        join_failed=1
    fi
}

check_native_join "client exited cleanly" test ${join_rc} -eq 0
check_native_join "server selected protocol 21" \
    rg -q 'server selected extended protocol 21' ${join_log}
check_native_join "gameplay received a snapshot" \
    rg -q 'CoD4x: first snapshot .* entering active play' ${join_log}
check_native_join "initial client-name records populated the protocol cache" \
    rg -q 'CoD4x: gamestate accepted .* [1-9][0-9]* client records' ${join_log}
check_native_join "runtime patch revision did not block the join" \
    zsh -c '! rg -q "cod4x_(patchv2|ambfix)\\.ff is different from the server" "$1"' _ ${join_log}
check_native_join "no server-message parser failure or connection loss" \
    zsh -c '! rg -q "Illegible server message|Connection Interrupted|Server connection timed out|\\[posix-crash\\]|\\[assert\\]|Com_Error" "$1"' _ ${join_log}

print "Artifacts: ${join_artifacts}"
exit ${join_failed}
