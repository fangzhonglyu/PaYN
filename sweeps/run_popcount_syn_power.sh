#!/bin/bash
# Compare the existing, identical-workload gate-level SAIFs in PrimeTime PX.
# These are pre-layout estimates: no routed wire capacitance or CTS.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"
CAMPAIGN=${CAMPAIGN:-pc16_20260930}
ACTIVITY=${ACTIVITY:-build/power_char/popcount_synth_${CAMPAIGN#pc16_}}
OUT=${OUT:-build/power_char/popcount_syn_power_${CAMPAIGN#pc16_}}
[[ "$ACTIVITY" == /* ]] || ACTIVITY="$REPO/$ACTIVITY"
[[ "$OUT" == /* ]] || OUT="$REPO/$OUT"
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export TSMC22_CELL_TIER=sc7mcpp140z TSMC22_LIB_FLAVORS=svt_c30
export TSMC22_HPK_FLAVORS=svt_c30 TSMC22_HPK=1 NTFY_CHNL=

run_arm() (
    local arm=$1 target top syn check saif work
    case "$arm" in
        control) target=PAYN_SC_SIGNED_SEGMENTED_CLEAN; top=payn_array_signed_segmented_clean;;
        inferred) target=PAYN_SC_POPCOUNT_INFERRED; top=payn_array_signed_segmented_popcount;;
        techmap) target=PAYN_SC_POPCOUNT_TECHMAP; top=payn_array_signed_segmented_popcount;;
        *) echo "Unknown arm $arm" >&2; exit 2;;
    esac
    syn="$REPO/syn/build/TSMC22/$target/${CAMPAIGN}_${arm}"
    check="$ACTIVITY/${arm}_syn_functional"
    saif="$check/designs/payn/power/power_payn_array.sv/dut.saif"
    work="$OUT/$arm"
    [[ "$(cat "$check/check.status")" == PASS ]]
    [[ -s "$saif" && -s "$syn/$top.syn.v" ]]
    mkdir -p "$OUT"
    mkdir "$work" # Refuse to overwrite a previous result.
    python3 -B sweeps/validate_sc_power_saif.py "$saif" --expected-period-ns 2.5 \
        > "$work/saif_validation.txt"
    export TOP="$top" NL="$syn/$top.syn.v" SDC="$syn/$top.syn.sdc" SAIF_FILE="$saif"
    printf 'NETLIST=%s\nSDC=%s\nSAIF=%s\nMODE=pre-layout, unit-delay activity, no SPEF/CTS\n' \
        "$NL" "$SDC" "$SAIF_FILE" > "$work/inputs.txt"
    cd "$work"
    pt_shell -file "$REPO/sweeps/pt_popcount_syn_power.tcl" > pt.log 2>&1
    if rg -n '^(Error:|ERROR:)' pt.log; then exit 1; fi
    rg -q '^POPCOUNT_SYN_POWER_DONE ' pt.log
    [[ -s power.rpt && -s saif_coverage.rpt && -s block_power.csv ]]
    echo "[$arm] pre-layout power complete: $work/power.rpt"
)

arms=("$@")
((${#arms[@]})) || arms=(control inferred techmap)
pids=()
for arm in "${arms[@]}"; do run_arm "$arm" & pids+=("$!"); done
status=0
for pid in "${pids[@]}"; do if wait "$pid"; then :; else status=1; fi; done
exit "$status"
