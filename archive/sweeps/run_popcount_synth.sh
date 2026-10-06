#!/bin/bash
# Isolated, concurrent synthesis comparison, K8/M16/NH8/NW8, WIDTH8/OWIDTH24,
# LOW_W9, 2.5 ns clock, 1.25 ns input delay, A7 SVT C30 + HPK, CG + multibit.
#
#   bash sweeps/run_popcount_synth.sh control inferred techmap
#   bash sweeps/run_popcount_synth.sh inferred techmap
#   CAMPAIGN=pc16_20260930_r2 bash sweeps/run_popcount_synth.sh
#   SKIP_PREFLIGHT=1 bash sweeps/run_popcount_synth.sh inferred techmap
#
# Each arm runs a bit-exact RTL array preflight before synthesis. Existing run
# directories are never reused or overwritten. Synthesis power reports use
# generic input activity; they are not routed workload energy measurements.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
CAMPAIGN=${CAMPAIGN:-pc16_20260930}
OUT=${OUT:-build/power_char/popcount_synth_${CAMPAIGN#pc16_}}
SKIP_PREFLIGHT=${SKIP_PREFLIGHT:-0}
[[ "$SKIP_PREFLIGHT" == 0 || "$SKIP_PREFLIGHT" == 1 ]] || {
    echo "SKIP_PREFLIGHT must be 0 or 1" >&2; exit 2;
}
[[ "$CAMPAIGN" =~ ^[A-Za-z0-9_]+$ ]] || {
    echo "CAMPAIGN must contain only letters, digits, and underscores" >&2; exit 2;
}
[[ -f "$ASTRAEA_FLOW/Makefile" ]] || {
    echo "ASTRAEA flow missing: $ASTRAEA_FLOW" >&2; exit 2;
}

ARMS=("$@")
((${#ARMS[@]})) || ARMS=(control inferred techmap)
declare -A SEEN=()
for arm in "${ARMS[@]}"; do
    case "$arm" in control|inferred|techmap) ;; *)
        echo "Unknown arm: $arm (choose control, inferred, techmap)" >&2; exit 2;;
    esac
    [[ ! -v SEEN[$arm] ]] || { echo "Repeated arm: $arm" >&2; exit 2; }
    SEEN[$arm]=1
done

# Exact module versions are required for every EDA flow in this repository.
source /etc/profile.d/modules.sh 2>/dev/null || \
    source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export SYNOPSYS=${SYNOPSYS:-/usr/caen/synopsys-synth-2021.06-SP1}
export USE_DW=1
export NTFY_CHNL=

run_arm() (
    local arm=$1 target top src extra="" run_name log syn_dir
    case "$arm" in
        control)
            target=TSMC22/PAYN_SC_SIGNED_SEGMENTED_CLEAN
            top=payn_array_signed_segmented_clean
            src=designs/payn/variants/signed_segmented_clean/payn_array_signed_segmented_clean.sv;;
        inferred|techmap)
            target=TSMC22/PAYN_SC_POPCOUNT_${arm^^}
            top=payn_array_signed_segmented_popcount
            src=designs/payn/variants/signed_segmented_popcount/payn_array_signed_segmented_popcount.sv
            [[ "$arm" != techmap ]] || extra=+define+PAYN_POPCOUNT_TECHMAP;;
    esac
    run_name=${CAMPAIGN}_${arm}
    syn_dir=syn/build/$target/$run_name
    log=$OUT/$arm.log
    mkdir -p "$OUT"
    # Lock also guards two concurrent driver invocations with the same arm.
    exec 9>"$OUT/${run_name}.lock"
    flock -n 9 || { echo "[$arm] Another worker owns $run_name" >&2; exit 2; }
    [[ ! -e "$syn_dir" && ! -e "$log" ]] || {
        echo "[$arm] Refusing existing $syn_dir or $log; choose a fresh CAMPAIGN and OUT" >&2
        exit 2
    }
    [[ -f "$src" ]] || { echo "[$arm] Source missing: $src" >&2; exit 2; }

    # Do not inherit optional optimization experiments from the launch shell.
    unset POST_LOAD_SCRIPT RTL_PREFLIGHT_CMD SYN_SAIF_FILE SYN_SAIF_INSTANCE
    unset MULTICYCLE_INPUT_PORTS MULTICYCLE_INPUT_CYCLES CLOCK_GATE_MAX_FANOUT
    export MINPOWER=0 FLATTEN=0 SYN_AREA_HIGH_EFFORT=0 MAX_FANOUT=16
    export INPUT_DELAY=1.25 OUTPUT_DELAY=0.05 PERIOD=2.5
    export TSMC22_CELL_TIER=sc7mcpp140z TSMC22_LIB_FLAVORS=svt_c30
    export TSMC22_HPK_FLAVORS=svt_c30 TSMC22_HPK=1 MULTIBIT_INFER=1 CLOCK_GATE=1
    export SYN_DEFINES="PAYN_K=8 PAYN_M=16 PAYN_NH=8 PAYN_NW=8 PAYN_SEG_LOW_W=9"
    export PAYN_POPCOUNT_EXPECTED_LANES=512
    export RUN_NAME=$run_name
    export RTL_PREFLIGHT_CMD="BUILD_DIR=build/rtl_preflight/$run_name SIM_SRCS=$src VCS_ARGS=+define+PAYN_ARRAY_EXTERNAL_RTL+define+PAYN_ARRAY_DUT=$top$extra+define+PAYN_SEG_LOW_W=9+define+SC_K=8+define+SC_M=16+define+SC_NH=8+define+SC_NW=8+define+SC_OWIDTH=24+define+SC_T=128 bash designs/payn/cosim/run_array.sh"

    echo "[$arm] preflight then synthesis; log=$log"
    {
        printf 'Arm: %s\nTarget: %s\nRun: %s\nFlow: %s\n' "$arm" "$target" "$run_name" "$ASTRAEA_FLOW"
        printf 'Settings: K8 M16 NH8 NW8 WIDTH8 OWIDTH24 LOW_W9 PERIOD2.5 INPUT_DELAY1.25 OUTPUT_DELAY0.05 HPK1 MULTIBIT1 CLOCK_GATE1\n'
        if [[ "$SKIP_PREFLIGHT" == 0 ]]; then
            # Keep functional/xprop/assertion flags, but omit the optional
            # debug database extraction that stalls in cfs_ident_exec here.
            bash -c "$RTL_PREFLIGHT_CMD \"\$@\"" -- \
                'VCS=vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
        else
            echo "RTL preflight skipped by caller (must already have passed for these sources/settings)"
        fi
        make synth TARGET="$target" NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW"
        [[ -s "$syn_dir/$top.syn.v" && -s "$syn_dir/area.rpt" && -s "$syn_dir/timing.rpt" ]]
        awk '/Total cell area/ {print; exit}' "$syn_dir/area.rpt"
        awk '/slack/ {print; exit}' "$syn_dir/timing.rpt"
        awk '/set_input_delay/ {print; exit}' "$syn_dir/$top.syn.sdc"
    } >"$log" 2>&1
    echo "[$arm] complete: $syn_dir"
)

PIDS=()
for arm in "${ARMS[@]}"; do
    run_arm "$arm" &
    PIDS+=("$!")
done
status=0
for i in "${!PIDS[@]}"; do
    if wait "${PIDS[$i]}"; then
        :
    else
        echo "[${ARMS[$i]}] failed; see $OUT/${ARMS[$i]}.log" >&2
        status=1
    fi
done
exit "$status"
