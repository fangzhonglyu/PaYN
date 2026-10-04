#!/bin/bash
# Area + post-PnR power of payn_array STREAM_MODE=1 (unary-temporal A, sample-
# ordered Sobol W) against a STREAM_MODE=0 control, through the identical
# ASTRAEA tutorial flow:  synth -> apr -> GL power-bench sim (SAIF) -> power_apr.
#
# Both arms: TSMC22/PAYN_SC_SWEEP, K8/M16/N8x8, OWIDTH=24, T=128, 2.5 ns,
# 384 back-to-back batches (3072 MAC cycles) in the SAIF window, uniform 7-bit
# magnitudes with random signs. Each arm's gate-level drain is checked
# bit-exact before its SAIF is used.
#
#   bash sweeps/run_stream_mode_power.sh            # both arms
#   bash sweeps/run_stream_mode_power.sh sm1        # one arm (sm0 | sm1)
#
# Results: build/power_char/stream_mode/results.csv
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
source /usr/share/Modules/init/bash
source ../ASTRAEA/env_setup.sh
# Cosim checkers need numpy; prefer a venv python if one is provided.
[ -n "${PYTHON_BIN_DIR:-}" ] && export PATH="$PYTHON_BIN_DIR:$PATH"
export USE_DW=1

TARGET=TSMC22/PAYN_SC_SWEEP
TOP=payn_array
K=8; M=16; N=8; T=128; OW=24; BATCHES=384; PERIOD=2.5
MAC_PER_CYCLE=$((K * M * N * N / T))
SHAPE="PAYN_K=$K PAYN_M=$M PAYN_NH=$N PAYN_NW=$N"
SIMDEF="+define+SC_K=$K+define+SC_M=$M+define+SC_NH=$N+define+SC_NW=$N+define+SC_OWIDTH=$OW+define+SC_T=$T+define+SC_BATCHES=$BATCHES"

OUT=build/power_char/stream_mode
CSV=$OUT/results.csv
mkdir -p "$OUT"
[ -f "$CSV" ] || echo "arm,stream_mode,synth_area_um2,apr_area_um2,setup_wns,hold_wns,power_mW,pJ_MAC,status" > "$CSV"

run_arm() {                       # $1=tag  $2=STREAM_MODE
    local tag=$1 mode=$2
    local log=$OUT/$tag.log
    local run=k${K}m${M}n${N}_$tag
    local syn_dir=syn/build/$TARGET/$run
    local apr_dir=apr/build/$TARGET/$run
    local tb preflight trace checker
    if [ "$mode" = 1 ]; then
        tb=designs/payn/power/power_payn_array_ut.sv
        preflight="BUILD_DIR=build/rtl_preflight/$run bash designs/payn/cosim/run_ut_matmul.sh"
        trace=array_streaming_ut_rtl.txt
        checker=designs/payn/cosim/cosim_streaming_ut.py
    else
        tb=designs/payn/power/power_payn_array.sv
        preflight="BUILD_DIR=build/rtl_preflight/$run VCS_ARGS=+define+SC_K=$K+define+SC_M=$M+define+SC_NH=$N+define+SC_NW=$N+define+SC_OWIDTH=$OW+define+SC_T=$T bash designs/payn/cosim/run_array.sh"
        trace=array_streaming_rtl.txt
        checker=designs/payn/cosim/cosim_streaming.py
    fi
    fail() { echo "$tag,$mode,${sarea:-},${area:-},${wns:-},${hold:-},,,$1" >> "$CSV"; echo "[$tag] FAILED: $1" | tee -a "$log"; }

    #---------------------------------------------------------------- synth --
    if [ -f "$syn_dir/$TOP.syn.v" ]; then
        echo "[$tag] reuse synthesis $run" | tee -a "$log"
    else
        echo "[$tag] synth STREAM_MODE=$mode -> $run" | tee -a "$log"
        SYN_DEFINES="$SHAPE PAYN_STREAM_MODE=$mode" RTL_PREFLIGHT_CMD="$preflight" \
            RUN_NAME=$run make synth TARGET=$TARGET >> "$log" 2>&1
    fi
    [ -f "$syn_dir/$TOP.syn.v" ] || { fail SYNTH_FAIL; return 1; }
    sarea=$(grep -m1 "Total cell area" "$syn_dir/area.rpt" | awk '{print $NF}')
    echo "[$tag] synth area=$sarea" | tee -a "$log"

    #------------------------------------------------------------------ apr --
    if [ ! -f "$apr_dir/outputs/$TOP.apr.v" ]; then
        echo "[$tag] apr -> $run" | tee -a "$log"
        SYNTH_RUN=$run RUN_NAME=$run make apr TARGET=$TARGET >> "$log" 2>&1
    fi
    [ -f "$apr_dir/outputs/$TOP.apr.v" ] || { fail APR_FAIL; return 1; }
    wns=$(sed -n 's/.*Slack Time *//p' "$apr_dir/reports/setup.rpt" | head -1)
    hold=$(sed -n 's/.*Slack Time *//p' "$apr_dir/reports/hold.rpt" | head -1)
    area=$(awk -v t="$TOP" '$1==t{print $3; exit}' "$apr_dir/reports/area.rpt" 2>/dev/null)
    echo "[$tag] apr area=$area setup=$wns hold=$hold" | tee -a "$log"

    #------------------------------------------------- GL power-bench sim ----
    local bdir=$OUT/${tag}_gl
    local glog=$OUT/${tag}_glsim.log
    echo "[$tag] GL sim $tb" | tee -a "$log"
    make sim GL=apr TARGET=$TARGET RUN=$run TB=$tb BUILD_DIR=$bdir \
         VCS_ARGS="$SIMDEF" > "$glog" 2>&1
    grep -q "PASS:" "$glog" || { fail GLSIM_FAIL; return 1; }
    python3 "$checker" "$bdir/$tb/$trace" >> "$log" 2>&1 || { fail COSIM_FAIL; return 1; }
    echo "[$tag] GL drain bit-exact" | tee -a "$log"

    #----------------------------------------------------------- power_apr ---
    local plog=$OUT/${tag}_power.log
    POWER_SAIF_VALIDATOR=sweeps/validate_sc_power_saif.py \
        make power_apr TARGET=$TARGET RUN=$run \
             SAIF="$(readlink -f "$bdir/$tb/dut.saif")" SAIF_STRIP_PATH=Top/dut > "$plog" 2>&1
    grep -qE "invalid (binary|SC) SAIF" "$plog" && { fail SAIF_INVALID; return 1; }
    local pw pj
    pw=$(grep -m1 "Total Power" "$apr_dir/reports/power.rpt" | grep -oE "[0-9]+\.[0-9]+e[-+][0-9]+" | head -1)
    [ -n "$pw" ] || { fail POWER_FAIL; return 1; }
    pj=$(python3 -c "print(f'{float(\"$pw\")*1000.0*$PERIOD/$MAC_PER_CYCLE:.6f}')")
    pw=$(python3 -c "print(f'{float(\"$pw\")*1000.0:.5f}')")
    echo "$tag,$mode,$sarea,$area,$wns,$hold,$pw,$pj,OK" >> "$CSV"
    echo "[$tag] RESULT area=$area um2  power=$pw mW  pJ/MAC=$pj" | tee -a "$log"
}

ARMS=("$@")
[ ${#ARMS[@]} -gt 0 ] || ARMS=(sm0 sm1)
for a in "${ARMS[@]}"; do
    case $a in
        sm0) run_arm sm0 0 ;;
        sm1) run_arm sm1 1 ;;
        *) echo "unknown arm: $a" >&2 ;;
    esac
done
echo "=== $CSV ==="
cat "$CSV"
