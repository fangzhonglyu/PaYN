#!/bin/bash
# Binary-parallel input-regime + native-width sweep. For each regime, runs the
# output-checking BP power bench (captures dut.saif per regime and asserts the
# array is functionally correct). Two axes:
#   - native datapath width  : BP_IWIDTH in {8,7,6}   (INT8/INT7/INT6 native HW)
#   - input regime           : signed vs ALL_POSITIVE, at BP_INPUT_BITS resolution
#
# RTL by default; pass GL=apr TARGET=<tech>/<name> to sweep the routed netlist
# (gate-level, timing checks on). Env: PT_SHELL etc. inherited from the flow.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TB="designs/baselines/binary_parallel/power/power_array_8.sv"
: "${SYNOPSYS:=/usr/caen/synopsys-synth-2021.06-SP1}"; export SYNOPSYS
EXTRA="${EXTRA:-}"   # e.g. EXTRA="GL=apr TARGET=TSMC22/BP_ARRAY_INT7"

# regime list: "<label> <iwidth> <input_bits> <signed|pos>"
REGIMES=(
  "int8_signed        8 8 signed"
  "int7_signed        8 7 signed"
  "int6_signed        8 6 signed"
  "int8_allpos        8 8 pos"
  "int7_allpos        8 7 pos"
  "native_int7_signed 7 7 signed"
  "native_int7_allpos 7 7 pos"
  "native_int6_signed 6 6 signed"
  "native_int6_allpos 6 6 pos"
)

pass=0; total=0
for r in "${REGIMES[@]}"; do
  set -- $r; label=$1; iw=$2; ib=$3; sgn=$4
  total=$((total+1))
  defs="+define+BP_IWIDTH=${iw} +define+BP_INPUT_BITS=${ib}"
  [ "$sgn" = pos ] && defs="$defs +define+BP_ALL_POSITIVE"
  bdir="build/regimes/bp_${label}"
  out=$(make -C "$REPO" sim TB="$TB" VCS_ARGS="$defs" BUILD_DIR="$REPO/$bdir" $EXTRA 2>&1)
  if echo "$out" | grep -q "PASS:"; then
    echo "  OK   ${label}  (IWIDTH=${iw} INPUT_BITS=${ib} ${sgn})  saif=${bdir}/../${TB}/dut.saif"
    pass=$((pass+1))
  else
    echo "  FAIL ${label}"
    echo "$out" | grep -iE "FUNC-FAIL|X-FAIL|Error-|error:" | head -3
  fi
done
echo "REGIMES: ${pass}/${total} passed"
[ "$pass" -eq "$total" ]
