#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h:h}

${script_dir}/check-dvar-union.sh

console_source=${repo_root}/src/client/cl_console.cpp
fx_source=${repo_root}/src/EffectsCore/fx_update_util.cpp
profile_source=${repo_root}/src/qcommon/com_playerprofile.cpp

if rg -q 'con_gameMsgWindowNLineCount.*current\.value.*1000\.0f' ${console_source}; then
    print -u2 'game-message duration is reading the line-count dvar'
    exit 1
fi
if ! rg -q 'con_gameMsgWindowNMsgTime\[dest - CON_DEST_GAME_FIRST\]->current\.value' ${console_source}; then
    print -u2 'game-message duration is not reading its message-time dvar'
    exit 1
fi

if rg -q 'blockerIndex = visState->blockerCount \+ 1' ${fx_source}; then
    print -u2 'FX visibility blockers are using a one-based write index'
    exit 1
fi
if ! rg -q 'blockerIndex = visState->blockerCount;' ${fx_source}; then
    print -u2 'FX visibility blocker writes do not begin at the published zero-based count'
    exit 1
fi

if ! rg -q '!I_stricmp\(name, "NativeInputCheck"\)' ${profile_source}; then
    print -u2 'the leaked native-input diagnostic player name is not migrated'
    exit 1
fi

print 'ok: message expiry, smoke visibility, and diagnostic-name migration are guarded'
