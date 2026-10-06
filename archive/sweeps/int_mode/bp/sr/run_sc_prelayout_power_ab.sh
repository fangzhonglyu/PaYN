#!/bin/bash
# Pre-layout SC power A/B of the lap hardware (review finding: the in-place
# doubling mux sits in every tile's SC accumulator path, so SC pJ/MAC may rise).
# Same method as sweeps/run_popcount_syn_power.sh: the synthesized netlist,
# unit-delay GL activity of the SC streaming power bench (384 batches, T=128,
# drain excluded by the bench's $toggle_stop), PT-PX with that SAIF and no
# SPEF / CTS (cell internal + pin-load switching + leakage).  Identical
# stimulus for every arm, so the deltas are activity-matched; absolute numbers
# are NOT comparable with the routed max-SDF headline (15.7-16.5 mW).
#
# Arms (synthesis runs, read only; nothing is written into syn/build):
#   csa  PAYN_SC_CSA/csa_20261002                (no INT mode)
#   lap  PAYN_SC_CSA_BP/csa_bp_20261004_lap      (BP ring, g = 8)
#   sr4  PAYN_SC_CSA_BP_SR4/csa_bp_sr4_20261004  (g = 4)
#   sr2  PAYN_SC_CSA_BP_SR2/csa_bp_sr2_20261004  (g = 2)
#   ipd  PAYN_SC_CSA_BP_IPD/csa_bp_ipd_20261004  (g = 1)
# Each arm's GL drain must pass cosim_streaming.py and its trace must equal
# the CSA RTL streaming trace (build/rtl_preflight/bp_sr/sc/ref_csa_stream).
#
# NEEDS AFS (ARM cell Verilog for GL, liberty for PT): run after `kinit && aklog`.
#   bash sweeps/int_mode/bp/sr/run_sc_prelayout_power_ab.sh            # all arms
#   bash sweeps/int_mode/bp/sr/run_sc_prelayout_power_ab.sh lap ipd    # subset
# Output: build/rtl_preflight/bp_sr/sc_power_ab/<arm>/{gl.log,power.rpt,power_hier.rpt,block_power.csv},
#         summary.txt
# Opt-in overrides (all unset = the behaviour above, unchanged):
#   SC_AB_OUT=<dir>            output directory (absolute or repo-relative) instead of
#                              build/rtl_preflight/bp_sr/sc_power_ab
#   SC_AB_<ARM>_RUN=<run>      synthesis run name for that arm (ARM = CSA LAP SR4 SR2 IPD),
#                              e.g. SC_AB_SR2_RUN=csa_bp_sr2_20261004_clean; the run must
#                              hold its netlist + SDC (no fallback)
#   The "nothing written into the synthesis runs" check covers the runs of all five
#   arms that exist (it used to cover only csa and lap).
# Full-precision hierarchy split + routed calibration (report_power -hier prints only
# 3 digits): run_sc_power_buckets.sh <out> <bucket_out>, then sc_power_ab_breakdown.py.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
cd "$REPO"
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
export NTFY_CHNL= TSMC22_CELL_TIER=sc7mcpp140z TSMC22_LIB_FLAVORS=svt_c30 TSMC22_HPK_FLAVORS=svt_c30 TSMC22_HPK=1
unset NETLIST_FILE SDC_FILE SDF_FILE VCS_ARGS
OUT=${SC_AB_OUT:-$REPO/build/rtl_preflight/bp_sr/sc_power_ab}
[[ "$OUT" == /* ]] || OUT=$REPO/$OUT
REF=$REPO/build/rtl_preflight/bp_sr/sc/ref_csa_stream/designs/payn/power/power_payn_array.sv/array_streaming_rtl.txt
STREAM=designs/payn/power/power_payn_array.sv
VCS_GL='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
GLDEF="+define+ARM_UD_MODEL+define+ARM_EN_X_SQUASH +delay_mode_unit +notimingcheck"
SHAPE="+define+SC_K=8+define+SC_M=16+define+SC_NH=8+define+SC_NW=8+define+SC_OWIDTH=24+define+SC_T=128+define+SC_BATCHES=384"
[[ -s "$REF" ]] || { echo "missing CSA RTL streaming reference $REF (run run_bp_sr_rtl_checks.sh PARTS=sc)" >&2; exit 2; }
mkdir -p "$OUT"
marker=$OUT/.start_marker; : > "$marker"

arm_cfg() {   # arm -> "target run top int_ports"
    case $1 in
        csa) echo "PAYN_SC_CSA ${SC_AB_CSA_RUN:-csa_20261002} payn_array_signed_segmented_csa 0" ;;
        lap) echo "PAYN_SC_CSA_BP ${SC_AB_LAP_RUN:-csa_bp_20261004_lap} payn_array_signed_segmented_csa_bp 1" ;;
        sr4) echo "PAYN_SC_CSA_BP_SR4 ${SC_AB_SR4_RUN:-csa_bp_sr4_20261004} payn_array_signed_segmented_csa_bp_sr 1" ;;
        sr2) echo "PAYN_SC_CSA_BP_SR2 ${SC_AB_SR2_RUN:-csa_bp_sr2_20261004} payn_array_signed_segmented_csa_bp_sr 1" ;;
        ipd) echo "PAYN_SC_CSA_BP_IPD ${SC_AB_IPD_RUN:-csa_bp_ipd_20261004} payn_array_signed_segmented_csa_bp_ipd 1" ;;
        *) echo "unknown arm $1" >&2; return 2 ;;
    esac
}

run_arm() (
    set -euo pipefail
    local arm=$1 tgt run top ip syn w defs saif
    read -r tgt run top ip <<< "$(arm_cfg "$arm")"
    syn=$REPO/syn/build/TSMC22/$tgt/$run
    [[ -s $syn/$top.syn.v && -s $syn/$top.syn.sdc ]] || { echo "[$arm] missing netlist/SDC in $syn"; exit 1; }
    w=$OUT/$arm
    rm -rf "$w"; mkdir -p "$w"
    defs="+define+PAYN_ARRAY_DUT=$top$SHAPE"
    (( ip )) && defs="+define+PAYN_ARRAY_DUT=$top+define+PAYN_INT_PORTS$SHAPE"
    BUILD_DIR="$w/gl" bash designs/payn/cosim/run_power_array.sh \
        GL=syn TARGET="TSMC22/$tgt" RUN="$run" NO_SDF=1 RTL_PREFLIGHT_CMD=true "VCS=$VCS_GL" \
        VCS_ARGS="$defs $GLDEF" > "$w/gl.log" 2>&1
    grep -q '^\[PASS\] streaming PaYN drain matches cycle reference' "$w/gl.log"
    grep -q "$syn/$top.syn.v\|syn/build/TSMC22/$tgt/$run/$top.syn.v" "$w/gl.log" || { echo "[$arm] GL did not read its netlist"; exit 1; }
    cmp "$w/gl/$STREAM/array_streaming_rtl.txt" "$REF"
    saif=$w/gl/$STREAM/dut.saif
    python3 -B sweeps/validate_sc_power_saif.py "$saif" --expected-period-ns 2.5 > "$w/saif_validation.txt"
    printf 'NETLIST=%s\nSDC=%s\nSAIF=%s\nMODE=pre-layout, unit-delay GL activity, no SPEF/CTS\n' \
        "$syn/$top.syn.v" "$syn/$top.syn.sdc" "$saif" > "$w/inputs.txt"
    cd "$w"
    TOP=$top NL=$syn/$top.syn.v SDC=$syn/$top.syn.sdc SAIF_FILE=$saif \
        pt_shell -file "$REPO/sweeps/pt_popcount_syn_power.tcl" > pt.log 2>&1
    if grep -n '^\(Error:\|ERROR:\)' pt.log; then exit 1; fi
    grep -q '^POPCOUNT_SYN_POWER_DONE ' pt.log
    echo "[$arm] done: $w/power.rpt"
)

arms=("$@")
((${#arms[@]})) || arms=(csa lap sr4 sr2 ipd)
pids=()
for a in "${arms[@]}"; do run_arm "$a" & pids+=("$!"); done
status=0
for p in "${pids[@]}"; do wait "$p" || status=1; done
# nothing may have been written into the synthesis runs (all five arms' runs)
protect=()
for a in csa lap sr4 sr2 ipd; do
    read -r t r _ _ <<< "$(arm_cfg "$a")"
    if [[ -d "$REPO/syn/build/TSMC22/$t/$r" ]]; then protect+=("$REPO/syn/build/TSMC22/$t/$r"); fi
done
if ((${#protect[@]})) && find "${protect[@]}" -newer "$marker" -print -quit | grep -q .; then
    echo "WARNING: files newer than the start marker inside a protected synthesis run"; status=1
fi
python3 - "$OUT" "${arms[@]}" <<'PY' | tee "$OUT/summary.txt"
import re, sys, csv
from pathlib import Path
out, arms = Path(sys.argv[1]), sys.argv[2:]
rows = {}
for a in arms:
    p = out / a / "power.rpt"
    if not p.is_file():
        continue
    t = p.read_text()
    m = re.search(r"Total Power\s*=\s*([0-9.eE+-]+)", t)
    tot = float(m[1]) * 1e3 if m else float("nan")          # W -> mW
    blk = {r["block"]: r for r in csv.DictReader((out / a / "block_power.csv").open())}
    rows[a] = (tot, float(blk["u_pe"]["total_mW"]), float(blk["tile_combinational"]["total_mW"]))
print("pre-layout SC power (unit-delay GL SAIF, no SPEF/CTS, drain excluded, identical stimulus); "
      "pJ/MAC = mW / (64 MAC/cycle x 0.4 GHz)")
print(f"{'arm':4s} {'total mW':>9s} {'pJ/MAC':>7s} {'vs lap':>8s} {'vs csa':>8s} {'u_pe mW':>8s} {'tile comb mW':>12s}")
for a, (tot, upe, tc) in rows.items():
    vl = f"{100 * (tot / rows['lap'][0] - 1):+.2f}%" if "lap" in rows else "-"
    vc = f"{100 * (tot / rows['csa'][0] - 1):+.2f}%" if "csa" in rows else "-"
    print(f"{a:4s} {tot:9.3f} {tot / 25.6:7.4f} {vl:>8s} {vc:>8s} {upe:8.3f} {tc:12.3f}")
PY
exit "$status"
