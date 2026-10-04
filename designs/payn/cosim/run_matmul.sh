#!/bin/bash
# payn_array (C-BSG) vs. the emulator's C-BSG vectors (t9_sc_matmul).
#
# Compiles test_payn_array.sv once, then runs both t9 cases (uniform, gaussian)
# at every length against their out_L*.mem, bit-for-bit.
#
# Env: T9_DIR (default ../gpu_aversion/t9_sc_matmul next to the repo),
#      BUILD_DIR (default <repo>/build/matmul), LENGTHS (default "128 64 43 16").
# Needs VCS and $SYNOPSYS (DesignWare sim library), e.g.
#   module load vcs/2023.12-SP2-1 synopsys-synth/2023.12-SP5
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
T9_DIR="${T9_DIR:-$(cd "${REPO}/.." && pwd)/gpu_aversion/t9_sc_matmul}"
BUILD="${BUILD_DIR:-${REPO}/build/matmul}"
LENGTHS="${LENGTHS:-128 64 43 16}"
: "${SYNOPSYS:?SYNOPSYS not set (load a synopsys-synth module for DesignWare)}"

mkdir -p "${BUILD}"
cd "${BUILD}"
vcs -sverilog -full64 -timescale=1ns/1ps -assert svaext +lint=TFIPC-L \
    +incdir+"${REPO}/designs" \
    -y "${SYNOPSYS}/dw/sim_ver" +libext+.v+ +incdir+"${SYNOPSYS}/dw/sim_ver" \
    "${REPO}/designs/payn/tb/test_payn_array.sv" -top Top -o simv > compile.log 2>&1 \
    || { tail -40 compile.log; echo "ERROR: compile failed (${BUILD}/compile.log)"; exit 1; }

fail=0
for c in uniform gaussian; do
    for L in ${LENGTHS}; do
        out=$(./simv +CASE="${T9_DIR}/${c}" +EXPECT="${T9_DIR}/${c}/out_L${L}.mem" +L="${L}" 2>&1 \
              | grep -E "PASS|FAIL|MISMATCH|Error|Fatal" || true)
        echo "[${c} L=${L}] ${out}"
        grep -q "^PASS" <<<"${out}" || fail=1
    done
done
exit ${fail}
