#!/bin/bash
# Area + post-PnR power of payn_array stream modes through the identical
# ASTRAEA tutorial flow:  synth -> apr -> GL power-bench sim (SAIF) -> power_apr.
#
# Arms (one synthesized+routed design each; the encoder's scheme is a
# compile-time choice, so UT and C-BSG are separate builds):
#   sm0       STREAM_MODE=0 control (legacy Sobol A and W, plain AND)
#   sm1       STREAM_MODE=1, host-side UT kA (A_ENCODER=0)
#   enc_ut    STREAM_MODE=1 + on-chip A encoder, A_CBSG=0 (UT)
#   enc_cbsg  STREAM_MODE=1 + on-chip A encoder, A_CBSG=1 (C-BSG)
#   gated_orig  payn_array_gated_cbsg STREAMS=0: traditional C-BSG (W gated
#               by A) with PaYN's original A/W generation
#   gated_emu   payn_array_gated_cbsg STREAMS=1: traditional C-BSG on the
#               emulator's streams (bit-exact with its C-BSG)
#             (both on target PAYN_SC_GATED_CBSG)
#
# All: TSMC22/PAYN_SC_SWEEP, K8/M16/N8x8, OWIDTH=24, T=128, 2.5 ns, 384
# back-to-back batches (3072 MAC cycles) in the SAIF window, uniform 7-bit
# magnitudes with random signs. Each run's gate-level drain is checked
# bit-exact before its SAIF is used.
#
#   bash sweeps/run_stream_mode_power.sh              # all six arms
#   bash sweeps/run_stream_mode_power.sh enc_cbsg     # one arm
#
# Needs AFS tokens for the TSMC22 kit (kinit && aklog) and a python with numpy
# + matplotlib on PATH (or PYTHON_BIN_DIR=<venv>/bin).
# Results: build/power_char/stream_mode/results.csv
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
source /usr/share/Modules/init/bash
source ../ASTRAEA/env_setup.sh
[ -n "${PYTHON_BIN_DIR:-}" ] && export PATH="$PYTHON_BIN_DIR:$PATH"
export USE_DW=1

TARGET=TSMC22/PAYN_SC_SWEEP
TOP=payn_array
GATED_TARGET=TSMC22/PAYN_SC_GATED_CBSG
GATED_TOP=payn_array_gated_cbsg
K=8; M=16; N=8; T=128; OW=24; BATCHES=384; PERIOD=2.5
MAC_PER_CYCLE=$((K * M * N * N / T))
SHAPE="PAYN_K=$K PAYN_M=$M PAYN_NH=$N PAYN_NW=$N"
SIMDEF="+define+SC_K=$K+define+SC_M=$M+define+SC_NH=$N+define+SC_NW=$N+define+SC_OWIDTH=$OW+define+SC_T=$T+define+SC_BATCHES=$BATCHES"

OUT=build/power_char/stream_mode
CSV=$OUT/results.csv
mkdir -p "$OUT"
[ -f "$CSV" ] || echo "run,design,synth_area_um2,apr_area_um2,setup_wns,hold_wns,power_mW,pJ_MAC,status" > "$CSV"

# implement <design> <syn_defines> <preflight>  -> sets sarea/area/wns/hold
implement() {
    local design=$1 defs=$2 preflight=$3
    local log=$OUT/$design.log
    local run=k${K}m${M}n${N}_$design
    local syn_dir=syn/build/$TARGET/$run
    local apr_dir=apr/build/$TARGET/$run
    sarea=; area=; wns=; hold=
    if [ ! -f "$syn_dir/$TOP.syn.v" ]; then
        echo "[$design] synth ($defs) -> $run" | tee -a "$log"
        SYN_DEFINES="$SHAPE $defs" RTL_PREFLIGHT_CMD="$preflight" \
            RUN_NAME=$run make synth TARGET=$TARGET >> "$log" 2>&1
    fi
    [ -f "$syn_dir/$TOP.syn.v" ] || { echo "$design,$design,,,,,,,SYNTH_FAIL" >> "$CSV"; return 1; }
    sarea=$(grep -m1 "Total cell area" "$syn_dir/area.rpt" | awk '{print $NF}')
    if [ ! -f "$apr_dir/outputs/$TOP.apr.v" ]; then
        echo "[$design] apr -> $run" | tee -a "$log"
        SYNTH_RUN=$run RUN_NAME=$run make apr TARGET=$TARGET >> "$log" 2>&1
    fi
    [ -f "$apr_dir/outputs/$TOP.apr.v" ] || { echo "$design,$design,$sarea,,,,,,APR_FAIL" >> "$CSV"; return 1; }
    wns=$(sed -n 's/.*Slack Time *//p' "$apr_dir/reports/setup.rpt" | head -1)
    hold=$(sed -n 's/.*Slack Time *//p' "$apr_dir/reports/hold.rpt" | head -1)
    area=$(awk -v t="$TOP" '$1==t{print $3; exit}' "$apr_dir/reports/area.rpt" 2>/dev/null)
    echo "[$design] synth area=$sarea  apr area=$area setup=$wns hold=$hold" | tee -a "$log"
}

# measure <tag> <design> <tb> <trace> <checker> <extra sim defines>
measure() {
    local tag=$1 design=$2 tb=$3 trace=$4 checker=$5 xdef=$6
    local log=$OUT/$design.log
    local run=k${K}m${M}n${N}_$design
    local apr_dir=apr/build/$TARGET/$run
    local bdir=$OUT/${tag}_gl glog=$OUT/${tag}_glsim.log plog=$OUT/${tag}_power.log
    echo "[$tag] GL sim $tb $xdef" | tee -a "$log"
    make sim GL=apr TARGET=$TARGET RUN=$run TB=$tb BUILD_DIR=$bdir \
         VCS_ARGS="$SIMDEF$xdef" > "$glog" 2>&1
    grep -q "PASS:" "$glog" || { echo "$tag,$design,$sarea,$area,$wns,$hold,,,GLSIM_FAIL" >> "$CSV"; return 1; }
    python3 "$checker" "$bdir/$tb/$trace" >> "$log" 2>&1 || {
        echo "$tag,$design,$sarea,$area,$wns,$hold,,,COSIM_FAIL" >> "$CSV"; return 1; }
    POWER_SAIF_VALIDATOR=sweeps/validate_sc_power_saif.py \
        make power_apr TARGET=$TARGET RUN=$run \
             SAIF="$(readlink -f "$bdir/$tb/dut.saif")" SAIF_STRIP_PATH=Top/dut > "$plog" 2>&1
    grep -qE "invalid (binary|SC) SAIF" "$plog" && {
        echo "$tag,$design,$sarea,$area,$wns,$hold,,,SAIF_INVALID" >> "$CSV"; return 1; }
    # power_apr writes into the APR run; keep a copy per measurement.
    cp -f "$apr_dir/reports/power.rpt" "$OUT/${tag}_power.rpt" 2>/dev/null
    local pw pj
    pw=$(grep -m1 "Total Power" "$OUT/${tag}_power.rpt" | grep -oE "[0-9]+\.[0-9]+e[-+][0-9]+" | head -1)
    [ -n "$pw" ] || { echo "$tag,$design,$sarea,$area,$wns,$hold,,,POWER_FAIL" >> "$CSV"; return 1; }
    pj=$(python3 -c "print(f'{float(\"$pw\")*1000.0*$PERIOD/$MAC_PER_CYCLE:.6f}')")
    pw=$(python3 -c "print(f'{float(\"$pw\")*1000.0:.5f}')")
    echo "$tag,$design,$sarea,$area,$wns,$hold,$pw,$pj,OK" >> "$CSV"
    echo "[$tag] RESULT area=$area um2  power=$pw mW  pJ/MAC=$pj" | tee -a "$log"
}

UTB=designs/payn/power/power_payn_array_ut.sv
UTRACE=array_streaming_ut_rtl.txt
UCHK=designs/payn/cosim/cosim_streaming_ut.py

ARMS=("$@")
[ ${#ARMS[@]} -gt 0 ] || ARMS=(sm0 sm1 enc_ut enc_cbsg gated_orig gated_emu)
for a in "${ARMS[@]}"; do
    case $a in
        sm0)
            implement sm0 "PAYN_STREAM_MODE=0" \
                "BUILD_DIR=build/rtl_preflight/sm0 VCS_ARGS=+define+SC_K=$K+define+SC_M=$M+define+SC_NH=$N+define+SC_NW=$N+define+SC_OWIDTH=$OW+define+SC_T=$T bash designs/payn/cosim/run_array.sh" \
            && measure sm0 sm0 designs/payn/power/power_payn_array.sv \
                array_streaming_rtl.txt designs/payn/cosim/cosim_streaming.py "" ;;
        sm1)
            implement sm1 "PAYN_STREAM_MODE=1" \
                "BUILD_DIR=build/rtl_preflight/sm1 bash designs/payn/cosim/run_ut_matmul.sh" \
            && measure sm1 sm1 $UTB $UTRACE $UCHK "+define+SC_A_ENCODER=0" ;;
        enc_ut|enc_cbsg)
            cbsg=$([ "$a" = enc_cbsg ] && echo 1 || echo 0)
            implement $a "PAYN_STREAM_MODE=1 PAYN_A_ENCODER=1 PAYN_A_CBSG=$cbsg" \
                "BUILD_DIR=build/rtl_preflight/$a A_ENCODER=1 bash designs/payn/cosim/run_ut_matmul.sh" \
            && measure $a $a $UTB $UTRACE $UCHK "+define+SC_A_ENCODER=1+define+SC_CBSG=$cbsg" ;;
        gated_orig)
            ( TARGET=$GATED_TARGET; TOP=$GATED_TOP
              implement gated_orig "PAYN_GATED_STREAMS=0" \
                  "BUILD_DIR=build/rtl_preflight/gated_orig SIM_SRCS=designs/payn/variants/gated_cbsg/payn_array_gated_cbsg.sv bash designs/payn/cosim/run_power_array.sh VCS_ARGS='-lca +define+PAYN_ARRAY_EXTERNAL_RTL+define+PAYN_ARRAY_DUT=payn_array_gated_cbsg+define+PAYN_GATED_CBSG+define+PAYN_GATED_STREAMS=0+define+SC_K=$K+define+SC_M=$M+define+SC_NH=$N+define+SC_NW=$N+define+SC_OWIDTH=$OW+define+SC_T=$T+define+SC_BATCHES=16' GL= TARGET=" \
              && measure gated_orig gated_orig designs/payn/power/power_payn_array.sv \
                  array_streaming_rtl.txt designs/payn/cosim/cosim_streaming.py \
                  "+define+PAYN_ARRAY_DUT=payn_array_gated_cbsg+define+PAYN_GATED_CBSG" ) ;;
        gated_emu)
            ( TARGET=$GATED_TARGET; TOP=$GATED_TOP
              implement gated_emu "PAYN_GATED_STREAMS=1" \
                  "BUILD_DIR=build/rtl_preflight/gated_emu SIM_SRCS=designs/payn/variants/gated_cbsg/payn_array_gated_cbsg.sv bash designs/payn/cosim/run_power_array_ut.sh VCS_ARGS='-lca +define+PAYN_ARRAY_EXTERNAL_RTL+define+PAYN_ARRAY_DUT=payn_array_gated_cbsg+define+PAYN_GATED_STREAMS=1+define+SC_GATED+define+SC_K=$K+define+SC_M=$M+define+SC_NH=$N+define+SC_NW=$N+define+SC_OWIDTH=$OW+define+SC_T=$T+define+SC_BATCHES=16' GL= TARGET=" \
              && measure gated_emu gated_emu $UTB $UTRACE $UCHK \
                  "+define+PAYN_ARRAY_DUT=payn_array_gated_cbsg+define+SC_GATED" ) ;;
        *) echo "unknown arm: $a" >&2 ;;
    esac
done
echo "=== $CSV ==="
cat "$CSV"
