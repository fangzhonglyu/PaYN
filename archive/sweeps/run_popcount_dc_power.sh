#!/bin/bash
# Matched pre-layout power through ASTRAEA's existing DC SAIF flow.
# No routed parasitics/CTS. ASTRAEA suppresses the unrealistic pre-CTS ICG
# output wire-load estimate; this remains a synthesis-level power estimate.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"
CAMPAIGN=${CAMPAIGN:-pc16_20260930}
ACTIVITY=${ACTIVITY:-build/power_char/popcount_synth_${CAMPAIGN#pc16_}}
OUT=${OUT:-build/power_char/popcount_dc_power_${CAMPAIGN#pc16_}}
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
    # DC's flow writes these reports inside the synthesis run. Preserve any
    # earlier analysis by refusing to overwrite its power result.
    [[ ! -e "$syn/pwr_saif.rpt" ]]
    mkdir -p "$OUT"
    mkdir "$work"
    printf 'NETLIST=%s\nSAIF=%s\nMODE=ASTRAEA DC SAIF pre-layout estimate\n' \
        "$syn/$top.syn.v" "$saif" > "$work/inputs.txt"
    make power TARGET="TSMC22/$target" RUN="${CAMPAIGN}_${arm}" SAIF="$saif" \
        POWER_SAIF_VALIDATOR="$REPO/sweeps/validate_sc_power_saif.py" NTFY_CHNL= \
        > "$work/flow.log" 2>&1
    cp "$syn/pwr_saif.rpt" "$syn/pwr_saif_hier.rpt" "$syn/saif_coverage.rpt" \
        "$syn/saif_header.rpt" "$syn/power.log" "$work/"
    echo "[$arm] DC workload power complete: $work/pwr_saif.rpt"
)

arms=("$@")
((${#arms[@]})) || arms=(control inferred techmap)
pids=()
for arm in "${arms[@]}"; do run_arm "$arm" & pids+=("$!"); done
status=0
for pid in "${pids[@]}"; do if wait "$pid"; then :; else status=1; fi; done
exit "$status"
