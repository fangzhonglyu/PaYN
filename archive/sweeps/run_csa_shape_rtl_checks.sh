#!/bin/bash
# RTL preflight for carry-save shapes: exhaustive M=8 counter test, then per
# shape the full-array cosim against sc_kernel.py and the streaming power bench
# against cosim_streaming.py (the bench the routed campaign uses).
#   bash sweeps/run_csa_shape_rtl_checks.sh                 # k8m8n8 k12m8n8 k16m8n8 k8m16n8
#   SHAPES="k16m8n8" bash sweeps/run_csa_shape_rtl_checks.sh
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export USE_DW=1 NTFY_CHNL=
SHAPES=${SHAPES:-"k8m8n8 k12m8n8 k16m8n8 k8m16n8"}
SRC=designs/payn/variants/signed_segmented_csa/payn_array_signed_segmented_csa.sv
VCS_PP='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
OUT=build/rtl_preflight
mkdir -p "$OUT"

make sim TOP=Top TB=designs/payn/tb/test_popcount8_csa.sv BUILD_DIR="$OUT/popcount8_csa" \
    GL= TARGET= RTL_PREFLIGHT_CMD= > "$OUT/popcount8_csa.log" 2>&1
grep -q '\[PASS\] 4FA M=8' "$OUT/popcount8_csa.log"
echo "popcount8_csa: PASS"

check_shape() {
    local shape=$1 K M N batches def
    K=$(sed -E 's/k([0-9]+)m([0-9]+)n([0-9]+)/\1/' <<<"$shape")
    M=$(sed -E 's/k([0-9]+)m([0-9]+)n([0-9]+)/\2/' <<<"$shape")
    N=$(sed -E 's/k([0-9]+)m([0-9]+)n([0-9]+)/\3/' <<<"$shape")
    batches=$((3072 / (128 / M)))
    def="+define+PAYN_ARRAY_EXTERNAL_RTL+define+PAYN_ARRAY_DUT=payn_array_signed_segmented_csa+define+PAYN_SEG_LOW_W=9+define+SC_K=$K+define+SC_M=$M+define+SC_NH=$N+define+SC_NW=$N+define+SC_OWIDTH=24+define+SC_T=128"
    BUILD_DIR="$OUT/ss_csa_$shape" SIM_SRCS=$SRC VCS_ARGS="$def" \
        bash designs/payn/cosim/run_array.sh NTFY_CHNL= "VCS=$VCS_PP" > "$OUT/ss_csa_$shape.log" 2>&1
    grep -q '\[PASS\]' "$OUT/ss_csa_$shape.log"
    BUILD_DIR="$OUT/ss_csa_${shape}_stream" SIM_SRCS=$SRC \
        bash designs/payn/cosim/run_power_array.sh NTFY_CHNL= "VCS=$VCS_PP" \
        VCS_ARGS="$def+define+SC_BATCHES=$batches" > "$OUT/ss_csa_${shape}_stream.log" 2>&1
    grep -q '\[PASS\]' "$OUT/ss_csa_${shape}_stream.log"
    echo "$shape: array cosim PASS; streaming cosim PASS ($batches batches)"
}

pids=()
for shape in $SHAPES; do check_shape "$shape" & pids+=("$!"); done
status=0
for pid in "${pids[@]}"; do wait "$pid" || status=1; done
exit "$status"
