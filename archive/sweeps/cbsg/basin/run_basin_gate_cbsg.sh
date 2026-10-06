#!/bin/bash
# Basin QoR gate for one routed C-BSG run (read-only on the run directory).  C-BSG copy of
# sweeps/pinned_pass2/run_basin_gate.sh (shared, unchanged).
#   bash sweeps/cbsg/basin/run_basin_gate_cbsg.sh RUN_DIR TOP OUT_DIR LABEL [PIN_PLAN]
# AF (TOP *_cbsg_af): the tiles, the a_bits_pipe / w_bits_pipe flops and the product AND2s are the CSA's, so the
#   shared gate applies unchanged and this script simply runs sweeps/pinned_pass2/run_basin_gate.sh.
# RG (TOP *_cbsg_rg): the tile's W bits come from per-tile comparators, not from pipe flops, so the shared
#   product-AND a/w skew finds no product ANDs (their W input roots at a comparator gate) and, measured anyway,
#   would carry ~1 ns of generator logic in every basin.  The skew criterion becomes the closest equivalent:
#   the W-magnitude (column broadcast) vs threshold (row broadcast) network-delay mismatch at the comparators
#   (sweeps/cbsg/basin/basin_skew_cbsg_pt.tcl MODE=rg, derivation in its header), measured on the routed
#   layout and, as the logic's own floor, on the synthesized netlist the run started from (zero wire load), and
#   gated by sweeps/cbsg/basin/basin_gate_cbsg.py --mode rg on the placement-induced increment; its tile
#   metrics, wire length and pin proof are the shared basin_gate.py functions.
# Writes OUT_DIR/product_and_skew.tsv, OUT_DIR/basin_gate.json and OUT_DIR/basin_gate.log.  Exit status 0 means
# the metrics were produced and the gate passed; 3 flags a collapsed basin or a failed pin proof (verdict in the
# JSON); anything else is an error.
set -Eeuo pipefail
[[ $# -ge 4 && $# -le 5 ]] || { echo "Usage: $0 RUN_DIR TOP OUT_DIR LABEL [PIN_PLAN]" >&2; exit 2; }
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TOP=$2
case "$TOP" in
    *_cbsg_af) exec bash "$REPO/sweeps/pinned_pass2/run_basin_gate.sh" "$@";;
    *_cbsg_rg) ;;
    *) echo "run_basin_gate_cbsg.sh: not a C-BSG top: $TOP" >&2; exit 2;;
esac
RUN_DIR=$(cd "$1" && pwd); OUT_DIR=$3; LABEL=$4; PLAN=${5:-}
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
[[ -s "$RUN_DIR/$TOP.syn.v" ]] || { echo "Missing $RUN_DIR/$TOP.syn.v (the synthesized netlist APR copied in)" >&2; exit 2; }
cd "$OUT_DIR"
unset NETLIST SDC SPEF
# Routed layout (apr.v + SPEF) and the logic's floor (the same netlist APR started from, zero wire load).
RUN_DIR="$RUN_DIR" TOP="$TOP" MODE=rg OUT="$OUT_DIR/product_and_skew.tsv" \
    pt_shell -file "$REPO/sweeps/cbsg/basin/basin_skew_cbsg_pt.tcl" > pt_skew.log 2>&1
RUN_DIR="$RUN_DIR" TOP="$TOP" MODE=rg OUT="$OUT_DIR/product_and_skew_synth_floor.tsv" \
    NETLIST="$RUN_DIR/$TOP.syn.v" SDC="$RUN_DIR/$TOP.syn.sdc" SPEF=none \
    pt_shell -file "$REPO/sweeps/cbsg/basin/basin_skew_cbsg_pt.tcl" > pt_skew_synth_floor.log 2>&1
for log in pt_skew.log pt_skew_synth_floor.log; do
    grep -q BASIN_SKEW_DONE "$log"
    if grep -Eq '^(Error|ERROR):' "$log"; then echo "PT errors in $OUT_DIR/$log" >&2; exit 2; fi
    grep -E '^BASIN_CMP_CONE|^BASIN_SKEW_DONE' "$log"
done
args=(--mode rg --def "$RUN_DIR/outputs/$TOP.apr.def" --skew "$OUT_DIR/product_and_skew.tsv"
      --skew-floor "$OUT_DIR/product_and_skew_synth_floor.tsv" --label "$LABEL" --json "$OUT_DIR/basin_gate.json")
[[ -z "$PLAN" ]] || args+=(--plan "$PLAN")
python3 "$REPO/sweeps/cbsg/basin/basin_gate_cbsg.py" "${args[@]}" | tee basin_gate.log
python3 - "$OUT_DIR/basin_gate.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1]))
# Every product AND of the 64 tiles must have been measured through its comparator.
assert j['product_ands'] == 8192 and j['comparators'] == 8192, (j['product_ands'], j['comparators'])
bad = j['gate']['status']!='PASS' or ('pin_proof' in j and j['pin_proof']['status']!='PASS')
sys.exit(3 if bad else 0)
PY
