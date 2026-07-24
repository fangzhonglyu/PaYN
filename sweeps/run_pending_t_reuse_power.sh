#!/bin/bash
# Reuse the accepted routed pending-bit checkpoint to measure how operand/sign
# reuse length changes power. No synthesis or APR is performed.
#
# Every point uses the same number of productive clocks. SC_BATCHES is chosen
# so magnitude/sign reload occurs every T/M clocks while the total SAIF window
# remains constant. Lightweight APR-run views keep each PT-PX report separate
# and leave the accepted checkpoint reports/activity untouched.
set -euo pipefail

cd /home/barrylyu/repos/PaYN
source /etc/profile.d/modules.sh 2>/dev/null || \
    source /usr/share/Modules/init/bash 2>/dev/null
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000

export SYNOPSYS=/usr/caen/synopsys-synth-2021.06-SP1
export USE_DW=1

TARGET=TSMC22/PAYN_SC_SIGNED_SEGMENTED
BASE_RUN=k8m16n8_lw9_distguide
TOP=payn_array_signed_segmented
TB=designs/payn/power/power_payn_array.sv
TOTAL_CYCLES=${TOTAL_CYCLES:-3072}
T_LIST=${T_LIST:-"32 48 64 96 128"}
MAX_JOBS=${MAX_JOBS:-2}
OUT_ROOT=build/power_char/pending_t_reuse
CSV=${OUT_ROOT}/results.csv

K=8
M=16
N_H=8
N_W=8
PERIOD_NS=2.5

BASE_DIR=apr/build/${TARGET}/${BASE_RUN}
test -f "${BASE_DIR}/outputs/${TOP}.apr.v"
test -f "${BASE_DIR}/outputs/${TOP}.apr.sdf"
test -f "${BASE_DIR}/outputs/${TOP}.spef"
test -f "${BASE_DIR}/${TOP}.syn.sdc"

mkdir -p "${OUT_ROOT}"
printf '%s\n' \
    "T,mac_cycles,batches,productive_cycles,power_mW,pJ_MAC,net_mW,internal_mW,leakage_mW,status" \
    > "${CSV}.new"

run_point() {
    local t=$1
    local mac_cycles=$((t / M))
    local batches=$((TOTAL_CYCLES / mac_cycles))
    local label=T${t}
    local build_dir=${OUT_ROOT}/${label}/sim
    local log=${OUT_ROOT}/${label}/run.log
    local view_run=t_reuse_${label}
    local view_dir=apr/build/${TARGET}/${view_run}
    local saif trace

    if ((t <= 0 || t % M != 0)); then
        printf '%s\n' "${t},,,,,,,,,INVALID_T" > "${OUT_ROOT}/${label}.row"
        return
    fi
    if ((TOTAL_CYCLES % mac_cycles != 0)); then
        printf '%s\n' "${t},${mac_cycles},,,,,,,,CYCLE_MISMATCH" \
            > "${OUT_ROOT}/${label}.row"
        return
    fi

    mkdir -p "${build_dir}" "${view_dir}/activity" "${view_dir}/reports"
    if [[ ! -e "${view_dir}/outputs" ]]; then
        ln -s "../${BASE_RUN}/outputs" "${view_dir}/outputs"
    fi
    if [[ ! -e "${view_dir}/${TOP}.syn.sdc" ]]; then
        ln -s "../${BASE_RUN}/${TOP}.syn.sdc" "${view_dir}/${TOP}.syn.sdc"
    fi

    : > "${log}"
    RTL_PREFLIGHT_CMD=true make sim GL=apr TARGET=${TARGET} RUN=${BASE_RUN} \
        USE_DW=1 BUILD_DIR="${build_dir}" TB="${TB}" \
        VCS_ARGS="+define+PAYN_ARRAY_DUT=payn_array_signed_segmented +define+SC_K=${K} +define+SC_M=${M} +define+SC_NH=${N_H} +define+SC_NW=${N_W} +define+SC_OWIDTH=24 +define+SC_T=${t} +define+SC_BATCHES=${batches}" \
        >> "${log}" 2>&1

    saif=${build_dir}/${TB}/dut.saif
    trace=${build_dir}/${TB}/array_streaming_rtl.txt
    test -s "${saif}"
    test -s "${trace}"
    python3 designs/payn/cosim/cosim_streaming.py "${trace}" >> "${log}" 2>&1
    python3 sweeps/validate_sc_power_saif.py "${saif}" \
        --expected-period-ns "${PERIOD_NS}" >> "${log}" 2>&1

    POWER_SAIF_VALIDATOR=sweeps/validate_sc_power_saif.py \
        make power_apr TARGET=${TARGET} RUN=${view_run} \
        SAIF="${saif}" SAIF_STRIP_PATH=Top/dut >> "${log}" 2>&1

    python3 - "${view_dir}/reports/power.rpt" "${t}" "${mac_cycles}" \
        "${batches}" "${TOTAL_CYCLES}" "${K}" "${M}" "${N_H}" "${N_W}" \
        "${PERIOD_NS}" > "${OUT_ROOT}/${label}.row" <<'PY'
import re
import sys

(report, t, mac_cycles, batches, total_cycles,
 k, m, nh, nw, period_ns) = sys.argv[1:]
text = open(report).read()

def value(pattern):
    match = re.search(pattern, text, re.MULTILINE)
    if not match:
        raise SystemExit(f"missing power field: {pattern}")
    return float(match.group(1)) * 1e3

total_mw = value(r"Total Power\s*=\s*([0-9.eE+-]+)")
net_mw = value(r"Net Switching Power\s*=\s*([0-9.eE+-]+)")
internal_mw = value(r"Cell Internal Power\s*=\s*([0-9.eE+-]+)")
leakage_mw = value(r"Cell Leakage Power\s*=\s*([0-9.eE+-]+)")
mac_per_cycle = int(k) * int(m) * int(nh) * int(nw) / int(t)
pj_mac = total_mw * float(period_ns) / mac_per_cycle
print(
    f"{t},{mac_cycles},{batches},{total_cycles},"
    f"{total_mw:.6f},{pj_mac:.6f},{net_mw:.6f},"
    f"{internal_mw:.6f},{leakage_mw:.6f},OK"
)
PY
}

for t in ${T_LIST}; do
    run_point "${t}" &
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do
        wait -n
    done
done
wait

for t in ${T_LIST}; do
    cat "${OUT_ROOT}/T${t}.row" >> "${CSV}.new"
done
mv "${CSV}.new" "${CSV}"
echo "Completed routed pending-bit T sweep: ${CSV}"
