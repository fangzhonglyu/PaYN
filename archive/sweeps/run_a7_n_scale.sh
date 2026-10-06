#!/bin/bash
# A7/SVT + HPK array-size scaling for the accepted pending-bit PaYN design.
#
# K=8, M=16, LOW_W=9, T=128 are fixed; N (= N_H = N_W) is the swept axis.
# Reproduces the accepted `spp_fixed` recipe at each N so the results are
# directly comparable to the 0.70984 pJ/MAC N=8 headline:
#
#   pass 1  distribution guides only            -> bootstrap activity SAIF
#   pass 2  + APR_WORKLOAD_POWER_OPT (spp)      -> accepted route
#
# The newer SYN_SAIF_FILE / APR_OPT_POWER / APR_MULTIBIT_FLOP_OPT knobs are
# deliberately NOT used: on N=8 they measured 0.72331 against spp_fixed's
# 0.70984, a 1.9% regression.
#
#   bash sweeps/run_a7_n_scale.sh 12          # synth + both APR passes + power
#   STOP_AFTER=synth bash sweeps/run_a7_n_scale.sh 10 12
set -u

cd /home/barrylyu/repos/PaYN
source /etc/profile.d/modules.sh 2>/dev/null || \
    source /usr/share/Modules/init/bash 2>/dev/null
module load synopsys-lib-compiler/2022.03-SP3 \
            synopsys-synth/2021.06-SP1 \
            primetime/2021.06-SP1 \
            vcs/2020.12-SP2-1 \
            innovus/21.14.000 \
            genus/21.14.000 2>/dev/null
export SYNOPSYS=${SYNOPSYS:-/usr/caen/synopsys-synth-2021.06-SP1}
export USE_DW=1

TARGET=TSMC22/PAYN_SC_SIGNED_SEGMENTED
TOP=payn_array_signed_segmented
SRC=designs/payn/variants/signed_segmented/payn_array_signed_segmented.sv
TB=designs/payn/power/power_payn_array.sv
K=${PAYN_K:-8}; M=${PAYN_M:-16}; T=128; LW=9
# 2**LOW_W must be >= K*M (README: at most one carry/borrow per cycle).
if [ $((1 << LW)) -lt $((K * M)) ]; then
    echo "ERROR: LOW_W=$LW gives 2^$LW=$((1<<LW)) < K*M=$((K*M))" >&2; exit 2
fi
TOTAL_CYCLES=3072
PERIOD=2.5
OUT=build/power_char/a7_n_scale
CSV=$OUT/results.csv
STOP_AFTER=${STOP_AFTER:-power}
N_VALUES=("$@")
[ ${#N_VALUES[@]} -gt 0 ] || N_VALUES=(12)
mkdir -p "$OUT"
[ -f "$CSV" ] || echo "N,stage,run,area_um2,setup_wns,hold_wns,power_mW,pJ_MAC,status" > "$CSV"

MAC_CYCLES=$((T / M))
N_BATCHES=$((TOTAL_CYCLES / MAC_CYCLES))

run_n() {
    local n=$1
    local log=$OUT/k${K}m${M}n${n}.log
    local synrun=k${K}m${M}n${n}_lw9
    local apr1=k${K}m${M}n${n}_lw9_distguide
    local apr2=k${K}m${M}n${n}_lw9_distguide_spp_fixed
    local syn_dir=syn/build/$TARGET/$synrun
    # MACs retired per clock = K*M*N^2/T
    local mac_per_cycle=$((K * M * n * n / T))

    local defs="+define+PAYN_ARRAY_DUT=$TOP+define+SC_K=$K+define+SC_M=$M+define+SC_NH=$n+define+SC_NW=$n+define+SC_OWIDTH=24+define+SC_T=$T+define+SC_BATCHES=$N_BATCHES"

    echo "[N=$n] MAC/cycle=$mac_per_cycle batches=$N_BATCHES" | tee -a "$log"

    # ---------------------------------------------------------------- synth --
    if [ -f "$syn_dir/$TOP.syn.v" ]; then
        echo "[N=$n] reuse existing synthesis $synrun" | tee -a "$log"
    else
        echo "[N=$n] synth -> $synrun" | tee -a "$log"
        SYN_DEFINES="PAYN_K=$K PAYN_M=$M PAYN_NH=$n PAYN_NW=$n PAYN_SEG_LOW_W=$LW" \
        RTL_PREFLIGHT_CMD="BUILD_DIR=build/rtl_preflight/ss_k${K}m${M}n${n} SIM_SRCS=$SRC VCS_ARGS=+define+PAYN_ARRAY_EXTERNAL_RTL+PAYN_ARRAY_DUT=$TOP+define+SC_K=$K+define+SC_M=$M+define+SC_NH=$n+define+SC_NW=$n+define+SC_OWIDTH=24+define+SC_T=$T bash designs/payn/cosim/run_array.sh" \
        RUN_NAME=$synrun make synth TARGET=$TARGET >> "$log" 2>&1
    fi
    if [ ! -f "$syn_dir/$TOP.syn.v" ]; then
        echo "$n,synth,$synrun,,,,,,SYNTH_FAIL" >> "$CSV"; return 1
    fi
    local sarea sslk
    sarea=$(grep -m1 "Total cell area" $syn_dir/area.rpt 2>/dev/null | awk '{print $NF}')
    sslk=$(grep -m1 "slack" $syn_dir/timing.rpt 2>/dev/null | awk '{print $NF}')
    echo "$n,synth,$synrun,$sarea,$sslk,,,,OK" >> "$CSV"
    echo "[N=$n] synth area=$sarea slack=$sslk" | tee -a "$log"
    [ "$STOP_AFTER" = synth ] && return 0

    # ------------------------------------------------------- APR pass 1 ------
    if [ ! -f "apr/build/$TARGET/$apr1/outputs/$TOP.apr.v" ]; then
        echo "[N=$n] APR pass 1 (distribution guides, bootstrap)" | tee -a "$log"
        SC_DISTRIBUTION_GUIDES=1 SC_NH=$n SC_NW=$n \
        SYNTH_RUN=$synrun RUN_NAME=$apr1 \
            make apr TARGET=$TARGET >> "$log" 2>&1
    fi
    [ -f "apr/build/$TARGET/$apr1/outputs/$TOP.apr.v" ] || {
        echo "$n,apr1,$apr1,,,,,,APR1_FAIL" >> "$CSV"; return 1; }

    echo "[N=$n] pass-1 gate sim -> bootstrap activity" | tee -a "$log"
    # Per-N build dir: the default build/$TB is shared and would collide when
    # two N values run concurrently.
    local bdir1=$OUT/k${K}m${M}n${n}_gl_boot
    make sim GL=apr TARGET=$TARGET RUN=$apr1 TB=$TB BUILD_DIR=$bdir1 \
         VCS_ARGS="$defs" >> "$log" 2>&1
    local boot_saif="apr/build/$TARGET/$apr1/activity/dut.saif"
    mkdir -p "apr/build/$TARGET/$apr1/activity"
    cp -f "$(readlink -f $bdir1/$TB/dut.saif)" "$boot_saif" 2>/dev/null
    [ -s "$boot_saif" ] || { echo "$n,apr1,$apr1,,,,,,NO_BOOT_SAIF" >> "$CSV"; return 1; }

    # ------------------------------------------------------- APR pass 2 ------
    echo "[N=$n] APR pass 2 (spp_fixed workload power opt)" | tee -a "$log"
    APR_WORKLOAD_POWER_OPT=1 \
    APR_ACTIVITY_FILE="$(readlink -f "$boot_saif")" APR_ACTIVITY_SCOPE=Top/dut \
    APR_LEAKAGE_TO_DYNAMIC_RATIO=0.0 APR_DETAIL_WIRE_LENGTH_OPT_EFFORT=high \
    SC_DISTRIBUTION_GUIDES=1 SC_NH=$n SC_NW=$n \
    SYNTH_RUN=$synrun RUN_NAME=$apr2 \
        make apr TARGET=$TARGET >> "$log" 2>&1
    local A2=apr/build/$TARGET/$apr2
    [ -f "$A2/outputs/$TOP.apr.v" ] || {
        echo "$n,apr2,$apr2,,,,,,APR2_FAIL" >> "$CSV"; return 1; }
    grep -q "Enabling workload-aware dynamic-power optimization" $A2/apr.log || {
        echo "$n,apr2,$apr2,,,,,,SPP_NOT_APPLIED" >> "$CSV"; return 1; }

    local wns hold area
    wns=$(sed -n 's/.*Slack Time *//p' $A2/reports/setup.rpt | head -1)
    hold=$(sed -n 's/.*Slack Time *//p' $A2/reports/hold.rpt | head -1)
    # Top row has a blank Module Name, so columns shift left by one:
    # $1=Hinst $2=InstCount $3=TotalArea.  NR==3/$4 would report Buffer area.
    area=$(awk -v t="$TOP" '$1==t{print $3; exit}' $A2/reports/area.rpt 2>/dev/null)
    echo "[N=$n] pass 2 setup=$wns hold=$hold area=$area" | tee -a "$log"

    # ------------------------------------------------------------- power -----
    echo "[N=$n] max-SDF gate sim + cosim + PT-PX" | tee -a "$log"
    local bdir2=$OUT/k${K}m${M}n${n}_gl_final
    # Dedicated log: $log already contains pass-1's "PASS:", so grepping it
    # would pass a failed pass-2 sim.
    local glog=$OUT/k${K}m${M}n${n}_glsim2.log
    make sim GL=apr TARGET=$TARGET RUN=$apr2 TB=$TB BUILD_DIR=$bdir2 \
         VCS_ARGS="$defs" > "$glog" 2>&1
    cat "$glog" >> "$log"
    grep -q "PASS:" "$glog" || { echo "$n,power,$apr2,$area,$wns,$hold,,,GLSIM_FAIL" >> "$CSV"; return 1; }
    local trace=$bdir2/$TB/array_streaming_rtl.txt
    if [ -f "$trace" ]; then
        python3 designs/payn/cosim/cosim_streaming.py "$trace" >> "$log" 2>&1 || {
            echo "$n,power,$apr2,$area,$wns,$hold,,,COSIM_FAIL" >> "$CSV"; return 1; }
    fi
    local plog=$OUT/k${K}m${M}n${n}_power.log
    POWER_SAIF_VALIDATOR=sweeps/validate_sc_power_saif.py \
        make power_apr TARGET=$TARGET RUN=$apr2 \
             SAIF="$(readlink -f $bdir2/$TB/dut.saif)" SAIF_STRIP_PATH=Top/dut > "$plog" 2>&1
    cat "$plog" >> "$log"
    grep -qE "invalid (binary|SC) SAIF" "$plog" && {
        echo "$n,power,$apr2,$area,$wns,$hold,,,SAIF_INVALID" >> "$CSV"; return 1; }

    local pw pj
    pw=$(grep -m1 "Total Power" $A2/reports/power.rpt | grep -oE "[0-9]+\.[0-9]+e[-+][0-9]+" | head -1)
    pj=$(python3 -c "print(f'{float('$pw')*1000.0*$PERIOD/$mac_per_cycle:.6f}')")
    pw=$(python3 -c "print(f'{float('$pw')*1000.0:.5f}')")
    echo "$n,power,$apr2,$area,$wns,$hold,$pw,$pj,OK" >> "$CSV"
    echo "[N=$n] RESULT power=$pw mW  pJ/MAC=$pj  (N=8 control 18.17200 / 0.70984)" | tee -a "$log"
}

for n in "${N_VALUES[@]}"; do run_n "$n"; done
echo "=== $CSV ==="
cat "$CSV"
