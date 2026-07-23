#!/bin/bash
# SC power bench: capture dut.saif over the stochastic-MAC window, then check the
# drained output bit-exact vs sc_kernel.py. Extra args pass to `make sim`
# (e.g. VCS_ARGS="+define+SC_K=8 ...").
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TB="designs/payn/power/power_payn_array.sv"
SIM_BUILD_DIR="${BUILD_DIR:-${REPO}/build}"
if [[ "${SIM_BUILD_DIR}" != /* ]]; then
    SIM_BUILD_DIR="${REPO}/${SIM_BUILD_DIR}"
fi
TRACE="${SIM_BUILD_DIR}/${TB}/array_rtl.txt"

make -C "${REPO}" sim TOP=Top BUILD_DIR="${SIM_BUILD_DIR}" \
    TB="${TB}" USE_DW=1 "$@"
python3 "${SCRIPT_DIR}/cosim_array.py" "${TRACE}"
