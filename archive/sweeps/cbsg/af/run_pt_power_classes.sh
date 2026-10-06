#!/bin/bash
# Routed power by functional class (A edge / W edge / W bank / kA encoders / thermometer / PE core), read only on the
# route: sweeps/cbsg/af/pt_power_classes.tcl in OUT_DIR, then sweeps/cbsg/af/power_classes.py.
#   bash sweeps/cbsg/af/run_pt_power_classes.sh ROUTE_DIR TOP af|csa SAIF REF_POWER_RPT OUT_DIR
# REF_POWER_RPT is the power.rpt PT wrote for this route and SAIF (the class run must reproduce its total), or
# 'none' for a smoke run without that check.
# Environment as sweeps/cbsg/run_cbsg_pinned_pass2.sh (TSMC22 sc7mcpp140z svt_c30 + HPK, pinless nets static).
set -Eeuo pipefail
[[ $# -eq 6 ]] || { echo "Usage: $0 ROUTE_DIR TOP af|csa SAIF REF_POWER_RPT OUT_DIR" >&2; exit 2; }
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ROUTE=$(readlink -f "$1"); TOP=$2; KIND=$3; SAIF=$(readlink -f "$4"); REF=$5; OUT=$6
[[ "$REF" == none ]] || REF=$(readlink -f "$REF")
[[ "$KIND" == af || "$KIND" == csa ]] || { echo "KIND must be af or csa" >&2; exit 2; }
for f in "$ROUTE/outputs/$TOP.apr.v" "$ROUTE/outputs/$TOP.spef" "$ROUTE/$TOP.syn.sdc" "$SAIF" $([[ "$REF" == none ]] || echo "$REF"); do
    [[ -s "$f" ]] || { echo "missing $f" >&2; exit 2; }
done
mkdir -p "$OUT"; OUT=$(readlink -f "$OUT")
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export SNPSLMD_QUEUE=true ZERO_PINLESS_NET_ACTIVITY=1
export TSMC22_CELL_TIER=sc7mcpp140z TSMC22_LIB_FLAVORS=svt_c30 TSMC22_HPK_FLAVORS=svt_c30 TSMC22_HPK=1
REF_TOTAL_W=""
if [[ "$REF" != none ]]; then
    REF_TOTAL_W=$(sed -nE 's/^Total Power\s*=\s*([0-9.eE+-]+).*/\1/p' "$REF" | head -n 1)
    [[ -n "$REF_TOTAL_W" ]]
fi
{
    echo "route=$ROUTE"; echo "top=$TOP kind=$KIND"
    echo "saif=$SAIF sha256=$(sha256sum "$SAIF" | cut -d' ' -f1)"
    echo "ref_power_rpt=$REF total_W=$REF_TOTAL_W"
    for f in "outputs/$TOP.apr.v" "outputs/$TOP.spef" "$TOP.syn.sdc"; do echo "$(sha256sum "$ROUTE/$f" | cut -d' ' -f1)  $f"; done
    echo "script sha256=$(sha256sum "$REPO/sweeps/cbsg/af/pt_power_classes.tcl" | cut -d' ' -f1)"
} > "$OUT/inputs.txt"
cd "$OUT"
ROUTE_DIR="$ROUTE" TOP="$TOP" KIND="$KIND" SAIF_FILE="$SAIF" REF_TOTAL_W="$REF_TOTAL_W" \
    pt_shell -file "$REPO/sweeps/cbsg/af/pt_power_classes.tcl" > pt_power_classes.log 2>&1
if grep -Eq '^(Error|ERROR):' pt_power_classes.log; then grep -E -m 5 '^(Error|ERROR):' pt_power_classes.log >&2; exit 1; fi
[[ "$REF" == none ]] || grep -q '^PWR_CHECK total_vs_route_power_rpt' pt_power_classes.log
python3 "$REPO/sweeps/cbsg/af/power_classes.py" pt_power_classes.log --kind "$KIND" --json power_classes.json \
    | tee power_classes.txt
