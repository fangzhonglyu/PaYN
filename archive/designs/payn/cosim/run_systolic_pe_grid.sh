#!/bin/bash
# Self-checking RTL simulation of a 2x3 grid of signed-segmented InnerPEs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TB="designs/payn/tb/test_systolic_pe_grid.sv"
SIM_BUILD_DIR="${BUILD_DIR:-${REPO}/build/rtl_systolic_pe_grid}"

if [[ "${SIM_BUILD_DIR}" != /* ]]; then
    SIM_BUILD_DIR="${REPO}/${SIM_BUILD_DIR}"
fi

make -C "${REPO}" sim TOP=Top TB="${TB}" USE_DW=1 \
    BUILD_DIR="${SIM_BUILD_DIR}" GL= TARGET= RTL_PREFLIGHT_CMD= "$@"
