#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TB="designs/payn/tb/test_peripheral_cosim.sv"
TRACE="${REPO}/build/${TB}/peripheral_v1_rtl.csv"

make -C "${REPO}" sim TB="${TB}"
python3 "${SCRIPT_DIR}/cosim_peripheral.py" "${TRACE}"
