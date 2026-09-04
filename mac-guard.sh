#!/bin/bash
# Resource guard. Source before anything heavy.
#   kbfree      -> free GB
#   kbcheck N   -> exit 1 unless at least N GB free
#   kbkill      -> kill any game/test process this project starts
kbfree() { vm_stat | awk '/Pages (free|inactive)/ {n+=$NF} END {printf "%.1f", n*16384/1073741824}'; }
kbcheck() { f=$(kbfree); awk -v f="$f" -v n="${1:-8}" 'BEGIN{exit !(f+0 < n+0)}' && { echo "LOW MEMORY: ${f}GB free, need ${1:-8}GB"; return 1; }; echo "memory ok: ${f}GB free"; }
kbkill() { pkill -9 -f 'kisak_posix|KisakBlack|run-gl.command|run-map.command' 2>/dev/null; sleep 1; return 0; }
export KB_JOBS=4          # never exceed this; -j8 plus parallel agents is what OOM'd the box
