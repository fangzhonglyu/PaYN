#!/bin/bash
# Times the bit-plane additions in a synthesis run (netlist + written SDC, the
# run's own timing view), and the CSA paths they touch (shift_in -> tile clock
# gates, mac_en, Sobol -> comparator -> bit pipe, register -> register).
# dc_shell runs in build/rtl_preflight/bp_paths/<target>_<run>/, so the probe
# never writes into a synthesis run directory.
#   bash sweeps/int_mode/bp/report_bp_new_paths.sh [RUN] [TARGET]
#     RUN    default csa_bp_20261003b
#     TARGET default PAYN_SC_CSA_BP; PAYN_SC_CSA probes the accepted baseline
#            (BP-only probes then report "no paths")
# Output: build/rtl_preflight/bp_paths/<target>_<run>/bp_new_paths.rpt
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUN=${1:-csa_bp_20261003b}
TGT=${2:-PAYN_SC_CSA_BP}
DIR="$REPO/syn/build/TSMC22/$TGT/$RUN"
[[ -s "$DIR/TARGET_DEF" ]] || { echo "no synthesis run at $DIR" >&2; exit 2; }
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
export DESIGN_ROOT=$REPO
set -a; . "$DIR/TARGET_DEF"; set +a
export BP_RUN_DIR=$DIR
OUT="$REPO/build/rtl_preflight/bp_paths/${TGT}_${RUN}"
mkdir -p "$OUT"
cd "$OUT"
dc_shell -f "$REPO/sweeps/int_mode/bp/dc_bp_new_paths.tcl" > bp_new_paths.rpt 2>&1
grep -E '^BP_PATH|Startpoint|Endpoint|slack' bp_new_paths.rpt
