#!/bin/bash
# Overlap repair of a finished ASTRAEA route, planned from its checkPlace REPORTS instead of apr.log.
#   bash flow/apr_overlap_repair.sh TARGET RUN        e.g. TSMC22/BITMOD_TILE_H bm_20261016b
# ASTRAEA's repair planner (apr_qualify.repair_plan) takes the overlap instances from every NRDB-2082 message in
# apr.log; when the last checkPlace's overlaps are not among them (they were reported only in the checkPlace report
# files), `make apr_repair` legalizes the wrong instances or finds none.  This takes the instances from the route's
# reports/placement_final.rpt and, if a repair already ran, reports/placement_before_repair.rpt (the route.enc
# checkpoint's own overlaps, which the overlap repair restarts from), and otherwise is `make apr_repair`: ASTRAEA's
# cmd_repair_prepare (archive, checkpoint restore, repair_targets.tcl) with only the plan replaced, the same
# repair_route.tcl with the Makefile's environment, and the same final qualification.
set -Eeuo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TARGET=${1:?usage: bash flow/apr_overlap_repair.sh TARGET RUN}
RUN=${2:?usage: bash flow/apr_overlap_repair.sh TARGET RUN}
FLOW_ROOT=${ASTRAEA_FLOW:?set ASTRAEA_FLOW (flow/env.sh)}
RUN_DIR="$REPO/apr/build/$TARGET/$RUN"
[[ -f "$RUN_DIR/TARGET_DEF" ]] || { echo "ERROR: $RUN_DIR/TARGET_DEF not found" >&2; exit 1; }
command -v innovus >/dev/null || { echo "ERROR: innovus not found (flow/env.sh)" >&2; exit 1; }
export FLOW_ROOT DESIGN_ROOT="$REPO" SYNTH_RUN="${SYNTH_RUN:-checkpoint_only_repair}"
set -a; . "$RUN_DIR/TARGET_DEF"; set +a

python3 -B - "$FLOW_ROOT/apr/scripts/apr_qualify.py" "$RUN_DIR" "$TOP" <<'PY'
import argparse, importlib.util, re, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("aq", sys.argv[1]); aq = importlib.util.module_from_spec(spec)
spec.loader.exec_module(aq)
route, top = Path(sys.argv[2]), sys.argv[3]
names = set()
for rpt in ("placement_final.rpt", "placement_before_repair.rpt"):
    p = route / "reports" / rpt
    if p.exists():
        m = re.search(r"set pchkOverlapList \[list \\\n(.*?)\n\s*\]", p.read_text(), re.S)
        if m:
            names |= set(re.findall(r"\{([^}]+)\}", m[1]))
if not names:
    sys.exit("no overlapping instances in the route's checkPlace reports")
def plan_from_reports(route, top):
    plan = dict(mode="overlap", checkpoint="route", overlap_instances=sorted(names), geometry=[], antenna_pins=[],
                source="checkPlace reports (flow/apr_overlap_repair.sh)")
    for f in (f"{top}.route.enc", f"{top}.route.enc.dat", f"{top}.syn.v", f"{top}.syn.sdc", "TARGET_DEF"):
        aq.require((route / f).exists(), f"missing repair input {f}")
    return plan
aq.repair_plan = plan_from_reports
sys.exit(aq.cmd_repair_prepare(argparse.Namespace(route=route, top=top, plan_only=False)))
PY

cd "$RUN_DIR"
echo "Repair log: $RUN_DIR/apr.log"
SKIP_FINAL_HOLD_OPT=1 FORCE_FINAL_HOLD_OPT=0 SKIP_FILLER=0 FORCE_STRONG_FINAL_DRC=0 \
DISABLE_POSTROUTE_SWAPVIA=1 APR_DRC_AUTOSTOP_RETRY=0 \
    innovus -batch -no_gui -files "$FLOW_ROOT/apr/scripts/repair_route.tcl" > apr.log 2>&1 || true
grep -q "ASTRAEA_CHECKPOINT_REPAIR_COMPLETE" apr.log || { echo "ERROR: repair did not complete; see $RUN_DIR/apr.log" >&2; exit 1; }
python3 -B "$FLOW_ROOT/apr/scripts/apr_qualify.py" qualify --route . --top "$TOP" --stage final \
    --json reports/qualification.json
