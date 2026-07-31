#!/bin/bash
# Padded-T power characterization: T need not be a multiple of M.
#
# A block with T % M != 0 executes in ceil(T/M) clocks; the final slice
# carries only T%M real samples and the bench (power_payn_array_tpad.sv)
# forces the dead lanes to zero at the u_pe boundary.  Same route-reuse
# methodology as run_pending_t_reuse_power.sh: the accepted spp_fixed
# checkpoint is reused with NO synthesis or APR, and VCS flags are kept
# identical to the original T sweep so results are directly comparable.
#
# Each point runs an RTL sim of the same bench first (minutes) and requires
# the bit-exact streaming cosim to pass -- this validates the pad-lane mask
# and its phase before the expensive gate sim (a mask on the wrong slice or
# lanes mismatches the drain).
#
# MACs completed depend on block count, not T: pJ/MAC uses
# K*N_H*N_W / ceil(T/M) per cycle, which reduces to the original
# K*M*N_H*N_W/T at multiples of M.
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
BASE_RUN=${BASE_RUN:-k8m16n8_lw9_distguide_spp_fixed}
TOP=payn_array_signed_segmented
RTL_SRC=designs/payn/variants/signed_segmented/payn_array_signed_segmented.sv
TB=designs/payn/power/power_payn_array_tpad.sv
TOTAL_CYCLES=${TOTAL_CYCLES:-3072}
T_LIST=${T_LIST:-"17 24 40 56 72 88 104 120"}
# Optional operand-seed override as a plain DECIMAL literal (e.g.
# SEED=3405705229; a 32'h... form cannot survive the make->shell quoting).
# Rerunning a point with a second seed measures the accumulator-trajectory
# noise floor that bounds how well nearby workloads can be compared.  Use a
# separate OUT_ROOT and VIEW_PREFIX so seed studies never overwrite the
# canonical results.
SEED=${SEED:-}
MAX_JOBS=${MAX_JOBS:-2}
SKIP_RTL=${SKIP_RTL:-0}
OUT_ROOT=${OUT_ROOT:-build/power_char/t_pad}
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
    "T,mac_cycles,pad_lanes,batches,productive_cycles,power_mW,pJ_MAC,net_mW,internal_mW,leakage_mW,status" \
    > "${CSV}.new"

run_point() {
    local t=$1
    local mac_cycles=$(( (t + M - 1) / M ))
    local pad_lanes=$(( mac_cycles * M - t ))
    # Nearest block count to the canonical window; exact for
    # mac_cycles in {1,2,3,4,6,8}, within 0.1% for 5 and 7.
    local batches=$(( (TOTAL_CYCLES + mac_cycles / 2) / mac_cycles ))
    local productive=$(( batches * mac_cycles ))
    local label=T${t}
    local build_dir=${OUT_ROOT}/${label}/sim
    local rtl_dir=${OUT_ROOT}/${label}/rtl
    local log=${OUT_ROOT}/${label}/run.log
    local view_run=${VIEW_PREFIX:-t_pad}_${label}
    local view_dir=apr/build/${TARGET}/${view_run}
    local defs="+define+PAYN_ARRAY_DUT=${TOP} +define+SC_K=${K} +define+SC_M=${M} +define+SC_NH=${N_H} +define+SC_NW=${N_W} +define+SC_OWIDTH=24 +define+SC_T=${t} +define+SC_BATCHES=${batches}"
    if [[ -n "${SEED}" ]]; then defs="${defs} +define+SC_SEED=${SEED}"; fi
    if [[ -n "${EXTRA_DEFS:-}" ]]; then defs="${defs} ${EXTRA_DEFS}"; fi
    local saif trace

    if ((t <= 0 || batches < 1)); then
        printf '%s\n' "${t},,,,,,,,,,INVALID_T" > "${OUT_ROOT}/${label}.row"
        return
    fi

    mkdir -p "${build_dir}" "${rtl_dir}" "${view_dir}/activity" "${view_dir}/reports"
    if [[ ! -e "${view_dir}/outputs" ]]; then
        ln -s "../${BASE_RUN}/outputs" "${view_dir}/outputs"
    fi
    if [[ ! -e "${view_dir}/${TOP}.syn.sdc" ]]; then
        ln -s "../${BASE_RUN}/${TOP}.syn.sdc" "${view_dir}/${TOP}.syn.sdc"
    fi

    : > "${log}"

    # ---- stage 1: RTL sim + bit-exact cosim (mask/phase validation) ----
    if [[ "${SKIP_RTL}" != 1 ]]; then
        make sim TOP=Top BUILD_DIR="${rtl_dir}" TB="${TB}" USE_DW=1 \
            SIM_SRCS="${RTL_SRC}" \
            VCS_ARGS="+define+PAYN_ARRAY_EXTERNAL_RTL ${defs}" \
            >> "${log}" 2>&1
        trace=${rtl_dir}/${TB}/array_streaming_rtl.txt
        test -s "${trace}"
        python3 designs/payn/cosim/cosim_streaming.py "${trace}" >> "${log}" 2>&1 || {
            printf '%s\n' "${t},${mac_cycles},${pad_lanes},${batches},${productive},,,,,,RTL_COSIM_FAIL" \
                > "${OUT_ROOT}/${label}.row"
            return
        }
    fi

    # ---- stage 2: max-SDF gate sim on the reused route ----
    RTL_PREFLIGHT_CMD=true make sim GL=apr TARGET=${TARGET} RUN=${BASE_RUN} \
        USE_DW=1 BUILD_DIR="${build_dir}" TB="${TB}" \
        VCS_ARGS="${defs}" \
        >> "${log}" 2>&1

    saif=${build_dir}/${TB}/dut.saif
    trace=${build_dir}/${TB}/array_streaming_rtl.txt
    test -s "${saif}"
    test -s "${trace}"
    python3 designs/payn/cosim/cosim_streaming.py "${trace}" >> "${log}" 2>&1 || {
        printf '%s\n' "${t},${mac_cycles},${pad_lanes},${batches},${productive},,,,,,GL_COSIM_FAIL" \
            > "${OUT_ROOT}/${label}.row"
        return
    }
    python3 sweeps/validate_sc_power_saif.py "${saif}" \
        --expected-period-ns "${PERIOD_NS}" >> "${log}" 2>&1

    # ---- stage 3: PT-PX on a view run ----
    POWER_SAIF_VALIDATOR=sweeps/validate_sc_power_saif.py \
        make power_apr TARGET=${TARGET} RUN=${view_run} \
        SAIF="${saif}" SAIF_STRIP_PATH=Top/dut >> "${log}" 2>&1

    python3 - "${view_dir}/reports/power.rpt" "${t}" "${mac_cycles}" \
        "${pad_lanes}" "${batches}" "${productive}" "${K}" "${N_H}" "${N_W}" \
        "${PERIOD_NS}" > "${OUT_ROOT}/${label}.row" <<'PY'
import re
import sys

(report, t, mac_cycles, pad_lanes, batches, productive,
 k, nh, nw, period_ns) = sys.argv[1:]
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
# One MAC per (tile, lane) per block: K*NH*NW MACs every mac_cycles clocks.
# Identical to K*M*NH*NW/T when T is a multiple of M.
mac_per_cycle = int(k) * int(nh) * int(nw) / int(mac_cycles)
pj_mac = total_mw * float(period_ns) / mac_per_cycle
print(
    f"{t},{mac_cycles},{pad_lanes},{batches},{productive},"
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
echo "Completed padded-T power sweep: ${CSV}"
