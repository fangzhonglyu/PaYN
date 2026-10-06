#!/bin/bash
# Functional gate-level comparison of the isolated popcount synthesis arms.
#
#   bash sweeps/check_popcount_syn.sh control inferred techmap
#   CHECK_TAG=syn_functional_r2 bash sweeps/check_popcount_syn.sh techmap
#
# Prerequisite: the matching RTL arm has already passed its independent RTL
# preflight. RTL_PREFLIGHT_CMD=true below suppresses that already-completed
# work; this script checks the newly synthesized vendor-cell netlist instead.
#
# The existing streaming bench runs 64 back-to-back T=128 batches, then drains
# all 64 outputs. run_power_array.sh invokes cosim_streaming.py to recompute
# that workload independently. NO_SDF, unit delays, disabled timing checks,
# and the ARM startup-X hooks make this a FUNCTIONAL check only. Its generated
# SAIF is retained as an artifact, not an accepted timing or power result.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
CAMPAIGN=${CAMPAIGN:-pc16_20260930}
CHECK_TAG=${CHECK_TAG:-syn_functional}
OUT=${OUT:-build/power_char/popcount_synth_${CAMPAIGN#pc16_}}
for value in "$CAMPAIGN" "$CHECK_TAG"; do
    [[ "$value" =~ ^[A-Za-z0-9_]+$ ]] || {
        echo "CAMPAIGN and CHECK_TAG must contain only letters, digits, and underscores" >&2
        exit 2
    }
done
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

source /etc/profile.d/modules.sh 2>/dev/null || \
    source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export SYNOPSYS=${SYNOPSYS:-/usr/caen/synopsys-synth-2021.06-SP1}
export USE_DW=1 NTFY_CHNL=
export TSMC22_CELL_TIER=sc7mcpp140z TSMC22_LIB_FLAVORS=svt_c30
export TSMC22_HPK_FLAVORS=svt_c30 TSMC22_HPK=1

check_arm() (
    local arm=$1 target top run_name netlist bdir log trace args header
    case "$arm" in
        control)
            target=TSMC22/PAYN_SC_SIGNED_SEGMENTED_CLEAN
            top=payn_array_signed_segmented_clean;;
        inferred)
            target=TSMC22/PAYN_SC_POPCOUNT_INFERRED
            top=payn_array_signed_segmented_popcount;;
        techmap)
            target=TSMC22/PAYN_SC_POPCOUNT_TECHMAP
            top=payn_array_signed_segmented_popcount;;
    esac
    run_name=${CAMPAIGN}_${arm}
    netlist=syn/build/$target/$run_name/$top.syn.v
    bdir=$OUT/${arm}_${CHECK_TAG}
    log=$OUT/${arm}_${CHECK_TAG}.log
    trace=$bdir/designs/payn/power/power_payn_array.sv/array_streaming_rtl.txt
    mkdir -p "$OUT"
    exec 9>"$OUT/${run_name}_${CHECK_TAG}.lock"
    flock -n 9 || { echo "[$arm] Another worker owns this check" >&2; exit 2; }
    [[ -s "$netlist" ]] || { echo "[$arm] Netlist missing: $netlist" >&2; exit 2; }
    [[ ! -e "$bdir" && ! -e "$log" ]] || {
        echo "[$arm] Refusing existing $bdir or $log; choose a fresh CHECK_TAG" >&2
        exit 2
    }
    mkdir "$bdir"
    {
        printf 'Arm: %s\nTarget: %s\nRun: %s\nNetlist: %s\n' "$arm" "$target" "$run_name" "$netlist"
        printf 'Check: functional only; NO_SDF=1; unit delay; timing checks disabled\n'
        printf 'Workload: K8 M16 NH8 NW8 WIDTH8 OWIDTH24 LOW_W9 T128 BATCHES64\n'
        printf 'Prerequisite: this arm has already passed RTL preflight\n'
        printf 'Models: TSMC22 A7 base SVT C30 and HPK SVT C30\n'
    } > "$bdir/check_manifest.txt"

    args="+define+PAYN_ARRAY_DUT=$top+define+PAYN_SEG_LOW_W=9+define+SC_K=8+define+SC_M=16+define+SC_NH=8+define+SC_NW=8+define+SC_WIDTH=8+define+SC_MAG_WIDTH=7+define+SC_OWIDTH=24+define+SC_T=128+define+SC_BATCHES=64+define+ARM_UD_MODEL+define+ARM_EN_X_SQUASH +delay_mode_unit +notimingcheck"
    echo "[$arm] post-synthesis functional check; log=$log"
    # ASTRAEA selects both base and HPK models from the target/environment.
    # Passing the preflight override on the make command line ensures target
    # defaults cannot recursively run the completed RTL check. The explicit
    # VCS command removes only -debug_access+all: optional CFS debug extraction
    # stalls on this host, and debug databases are unnecessary for this check.
    if BUILD_DIR="$bdir" bash designs/payn/cosim/run_power_array.sh \
        GL=syn TARGET="$target" RUN="$run_name" NO_SDF=1 \
        RTL_PREFLIGHT_CMD=true NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" \
        VCS_ARGS="$args" \
        'VCS=vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext' \
        > "$log" 2>&1; then
        :
    else
        echo FAIL > "$bdir/check.status"
        echo "[$arm] simulation or independent streaming cosim failed; see $log" >&2
        exit 1
    fi

    # Simulator fatal diagnostics are checked even if a tool exits with zero.
    if rg -n '(^[[:space:]]*(Error|ERROR|Fatal|FATAL)(:|-\[)|\[FAIL\]|\[X-FAIL\]|TIMEOUT @|^Traceback \(most recent call last\):)' "$log"; then
        echo FAIL > "$bdir/check.status"
        echo "[$arm] error/fatal diagnostic found in $log" >&2
        exit 1
    fi
    if ! rg -q '^PASS: streaming SC SAIF captured; 64 batches x 8 cycles,' "$log" || \
       ! rg -q '^\[PASS\] streaming PaYN drain matches cycle reference \(K=8 M=16 N=8x8 T=128 batches=64\)$' "$log"; then
        echo FAIL > "$bdir/check.status"
        echo "[$arm] missing simulator or independent checker success marker" >&2
        exit 1
    fi
    [[ -s "$trace" ]] || { echo FAIL > "$bdir/check.status"; exit 1; }
    IFS= read -r header < "$trace"
    [[ "$header" == 'STREAMCFG 8 16 8 8 8 24 128 64 0' ]] || {
        echo FAIL > "$bdir/check.status"
        echo "[$arm] unexpected workload trace header: $header" >&2
        exit 1
    }
    echo PASS > "$bdir/check.status"
    echo "[$arm] PASS: 64 outputs match independent reference after 64 batches (functional only)"
)

PIDS=()
for arm in "${ARMS[@]}"; do
    check_arm "$arm" &
    PIDS+=("$!")
done
status=0
for i in "${!PIDS[@]}"; do
    if wait "${PIDS[$i]}"; then
        :
    else
        echo "[${ARMS[$i]}] functional check failed" >&2
        status=1
    fi
done
exit "$status"
