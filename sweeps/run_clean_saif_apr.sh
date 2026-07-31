#!/bin/bash
# Activity-annotated synthesis + generous input delays for the cleaned
# pending-bit PaYN variant, carried through the accepted spp_fixed APR recipe to
# a measured pJ/MAC.
#
# Three arms, all K8/M16/N8/LOW_W9/T=128, so the two knobs are separable:
#
#   base      INPUT_DELAY=0.05 (flow default), no SAIF   <- matches the accepted
#                                                           0.70984 recipe, so it
#                                                           isolates the RTL change
#   id125     INPUT_DELAY=1.25, no SAIF                  <- isolates the constraint
#   id125saif INPUT_DELAY=1.25 + SYN_SAIF_FILE           <- the combined point
#
# Why INPUT_DELAY=1.25: the bench launches every control at the NEGEDGE, i.e.
# half a period before the capturing edge.  The flow default declares 0.05, so
# STA verifies ~2.45 ns of propagation for a signal that really has 1.25 ns.
# APR is free to spend the difference, and on wide arrays shift_in/mac_en then
# reach a far tile's ICG enable inside its setup window -- the notifier drives
# ENCLK to X and corrupts the accumulator.  Declaring 1.25 makes the constraint
# match the bench.
#
# Note: SYN_SAIF_FILE regressed on the ORIGINAL variant at N=8 (0.72331 against
# spp_fixed's 0.70984, +1.9%).  This re-tests it on the cleaned RTL alongside
# the corrected input delay.
#
#   bash sweeps/run_clean_saif_apr.sh                 # all three arms
#   bash sweeps/run_clean_saif_apr.sh id125saif       # one arm
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

TARGET=TSMC22/PAYN_SC_SIGNED_SEGMENTED_CLEAN
TOP=payn_array_signed_segmented_clean
SRC=designs/payn/variants/signed_segmented_clean/payn_array_signed_segmented_clean.sv
TB=designs/payn/power/power_payn_array.sv
K=8; M=16; N=8; T=128; LW=9
if [ $((1 << LW)) -lt $((K * M)) ]; then
    echo "ERROR: LOW_W=$LW gives 2^$LW=$((1<<LW)) < K*M=$((K*M))" >&2; exit 2
fi
TOTAL_CYCLES=3072
PERIOD=2.5
MAC_CYCLES=$((T / M))
N_BATCHES=$((TOTAL_CYCLES / MAC_CYCLES))
MAC_PER_CYCLE=$((K * M * N * N / T))

OUT=build/power_char/clean_saif_apr
CSV=$OUT/results.csv
mkdir -p "$OUT"
[ -f "$CSV" ] || echo "arm,input_delay,syn_saif,area_um2,setup_wns,hold_wns,power_mW,pJ_MAC,status" > "$CSV"

DEFS="+define+PAYN_ARRAY_DUT=$TOP+define+SC_K=$K+define+SC_M=$M+define+SC_NH=$N+define+SC_NW=$N+define+SC_OWIDTH=24+define+SC_T=$T+define+SC_BATCHES=$N_BATCHES"
SYNDEF="PAYN_K=$K PAYN_M=$M PAYN_NH=$N PAYN_NW=$N PAYN_SEG_LOW_W=$LW"

#--------------------------------------------------------------- RTL SAIF ------
# One RTL run of the SAME bench that later produces the gate SAIF, so the
# activity driving synthesis and the activity driving the measurement match.
rtl_saif() {
    local bdir=$OUT/rtl_saif
    local saif=$bdir/$TB/dut.saif
    if [ -s "$saif" ]; then
        echo "[rtl_saif] reuse $saif"; return 0
    fi
    echo "[rtl_saif] RTL power-bench run -> $saif"
    make sim TOP=Top TB="$TB" USE_DW=1 BUILD_DIR="$bdir" \
         GL= TARGET= RTL_PREFLIGHT_CMD= SIM_SRCS="$SRC" \
         VCS_ARGS="+define+PAYN_ARRAY_EXTERNAL_RTL+define+PAYN_SEG_LOW_W=$LW$DEFS" \
         > "$OUT/rtl_saif.log" 2>&1
    # An empty/instance-less SAIF silently defeats workload-driven synthesis:
    # DC would then optimize against 0% activity.  synth.tcl also checks, but
    # fail here where the cause is visible.
    if [ ! -s "$saif" ] || ! grep -q "(INSTANCE " "$saif"; then
        echo "[rtl_saif] FAILED: no (INSTANCE) blocks in $saif" >&2
        tail -20 "$OUT/rtl_saif.log" >&2
        return 1
    fi
    echo "[rtl_saif] ok: $(grep -c '(INSTANCE ' "$saif") instance blocks"
}

#------------------------------------------------------------------- arm -------
run_arm() {                       # $1=tag  $2=INPUT_DELAY  $3=use_saif(0|1)
    local tag=$1 idly=$2 usesaif=$3
    local log=$OUT/$tag.log
    local synrun=k${K}m${M}n${N}_lw${LW}_$tag
    local apr1=${synrun}_distguide
    local apr2=${synrun}_distguide_spp_fixed
    local syn_dir=syn/build/$TARGET/$synrun

    echo "[$tag] INPUT_DELAY=$idly SYN_SAIF=$usesaif MAC/cycle=$MAC_PER_CYCLE batches=$N_BATCHES" | tee -a "$log"

    local saif_env=()
    if [ "$usesaif" = 1 ]; then
        rtl_saif >> "$log" 2>&1 || { echo "$tag,$idly,$usesaif,,,,,,RTL_SAIF_FAIL" >> "$CSV"; return 1; }
        saif_env=(SYN_SAIF_FILE="$(readlink -f $OUT/rtl_saif/$TB/dut.saif)"
                  SYN_SAIF_INSTANCE=Top/dut)
    fi

    #--------------------------------------------------------------- synth -----
    if [ -f "$syn_dir/$TOP.syn.v" ]; then
        echo "[$tag] reuse existing synthesis $synrun" | tee -a "$log"
    else
        echo "[$tag] synth -> $synrun" | tee -a "$log"
        env INPUT_DELAY="$idly" "${saif_env[@]}" \
            SYN_DEFINES="$SYNDEF" \
            RTL_PREFLIGHT_CMD="BUILD_DIR=build/rtl_preflight/clean_$tag SIM_SRCS=$SRC VCS_ARGS=+define+PAYN_ARRAY_EXTERNAL_RTL+define+PAYN_ARRAY_DUT=$TOP+define+PAYN_SEG_LOW_W=$LW+define+SC_K=$K+define+SC_M=$M+define+SC_NH=$N+define+SC_NW=$N+define+SC_OWIDTH=24+define+SC_T=$T bash designs/payn/cosim/run_array.sh" \
            RUN_NAME=$synrun make synth TARGET=$TARGET >> "$log" 2>&1
    fi
    [ -f "$syn_dir/$TOP.syn.v" ] || { echo "$tag,$idly,$usesaif,,,,,,SYNTH_FAIL" >> "$CSV"; return 1; }

    # Confirm the knobs actually took effect rather than trusting the env.
    local sdc_idly
    sdc_idly=$(grep -m1 "set_input_delay" $syn_dir/$TOP.syn.sdc | awk '{print $4}')
    echo "[$tag] SDC input delay = $sdc_idly (asked $idly)" | tee -a "$log"
    # DC's puts output goes to the run dir's synth.log, not to this arm log.
    if [ "$usesaif" = 1 ] && \
       ! grep -q "Workload-driven synthesis: ENABLED" "$syn_dir/synth.log"; then
        echo "$tag,$idly,$usesaif,,,,,,SAIF_SYN_NOT_APPLIED" >> "$CSV"; return 1
    fi
    [ "$usesaif" = 1 ] && \
        echo "[$tag] SAIF annotated: $(grep -c 'Annotated' $syn_dir/saif_coverage_rtl.rpt 2>/dev/null) coverage lines" | tee -a "$log"
    local sarea
    sarea=$(grep -m1 "Total cell area" $syn_dir/area.rpt | awk '{print $NF}')
    echo "[$tag] synth area=$sarea" | tee -a "$log"

    #---------------------------------------------------------- APR pass 1 -----
    if [ ! -f "apr/build/$TARGET/$apr1/outputs/$TOP.apr.v" ]; then
        echo "[$tag] APR pass 1 (distribution guides, bootstrap)" | tee -a "$log"
        SC_DISTRIBUTION_GUIDES=1 SC_NH=$N SC_NW=$N \
        SYNTH_RUN=$synrun RUN_NAME=$apr1 \
            make apr TARGET=$TARGET >> "$log" 2>&1
    fi
    [ -f "apr/build/$TARGET/$apr1/outputs/$TOP.apr.v" ] || {
        echo "$tag,$idly,$usesaif,,,,,,APR1_FAIL" >> "$CSV"; return 1; }

    echo "[$tag] pass-1 gate sim -> bootstrap activity" | tee -a "$log"
    local bdir1=$OUT/${tag}_gl_boot
    make sim GL=apr TARGET=$TARGET RUN=$apr1 TB=$TB BUILD_DIR=$bdir1 \
         VCS_ARGS="$DEFS" >> "$log" 2>&1
    local boot_saif="apr/build/$TARGET/$apr1/activity/dut.saif"
    mkdir -p "apr/build/$TARGET/$apr1/activity"
    cp -f "$(readlink -f $bdir1/$TB/dut.saif)" "$boot_saif" 2>/dev/null
    [ -s "$boot_saif" ] || { echo "$tag,$idly,$usesaif,,,,,,NO_BOOT_SAIF" >> "$CSV"; return 1; }

    #---------------------------------------------------------- APR pass 2 -----
    echo "[$tag] APR pass 2 (spp_fixed workload power opt)" | tee -a "$log"
    APR_WORKLOAD_POWER_OPT=1 \
    APR_ACTIVITY_FILE="$(readlink -f "$boot_saif")" APR_ACTIVITY_SCOPE=Top/dut \
    APR_LEAKAGE_TO_DYNAMIC_RATIO=0.0 APR_DETAIL_WIRE_LENGTH_OPT_EFFORT=high \
    SC_DISTRIBUTION_GUIDES=1 SC_NH=$N SC_NW=$N \
    SYNTH_RUN=$synrun RUN_NAME=$apr2 \
        make apr TARGET=$TARGET >> "$log" 2>&1
    local A2=apr/build/$TARGET/$apr2
    [ -f "$A2/outputs/$TOP.apr.v" ] || {
        echo "$tag,$idly,$usesaif,,,,,,APR2_FAIL" >> "$CSV"; return 1; }
    grep -q "Enabling workload-aware dynamic-power optimization" $A2/apr.log || {
        echo "$tag,$idly,$usesaif,,,,,,SPP_NOT_APPLIED" >> "$CSV"; return 1; }

    local wns hold area
    wns=$(sed -n 's/.*Slack Time *//p' $A2/reports/setup.rpt | head -1)
    hold=$(sed -n 's/.*Slack Time *//p' $A2/reports/hold.rpt | head -1)
    # Top row has a blank Module Name, so columns shift left by one:
    # $1=Hinst $2=InstCount $3=TotalArea.
    area=$(awk -v t="$TOP" '$1==t{print $3; exit}' $A2/reports/area.rpt 2>/dev/null)
    echo "[$tag] pass 2 setup=$wns hold=$hold area=$area" | tee -a "$log"

    #-------------------------------------------------------------- power ------
    echo "[$tag] max-SDF gate sim + cosim + PT-PX" | tee -a "$log"
    local bdir2=$OUT/${tag}_gl_final
    # Dedicated log: $log already contains pass-1's "PASS:", so grepping it
    # would pass a failed pass-2 sim.
    local glog=$OUT/${tag}_glsim2.log
    make sim GL=apr TARGET=$TARGET RUN=$apr2 TB=$TB BUILD_DIR=$bdir2 \
         VCS_ARGS="$DEFS" > "$glog" 2>&1
    cat "$glog" >> "$log"
    grep -q "PASS:" "$glog" || { echo "$tag,$idly,$usesaif,$area,$wns,$hold,,,GLSIM_FAIL" >> "$CSV"; return 1; }
    local trace=$bdir2/$TB/array_streaming_rtl.txt
    if [ -f "$trace" ]; then
        python3 designs/payn/cosim/cosim_streaming.py "$trace" >> "$log" 2>&1 || {
            echo "$tag,$idly,$usesaif,$area,$wns,$hold,,,COSIM_FAIL" >> "$CSV"; return 1; }
    fi
    local plog=$OUT/${tag}_power.log
    POWER_SAIF_VALIDATOR=sweeps/validate_sc_power_saif.py \
        make power_apr TARGET=$TARGET RUN=$apr2 \
             SAIF="$(readlink -f $bdir2/$TB/dut.saif)" SAIF_STRIP_PATH=Top/dut > "$plog" 2>&1
    cat "$plog" >> "$log"
    grep -qE "invalid (binary|SC) SAIF" "$plog" && {
        echo "$tag,$idly,$usesaif,$area,$wns,$hold,,,SAIF_INVALID" >> "$CSV"; return 1; }

    local pw pj
    pw=$(grep -m1 "Total Power" $A2/reports/power.rpt | grep -oE "[0-9]+\.[0-9]+e[-+][0-9]+" | head -1)
    pj=$(python3 -c "print(f'{float('$pw')*1000.0*$PERIOD/$MAC_PER_CYCLE:.6f}')")
    pw=$(python3 -c "print(f'{float('$pw')*1000.0:.5f}')")
    echo "$tag,$idly,$usesaif,$area,$wns,$hold,$pw,$pj,OK" >> "$CSV"
    echo "[$tag] RESULT power=$pw mW  pJ/MAC=$pj  (accepted original control 18.17200 / 0.70984)" | tee -a "$log"
}

ARMS=("$@")
[ ${#ARMS[@]} -gt 0 ] || ARMS=(base id125 id125saif)
for a in "${ARMS[@]}"; do
    case $a in
        base)      run_arm base      0.05 0 ;;
        id125)     run_arm id125     1.25 0 ;;
        id125saif) run_arm id125saif 1.25 1 ;;
        *) echo "unknown arm: $a" >&2 ;;
    esac
done
echo "=== $CSV ==="
cat "$CSV"
