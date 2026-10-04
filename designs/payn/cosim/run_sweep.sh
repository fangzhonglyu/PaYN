#!/bin/bash
# Dimension sweep: payn_array (C-BSG) vs. the emulator's C-BSG goldens.
#
# For every array config (K / M lanes / N_H / N_W), compile once, then run
# every case (gen_cases.py) at every length L against its emulator golden
# (emu_golden.py). Goldens depend only on the case and L, not on the array
# config, so one golden set checks all configs.
#
#   CASES_DIR=<cases> GOLDEN_DIR=<goldens> bash run_sweep.sh
#
# Env: CONFIGS (default "8,16,8,8 4,8,4,4 6,4,3,5 16,2,2,2" = K,M,NH,NW),
#      LENGTHS (default "128 100 64 43 16 1"), BUILD_DIR.
# Needs VCS and $SYNOPSYS (DesignWare sim library).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
: "${CASES_DIR:?set CASES_DIR}"
: "${GOLDEN_DIR:?set GOLDEN_DIR}"
: "${SYNOPSYS:?SYNOPSYS not set (load a synopsys-synth module for DesignWare)}"
CONFIGS="${CONFIGS:-8,16,8,8 4,8,4,4 6,4,3,5 16,2,2,2}"
LENGTHS="${LENGTHS:-128 100 64 43 16 1}"
BUILD="${BUILD_DIR:-${REPO}/build/sweep}"

total=0; passed=0; failed=()
for cfg in ${CONFIGS}; do
    IFS=, read -r K M NH NW <<<"${cfg}"
    tag="k${K}m${M}_${NH}x${NW}"
    bdir="${BUILD}/${tag}"
    mkdir -p "${bdir}"
    ( cd "${bdir}" && vcs -sverilog -full64 -timescale=1ns/1ps -assert svaext \
        +incdir+"${REPO}/designs" \
        -y "${SYNOPSYS}/dw/sim_ver" +libext+.v+ +incdir+"${SYNOPSYS}/dw/sim_ver" \
        +define+SC_K=${K}+SC_M=${M}+SC_NH=${NH}+SC_NW=${NW} \
        "${REPO}/designs/payn/tb/test_payn_array.sv" -top Top -o simv \
        > compile.log 2>&1 ) || { echo "[${tag}] COMPILE FAILED (${bdir}/compile.log)"; failed+=("${tag}:compile"); continue; }

    c_pass=0; c_total=0
    for case in "${CASES_DIR}"/*/; do
        name=$(basename "${case}")
        read -r N MB D < "${case}/shape.txt"
        for L in ${LENGTHS}; do
            exp="${GOLDEN_DIR}/${name}/out_L${L}.mem"
            out=$(cd "${bdir}" && ./simv +CASE="${case%/}" +EXPECT="${exp}" +L="${L}" \
                  +N="${N}" +M="${MB}" +D="${D}" 2>&1 \
                  | grep -E "^(PASS|FAIL|MISMATCH)|Error|Fatal" | head -3)
            total=$((total + 1)); c_total=$((c_total + 1))
            if grep -q "^PASS" <<<"${out}"; then
                passed=$((passed + 1)); c_pass=$((c_pass + 1))
            else
                failed+=("${tag}:${name}:L${L}")
                echo "[${tag}] ${name} L=${L}: ${out}"
            fi
        done
    done
    echo "[${tag}] ${c_pass}/${c_total} pass"
done
echo "TOTAL ${passed}/${total} pass"
[ ${#failed[@]} -eq 0 ] || { printf 'FAILED: %s\n' "${failed[@]}"; exit 1; }
