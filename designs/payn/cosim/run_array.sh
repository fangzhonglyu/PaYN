#!/bin/bash
# End-to-end bit-exact array cosim: run payn_array, check drain vs sc_kernel.py.
# Extra args pass through to `make sim` (e.g. VCS_ARGS="+define+SC_K=6 ...").
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TB="designs/payn/tb/test_payn_array.sv"
SIM_BUILD_DIR="${BUILD_DIR:-${REPO}/build}"
if [[ "${SIM_BUILD_DIR}" != /* ]]; then
    SIM_BUILD_DIR="${REPO}/${SIM_BUILD_DIR}"
fi
TRACE="${SIM_BUILD_DIR}/${TB}/array_rtl.txt"

# Clear GL/TARGET/RTL_PREFLIGHT_CMD: this is a plain zero-delay RTL cosim. Those
# vars are inherited from the environment when this script is invoked AS the
# GL-sim preflight (make exports command-line vars), and leaving them set would
# make this inner `make sim` re-enter the GL branch and recurse into this same
# preflight forever.
make -C "${REPO}" sim TOP=Top TB="${TB}" USE_DW=1 \
    BUILD_DIR="${SIM_BUILD_DIR}" GL= TARGET= RTL_PREFLIGHT_CMD= "$@"
python3 "${SCRIPT_DIR}/cosim_array.py" "${TRACE}"
