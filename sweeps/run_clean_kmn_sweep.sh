#!/bin/bash
# K x M x N sweep on the CLEANED segmented RTL with the corrected input delay.
#
#   RTL        designs/payn/variants/signed_segmented_clean  (shared HIGH_W adder)
#   constraint INPUT_DELAY=1.25  -- matches the bench's negedge launch instead of
#              the flow default 0.05, which lets STA sign off ~2.45 ns of
#              propagation on a signal that really has 1.25 ns
#   grid       K in {4,8,12} x M in {8,16} x N in {6,8,10}
#   fixed      LOW_W=9, T=128, OWIDTH=24, PERIOD=2.5, 3072 productive cycles
#
# LOW_W=9 is valid across the whole grid: 2**9 = 512 >= max(K*M) = 192.
# T/M and K*M*N^2/T are integers for every config (checked before launch).
#
# SYN_SAIF_FILE is deliberately NOT used: on this RTL it produced a netlist
# byte-identical to the non-annotated one apart from the date comment, because
# ASTRAEA compiles with `compile_ultra -gate_clock -no_autoungroup` and no power
# objective, so activity steers nothing structural.  Paying for it would buy a
# duplicate run.
#
# Each config: synth -> APR distguide (bootstrap) -> gate sim -> APR spp_fixed
# -> max-SDF gate sim -> streaming cosim -> PT-PX with the SC SAIF validator.
#
#   bash sweeps/run_clean_kmn_sweep.sh                  # all 18, sequential
#   bash sweeps/run_clean_kmn_sweep.sh k8m16n8 k4m8n6   # named configs only
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
LW=9; T=128; PERIOD=2.5; TOTAL_CYCLES=3072; IDLY=1.25
# Distribution guides spread N*N tiles across the die.  They need each row's
# a_bits_pipe/w_bits_pipe registers to be findable by a per-row name prefix, and
# at small K*M multibit banking merges rows 0+1, 2+3, ... into shared cells --
# the guide script then finds nothing for rows >= 1 and aborts.  For the tiny
# low-corner shapes the guides are meaningless anyway (there is nothing to
# spread), so run those with GUIDES=0.  Runs are named for which was used, so
# guided and unguided results never collide.
GUIDES=${GUIDES:-1}

OUT=build/power_char/clean_kmn
CSV=$OUT/results.csv
mkdir -p "$OUT"
[ -f "$CSV" ] || echo "config,K,M,N,syn_area_um2,syn_slack,apr_area_um2,setup_wns,hold_wns,power_mW,pJ_MAC,status" > "$CSV"

# Concurrent workers append here, so serialize the writes.
emit() { flock "$CSV.lock" -c "echo '$1' >> '$CSV'"; }

ALL_CONFIGS=()
for K in 4 8 12; do for M in 8 16; do for N in 6 8 10; do
    ALL_CONFIGS+=("k${K}m${M}n${N}")
done; done; done

run_cfg() {
    local cfg=$1
    local K M N
    K=$(sed -E 's/k([0-9]+)m([0-9]+)n([0-9]+)/\1/' <<<"$cfg")
    M=$(sed -E 's/k([0-9]+)m([0-9]+)n([0-9]+)/\2/' <<<"$cfg")
    N=$(sed -E 's/k([0-9]+)m([0-9]+)n([0-9]+)/\3/' <<<"$cfg")

    # Guard the two invariants the RTL and the pJ/MAC arithmetic depend on.
    if [ $((1 << LW)) -lt $((K * M)) ]; then
        echo "$cfg,$K,$M,$N,,,,,,,,LOW_W_TOO_SMALL"; emit "$cfg,$K,$M,$N,,,,,,,,LOW_W_TOO_SMALL"; return 1; fi
    if [ $((T % M)) -ne 0 ]; then
        emit "$cfg,$K,$M,$N,,,,,,,,T_NOT_DIVISIBLE_BY_M"; return 1; fi

    local MAC_CYCLES=$((T / M))
    local N_BATCHES=$((TOTAL_CYCLES / MAC_CYCLES))
    [ "$N_BATCHES" -ge 1 ] || { emit "$cfg,$K,$M,$N,,,,,,,,NO_BATCHES"; return 1; }
    # A rate, not a count.  Degenerate shapes retire less than one MAC per clock
    # (K=M=N=1 is 1/128), so this must stay fractional -- bash integer division
    # would floor it to 0 and the pJ/MAC divide would blow up.
    local MAC_PER_CYCLE
    MAC_PER_CYCLE=$(python3 -c "print($K*$M*$N*$N/$T)")

    local log=$OUT/$cfg.log
    local synrun=${cfg}_lw${LW}_id125
    local gtag; if [ "$GUIDES" = 1 ]; then gtag=distguide; else gtag=noguide; fi
    local apr1=${synrun}_${gtag}
    local apr2=${synrun}_${gtag}_spp_fixed
    local syn_dir=syn/build/$TARGET/$synrun
    local defs="+define+PAYN_ARRAY_DUT=$TOP+define+SC_K=$K+define+SC_M=$M+define+SC_NH=$N+define+SC_NW=$N+define+SC_OWIDTH=24+define+SC_T=$T+define+SC_BATCHES=$N_BATCHES"
    # Gate-sim X hygiene -- root causes and evidence in
    # doc/handoff_low_corner_gl_x.md (resolved 2026-07-31):
    #  * ARM_UD_MODEL + ARM_EN_X_SQUASH: the ARM cells model flops as
    #    sequential UDPs, which +vcs+initreg cannot initialize, so every
    #    register powers up X.  At K*M <= 4 synthesis maps the acc_low sync
    #    reset through an (n & ~n) cancellation that 4-state logic cannot
    #    resolve, and the Q->D feedback locks the X in permanently.  The
    #    squash define replaces X on a sequential UDP output with 0 at the
    #    library's own hook.  Steady-state activity is untouched, so SAIF
    #    from earlier runs without the define stays comparable.
    #  * +neg_tchk: honor negative SETUPHOLD/RECREM limits from the SDF.
    #    Without it VCS zeroes them ("Negative SETUPHOLD value replaced by
    #    0") and manufactures false ICG enable setup violations whose
    #    notifiers X the gated clock (k4m1n1: E at CK-9ps against a true
    #    window ending at CK-17ps).  STA uses the negative values and
    #    passes these paths.
    local glargs="$defs+define+ARM_UD_MODEL+define+ARM_EN_X_SQUASH +neg_tchk"

    echo "[$cfg] K=$K M=$M N=$N MAC/cycle=$MAC_PER_CYCLE batches=$N_BATCHES" | tee -a "$log"

    #---------------------------------------------------------------- synth ---
    if [ ! -f "$syn_dir/$TOP.syn.v" ]; then
        echo "[$cfg] synth (INPUT_DELAY=$IDLY)" | tee -a "$log"
        env INPUT_DELAY="$IDLY" \
            SYN_DEFINES="PAYN_K=$K PAYN_M=$M PAYN_NH=$N PAYN_NW=$N PAYN_SEG_LOW_W=$LW" \
            RTL_PREFLIGHT_CMD="BUILD_DIR=build/rtl_preflight/clean_$cfg SIM_SRCS=$SRC VCS_ARGS=+define+PAYN_ARRAY_EXTERNAL_RTL+define+PAYN_ARRAY_DUT=$TOP+define+PAYN_SEG_LOW_W=$LW+define+SC_K=$K+define+SC_M=$M+define+SC_NH=$N+define+SC_NW=$N+define+SC_OWIDTH=24+define+SC_T=$T bash designs/payn/cosim/run_array.sh" \
            RUN_NAME=$synrun make synth TARGET=$TARGET >> "$log" 2>&1
    else
        echo "[$cfg] reuse existing synthesis" | tee -a "$log"
    fi
    [ -f "$syn_dir/$TOP.syn.v" ] || { emit "$cfg,$K,$M,$N,,,,,,,,SYNTH_FAIL"; return 1; }

    # Verify the constraint landed rather than trusting the environment.
    local sdc_idly
    sdc_idly=$(grep -m1 "set_input_delay" "$syn_dir/$TOP.syn.sdc" | awk '{print $4}')
    if [ "$sdc_idly" != "$IDLY" ]; then
        echo "[$cfg] SDC input delay is $sdc_idly, expected $IDLY" | tee -a "$log"
        emit "$cfg,$K,$M,$N,,,,,,,,INPUT_DELAY_NOT_APPLIED"; return 1
    fi
    local sarea sslack
    sarea=$(grep -m1 "Total cell area" $syn_dir/area.rpt | awk '{print $NF}')
    sslack=$(grep -m1 "slack" $syn_dir/timing.rpt | awk '{print $NF}')
    echo "[$cfg] synth area=$sarea slack=$sslack idly=$sdc_idly" | tee -a "$log"

    #----------------------------------------------------------- APR pass 1 ---
    if [ ! -f "apr/build/$TARGET/$apr1/outputs/$TOP.apr.v" ]; then
        echo "[$cfg] APR pass 1 (distribution guides, bootstrap)" | tee -a "$log"
        SC_DISTRIBUTION_GUIDES=$GUIDES SC_NH=$N SC_NW=$N \
        SYNTH_RUN=$synrun RUN_NAME=$apr1 make apr TARGET=$TARGET >> "$log" 2>&1
    fi
    [ -f "apr/build/$TARGET/$apr1/outputs/$TOP.apr.v" ] || {
        emit "$cfg,$K,$M,$N,$sarea,$sslack,,,,,,APR1_FAIL"; return 1; }

    echo "[$cfg] pass-1 gate sim -> bootstrap activity" | tee -a "$log"
    local bdir1=$OUT/${cfg}_gl_boot
    make sim GL=apr TARGET=$TARGET RUN=$apr1 TB=$TB BUILD_DIR=$bdir1 \
         VCS_ARGS="$glargs" >> "$log" 2>&1
    local boot_saif="apr/build/$TARGET/$apr1/activity/dut.saif"
    mkdir -p "apr/build/$TARGET/$apr1/activity"
    cp -f "$(readlink -f $bdir1/$TB/dut.saif)" "$boot_saif" 2>/dev/null
    [ -s "$boot_saif" ] || { emit "$cfg,$K,$M,$N,$sarea,$sslack,,,,,,NO_BOOT_SAIF"; return 1; }

    #----------------------------------------------------------- APR pass 2 ---
    echo "[$cfg] APR pass 2 (spp_fixed workload power opt)" | tee -a "$log"
    APR_WORKLOAD_POWER_OPT=1 \
    APR_ACTIVITY_FILE="$(readlink -f "$boot_saif")" APR_ACTIVITY_SCOPE=Top/dut \
    APR_LEAKAGE_TO_DYNAMIC_RATIO=0.0 APR_DETAIL_WIRE_LENGTH_OPT_EFFORT=high \
    SC_DISTRIBUTION_GUIDES=$GUIDES SC_NH=$N SC_NW=$N \
    SYNTH_RUN=$synrun RUN_NAME=$apr2 make apr TARGET=$TARGET >> "$log" 2>&1
    local A2=apr/build/$TARGET/$apr2
    [ -f "$A2/outputs/$TOP.apr.v" ] || {
        emit "$cfg,$K,$M,$N,$sarea,$sslack,,,,,,APR2_FAIL"; return 1; }
    grep -q "Enabling workload-aware dynamic-power optimization" $A2/apr.log || {
        emit "$cfg,$K,$M,$N,$sarea,$sslack,,,,,,SPP_NOT_APPLIED"; return 1; }

    local wns hold aarea
    wns=$(sed -n 's/.*Slack Time *//p' $A2/reports/setup.rpt | head -1)
    hold=$(sed -n 's/.*Slack Time *//p' $A2/reports/hold.rpt | head -1)
    # Top row has a blank Module Name, so columns shift left by one:
    # $1=Hinst $2=InstCount $3=TotalArea.
    aarea=$(awk -v t="$TOP" '$1==t{print $3; exit}' $A2/reports/area.rpt 2>/dev/null)
    echo "[$cfg] pass 2 setup=$wns hold=$hold area=$aarea" | tee -a "$log"

    #---------------------------------------------------------------- power ---
    echo "[$cfg] max-SDF gate sim + cosim + PT-PX" | tee -a "$log"
    local bdir2=$OUT/${cfg}_gl_final
    # Dedicated log: $log already holds pass-1's "PASS:", so grepping it would
    # let a failed pass-2 sim through.
    local glog=$OUT/${cfg}_glsim2.log
    make sim GL=apr TARGET=$TARGET RUN=$apr2 TB=$TB BUILD_DIR=$bdir2 \
         VCS_ARGS="$glargs" > "$glog" 2>&1
    cat "$glog" >> "$log"
    grep -q "PASS:" "$glog" || {
        emit "$cfg,$K,$M,$N,$sarea,$sslack,$aarea,$wns,$hold,,,GLSIM_FAIL"; return 1; }
    local trace=$bdir2/$TB/array_streaming_rtl.txt
    if [ -f "$trace" ]; then
        python3 designs/payn/cosim/cosim_streaming.py "$trace" >> "$log" 2>&1 || {
            emit "$cfg,$K,$M,$N,$sarea,$sslack,$aarea,$wns,$hold,,,COSIM_FAIL"; return 1; }
    fi
    local plog=$OUT/${cfg}_power.log
    POWER_SAIF_VALIDATOR=sweeps/validate_sc_power_saif.py \
        make power_apr TARGET=$TARGET RUN=$apr2 \
             SAIF="$(readlink -f $bdir2/$TB/dut.saif)" SAIF_STRIP_PATH=Top/dut > "$plog" 2>&1
    cat "$plog" >> "$log"
    grep -qE "invalid (binary|SC) SAIF" "$plog" && {
        emit "$cfg,$K,$M,$N,$sarea,$sslack,$aarea,$wns,$hold,,,SAIF_INVALID"; return 1; }

    local pw pj
    pw=$(grep -m1 "Total Power" $A2/reports/power.rpt | grep -oE "[0-9]+\.[0-9]+e[-+][0-9]+" | head -1)
    pj=$(python3 -c "print(f'{float('$pw')*1000.0*$PERIOD/$MAC_PER_CYCLE:.6f}')")
    pw=$(python3 -c "print(f'{float('$pw')*1000.0:.5f}')")
    emit "$cfg,$K,$M,$N,$sarea,$sslack,$aarea,$wns,$hold,$pw,$pj,OK"
    echo "[$cfg] RESULT power=$pw mW  pJ/MAC=$pj" | tee -a "$log"
}

CONFIGS=("$@")
[ ${#CONFIGS[@]} -gt 0 ] || CONFIGS=("${ALL_CONFIGS[@]}")
for c in "${CONFIGS[@]}"; do run_cfg "$c"; done
echo "=== $CSV ==="
cat "$CSV"
