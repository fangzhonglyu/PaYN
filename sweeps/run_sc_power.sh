#!/bin/bash
# Area + post-PnR power of payn_array (C-BSG) through the ASTRAEA tutorial flow:
#   synth -> apr -> GL power-bench sim (SAIF) -> power_apr
#
# TSMC22/PAYN_SC_SWEEP at K8/M16/N8x8 (override with K/M/N), OWIDTH=24, T=128,
# 2.5 ns, 384 back-to-back K-blocks (3072 MAC cycles) in the SAIF window,
# uniform 7-bit magnitudes with random signs. The gate-level drain is checked
# bit-exact against the emulator's C-BSG before its SAIF is used.
#
#   bash sweeps/run_sc_power.sh
#   K=4 M=8 N=4 T=64 bash sweeps/run_sc_power.sh
#
# Needs AFS tokens for the TSMC22 kit (kinit && aklog) and a python with numpy
# + matplotlib on PATH (or PYTHON_BIN_DIR=<venv>/bin).
# Results: build/power_char/sc/results.csv
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
source /usr/share/Modules/init/bash
source ../ASTRAEA/env_setup.sh
[ -n "${PYTHON_BIN_DIR:-}" ] && export PATH="$PYTHON_BIN_DIR:$PATH"
export USE_DW=1

TARGET=TSMC22/PAYN_SC_SWEEP
TOP=payn_array
K=${K:-8}; M=${M:-16}; N=${N:-8}; T=${T:-128}; OW=24; PERIOD=2.5
BATCHES=${BATCHES:-$((3072 * M / T))}
MAC_PER_CYCLE=$((K * M * N * N / T))
SIMDEF="+define+SC_K=$K+define+SC_M=$M+define+SC_NH=$N+define+SC_NW=$N+define+SC_OWIDTH=$OW+define+SC_T=$T+define+SC_BATCHES=$BATCHES"
TB=designs/payn/power/power_payn_array.sv

OUT=build/power_char/sc
CSV=$OUT/results.csv
RUN=k${K}m${M}n${N}
LOG=$OUT/$RUN.log
mkdir -p "$OUT"
[ -f "$CSV" ] || echo "run,T,synth_area_um2,apr_area_um2,setup_wns,hold_wns,power_mW,pJ_MAC,status" > "$CSV"
fail() { echo "$RUN,$T,${sarea:-},${area:-},${wns:-},${hold:-},,,$1" >> "$CSV"; echo "[$RUN] FAILED: $1" | tee -a "$LOG"; exit 1; }

SYN_DIR=syn/build/$TARGET/$RUN
APR_DIR=apr/build/$TARGET/$RUN

#------------------------------------------------------------------- synth --
if [ ! -f "$SYN_DIR/$TOP.syn.v" ]; then
    echo "[$RUN] synth" | tee -a "$LOG"
    SYN_DEFINES="PAYN_K=$K PAYN_M=$M PAYN_NH=$N PAYN_NW=$N" \
    RTL_PREFLIGHT_CMD="BUILD_DIR=build/rtl_preflight/$RUN bash designs/payn/cosim/run_power_array.sh VCS_ARGS='-lca $SIMDEF+define+SC_BATCHES=16' GL= TARGET=" \
        RUN_NAME=$RUN make synth TARGET=$TARGET >> "$LOG" 2>&1
fi
[ -f "$SYN_DIR/$TOP.syn.v" ] || fail SYNTH_FAIL
sarea=$(grep -m1 "Total cell area" "$SYN_DIR/area.rpt" | awk '{print $NF}')

#--------------------------------------------------------------------- apr --
if [ ! -f "$APR_DIR/outputs/$TOP.apr.v" ]; then
    echo "[$RUN] apr" | tee -a "$LOG"
    SYNTH_RUN=$RUN RUN_NAME=$RUN make apr TARGET=$TARGET >> "$LOG" 2>&1
fi
[ -f "$APR_DIR/outputs/$TOP.apr.v" ] || fail APR_FAIL
wns=$(sed -n 's/.*Slack Time *//p' "$APR_DIR/reports/setup.rpt" | head -1)
hold=$(sed -n 's/.*Slack Time *//p' "$APR_DIR/reports/hold.rpt" | head -1)
area=$(awk -v t="$TOP" '$1==t{print $3; exit}' "$APR_DIR/reports/area.rpt" 2>/dev/null)
echo "[$RUN] synth area=$sarea  apr area=$area setup=$wns hold=$hold" | tee -a "$LOG"

#------------------------------------------------- GL power-bench sim -------
BDIR=$OUT/${RUN}_t${T}_gl
GLOG=$OUT/${RUN}_t${T}_glsim.log
echo "[$RUN] GL sim T=$T" | tee -a "$LOG"
make sim GL=apr TARGET=$TARGET RUN=$RUN TB=$TB BUILD_DIR=$BDIR VCS_ARGS="$SIMDEF" > "$GLOG" 2>&1
grep -q "PASS:" "$GLOG" || fail GLSIM_FAIL
python3 designs/payn/cosim/cosim_streaming.py "$BDIR/$TB/array_streaming_rtl.txt" >> "$LOG" 2>&1 \
    || fail COSIM_FAIL
echo "[$RUN] GL drain bit-exact" | tee -a "$LOG"

#--------------------------------------------------------------- power_apr --
PLOG=$OUT/${RUN}_t${T}_power.log
POWER_SAIF_VALIDATOR=sweeps/validate_sc_power_saif.py \
    make power_apr TARGET=$TARGET RUN=$RUN \
         SAIF="$(readlink -f "$BDIR/$TB/dut.saif")" SAIF_STRIP_PATH=Top/dut > "$PLOG" 2>&1
grep -qE "invalid (binary|SC) SAIF" "$PLOG" && fail SAIF_INVALID
cp -f "$APR_DIR/reports/power.rpt" "$OUT/${RUN}_t${T}_power.rpt" 2>/dev/null
pw=$(grep -m1 "Total Power" "$OUT/${RUN}_t${T}_power.rpt" | grep -oE "[0-9]+\.[0-9]+e[-+][0-9]+" | head -1)
[ -n "$pw" ] || fail POWER_FAIL
pj=$(python3 -c "print(f'{float(\"$pw\")*1000.0*$PERIOD/$MAC_PER_CYCLE:.6f}')")
pw=$(python3 -c "print(f'{float(\"$pw\")*1000.0:.5f}')")
echo "$RUN,$T,$sarea,$area,$wns,$hold,$pw,$pj,OK" >> "$CSV"
echo "[$RUN] RESULT T=$T area=$area um2  power=$pw mW  pJ/MAC=$pj" | tee -a "$LOG"
