#!/bin/bash
# Basin QoR gate for one routed run (read-only on the run directory).
#   bash sweeps/pinned_pass2/run_basin_gate.sh RUN_DIR TOP OUT_DIR LABEL [PIN_PLAN]
# Writes OUT_DIR/product_and_skew.tsv (PT, basin_skew_pt.tcl),
# OUT_DIR/basin_gate.json and OUT_DIR/basin_gate.log. Exit status 0 means the
# metrics were produced; the verdict (grid / collapsed) is in the JSON, and
# exit status 3 flags a collapsed basin or a failed pin proof.
set -Eeuo pipefail
[[ $# -ge 4 && $# -le 5 ]] || { echo "Usage: $0 RUN_DIR TOP OUT_DIR LABEL [PIN_PLAN]" >&2; exit 2; }
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
RUN_DIR=$(cd "$1" && pwd); TOP=$2; OUT_DIR=$3; LABEL=$4; PLAN=${5:-}
mkdir -p "$OUT_DIR"; OUT_DIR=$(cd "$OUT_DIR" && pwd)
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export TSMC22_CELL_TIER=sc7mcpp140z TSMC22_LIB_FLAVORS=svt_c30 TSMC22_HPK_FLAVORS=svt_c30 TSMC22_HPK=1
for f in "outputs/$TOP.apr.v" "outputs/$TOP.spef" "outputs/$TOP.apr.def" "$TOP.syn.sdc"; do
    [[ -s "$RUN_DIR/$f" ]] || { echo "Missing $RUN_DIR/$f" >&2; exit 2; }
done
cd "$OUT_DIR"
RUN_DIR="$RUN_DIR" TOP="$TOP" OUT="$OUT_DIR/product_and_skew.tsv" \
    pt_shell -file "$REPO/sweeps/pinned_pass2/basin_skew_pt.tcl" > pt_skew.log 2>&1
grep -q BASIN_SKEW_DONE pt_skew.log
if grep -Eq '^(Error|ERROR):' pt_skew.log; then echo "PT errors in $OUT_DIR/pt_skew.log" >&2; exit 2; fi
grep BASIN_SKEW_DONE pt_skew.log
args=(--def "$RUN_DIR/outputs/$TOP.apr.def" --skew "$OUT_DIR/product_and_skew.tsv" --label "$LABEL" --json "$OUT_DIR/basin_gate.json")
[[ -z "$PLAN" ]] || args+=(--plan "$PLAN")
python3 "$REPO/sweeps/pinned_pass2/basin_gate.py" "${args[@]}" | tee basin_gate.log
python3 - "$OUT_DIR/basin_gate.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1]))
bad = j['gate']['status']!='PASS' or ('pin_proof' in j and j['pin_proof']['status']!='PASS')
sys.exit(3 if bad else 0)
PY
