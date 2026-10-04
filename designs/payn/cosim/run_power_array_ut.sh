#!/bin/bash
# UT (STREAM_MODE=1) power bench: capture dut.saif over back-to-back K-blocks,
# then check the drain bit-exact against the emulator-defined reference.
# Extra args pass to `make sim` (e.g. GL=apr TARGET=TSMC22/PAYN_SC_UT RUN=...).
# RTL runs need VCS_ARGS="-lca +define+PAYN_STREAM_MODE=1" (SV-SAIF + mode).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TB="designs/payn/power/power_payn_array_ut.sv"
SIM_BUILD_DIR="${BUILD_DIR:-${REPO}/build}"
if [[ "${SIM_BUILD_DIR}" != /* ]]; then
    SIM_BUILD_DIR="${REPO}/${SIM_BUILD_DIR}"
fi
TRACE="${SIM_BUILD_DIR}/${TB}/array_streaming_ut_rtl.txt"

make -C "${REPO}" sim TOP=Top BUILD_DIR="${SIM_BUILD_DIR}" \
    TB="${TB}" USE_DW=1 "$@"
python3 "${SCRIPT_DIR}/cosim_streaming_ut.py" "${TRACE}"
