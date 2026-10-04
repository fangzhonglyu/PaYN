#!/bin/bash
# Unary-temporal PaYN (payn_array STREAM_MODE=1) vs. emulator golden accumulators.
#
# Compiles test_payn_array_ut.sv once, then runs every case x length:
#   * vs. vectors_ut/<case>/out_L*.mem   (SC_MULT_SCHEME=ut, from emu_golden.py)
#   * vs. the C-BSG t9 vectors at L=128/64, where ut and cbsg are identical
#
# Env: T9_DIR (default ../gpu_aversion/t9_sc_matmul next to the repo),
#      BUILD_DIR (default <repo>/build/ut_matmul), LENGTHS (default "128 64 43 16").
# Needs VCS and $SYNOPSYS (DesignWare sim library), e.g.
#   module load vcs/2023.12-SP2-1 synopsys-synth/2023.12-SP5
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
T9_DIR="${T9_DIR:-$(cd "${REPO}/.." && pwd)/gpu_aversion/t9_sc_matmul}"
BUILD="${BUILD_DIR:-${REPO}/build/ut_matmul}"
LENGTHS="${LENGTHS:-128 64 43 16}"
: "${SYNOPSYS:?SYNOPSYS not set (load a synopsys-synth module for DesignWare)}"

mkdir -p "${BUILD}"
cd "${BUILD}"
vcs -sverilog -full64 -timescale=1ns/1ps -assert svaext +lint=TFIPC-L \
    +incdir+"${REPO}/designs" \
    -y "${SYNOPSYS}/dw/sim_ver" +libext+.v+ +incdir+"${SYNOPSYS}/dw/sim_ver" \
    "${REPO}/designs/payn/tb/test_payn_array_ut.sv" -top Top -o simv > compile.log 2>&1 \
    || { tail -40 compile.log; echo "ERROR: compile failed (${BUILD}/compile.log)"; exit 1; }

fail=0
run() {  # case_dir expect_file L label
    local out
    out=$(./simv +CASE="$1" +EXPECT="$2" +L="$3" 2>&1 | grep -E "PASS|FAIL|MISMATCH|Error|Fatal" || true)
    echo "[$4] ${out}"
    grep -q "^PASS" <<<"${out}" || fail=1
}
for c in uniform gaussian; do
    for L in ${LENGTHS}; do
        run "${T9_DIR}/${c}" "${SCRIPT_DIR}/vectors_ut/${c}/out_L${L}.mem" "${L}" "${c} ut   L=${L}"
    done
    for L in 128 64; do
        run "${T9_DIR}/${c}" "${T9_DIR}/${c}/out_L${L}.mem" "${L}" "${c} cbsg L=${L}"
    done
done
exit ${fail}
