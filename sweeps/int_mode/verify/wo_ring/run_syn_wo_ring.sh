#!/bin/bash
# Synthesize the WO-ring INT-only blocks (wo_ring_blocks.sv) one top at a time.
#   bash sweeps/int_mode/verify/wo_ring/run_syn_wo_ring.sh
# Outputs: sweeps/int_mode/verify/wo_ring/syn/<TOP>/{<TOP>.area.rpt,.ref.rpt,.timing.rpt,dc.log}
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
TOPS=${TOPS:-"WoRingPeDelta WoFeederA WoFeederW WoCollectorRow"}
pids=()
for top in $TOPS; do
    d="$HERE/syn/$top"
    mkdir -p "$d"
    ( cd "$d" && TOP=$top SRC_DIR="$HERE" dc_shell -f "$HERE/syn_wo_ring.tcl" > dc.log 2>&1 ) &
    pids+=($!)
done
rc=0
for p in "${pids[@]}"; do wait "$p" || rc=1; done
for top in $TOPS; do
    printf '%-16s ' "$top"; grep -E "Total cell area" "$HERE/syn/$top/$top.area.rpt" || echo "FAILED"
done
exit $rc
