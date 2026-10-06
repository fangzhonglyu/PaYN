#!/bin/bash
# Replicate of the AF pinned pass 2 route with the IDENTICAL recipe of sweeps/cbsg/run_cbsg_pinned_pass2.sh's
# do_apr (same modules, exports, pin/guide pre-place script, bootstrap SAIF, workload power opt) under a separate run
# name, then run_popcount_apr.sh's check_apr 'final' (extracted at run time, as the drivers do).
# Purpose (2026-10-05): the campaign's pinned route cbsg_af_20261005_distguide_spp_pins failed the strict final DRC
# qualification -- the flow's post-route two-pass addFiller left 69,437 router-counted M1 violations because
# NanoRoute's strong reroute ran no search-and-repair iterations (the floating final, same flow, ran four and reached
# 0).  This replicate tests whether that outcome is deterministic.  It does not touch the campaign's driver state.
#   bash sweeps/cbsg/af/run_af_pinned_replicate.sh REP_SUFFIX OUT_DIR      (e.g. rep2 build/power_char/cbsg_20261005/af/pinned_rep2)
set -Eeuo pipefail
[[ $# -eq 2 ]] || { echo "Usage: $0 REP_SUFFIX OUT_DIR" >&2; exit 2; }
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$REPO"
SUF=$1; OUTD=$2
[[ "$SUF" =~ ^[A-Za-z0-9]+$ ]] || { echo 'Invalid REP_SUFFIX' >&2; exit 2; }
mkdir -p "$OUTD"; OUTD=$(readlink -f "$OUTD")
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
# ---- identical to sweeps/cbsg/run_cbsg_pinned_pass2.sh ----
export SYNOPSYS=${SYNOPSYS:-/usr/caen/synopsys-synth-2021.06-SP1}
export ZERO_PINLESS_NET_ACTIVITY=1
export USE_DW=1 NTFY_CHNL=
export TSMC22_CELL_TIER=sc7mcpp140z TSMC22_LIB_FLAVORS=svt_c30
export TSMC22_HPK_FLAVORS=svt_c30 TSMC22_HPK=1
export CORE_UTIL=0.70 CORE_ASPECT=1.000 PERIOD=2.5 INPUT_DELAY=1.25 OUTPUT_DELAY=0.05
export CLOCK_UNCERTAINTY=0.125 SC_DISTRIBUTION_GUIDES=1 SC_PLACE_GUIDES=0 SC_NH=8 SC_NW=8
export APR_OPT_POWER=0 APR_MULTIBIT_FLOP_OPT=0 APR_LEAN_OPT=0
unset NETLIST_FILE SDC_FILE SDF_FILE PRE_PLACE_SCRIPT POST_LOAD_SCRIPT
unset APR_ACTIVITY_FILE APR_ACTIVITY_SCOPE APR_POWER_ANALYSIS_VIEW
unset APR_WORKLOAD_POWER_OPT APR_LEAKAGE_TO_DYNAMIC_RATIO APR_DETAIL_WIRE_LENGTH_OPT_EFFORT
unset SC_DIST_HIER_PREFIX SC_TILE_HIER_PREFIX NO_SDF VCS_ARGS
PIN_SCRIPT=apr/scripts/cbsg/place_pins_and_guides_sc_cbsg.tcl
export SC_DISTRIBUTION_GUIDES=0 PRE_PLACE_SCRIPT=$PIN_SCRIPT SC_DIST_HIER_PREFIX=u_pe/u_array_core
unset SC_PIN_SPAN SC_PIN_LAYERS_H SC_PIN_LAYERS_V SC_PIN_TRACK_UM SC_PIN_MIN_PITCH_TRACKS
unset SC_PIN_SOUTH_CTRL_STEP_UM SC_PIN_PLAN_FILE SC_DIST_GUIDE_BAND SC_DIST_GUIDE_MARGIN SC_DIST_GUIDE_DENSITY
export SNPSLMD_QUEUE=true PYTHONDONTWRITEBYTECODE=1
source "$REPO/sweeps/cbsg/cbsg_campaign_lib.sh"
arm=af
cbsg_arm_config af
bootrun=${synrun}_distguide
run=${bootrun}_spp_pins_${SUF}
bootdir="$REPO/apr/build/$target/$bootrun"
boot_saif="$bootdir/activity/dut.saif"
finaldir="$REPO/apr/build/$target/$run"
[[ ! -e "$finaldir" ]] || { echo "Refusing existing $finaldir" >&2; exit 2; }
exec 9>"$OUTD/worker.lock"
flock -n 9 || { echo "Another worker owns $OUTD" >&2; exit 2; }
# The campaign route's inputs must be the ones replicated.
grep -Fxq "bootstrap_saif=$boot_saif sha256=$(sha256sum "$boot_saif" | cut -d' ' -f1)" \
    "$REPO/build/power_char/cbsg_20261005/af/pinned/inputs.txt"
grep -Fxq "pre_place_script=$PIN_SCRIPT sha256=$(sha256sum "$REPO/$PIN_SCRIPT" | cut -d' ' -f1)" \
    "$REPO/build/power_char/cbsg_20261005/af/pinned/inputs.txt"
printf 'replicate of %s\nrun=%s\nbootstrap_saif=%s sha256=%s\npin_script sha256=%s\nflow apr.tcl sha256=%s\n' \
    "apr/build/$target/${bootrun}_spp_pins" "$run" "$boot_saif" "$(sha256sum "$boot_saif" | cut -d' ' -f1)" \
    "$(sha256sum "$REPO/$PIN_SCRIPT" | cut -d' ' -f1)" "$(sha256sum "$ASTRAEA_FLOW/apr/scripts/apr.tcl" | cut -d' ' -f1)" \
    > "$OUTD/inputs.txt"
make_status=0
PRE_REPORT_SCRIPT=apr/scripts/check_popcount_placement.tcl \
APR_WORKLOAD_POWER_OPT=1 APR_ACTIVITY_FILE="$boot_saif" APR_ACTIVITY_SCOPE=Top/dut \
APR_LEAKAGE_TO_DYNAMIC_RATIO=0.0 APR_DETAIL_WIRE_LENGTH_OPT_EFFORT=high \
SYNTH_RUN="$synrun" RUN_NAME="$run" \
    make apr TARGET="$target" NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" > "$OUTD/apr_make.log" 2>&1 || make_status=$?
log="$finaldir/apr.log"
echo "make apr status=$make_status"
grep -Fq "Running PRE_PLACE_SCRIPT script: $REPO/$PIN_SCRIPT" "$log"
grep -E '^SC_PIN_PLACEMENT|^SC_DISTRIBUTION_GUIDES|#fixedPin=' "$log" | tee "$OUTD/pins_guides.txt"
grep -Eq '#fixedPin=1611, #floatPin=0\b' "$log"
grep -E 'markers_after_fix|strong reroute|optimization iteration|Total number of DRC violations = [0-9]+$|Verification Complete' "$log" \
    | tail -n 40 > "$OUTD/drc_trace.txt" || true
rc=0
python3 - "$REPO/sweeps/run_popcount_apr.sh" "$finaldir" "$top" final <<'PY' > "$OUTD/check_apr_final.log" 2>&1 || rc=$?
from pathlib import Path
import re,subprocess,sys
runner,path,top,qualification=sys.argv[1:]
blocks=re.findall(r"<<'PY'\n(.*?)\nPY",Path(runner).read_text(),re.S)
assert blocks and 'popcount_qualification.json' in blocks[0]
subprocess.run([sys.executable,'-c',blocks[0],path,top,qualification],check=True)
PY
echo "check_apr final rc=$rc"
tail -n 3 "$OUTD/check_apr_final.log"
exit "$rc"
