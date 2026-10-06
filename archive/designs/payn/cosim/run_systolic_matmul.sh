#!/bin/bash
# End-to-end binary matmul cosim through 64 production-size PEs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TB="designs/payn/tb/test_systolic_matmul.sv"
SIM_BUILD_DIR="${BUILD_DIR:-${REPO}/build/rtl_systolic_matmul}"

if [[ "${SIM_BUILD_DIR}" != /* ]]; then
    SIM_BUILD_DIR="${REPO}/${SIM_BUILD_DIR}"
fi

TRACE="${SIM_BUILD_DIR}/${TB}/systolic_matmul_rtl.txt"

make -C "${REPO}" sim TOP=Top TB="${TB}" USE_DW=1 \
    BUILD_DIR="${SIM_BUILD_DIR}" GL= TARGET= RTL_PREFLIGHT_CMD= "$@"
python3 "${SCRIPT_DIR}/cosim_systolic_matmul.py" "${TRACE}"
