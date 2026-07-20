#!/bin/bash
# End-to-end bit-exact array cosim: run payn_array, check drain vs sc_kernel.py.
# Extra args pass through to `make sim` (e.g. VCS_ARGS="+define+SC_K=6 ...").
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TB="designs/payn/tb/test_payn_array.sv"
TRACE="${REPO}/build/${TB}/array_rtl.txt"

# Clear GL/TARGET/RTL_PREFLIGHT_CMD: this is a plain zero-delay RTL cosim. Those
# vars are inherited from the environment when this script is invoked AS the
# GL-sim preflight (make exports command-line vars), and leaving them set would
# make this inner `make sim` re-enter the GL branch and recurse into this same
# preflight forever.
make -C "${REPO}" sim TB="${TB}" USE_DW=1 GL= TARGET= RTL_PREFLIGHT_CMD= "$@"
python3 "${SCRIPT_DIR}/cosim_array.py" "${TRACE}"
