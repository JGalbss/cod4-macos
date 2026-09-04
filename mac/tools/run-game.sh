#!/bin/bash
# Run the game with a hard lifetime and no survivors.
#
# A game that hangs on a window, a zone load or an assert otherwise sits there
# holding gigabytes. This kills any previous instance first, runs the new one in
# its own process group under a timeout, and sweeps again on the way out - including
# when the caller interrupts it.
#
#   run-game.sh <seconds> <logfile> [engine args...]
set -u

readonly GAME_DATA="${KISAK_GAME_DATA:-$HOME/Games/cod4}"
readonly TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BIN="$(cd "$TOOLS_DIR/../.." && pwd)/bin/posix/jgalbs cod4"
readonly PATTERN='/bin/posix/jgalbs cod4'

sweep() { pkill -9 -f "$PATTERN" 2>/dev/null; return 0; }

readonly SECONDS_LIMIT="${1:?usage: run-game.sh <seconds> <logfile> [args...]}"
readonly LOG="${2:?usage: run-game.sh <seconds> <logfile> [args...]}"
shift 2

free_gb=$(vm_stat | awk '/Pages (free|inactive)/ {n+=$NF} END {printf "%.1f", n*16384/1073741824}')
if awk -v f="$free_gb" 'BEGIN{exit !(f+0 < 6)}'; then
    echo "REFUSING TO RUN: only ${free_gb}GB free" >&2
    exit 1
fi

trap 'sweep' EXIT INT TERM
sweep
sleep 0.5

cd "$GAME_DATA" || exit 1
if [ -n "${KISAK_LLDB:-}" ]; then
    # -o run -o bt: stop at the fault and print every thread, then leave. The engine
    # runs on a secondary thread, so "all" matters - thread 1 is just Cocoa.
    # -k runs only when the target crashes, which is when the stack is worth having.
    # "bt all" because the engine runs on a secondary thread; thread 1 is just Cocoa.
    # KISAK_LLDB_CMDS adds newline-separated crash-time commands, for when the
    # default registers and backtrace aren't enough to place the fault.
    # KISAK_LLDB_PRE and KISAK_LLDB_POST bracket the run, for setup that needs a
    # target but no process (breakpoints) and setup that needs a live one
    # (watchpoints on engine globals, which only resolve once the process exists).
    collect() { # collect <flag> <newline-separated commands>
        out=()
        [ -n "$2" ] && while IFS= read -r cmd; do
            [ -n "$cmd" ] && out+=("$1" "$cmd")
        done <<< "$2"
    }
    collect -o "${KISAK_LLDB_PRE:-}";  pre=(${out[@]+"${out[@]}"})
    collect -o "${KISAK_LLDB_POST:-}"; post=(${out[@]+"${out[@]}"})
    collect -k "${KISAK_LLDB_CMDS:-}"; extra=(${out[@]+"${out[@]}"})
    "$TOOLS_DIR/run-timeboxed.py" "$SECONDS_LIMIT" \
        lldb -b ${pre[@]+"${pre[@]}"} -o run ${post[@]+"${post[@]}"} \
             -k "bt all" -k "register read x0 x1 x19 x20 x21 lr" \
             -k "image lookup -va \$lr" ${extra[@]+"${extra[@]}"} -k "quit" \
        -- "$BIN" +set fs_basepath "$GAME_DATA" "$@" > "$LOG" 2>&1
else
    "$TOOLS_DIR/run-timeboxed.py" "$SECONDS_LIMIT" \
        "$BIN" +set fs_basepath "$GAME_DATA" "$@" > "$LOG" 2>&1
fi
status=$?

sweep
sleep 0.5
if pgrep -f "$PATTERN" > /dev/null; then
    echo "WARNING: a game process survived the sweep" >&2
    pgrep -fl "$PATTERN" >&2
fi
echo "[run-game] exit=$status  log=$LOG  lines=$(wc -l < "$LOG")"
exit $status
