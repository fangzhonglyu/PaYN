#!/bin/bash
# Functional power/area split of a C-BSG RG netlist (read-only on the run directory).
#   bash sweeps/cbsg/rg/run_power_split.sh OUT_DIR NETLIST SDC SPEF|none SAIF FLOW_POWER_RPT WINDOW BLOCKS LABEL
# Runs sweeps/cbsg/rg/pt_rg_power_split.tcl (ASTRAEA power.tcl's setup + the cone dump) in OUT_DIR, then
# sweeps/cbsg/rg/power_split.py, which requires the cell-sum total to equal FLOW_POWER_RPT's total.
set -Eeuo pipefail
[[ $# -eq 9 ]] || { echo "Usage: $0 OUT_DIR NETLIST SDC SPEF|none SAIF FLOW_POWER_RPT WINDOW BLOCKS LABEL" >&2; exit 2; }
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
OUT=$1; NETLIST=$(readlink -f "$2"); SDC=$(readlink -f "$3"); SPEF=$4; SAIF=$(readlink -f "$5")
FLOW=$(readlink -f "$6"); WINDOW=$7; BLOCKS=$8; LABEL=$9
[[ "$SPEF" == none ]] || SPEF=$(readlink -f "$SPEF")
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export TSMC22_CELL_TIER=sc7mcpp140z TSMC22_LIB_FLAVORS=svt_c30 TSMC22_HPK_FLAVORS=svt_c30 TSMC22_HPK=1
export ZERO_PINLESS_NET_ACTIVITY=1 SNPSLMD_QUEUE=true PYTHONDONTWRITEBYTECODE=1
mkdir -p "$OUT"; cd "$OUT"
TOP=payn_array_signed_segmented_csa_cbsg_rg NETLIST="$NETLIST" SDC="$SDC" SPEF="$SPEF" SAIF_FILE="$SAIF" \
    SAIF_STRIP_PATH=Top/dut pt_shell -file "$REPO/sweeps/cbsg/rg/pt_rg_power_split.tcl" > pt_power_split.log 2>&1
grep -q RG_SPLIT_DONE pt_power_split.log
if grep -Eq '^(Error|ERROR):' pt_power_split.log; then echo "PT errors in $OUT/pt_power_split.log" >&2; exit 2; fi
printf 'netlist %s\nsdc %s\nspef %s\nsaif %s\nflow_power %s\n' "$NETLIST" "$SDC" "$SPEF" "$SAIF" "$FLOW" > inputs.txt
python3 "$REPO/sweeps/cbsg/rg/power_split.py" rg_power_split.txt --flow-power "$FLOW" --window "$WINDOW" \
    --blocks "$BLOCKS" --label "$LABEL" --json power_split.json | tee power_split.txt
