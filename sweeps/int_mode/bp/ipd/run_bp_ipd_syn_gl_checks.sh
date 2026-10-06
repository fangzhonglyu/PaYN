#!/bin/bash
# Post-synthesis functional GL checks for TSMC22/PAYN_SC_CSA_BP_IPD (in-place
# doubling BP variant).  Adapted from sweeps/run_csa_bp_syn_gl_checks.sh
# (unchanged; its target, top and bench are fixed to PAYN_SC_CSA_BP): the
# synthesized netlist, NO_SDF, unit delay, timing checks off, ARM_UD_MODEL +
# ARM_EN_X_SQUASH.
#   (a) SC: 384-batch streaming power bench with +define+PAYN_INT_PORTS, drain
#       checked by cosim_streaming.py; the trace must equal the IPD RTL run's
#       (build/rtl_preflight/bp_ipd/sc/ipd_sc_stream from run_bp_ipd_rtl_checks.sh),
#       which itself equals the CSA top's.
#   (b) INT: designs/payn/tb/test_payn_array_bp_ipd.sv on the real ports with
#       1-edge laps: all three precisions, multi-block, extremes, JUNK, MODE_AT=3,
#       a near-limit INT8 reduction, both shift contracts; negative controls
#       (stray ring, double lap, no lap) must fail the checker.  Every GL trace
#       must equal the IPD RTL trace of the same case
#       (build/rtl_preflight/bp_ipd/int/<label>/).
# Functional only: timing is signed off by STA.
#   bash sweeps/int_mode/bp/ipd/run_bp_ipd_syn_gl_checks.sh     # RUN=csa_bp_ipd_20261004
# Logs: build/rtl_preflight/bp_ipd/syn_gl/
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
export NTFY_CHNL=
unset NETLIST_FILE SDC_FILE SDF_FILE VCS_ARGS
TARGET=TSMC22/PAYN_SC_CSA_BP_IPD
RUN=${RUN:-csa_bp_ipd_20261004}
TOP=payn_array_signed_segmented_csa_bp_ipd
RTL_OUT=build/rtl_preflight/bp_ipd
OUT=$RTL_OUT/syn_gl
MAX_JOBS=${MAX_JOBS:-8}
VCS_GL='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
GLDEF="+define+ARM_UD_MODEL+define+ARM_EN_X_SQUASH +delay_mode_unit +notimingcheck"
[[ -s "syn/build/$TARGET/$RUN/$TOP.syn.v" ]] || { echo "missing netlist for $RUN" >&2; exit 2; }
STREAM_TRACE=designs/payn/power/power_payn_array.sv/array_streaming_rtl.txt
mkdir -p "$OUT"

run_sc() {
    local bdir="$OUT/sc_stream" log="$OUT/sc_stream.log"
    rm -rf "$bdir"
    BUILD_DIR="$bdir" bash designs/payn/cosim/run_power_array.sh \
        GL=syn TARGET="$TARGET" RUN="$RUN" NO_SDF=1 RTL_PREFLIGHT_CMD=true "VCS=$VCS_GL" \
        VCS_ARGS="+define+PAYN_ARRAY_DUT=$TOP+define+PAYN_INT_PORTS+define+SC_K=8+define+SC_M=16+define+SC_NH=8+define+SC_NW=8+define+SC_OWIDTH=24+define+SC_T=128+define+SC_BATCHES=384 $GLDEF" \
        > "$log" 2>&1
    grep -q '^\[PASS\] streaming PaYN drain matches cycle reference' "$log"
    if grep -nE '\[X-FAIL\]|\[INT-FAIL\]|TIMEOUT @|Error-\[' "$log"; then return 1; fi
    grep -q "syn/build/$TARGET/$RUN/$TOP.syn.v" "$log" || { echo "SC GL did not read the IPD netlist"; return 1; }
    cmp "$bdir/$STREAM_TRACE" "$RTL_OUT/sc/ipd_sc_stream/$STREAM_TRACE"
    cmp "$bdir/$STREAM_TRACE" "$RTL_OUT/sc/ref_csa_stream/$STREAM_TRACE"
    echo "SC streaming (384 batches) on the synthesized IPD netlist: PASS, trace identical to the IPD RTL and the CSA RTL"
}

TB=designs/payn/tb/test_payn_array_bp_ipd.sv
INT_DIR=$OUT/int
# Labels match run_bp_ipd_rtl_checks.sh (same operands, so traces must be identical).
CASES=$(cat <<'EOF'
int8_uniform_L1024_m2n16         8 8 1024 2 16 uniform     3 -           pass
int8_allmin_L1024_m1n8           8 8 1024 1  8 allmin      0 -           pass
int8_alternating_L1024_m2n8      8 8 1024 2  8 alternating 0 -           pass
int8_uniform_L256_m2n16_junk     8 8  256 2 16 uniform     6 JUNK        pass
int8_uniform_L256_m2n8_modeat3   8 8  256 2  8 uniform     7 MODE_AT=3   pass
int8_neg1xmin_L65408_m1n8        8 8 65408 1 8 neg1xmin    0 -           pass
w4a8_uniform_L1024_m2n16         8 4 1024 2 16 uniform    12 -           pass
w4a8_minxmax_L1024_m1n8          8 4 1024 1  8 minxmax     0 -           pass
int4_uniform_L1024_m4n16         4 4 1024 4 16 uniform    22 -           pass
int4_allmin_L1024_m2n8           4 4 1024 2  8 allmin      0 -           pass
int4_uniform_L256_m2n16_junk     4 4  256 2 16 uniform    23 JUNK        pass
int8_uniform_L1024_m2n16_lapring 8 8 1024 2 16 uniform     3 LAP_RING_ONLY pass
int8_uniform_L4096_m1n8_lapring  8 8 4096 1  8 uniform     4 LAP_RING_ONLY pass
int8_uniform_L256_m2n16_junk_lapring 8 8 256 2 16 uniform  6 JUNK,LAP_RING_ONLY pass
w4a8_uniform_L1024_m2n16_lapring 8 4 1024 2 16 uniform    12 LAP_RING_ONLY pass
int4_uniform_L256_m2n16_junk_lapring 4 4 256 2 16 uniform 23 JUNK,LAP_RING_ONLY pass
neg_int8_ringstray_L256_m1n8_lapring 8 8 256 1 8 uniform  37 NEG_RING_STRAY,LAP_RING_ONLY fail:CHECK
neg_int8_ringstraymid_L1024_m1n8_lapring 8 8 1024 1 8 uniform 46 NEG_RING_STRAY_MID,LAP_RING_ONLY fail:CHECK
neg_int8_lap2_L256_m1n8_lapring  8 8  256 1  8 uniform    42 LAP_LEN=2,LAP_RING_ONLY fail:CHECK
neg_int8_lap0_L256_m1n8_lapring  8 8  256 1  8 uniform    41 LAP_LEN=0,LAP_RING_ONLY fail:CHECK
EOF
)

int_case() {   # simv label BA BW L MROWS NCOLS DIST SEED FLAGS EXPECT (pass | fail:CHECK)
    local simv=$1 label=$2 ba=$3 bw=$4 L=$5 mrows=$6 ncols=$7 dist=$8 seed=$9 flags=${10} expect=${11:-pass}
    local dir="$INT_DIR/$label" plus=() fl x ref="$RTL_OUT/int/$label/bpt_trace.txt"
    if [[ "$flags" != - ]]; then
        IFS=, read -ra fl <<< "$flags"
        for x in "${fl[@]}"; do plus+=("+$x"); done
    fi
    rm -rf "$dir"; mkdir -p "$dir"
    python3 sweeps/int_mode/bp/gen_bp_workload.py --ba "$ba" --bw "$bw" --L "$L" \
        --mrows "$mrows" --ncols "$ncols" --dist "$dist" --seed "$seed" --out-dir "$dir" > "$dir/gen.log"
    (cd "$dir" && "$simv" +BA="$ba" +BW="$bw" +L="$L" +MROWS="$mrows" +NCOLS="$ncols" "${plus[@]}" \
        > sim.log 2>&1) || { echo "$label: FAIL (simulation error, see $dir/sim.log)"; return 1; }
    grep -q '^PASS: BP INT bench' "$dir/sim.log" || { echo "$label: FAIL (no bench PASS)"; return 1; }
    [[ -f "$ref" ]] || { echo "$label: FAIL (no RTL reference trace $ref; run run_bp_ipd_rtl_checks.sh first)"; return 1; }
    cmp -s "$dir/bpt_trace.txt" "$ref" || { echo "$label: FAIL (GL trace differs from RTL trace)"; return 1; }
    if [[ "$expect" == fail:CHECK ]]; then
        if python3 sweeps/int_mode/bp/check_bp_trace.py "$dir" --json "$dir/check.json" > "$dir/check.log" 2>&1; then
            echo "$label: FAIL (negative control not caught)"; return 1
        fi
        grep -q '^\[FAIL\]' "$dir/check.log" || { echo "$label: FAIL (checker error)"; return 1; }
        echo "$label: PASS (negative control caught, GL trace identical to RTL: $(tail -n 1 "$dir/check.log" | sed 's/^\[FAIL\] //'))"
        return 0
    fi
    python3 sweeps/int_mode/bp/check_bp_trace.py "$dir" --json "$dir/check.json" > "$dir/check.log" 2>&1 \
        || { echo "$label: FAIL $(tail -n 1 "$dir/check.log")"; return 1; }
    echo "$label: PASS (GL trace identical to RTL) $(tail -n 1 "$dir/check.log" | sed 's/^\[PASS\] //')"
}

run_int() {
    local build="$OUT/int_build" status=0 simv
    rm -rf "$INT_DIR" "$build"; mkdir -p "$INT_DIR" "$build/$TB"
    python3 sweeps/int_mode/bp/gen_bp_workload.py --ba 8 --bw 8 --L 128 --mrows 1 --ncols 8 \
        --dist uniform --seed 1 --out-dir "$build/$TB" > /dev/null
    make sim GL=syn TARGET="$TARGET" RUN="$RUN" TB="$TB" BUILD_DIR="$build" NO_SDF=1 \
        RTL_PREFLIGHT_CMD=true "VCS=$VCS_GL" VCS_ARGS="+define+PAYN_ARRAY_DUT=$TOP $GLDEF" \
        > "$OUT/int_compile.log" 2>&1
    grep -q '^PASS: BP INT bench' "$OUT/int_compile.log"
    grep -q "syn/build/$TARGET/$RUN/$TOP.syn.v" "$OUT/int_compile.log" || { echo "INT GL did not read the IPD netlist"; return 1; }
    simv="$REPO/$build/$TB/simv"
    while read -r label ba bw L mrows ncols dist seed flags expect; do
        [[ -n "$label" ]] || continue
        int_case "$simv" "$label" "$ba" "$bw" "$L" "$mrows" "$ncols" "$dist" "$seed" "$flags" "$expect" &
        while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
    done <<< "$CASES"
    while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done
    echo "INT on the synthesized IPD netlist: $(grep -c . <<< "$CASES") cases, status $([[ $status == 0 ]] && echo PASS || echo FAIL)"
    return "$status"
}

status=0
run_sc > "$OUT/sc_summary.log" 2>&1 & p1=$!
run_int > "$OUT/int_summary.log" 2>&1 & p2=$!
wait $p1 || status=1
wait $p2 || status=1
echo "== $OUT/sc_summary.log"; cat "$OUT/sc_summary.log"
echo "== $OUT/int_summary.log"; sort "$OUT/int_summary.log"
echo "bp_ipd post-synthesis GL checks: $([[ $status == 0 ]] && echo PASS || echo FAIL)"
exit "$status"
