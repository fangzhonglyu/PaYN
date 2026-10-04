#!/bin/bash
# Dimension sweep: payn_array STREAM_MODE=1 vs. Triton emulator goldens.
#
# For every array config (K / M lanes / N_H / N_W) and A path, compile once
# (the encoder's scheme is a compile-time choice, so each A path is a build),
# then run every case (gen_ut_cases.py) at every length L against its emulator
# golden (emu_golden.py). Goldens depend only on the case, L and scheme, not on
# the array config, so one golden set checks all configs. A paths (MODES):
#   host-ut   A_ENCODER=0, testbench feeds kA = round(bA*L/128)  vs GOLDEN_DIR
#   enc-ut    A_ENCODER=1, A_CBSG=0                              vs GOLDEN_DIR
#   enc-cbsg  A_ENCODER=1, A_CBSG=1                              vs GOLDEN_CBSG_DIR
#   gated     payn_array_gated_cbsg STREAMS=1 (gated W, emulator
#             streams)                                           vs GOLDEN_CBSG_DIR
#
#   CASES_DIR=<cases> GOLDEN_DIR=<ut goldens> GOLDEN_CBSG_DIR=<cbsg goldens> \
#       bash run_ut_sweep.sh
#
# Env: CONFIGS (default "8,16,8,8 4,8,4,4 6,4,3,5 16,2,2,2" = K,M,NH,NW),
#      MODES (default "host-ut enc-ut enc-cbsg gated"),
#      LENGTHS (default "128 100 64 43 16 1"), BUILD_DIR.
# Needs VCS and $SYNOPSYS (DesignWare sim library).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
: "${CASES_DIR:?set CASES_DIR}"
: "${GOLDEN_DIR:?set GOLDEN_DIR}"
: "${SYNOPSYS:?SYNOPSYS not set (load a synopsys-synth module for DesignWare)}"
CONFIGS="${CONFIGS:-8,16,8,8 4,8,4,4 6,4,3,5 16,2,2,2}"
MODES="${MODES:-host-ut enc-ut enc-cbsg gated}"
LENGTHS="${LENGTHS:-128 100 64 43 16 1}"
BUILD="${BUILD_DIR:-${REPO}/build/ut_sweep}"

total=0; passed=0; failed=()
for cfg in ${CONFIGS}; do
  IFS=, read -r K M NH NW <<<"${cfg}"
  for mode in ${MODES}; do
    case "${mode}" in
        host-ut)  enc=0; cbsg=0; xdef=""; gdir="${GOLDEN_DIR}" ;;
        enc-ut)   enc=1; cbsg=0; xdef=""; gdir="${GOLDEN_DIR}" ;;
        enc-cbsg) enc=1; cbsg=1; xdef=""; gdir="${GOLDEN_CBSG_DIR:?set GOLDEN_CBSG_DIR for enc-cbsg}" ;;
        gated)    enc=0; cbsg=0; xdef="+SC_GATED"; gdir="${GOLDEN_CBSG_DIR:?set GOLDEN_CBSG_DIR for gated}" ;;
        *) echo "unknown mode ${mode}" >&2; exit 2 ;;
    esac
    tag="k${K}m${M}_${NH}x${NW}_${mode}"
    bdir="${BUILD}/${tag}"
    mkdir -p "${bdir}"
    ( cd "${bdir}" && vcs -sverilog -full64 -timescale=1ns/1ps -assert svaext \
        +incdir+"${REPO}/designs" \
        -y "${SYNOPSYS}/dw/sim_ver" +libext+.v+ +incdir+"${SYNOPSYS}/dw/sim_ver" \
        +define+SC_K=${K}+SC_M=${M}+SC_NH=${NH}+SC_NW=${NW}+SC_A_ENCODER=${enc}+SC_CBSG=${cbsg}${xdef} \
        "${REPO}/designs/payn/tb/test_payn_array_ut.sv" -top Top -o simv \
        > compile.log 2>&1 ) || { echo "[${tag}] COMPILE FAILED (${bdir}/compile.log)"; failed+=("${tag}:compile"); continue; }

    m_pass=0; m_total=0
    for case in "${CASES_DIR}"/*/; do
        name=$(basename "${case}")
        read -r N MB D < "${case}/shape.txt"
        for L in ${LENGTHS}; do
            exp="${gdir}/${name}/out_L${L}.mem"
            out=$(cd "${bdir}" && ./simv +CASE="${case%/}" +EXPECT="${exp}" +L="${L}" \
                  +N="${N}" +M="${MB}" +D="${D}" 2>&1 \
                  | grep -E "^(PASS|FAIL|MISMATCH)|Error|Fatal" | head -3)
            total=$((total + 1)); m_total=$((m_total + 1))
            if grep -q "^PASS" <<<"${out}"; then
                passed=$((passed + 1)); m_pass=$((m_pass + 1))
            else
                failed+=("${tag}:${name}:L${L}")
                echo "[${tag}] ${name} L=${L}: ${out}"
            fi
        done
    done
    echo "[${tag}] ${m_pass}/${m_total} pass"
  done
done
echo "TOTAL ${passed}/${total} pass"
[ ${#failed[@]} -eq 0 ] || { printf 'FAILED: %s\n' "${failed[@]}"; exit 1; }
