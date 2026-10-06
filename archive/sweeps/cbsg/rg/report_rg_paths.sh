#!/bin/bash
# Times the C-BSG RG array's paths in a synthesis run (netlist + written SDC, the run's own timing view),
# above all the single-cycle PE path a_bits_pipe -> W index generator -> compare -> CSA tile -> acc_low.
# dc_shell runs in build/cbsg/rg/syn_paths/<run>/, so the probe never writes into the synthesis run.
#   bash sweeps/cbsg/rg/report_rg_paths.sh [RUN] [TARGET]
#     RUN    default cbsg_rg_20261005
#     TARGET default PAYN_SC_CSA_CBSG_RG
# Needs the TSMC22 kit (AFS token).  Output: build/cbsg/rg/syn_paths/<target>_<run>/rg_paths.rpt
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUN=${1:-cbsg_rg_20261005}
TGT=${2:-PAYN_SC_CSA_CBSG_RG}
DIR="$REPO/syn/build/TSMC22/$TGT/$RUN"
[[ -s "$DIR/TARGET_DEF" ]] || { echo "no synthesis run at $DIR" >&2; exit 2; }
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
export DESIGN_ROOT=$REPO SNPSLMD_QUEUE=true
set -a; . "$DIR/TARGET_DEF"; set +a
export RG_RUN_DIR=$DIR
OUT="$REPO/build/cbsg/rg/syn_paths/${TGT}_${RUN}"
mkdir -p "$OUT"
cd "$OUT"
dc_shell -f "$REPO/sweeps/cbsg/rg/dc_rg_paths.tcl" > rg_paths.rpt 2>&1
grep -E '^RG_PATH|^RG_INFO|Startpoint|Endpoint|slack' rg_paths.rpt
