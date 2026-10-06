#!/bin/bash
# Matched synthesis A/B for the lane-stratified SNG (doc/SC_area_efficiency.md):
#   PAYN_SNG_BASELINE / PAYN_SNG_STRAT     edge SNG alone (held operands + RNG + bits)
#   PAYN_LANE_PLAIN_X8 / PAYN_LANE_STRAT_X8 one tile's 8 lane hit counters
# All four run concurrently with the popcount-campaign knobs set in their targets.
#   bash sweeps/run_strat_sng_synth.sh [TAG]      (default TAG=20261002)
# Existing run directories are refused.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
TAG=${1:-20261002}
OUT=build/sng_area_$TAG
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export NTFY_CHNL=
unset POST_LOAD_SCRIPT RTL_PREFLIGHT_CMD SYN_SAIF_FILE SYN_SAIF_INSTANCE
mkdir -p "$OUT"
declare -A RUN=([PAYN_SNG_BASELINE]=sng_${TAG}_baseline [PAYN_SNG_STRAT]=sng_${TAG}_strat
                [PAYN_LANE_PLAIN_X8]=lane_${TAG}_plain [PAYN_LANE_STRAT_X8]=lane_${TAG}_strat)
for t in "${!RUN[@]}"; do
    [[ ! -e syn/build/TSMC22/$t/${RUN[$t]} ]] || { echo "Refusing existing $t/${RUN[$t]}" >&2; exit 2; }
done
pids=()
for t in "${!RUN[@]}"; do
    RUN_NAME=${RUN[$t]} make synth TARGET=TSMC22/$t NTFY_CHNL= > "$OUT/$t.log" 2>&1 &
    pids+=($!)
done
status=0
for p in "${pids[@]}"; do wait "$p" || status=1; done
for t in PAYN_SNG_BASELINE PAYN_SNG_STRAT PAYN_LANE_PLAIN_X8 PAYN_LANE_STRAT_X8; do
    printf '%-20s ' "$t"
    awk '/Total cell area/ {print $4; exit}' "syn/build/TSMC22/$t/${RUN[$t]}/area.rpt"
done
exit $status
