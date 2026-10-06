#!/bin/bash
# Times the sub-ring lap additions in a BP synthesis run (netlist + written
# SDC, the run's own timing view) with sweeps/int_mode/bp/sr/dc_bp_sr_new_paths.tcl;
# adapted from sweeps/int_mode/bp/ipd/report_bp_ipd_new_paths.sh.  dc_shell runs
# in build/rtl_preflight/bp_sr/bp_paths/<target>_<run>/, never in the synthesis
# run directory.  NEEDS AFS (the TSMC22 libraries).
#   bash sweeps/int_mode/bp/sr/report_bp_sr_new_paths.sh csa_bp_sr2_20261004 PAYN_SC_CSA_BP_SR2 2
#   bash sweeps/int_mode/bp/sr/report_bp_sr_new_paths.sh csa_bp_sr4_20261004 PAYN_SC_CSA_BP_SR4 4
#   bash sweeps/int_mode/bp/sr/report_bp_sr_new_paths.sh csa_bp_ipd_20261004 PAYN_SC_CSA_BP_IPD 1
#   bash sweeps/int_mode/bp/sr/report_bp_sr_new_paths.sh csa_bp_20261004_lap PAYN_SC_CSA_BP 8
# Output: build/rtl_preflight/bp_sr/bp_paths/<target>_<run>/bp_sr_new_paths.rpt and summary.txt.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
RUN=${1:-csa_bp_sr2_20261004}
TGT=${2:-PAYN_SC_CSA_BP_SR2}
export LAP_G=${3:-2}
DIR="$REPO/syn/build/TSMC22/$TGT/$RUN"
[[ -s "$DIR/TARGET_DEF" ]] || { echo "no synthesis run at $DIR" >&2; exit 2; }
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
export DESIGN_ROOT=$REPO
set -a; . "$DIR/TARGET_DEF"; set +a
export BP_RUN_DIR=$DIR
OUT="$REPO/build/rtl_preflight/bp_sr/bp_paths/${TGT}_${RUN}"
mkdir -p "$OUT"
cd "$OUT"
dc_shell -f "$REPO/sweeps/int_mode/bp/sr/dc_bp_sr_new_paths.tcl" > bp_sr_new_paths.rpt 2>&1
python3 - bp_sr_new_paths.rpt > summary.txt <<'PY'
import re, sys
text = open(sys.argv[1]).read()
parts = re.split(r"^BP_PATH (.*)$", text, flags=re.M)
for label, body in zip(parts[1::2], parts[2::2]):
    sp = re.search(r"Startpoint: (\S+)", body)
    ep = re.search(r"Endpoint: (\S+)", body)
    sl = re.search(r"slack \((?:MET|VIOLATED)\)\s+(-?[0-9.]+)", body)
    if label.startswith("combinational loops"):
        print(f"{label}: {'DC: No loops.' if 'No loops.' in body else 'LOOPS REPORTED (see rpt)'}")
        continue
    if label.startswith("check_timing"):
        warn = [l for l in body.splitlines() if l.startswith("Warning") and "loop" in l.lower()]
        print(f"{label}: {'no loop warnings' if not warn else 'LOOP WARNING: ' + warn[0]}")
        continue
    if sl:
        print(f"{label}: slack {sl[1]}  ({sp[1] if sp else '?'} -> {ep[1] if ep else '?'})")
    else:
        print(f"{label}: no path")
PY
cat summary.txt
