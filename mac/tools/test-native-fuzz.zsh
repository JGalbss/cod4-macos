#!/bin/zsh

set -eu

fuzz_script_dir=${0:A:h}
fuzz_repo_root=${fuzz_script_dir:h:h}
fuzz_binary=${KISAK_TEST_BINARY:-${fuzz_repo_root}/bin/posix/jgalbs cod4}
fuzz_data=${COD4_DATA:-}
fuzz_cases=${KISAK_FUZZ_CASES:-5}
fuzz_frames=${KISAK_FUZZ_FRAMES:-1200}
fuzz_seed=${KISAK_FUZZ_SEED:-1337}
fuzz_artifacts=${KISAK_TEST_ARTIFACT_DIR:-$(mktemp -d /tmp/kisak-native-fuzz.XXXXXX)}
fuzz_maps=(mp_vacant mp_crash mp_shipment mp_backlot mp_strike)
fuzz_keys=(119 97 115 100 32 99 114 118 200 201)

if [[ -z ${fuzz_data} || ! -d ${fuzz_data} ]]; then
    print -u2 "Set COD4_DATA to the native CoD4 data directory."
    exit 2
fi
if [[ ! -x ${fuzz_binary} ]]; then
    print -u2 "Native client is not executable: ${fuzz_binary}"
    exit 2
fi
if (( fuzz_cases < 1 || fuzz_cases > ${#fuzz_maps} )); then
    print -u2 "KISAK_FUZZ_CASES must be between 1 and ${#fuzz_maps}."
    exit 2
fi
if (( fuzz_frames < 300 || fuzz_frames > 6000 )); then
    print -u2 "KISAK_FUZZ_FRAMES must be between 300 and 6000."
    exit 2
fi

mkdir -p ${fuzz_artifacts}

fuzz_failed=0
for (( fuzz_case = 1; fuzz_case <= fuzz_cases; ++fuzz_case )); do
    fuzz_map=${fuzz_maps[fuzz_case]}
    fuzz_home=${fuzz_artifacts}/home-${fuzz_case}-${fuzz_map}
    fuzz_log=${fuzz_artifacts}/${fuzz_case}-${fuzz_map}.log
    mkdir -p ${fuzz_home}

    # Deterministic LCG: failures can be reproduced from the reported seed.
    fuzz_state=$(( (fuzz_seed + fuzz_case * 7919) & 0x7fffffff ))
    fuzz_autokey=
    fuzz_automouse=
    fuzz_frame=45
    while (( fuzz_frame < fuzz_frames - 30 )); do
        fuzz_state=$(( (1103515245 * fuzz_state + 12345) & 0x7fffffff ))
        fuzz_key=${fuzz_keys[$((fuzz_state % ${#fuzz_keys} + 1))]}
        fuzz_state=$(( (1103515245 * fuzz_state + 12345) & 0x7fffffff ))
        fuzz_hold=$((fuzz_state % 36 + 2))
        fuzz_state=$(( (1103515245 * fuzz_state + 12345) & 0x7fffffff ))
        fuzz_dx=$((fuzz_state % 801 - 400))
        fuzz_state=$(( (1103515245 * fuzz_state + 12345) & 0x7fffffff ))
        fuzz_dy=$((fuzz_state % 401 - 200))
        if [[ -n ${fuzz_autokey} ]]; then
            fuzz_autokey+=';'
            fuzz_automouse+=';'
        fi
        fuzz_autokey+="${fuzz_key},-${fuzz_frame},${fuzz_hold}"
        fuzz_automouse+="${fuzz_dx},${fuzz_dy},-${fuzz_frame}"
        fuzz_state=$(( (1103515245 * fuzz_state + 12345) & 0x7fffffff ))
        fuzz_frame=$((fuzz_frame + fuzz_state % 22 + 6))
    done

    set +e
    KISAK_METAL_AUTO_JOIN=1 \
    KISAK_AUTOKEY=${fuzz_autokey} \
    KISAK_AUTOMOUSE=${fuzz_automouse} \
    KISAK_AUTOCMD="-${fuzz_frames},quit" \
    ${fuzz_script_dir}/run-timeboxed.py $((fuzz_frames / 45 + 30)) \
        ${fuzz_binary} \
        +set fs_basepath ${fuzz_data} \
        +set fs_homepath ${fuzz_home} \
        +set developer 1 \
        +set r_vsync 0 \
        +set com_maxfps 60 \
        +set g_gametype war \
        +devmap ${fuzz_map} >${fuzz_log} 2>&1
    fuzz_rc=$?
    set -e

    if (( fuzz_rc == 0 )) \
        && ! rg -q '\[assert\]|\[posix-crash\]|invalid critical-section|FX sprite-list corruption|Error during initialization|Com_Error' ${fuzz_log}; then
        print "PASS  case=${fuzz_case} map=${fuzz_map} seed=$((fuzz_seed + fuzz_case * 7919))"
    else
        print "FAIL  case=${fuzz_case} map=${fuzz_map} seed=$((fuzz_seed + fuzz_case * 7919)) rc=${fuzz_rc}"
        fuzz_failed=1
    fi
done

print "Artifacts: ${fuzz_artifacts}"
exit ${fuzz_failed}
