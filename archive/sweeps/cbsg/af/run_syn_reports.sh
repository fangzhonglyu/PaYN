#!/bin/bash
# Post-synthesis area classes and timing probes for the C-BSG AF array and the
# accepted CSA baseline, then the block-by-block area comparison.
#   bash sweeps/cbsg/af/run_syn_reports.sh [AF_RUN] [CSA_RUN]
#     AF_RUN   default cbsg_af_20261005   (syn/build/TSMC22/PAYN_SC_CSA_CBSG_AF/<run>)
#     CSA_RUN  default csa_20261002       (syn/build/TSMC22/PAYN_SC_CSA/<run>)
# dc_shell reads each run's written netlist + SDC (sweeps/cbsg/af/dc_af_probe.tcl)
# in build/cbsg/af/syn/<target>_<run>/, never in the synthesis run directory.
# Outputs: build/cbsg/af/syn/<target>_<run>/probe.rpt, and
#          build/cbsg/af/syn/area_breakdown.{txt,json} (sweeps/cbsg/af/area_breakdown.py).
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
AF_RUN=${1:-cbsg_af_20261005}
CSA_RUN=${2:-csa_20261002}
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
export DESIGN_ROOT=$REPO
OUTROOT="$REPO/build/cbsg/af/syn"

probe() {   # target run kind
    local tgt=$1 run=$2 kind=$3 dir out
    dir="$REPO/syn/build/TSMC22/$tgt/$run"
    [[ -s "$dir/TARGET_DEF" ]] || { echo "no synthesis run at $dir" >&2; return 2; }
    out="$OUTROOT/${tgt}_${run}"
    mkdir -p "$out"
    (
        set -a; . "$dir/TARGET_DEF"; set +a
        export PROBE_RUN_DIR=$dir PROBE_KIND=$kind
        cd "$out"
        dc_shell -f "$REPO/sweeps/cbsg/af/dc_af_probe.tcl" > probe.rpt 2>&1
    )
    if grep -nE '^Error' "$out/probe.rpt"; then echo "probe errors in $out/probe.rpt" >&2; return 1; fi
    echo "$out/probe.rpt"
}

if [[ -z "${SKIP_PROBE:-}" ]]; then
    probe PAYN_SC_CSA_CBSG_AF "$AF_RUN" af &
    p1=$!
    probe PAYN_SC_CSA "$CSA_RUN" csa &
    p2=$!
    wait $p1
    wait $p2
fi
python3 "$REPO/sweeps/cbsg/af/area_breakdown.py" \
    --af "$REPO/syn/build/TSMC22/PAYN_SC_CSA_CBSG_AF/$AF_RUN" \
    --af-probe "$OUTROOT/PAYN_SC_CSA_CBSG_AF_${AF_RUN}/probe.rpt" \
    --csa "$REPO/syn/build/TSMC22/PAYN_SC_CSA/$CSA_RUN" \
    --csa-probe "$OUTROOT/PAYN_SC_CSA_${CSA_RUN}/probe.rpt" \
    --json "$OUTROOT/area_breakdown.json" | tee "$OUTROOT/area_breakdown.txt"
# Timing summary: one line per probe (label | startpoint -> endpoint | arrival | slack), both designs.
for pr in "$OUTROOT/PAYN_SC_CSA_CBSG_AF_${AF_RUN}/probe.rpt" "$OUTROOT/PAYN_SC_CSA_${CSA_RUN}/probe.rpt"; do
    echo "== $pr"
    awk '/^PROBE_PATH/ {lbl = substr($0, 12); got = 0}
         /Startpoint:/ {sp = $2} /Endpoint:/ {ep = $2}
         /data arrival time/ && !got {arr = $NF; got = 1}
         /slack \(/ && lbl != "" {printf "%-70s | %s -> %s | arrival %s ns | slack %s ns\n", lbl, sp, ep, arr, $NF; lbl = ""}' "$pr"
done | tee "$OUTROOT/timing_summary.txt"
