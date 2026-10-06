#!/bin/bash
# C-BSG copy of sweeps/run_pinned_pass2.sh (shared, unchanged): APR pass 2 with FIXED grid-matched IO pins for
# the two C-BSG variants of the carry-save array, AF and RG in parallel.  This is the headline route.
#   bash sweeps/cbsg/run_cbsg_pinned_pass2.sh                  # af and rg
#   bash sweeps/cbsg/run_cbsg_pinned_pass2.sh rg               # one arm
#   RETRY_FAILED=1 bash sweeps/cbsg/run_cbsg_pinned_pass2.sh   # retry failed stages
#   DRY_RUN=1 bash sweeps/cbsg/run_cbsg_pinned_pass2.sh        # preflight (pin plan + guides dry run on the
#                                                              # netlist, prerequisites) and print the stages
# Prerequisite per arm: bootstrap_audit of sweeps/cbsg/run_cbsg_apr.sh, i.e. the bootstrap route
# apr/build/<target>/<synth>_distguide with its audited GL SAIF as activity/dut.saif.
#
# Pass 2 is exactly run_cbsg_apr.sh's do_apr 'final' (= run_popcount_apr.sh's: same module versions, exports,
# PRE_REPORT_SCRIPT, workload power opt from the arm's own bootstrap SAIF, leakage ratio 0, detail wire-length
# effort high) except for the placement pre-script:
#   PRE_PLACE_SCRIPT=apr/scripts/cbsg/place_pins_and_guides_sc_cbsg.tcl, the C-BSG copy of the shared pin script
#   (header there): the unchanged shared distribution guides, then every top-level pin fixed to the 8x8 grid, with
#   the per-row stream length (AF a_len_in / RG row_len_in) on the EAST edge in its row band and block_start /
#   slice_start in the SOUTH control group; any unrecognised port is an error.
# As in the shared driver, SC_DISTRIBUTION_GUIDES=0 keeps the target from overriding PRE_PLACE_SCRIPT, and this
# driver exports SC_NH/SC_NW and SC_DIST_HIER_PREFIX itself.  The guide line it must reproduce is taken from the
# arm's bootstrap apr.log (same guide script, target branch on) and checked against the netlist's own counts;
# apr.log is checked for the pin plan line and GigaPlace's '#fixedPin=N, #floatPin=0'.
#
# Stages per arm (PASS markers, attempt logs; failed stages are preserved; RETRY_FAILED=1 resumes):
#   final_apr      make apr <bootstrap>_spp_pins
#   qualify        check_apr 'final'; if the only defects are residual geometry-DRC / antenna markers,
#                  sweeps/repair_popcount_apr.sh (targeted, in place), then check_apr again.  NOTE: that shared
#                  script's target list (its line 16) does not include the C-BSG targets; this stage stops with
#                  an explanation if a repair is needed and the list still refuses the target.
#   gate           basin QoR gate + pin proof (sweeps/cbsg/basin/run_basin_gate_cbsg.sh): AF runs the shared
#                  gate unchanged (corr(tile x, column) >= 0.8, mean |a-w skew| <= 50 ps at the product AND2s);
#                  RG replaces the skew with its closest equivalent, the W-magnitude vs threshold broadcast-
#                  network mismatch at the per-tile comparators over the netlist's zero-wire floor (derivation in
#                  sweeps/cbsg/basin/basin_skew_cbsg_pt.tcl).  A collapsed verdict is recorded, not hidden.
#   final_sim      full-timing max-SDF GL of the pinned route, uniform L=128 power bench (384 blocks, 3,072
#                  window clocks): bench PASS, trace header, bit-exact drain (sweeps/cbsg/<arm>/
#                  check_power_trace.py), SAIF validation, routed-SDF clock audit (raw routed SDF, no ideal-clock
#                  view; clock gates' CK->ECK checked against the period).
#   final_audit    sweeps/validate_routed_gl.py strict, then (only on a strict failure) the arm's opt-in
#                  approvals with a rationale file ($work/gl_validator_args_rationale.txt citing every flag);
#                  the audited SAIF becomes the route's activity/dut.saif.
#   power          make power_apr (PT-PX, routed SPEF, GL SAIF) + coverage audit
#   result         result.csv (headline: area, WNS, power, pJ/MAC, hierarchy, wire, basin, GL approvals)
#   ladder_sim     the same GL on the same routed netlist with the per-row ladder workload (AF CBSG_PWR_LADDER;
#                  RG ladder_rowmix, or RG_LADDER=rowgrouped), same checks; its SAIF stays in the campaign
#   ladder_audit   as final_audit (the route's activity file is NOT replaced)
#   ladder_power   make power_apr on a PT-only view apr/build/<target>/<pinned run>_pt_ladder (symlinks to the
#                  route's netlist, SPEF and SDC; the route's reports and activity are untouched) + coverage audit
#   ladder_result  ladder/result.csv (power, pJ per kernel MAC = P * window * 2.5 ns / (blocks * 512))
#   routed_func    the arm's bit-exact functional bench on the routed netlist with the raw routed SDF (strict
#                  audit): verifies that neither pre-layout workaround is needed after CTS.  AF: three golden cases
#                  each with +RESET_SETTLE=2 (must pass) and +RESET_SETTLE=0 (recorded: is the 2-edge settle still
#                  needed?); RG: three golden cases (its bench hard-codes the 2 idle edges, so settle 0 is not
#                  testable without a bench change; recorded as such).
# The headline stays uniform L=128.  After all arms: sweeps/cbsg/compare_cbsg_pinned.py writes results.csv and
# comparison.txt (vs the CSA pinned pass 2 of build/power_char/pinned_pass2_20261004/csa, read only).
# Outputs: build/power_char/cbsg_20261005/<arm>/pinned/ and build/power_char/cbsg_20261005/{results.csv,
# comparison.txt}.
set -Eeuo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$REPO"
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
CAMPAIGN=${CAMPAIGN:-cbsg_20261005}
RETRY_FAILED=${RETRY_FAILED:-0}
DRY_RUN=${DRY_RUN:-0}
[[ "$CAMPAIGN" =~ ^[A-Za-z0-9_]+$ ]] || { echo 'Invalid CAMPAIGN' >&2; exit 2; }
[[ "$RETRY_FAILED" == 0 || "$RETRY_FAILED" == 1 ]] || { echo 'RETRY_FAILED must be 0 or 1' >&2; exit 2; }
[[ "$DRY_RUN" == 0 || "$DRY_RUN" == 1 ]] || { echo 'DRY_RUN must be 0 or 1' >&2; exit 2; }
[[ -f "$ASTRAEA_FLOW/Makefile" ]] || { echo 'ASTRAEA Makefile missing' >&2; exit 2; }
ARMS=("$@")
((${#ARMS[@]})) || ARMS=(af rg)
declare -A SEEN=()
for arm in "${ARMS[@]}"; do
    case "$arm" in af|rg) ;; *) echo "Unknown arm: $arm" >&2; exit 2;; esac
    [[ ! -v SEEN[$arm] ]] || { echo "Repeated arm: $arm" >&2; exit 2; }
    SEEN[$arm]=1
done
OUT=${OUT:-$REPO/build/power_char/$CAMPAIGN}
[[ "$OUT" == /* ]] || OUT="$REPO/$OUT"
BOOT_OUT=$OUT           # where run_cbsg_apr.sh keeps <arm>/bootstrap (read only here)
if [[ "$DRY_RUN" == 1 ]]; then
    OUT=$(mktemp -d "${TMPDIR:-/tmp}/cbsg_pinned_dryrun.XXXXXX")
    echo "DRY_RUN: preflight only; scratch campaign directory $OUT"
fi
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
# ---- identical to sweeps/run_popcount_apr.sh ----
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
VCS_CMD='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
# ---- the only deviation from run_popcount_apr.sh's final pass: the pre-placement script ----
# CBSG_PIN_SCRIPT / CBSG_PINNED_SUFFIX (default: the campaign plan, no suffix) run a pinned VARIANT through the
# same stages: pin script <CBSG_PIN_SCRIPT>, route <bootstrap>_spp_pins_<suffix>, work dir <OUT>/<arm>/pinned_<suffix>.
PIN_SCRIPT=${CBSG_PIN_SCRIPT:-apr/scripts/cbsg/place_pins_and_guides_sc_cbsg.tcl}
PSUF=${CBSG_PINNED_SUFFIX:-}
[[ -z "$PSUF" || "$PSUF" =~ ^[A-Za-z0-9]+$ ]] || { echo 'Invalid CBSG_PINNED_SUFFIX' >&2; exit 2; }
[[ -z "$PSUF" || "$PIN_SCRIPT" != apr/scripts/cbsg/place_pins_and_guides_sc_cbsg.tcl || -n "${CBSG_ALLOW_SAME_SCRIPT:-}" ]] || \
    { echo 'A suffixed variant with the campaign pin script is a replicate; set CBSG_ALLOW_SAME_SCRIPT=1 to mean it' >&2; exit 2; }
[[ -f "$REPO/$PIN_SCRIPT" ]] || { echo "Missing $PIN_SCRIPT" >&2; exit 2; }
export SC_DISTRIBUTION_GUIDES=0 PRE_PLACE_SCRIPT=$PIN_SCRIPT SC_DIST_HIER_PREFIX=u_pe/u_array_core
unset SC_PIN_SPAN SC_PIN_LAYERS_H SC_PIN_LAYERS_V SC_PIN_TRACK_UM SC_PIN_MIN_PITCH_TRACKS
unset SC_PIN_SOUTH_CTRL_STEP_UM SC_PIN_PLAN_FILE SC_DIST_GUIDE_BAND SC_DIST_GUIDE_MARGIN SC_DIST_GUIDE_DENSITY
# ---- C-BSG additions (no effect on results) ----
export SNPSLMD_QUEUE=true PYTHONDONTWRITEBYTECODE=1   # wait for Synopsys licenses instead of failing
source "$REPO/sweeps/cbsg/cbsg_campaign_lib.sh"

stage() {
    local name=$1 artifact=$2
    shift 2
    local marker="$work/$name.status" attempt=1 log
    if [[ "$DRY_RUN" == 1 ]]; then
        echo "[$arm] DRY_RUN stage $name -> $artifact : $*"
        return
    fi
    if [[ -f "$marker" ]]; then
        [[ "$(cat "$marker")" == PASS && -e "$artifact" ]] || {
            echo "[$arm] Invalid completed stage: $name" >&2; return 1;
        }
        echo "[$arm] reuse completed $name"
        return
    fi
    while [[ -e "$work/$name.attempt_$attempt.log" ]]; do attempt=$((attempt+1)); done
    if [[ -e "$artifact" || "$attempt" -gt 1 ]]; then
        [[ "$RETRY_FAILED" == 1 ]] || {
            echo "[$arm] Unfinished $name preserved; inspect logs then use RETRY_FAILED=1 to retry" >&2
            return 1
        }
        if [[ -e "$artifact" ]]; then
            mv "$artifact" "${artifact}.failed_$(date +%Y%m%d_%H%M%S)_${BASHPID}"
        fi
    fi
    log="$work/$name.attempt_$attempt.log"
    echo "[$arm] $name started $(date -Is); $log"
    "$@" > "$log" 2>&1
    printf 'PASS\n' > "$marker"
    echo "[$arm] $name passed $(date -Is)"
}

# The exact qualification of run_popcount_apr.sh (its first python block),
# as sweeps/repair_popcount_apr.sh also uses it.
check_apr() {
    python3 - "$REPO/sweeps/run_popcount_apr.sh" "$1" "$top" "$2" <<'PY'
from pathlib import Path
import re,subprocess,sys
runner,path,top,qualification=sys.argv[1:]
blocks=re.findall(r"<<'PY'\n(.*?)\nPY",Path(runner).read_text(),re.S)
assert blocks and 'popcount_qualification.json' in blocks[0]
subprocess.run([sys.executable,'-c',blocks[0],path,top,qualification],check=True)
PY
}

do_apr() {
    local make_status=0 npins
    PRE_REPORT_SCRIPT=apr/scripts/check_popcount_placement.tcl \
    APR_WORKLOAD_POWER_OPT=1 APR_ACTIVITY_FILE="$boot_saif" APR_ACTIVITY_SCOPE=Top/dut \
    APR_LEAKAGE_TO_DYNAMIC_RATIO=0.0 APR_DETAIL_WIRE_LENGTH_OPT_EFFORT=high \
    SYNTH_RUN="$synrun" RUN_NAME="$finalrun" \
        make apr TARGET="$target" NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" || make_status=$?
    local log="$finaldir/apr.log"
    grep -q 'Enabling workload-aware dynamic-power optimization' "$log"
    grep -q 'leakageToDynamicRatio=0.0 detail_wirelength_effort=high' "$log"
    grep -Fq "INFO: activity_file=$boot_saif scope='Top/dut'" "$log"
    grep -Fq "Running PRE_PLACE_SCRIPT script: $REPO/$PIN_SCRIPT" "$log"
    grep -Fq "$guide_line" "$log"
    grep -q '^SC_PIN_PLACEMENT: fixed=' "$log"
    if grep -q '^ERROR: SC_PIN_PLACEMENT' "$log"; then echo 'pin script error' >&2; return 1; fi
    if grep -q '^WARNING: SC_PIN_PLACEMENT' "$log"; then echo 'pin script warning (unexpected for the C-BSG plan)' >&2; return 1; fi
    npins=$(awk '/^SC_PIN_PLACEMENT: fixed=/{sub(/^SC_PIN_PLACEMENT: fixed=/,""); print $1; exit}' "$log")
    [[ "$npins" == "$expected_pins" ]]
    grep -Eq "^SC_PIN_PLACEMENT: fixed=$npins .* len_bus=$len_bus LEN_W=8$" "$log"
    # GigaPlace (place_opt_design) must see every pin fixed and none floating.
    grep -Eq "#fixedPin=$npins, #floatPin=0\b" "$log"
    if grep -Eq '#floatPin=[1-9]' "$log"; then echo 'GigaPlace saw floating pins' >&2; return 1; fi
    grep -Eq 'Illegally Assigned Pins\s*:\s*0' "$log"
    cp -p "$finaldir/sc_pin_plan.tsv" "$finaldir/sc_pin_plan.checkPin.rpt" "$work/"
    grep -E '^SC_PIN_PLACEMENT|^SC_DISTRIBUTION_GUIDES|#fixedPin=' "$log"
    echo "make apr status=$make_status (qualification is decided by the qualify stage)"
    grep -q 'Innovus script finished' "$log"
}

do_qualify() {
    local repaired=0
    if check_apr "$finaldir" final; then
        echo "First completed route passes the strict final qualification."
    else
        echo "Strict final qualification failed; checking whether only residual DRC/antenna markers remain."
        check_apr "$finaldir" bootstrap
        python3 - "$finaldir/reports/popcount_qualification.json" <<'PY'
import json,sys
q=json.load(open(sys.argv[1]))
assert q['placement_overlapping_instances']==0 and not q['placement_late_overlap_warning'], f'placement overlaps; not a residual-marker repair case: {q}'
assert q['geometry_drc']>0 or q['antenna_violations']>0, f'no residual markers to repair: {q}'
print('Residual markers only (connectivity clean, timing met, placement legal):', json.dumps(q))
PY
        if ! cbsg_repair_accepts "$target"; then
            echo "sweeps/repair_popcount_apr.sh refuses $target: its target list ('case \"\$TARGET\" in ...', line 16)" \
                 "predates the C-BSG targets.  The route needs only the targeted residual-marker repair.  Adding" \
                 "TSMC22/PAYN_SC_CSA_CBSG_AF and TSMC22/PAYN_SC_CSA_CBSG_RG to that list is a one-line change to a" \
                 "shared script and needs the owner's approval; then rerun with RETRY_FAILED=1 (final_apr is reused)." >&2
            return 1
        fi
        cp -p "$finaldir/$top.geom.rpt" "$work/first_route_geom.rpt"
        cp -p "$finaldir/$top.antenna.rpt" "$work/first_route_antenna.rpt"
        REPAIR_MODE=targeted bash sweeps/repair_popcount_apr.sh "$target" "$finalrun" "$finalrun"
        check_apr "$finaldir" final
        repaired=1
    fi
    python3 - "$finaldir" "$work" "$repaired" <<'PY'
import json,sys,datetime
from pathlib import Path
route,work,repaired=Path(sys.argv[1]),Path(sys.argv[2]),int(sys.argv[3])
q=json.loads((route/'reports'/'popcount_qualification.json').read_text())
assert q['qualification']=='final'
q['targeted_repair']=bool(repaired)
if repaired:
    q['repair_plan']=json.loads((route/'repair_plan.json').read_text())
    q['original_route_archive']=[str(p) for p in sorted(route.glob('before_legalization_*'))]
q['utc']=datetime.datetime.now(datetime.timezone.utc).isoformat()
(work/'qualification.json').write_text(json.dumps(q,indent=2)+'\n')
print(json.dumps(q))
PY
}

do_gate() {
    local rc=0
    bash sweeps/cbsg/basin/run_basin_gate_cbsg.sh "$finaldir" "$top" "$work/basin" "${arm}_pinned" \
        "$work/sc_pin_plan.tsv" || rc=$?
    [[ "$rc" == 0 || "$rc" == 3 ]]
    python3 - "$work/basin/basin_gate.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1]))
print('basin', j['gate']['basin'], 'corr', round(j['corr_x_col'],3), 'skew_ps', round(j['abs_skew_mean_ps'],1),
      'skew_metric', j.get('skew_metric', 'and: shared gate metric'),
      'pin_proof', j['pin_proof']['status'], 'fixed', j['pin_proof']['fixed_in_def'], 'mismatches', j['pin_proof']['mismatches'])
PY
}

do_sim() {   # simdir workload
    cbsg_gl_sim "$finalrun" "$1" "$2"
}

do_audit() {   # simdir [install]
    cbsg_gl_audit "$1"
    [[ "${2:-}" != install ]] || cbsg_install_saif "$1" "$finaldir"
}

pt_reports_check() {   # run_dir
    [[ -s "$1/reports/power.rpt" && -s "$1/reports/saif_coverage.rpt" && -s "$1/reports/parasitics_coverage.rpt" ]]
    grep -q 'Report : Averaged Power' "$1/reports/power.rpt"
    python3 sweeps/validate_pt_power_coverage.py "$1/reports" \
        --power-log "$1/power_apr.log" --json "$1/reports/power_coverage.json"
}

do_power() {
    local saved="$work/power_result"
    mkdir -p "$saved/prior_reports"
    cp -p "$finaldir"/reports/*.rpt "$saved/prior_reports/"
    [[ ! -f "$finaldir/power_apr.log" ]] || cp -p "$finaldir/power_apr.log" "$saved/prior_power_apr.log"
    POWER_SAIF_VALIDATOR="$REPO/sweeps/validate_sc_power_saif.py" \
        make power_apr TARGET="$target" RUN="$finalrun" \
        SAIF="$finaldir/activity/dut.saif" SAIF_STRIP_PATH=Top/dut \
        NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW"
    pt_reports_check "$finaldir"
    cp -p "$finaldir/power_apr.log" "$finaldir/reports/power_coverage.json" "$saved/"
    cp -p "$finaldir"/reports/*.rpt "$saved/"
}

# The ladder SAIF is measured on the same routed netlist without touching the route: a PT-only view directory
# beside it holds symlinks to the route's netlist, SPEF and SDC (all apr/scripts/power.tcl reads), so make
# power_apr writes its SAIF snapshot, reports and log there.
do_ladder_power() {
    local view="$REPO/apr/build/$target/${finalrun}_pt_ladder" saved="$work/ladder/power_result" f
    local saif="$work/gl_ladder/$TB/dut.saif"
    [[ ! -e "$view" ]] || mv "$view" "${view}.failed_$(date +%Y%m%d_%H%M%S)_${BASHPID}"
    mkdir -p "$view/outputs" "$saved"
    ln -s "$finaldir/outputs/$top.apr.v" "$view/outputs/$top.apr.v"
    ln -s "$finaldir/outputs/$top.spef" "$view/outputs/$top.spef"
    ln -s "$finaldir/$top.syn.sdc" "$view/$top.syn.sdc"
    {
        echo "PT-only view of $finaldir for the ladder workload ($ladder_name), written by sweeps/cbsg/run_cbsg_pinned_pass2.sh"
        echo "ladder_power; the route's own reports and activity file are untouched."
        for f in "outputs/$top.apr.v" "outputs/$top.spef" "$top.syn.sdc"; do
            echo "$(sha256sum "$finaldir/$f" | cut -d' ' -f1)  $f"
        done
    } > "$view/VIEW_OF.txt"
    POWER_SAIF_VALIDATOR="$REPO/sweeps/validate_sc_power_saif.py" \
        make power_apr TARGET="$target" RUN="${finalrun}_pt_ladder" \
        SAIF="$saif" SAIF_STRIP_PATH=Top/dut NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW"
    pt_reports_check "$view"
    cmp -s "$saif" "$view/activity/dut.saif"
    cp -p "$view/power_apr.log" "$view/reports/power_coverage.json" "$view/VIEW_OF.txt" "$saved/"
    cp -p "$view"/reports/*.rpt "$saved/"
}

do_result() {   # uniform|ladder
    local wl=$1 dir="$work" sim="$work/gl_final"
    [[ "$wl" == uniform ]] || { dir="$work/ladder"; sim="$work/gl_ladder"; }
    python3 - "$arm" "$target" "$finalrun" "$finaldir" "$top" "$work" "$dir" "$sim" "$wl" "$rng_insts" <<'PY'
import csv,json,re,sys
from pathlib import Path
arm,target,run,dirname,top,work,dest,sim,wl,rng=sys.argv[1:]
work,dest,sim=Path(work),Path(dest),Path(sim); rng=rng.split()
p=dest/'power_result'; report=(p/'power.rpt').read_text()
def total(name):
    m=re.search(name+r'\s*=\s*([0-9.eE+-]+)',report); assert m,name; return float(m[1])*1e3
area=None
for line in (Path(dirname)/'reports'/'area.rpt').read_text().splitlines():
    f=line.split()
    if f and f[0]==top: area=float(f[2]); break
assert area is not None
# First-level hierarchical cells from cell_power.rpt (7 significant digits;
# power_hier.rpt prints 3).
hier={}
for line in (p/'cell_power.rpt').read_text().splitlines():
    m=re.match(r'^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+\(.*\)\s+h\s*$',line)
    if m and m[1] not in hier: hier[m[1]]=float(m[5])*1e3
assert {'u_pe','u_peripheral',*rng} <= set(hier), hier
q=json.loads((work/'qualification.json').read_text())
g=json.loads((work/'basin'/'basin_gate.json').read_text())
t=json.loads((sim/'timing_qualification.json').read_text())
assert t['status']=='PASS'
c=json.loads((sim/'trace_check.json').read_text())
a=json.loads((sim/'sdf_clock_audit.json').read_text())
window=c.get('window_edges',c.get('window_clocks')); blocks=c['blocks']
power=total('Total Power')
row=dict(arm=arm,target=target,run=run,workload=c['workload'],K=8,M=16,N=8,blocks=blocks,window_clocks=window,
         kernel_macs=blocks*512,mean_cycles_per_block=window/blocks,area_um2=area,
         setup_wns_ns=q['setup_wns_ns'],hold_wns_ns=q['hold_wns_ns'],
         power_mW=power,internal_mW=total('Cell Internal Power'),switching_mW=total('Net Switching Power'),
         leakage_mW=total('Cell Leakage Power'),pJ_MAC=power*window*2.5/(blocks*512),
         u_pe_mW=hier['u_pe'],u_peripheral_mW=hier['u_peripheral'],sobol_mW=sum(hier[k] for k in rng),
         rng_instances=' '.join(rng),
         other_top_children_mW=json.dumps({k:round(v,5) for k,v in hier.items() if k not in ('u_pe','u_peripheral',*rng)}),
         a_one_density=c.get('a_one_density',''),mean_kA=c.get('mean_kA',''),
         wire_mm=g['wire_mm'],corr_x_col=g['corr_x_col'],corr_y_negrow=g['corr_y_negrow'],d_col_um=g['d_col_um'],
         d_row_um=g['d_row_um'],tile_radius_um=g['tile_radius_um'],
         skew_metric=g.get('skew_metric','and: mean |w_arr - a_arr| at the product AND2s (shared gate metric)'),
         mean_abs_skew_ps=g['abs_skew_mean_ps'],p90_abs_skew_ps=g['abs_skew_p90_ps'],
         rg_raw_abs_skew_ps=g.get('raw_abs_skew_mean_ps',''),rg_floor_skew_ps=g.get('floor_skew_mean_ps',''),
         basin=g['gate']['basin'],pin_proof=g['pin_proof']['status'],
         pins_fixed=g['pin_proof']['fixed_in_def'],targeted_repair=q['targeted_repair'],
         gl_approved_ndi_clamps=len(t['approved_negative_iopath_clamps']),
         gl_approved_iwsba=len(t['approved_annotated_interconnects']),
         gl_sdf_warnings=json.dumps(t['sdf_warning_categories'],sort_keys=True),
         worst_icg_ck_eck_ns=a['worst_icg_iopath_ns'],
         geometry_drc=q['geometry_drc'],antenna_violations=q['antenna_violations'],
         placement_overlapping_instances=q['placement_overlapping_instances'],
         qualification=q['qualification'],status='PASS')
with (dest/'result.csv').open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=list(row)); w.writeheader(); w.writerow(row)
print(json.dumps(row,indent=2))
PY
}

# Bit-exact functional bench on the routed netlist with the raw routed SDF (no ideal-clock view): does the
# routed, clock-tree-synthesized design still need either pre-layout workaround?
do_routed_func() {
    local d="$work/routed_func" b="$work/routed_func/build" cases c s run
    local pass_pat settle_list results="$work/routed_func/runs.tsv" defs="+neg_tchk +sdfverbose"
    mkdir -p "$b/$ftb"
    if [[ "$arm" == af ]]; then
        pass_pat="PASS: CBSG AF bench"; settle_list="2 0"; defs="$defs +define+CBSG_RESET_SETTLE=2"
        echo "$CBSG_GOLDEN/plain_u128" > "$b/$ftb/cbsg_cases.txt"
        cases="plain_u128 chunked_rung calls_av257"
    else
        pass_pat="PASS: CBSG-RG bench"; settle_list="2"
        cases="plain_u128 calls_prot chunked_rung"
    fi
    for c in $cases; do [[ -d "$CBSG_GOLDEN/$c" ]] || { echo "missing golden case $CBSG_GOLDEN/$c" >&2; return 1; }; done
    make sim GL=apr TARGET="$target" RUN="$finalrun" TB="$ftb" BUILD_DIR="$b" \
        SDF_CORNER=max NO_SDF= RTL_PREFLIGHT_CMD=true VCS_ARGS="$defs" "VCS=$VCS_CMD" \
        NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" > "$b/compile.log" 2>&1
    [[ -x "$b/$ftb/simv" ]]
    grep -q 'sdf corner = max' "$b/compile.log"
    printf 'settle\tcase\tbench\taudit\tstatus\n' > "$results"
    for s in $settle_list; do
        for c in $cases; do
            run="$d/settle${s}_$c"; mkdir -p "$run"
            if [[ "$arm" == af ]]; then
                (cd "$run" && "$b/$ftb/simv" +vcs+lic+wait "+CASES=$CBSG_GOLDEN/$c" "+RESET_SETTLE=$s" > run.log 2>&1) || true
            else
                (cd "$run" && "$b/$ftb/simv" +vcs+lic+wait "+CASE=$CBSG_GOLDEN/$c" > run.log 2>&1) || true
            fi
            # The validator input: the compile log up to its own run (command line, corner) + this run's log.
            { sed '/Running gate-level simulation/q' "$b/compile.log"; cat "$run/run.log"; } > "$run/simulation.log"
            local bench=FAIL audit=FAIL
            if grep -q "^$pass_pat" "$run/run.log" && ! grep -qE 'Error-\[|\$fatal|\[TIMEOUT\]' "$run/run.log"; then bench=PASS; fi
            if cbsg_gl_audit "$run" "$pass_pat" > "$run/audit.log" 2>&1; then audit=PASS; fi
            local st=FAIL; [[ "$bench" == PASS && "$audit" == PASS ]] && st=PASS
            printf '%s\t%s\t%s\t%s\t%s\n' "$s" "$c" "$bench" "$audit" "$st" >> "$results"
        done
    done
    cat "$results"
    python3 - "$results" "$arm" "$work/gl_final/sdf_clock_audit.json" "$d/summary.json" <<'PY'
import csv,json,sys
rows=list(csv.DictReader(open(sys.argv[1]),delimiter='\t')); arm=sys.argv[2]
icg=json.load(open(sys.argv[3]))
ok=lambda s: all(r['status']=='PASS' for r in rows if r['settle']==s)
out=dict(arm=arm, runs=rows,
         ideal_clock_view_needed=not (icg['status']=='PASS' and ok('2')),
         worst_icg_ck_eck_ns=icg['worst_icg_iopath_ns'], icg_cells=icg['icg_cells'])
if arm=='af':
    out['reset_settle_needed']=(not ok('0'))
    out['note']='settle 0 = first load on the first edge after reset (the RTL suite\'s tightest schedule)'
else:
    out['reset_settle_needed']='not testable: test_payn_array_cbsg_rg.sv and power_payn_array_cbsg_rg.sv hard-code 2 idle edges'
json.dump(out,open(sys.argv[4],'w'),indent=2)
print(json.dumps({k:v for k,v in out.items() if k!='runs'}))
assert ok('2'), 'routed functional runs failed at the standard 2-edge settle'
PY
}

run_arm() (
    local arm=$1 target top synrun TB trace_name checker rng_insts ftb ladder_def ladder_name ladder_wl glargs
    local bootrun finalrun syndir bootdir finaldir boot_saif guide_line expected_guides expected_pins len_bus
    local current_stage=initialization
    local work="$OUT/$arm/pinned${PSUF:+_$PSUF}"
    cbsg_arm_config "$arm"
    [[ "$arm" == af ]] && len_bus=a_len_in || len_bus=row_len_in
    bootrun=${synrun}_distguide
    finalrun=${bootrun}_spp_pins${PSUF:+_$PSUF}
    syndir="$REPO/syn/build/$target/$synrun"
    bootdir="$REPO/apr/build/$target/$bootrun"
    finaldir="$REPO/apr/build/$target/$finalrun"
    boot_saif="$bootdir/activity/dut.saif"
    mkdir -p "$work"
    exec 9>"$work/worker.lock"
    flock -n 9 || { echo "[$arm] Another worker owns this run" >&2; exit 2; }
    trap 'rc=$?; printf "FAILED stage=%s exit=%s time=%s\n" "$current_stage" "$rc" "$(date -Is)" >> "$work/failures.log"; exit "$rc"' ERR
    [[ -s "$syndir/$top.syn.v" && -s "$syndir/$top.syn.sdc" ]]
    # The guide line the shared guide script must print for this netlist (same computation as run_cbsg_apr.sh).
    expected_guides=$(python3 - "$syndir/$top.syn.v" <<'PY'
import re,sys
s=open(sys.argv[1]).read()
mods={m[1]:s[m.start():s.index('endmodule',m.start())] for m in re.finditer(r'^\s*module\s+(\S+)\s*\(',s,re.M)}
def inst(body): return [m[2].lstrip('\\') for m in re.finditer(r'^\s*(\S+)\s+(\\\S+|\S+)\s*\(\s*\.',body,re.M)]
def child(body,name):
    for m in re.finditer(r'^\s*(\S+)\s+(\S+)\s*\(\s*\.',body,re.M):
        if m[2]==name: return m[1]
top=[k for k in mods if re.search(r'^\s*\S+\s+u_pe\s*\(',mods[k],re.M)][0]
core=inst(mods[child(mods[child(mods[top],'u_pe')],'u_array_core')])
cnt=lambda stems,i: sum(1 for c in core if any(c.startswith(f'{st}_reg_{i}__') for st in stems))
a=sum(cnt(('a_bits_pipe','a_signs_pipe'),h) for h in range(8))
w=sum(cnt(('w_bits_pipe','w_encoded_pipe','w_signs_pipe'),v) for v in range(8))
k=sum(cnt(('w_keep_pipe',),v) for v in range(8))
print(f'SC_DISTRIBUTION_GUIDES: nh=8 nw=8 band=0.55 density=0.72 a_cells={a} w_cells={w} w_keep={k}')
PY
)
    expected_pins=$(python3 - "$syndir/$top.syn.v" "$top" <<'PY'
import re,sys
s=open(sys.argv[1]).read()
start=re.search(r'^module\s+'+re.escape(sys.argv[2])+r'\b',s,re.M).start()
body=s[start:s.index('endmodule',start)]
n=0
for d in re.finditer(r'^\s*(input|output|inout)\s*(\[(\d+):(\d+)\])?\s*([^;]+);', body, re.M):
    w=abs(int(d[3])-int(d[4]))+1 if d[2] else 1
    n+=w*len([x for x in d[5].split(',') if x.strip()])
print(n)
PY
)
    local missing=""
    [[ -s "$boot_saif" ]] || missing="$missing bootstrap SAIF $boot_saif;"
    [[ -s "$bootdir/apr.log" ]] || missing="$missing bootstrap apr.log $bootdir/apr.log;"
    [[ -f "$BOOT_OUT/$arm/bootstrap/bootstrap_audit.status" ]] || missing="$missing $BOOT_OUT/$arm/bootstrap/bootstrap_audit.status;"
    guide_line=""
    [[ ! -s "$bootdir/apr.log" ]] || guide_line=$(awk '/^SC_DISTRIBUTION_GUIDES:/{print; exit}' "$bootdir/apr.log")
    if [[ "$DRY_RUN" == 1 ]]; then
        echo "[$arm] DRY_RUN expected pins $expected_pins, expected guide line: $expected_guides"
        [[ -z "$missing" ]] || echo "[$arm] DRY_RUN prerequisites not there yet (run sweeps/cbsg/run_cbsg_apr.sh $arm through bootstrap_audit):$missing"
        [[ -z "$guide_line" ]] || echo "[$arm] DRY_RUN bootstrap guide line: $guide_line"
        [[ -n "$guide_line" ]] || guide_line=$expected_guides
    else
        [[ -z "$missing" ]] || { echo "[$arm] missing prerequisites (run sweeps/cbsg/run_cbsg_apr.sh $arm through bootstrap_audit):$missing" >&2; exit 2; }
    fi
    [[ -n "$guide_line" && "$guide_line" == "$expected_guides" ]] || {
        echo "[$arm] bootstrap guide line '$guide_line' != netlist prediction '$expected_guides'" >&2; exit 2; }
    [[ "$expected_pins" == 1611 ]] || { echo "[$arm] unexpected port count $expected_pins (C-BSG tops have 1611)" >&2; exit 2; }
    cbsg_repair_accepts "$target" || echo "[$arm] WARNING: sweeps/repair_popcount_apr.sh does not list $target; a route that needs the targeted residual-marker repair will stop at the qualify stage (see its message)."
    local boot_sha="(not yet)"
    [[ ! -s "$boot_saif" ]] || boot_sha=$(sha256sum "$boot_saif" | cut -d' ' -f1)
    local manifest
    manifest=$(printf 'target=%s\ntop=%s\nsynthesis=%s netlist sha256=%s\nbootstrap_route=%s\nbootstrap_saif=%s sha256=%s\nfinal_route=%s\nflow=%s apr.tcl sha256=%s\npre_place_script=%s sha256=%s\nguide_script sha256=%s\nexpected_pins=%s len_bus=%s\nguides=%s\nbench=%s sha256=%s\nfunctional_bench=%s sha256=%s\nladder=%s %s\nK=8 M=16 NH=8 NW=8 OWIDTH=24 LOW_W=9 T=128 batches=%s period=2.5 input_delay=1.25 uncertainty=0.125 core_util=0.70 HPK=1 APR_OPT_POWER=0 APR_MULTIBIT_FLOP_OPT=0 APR_LEAN_OPT=0 workload_power_opt=1 leakage_ratio=0.0 wirelength_effort=high SC_DISTRIBUTION_GUIDES=0(target branch off; guides sourced by the pin script)\nglargs=%s\n' \
        "$target" "$top" "$syndir" "$(sha256sum "$syndir/$top.syn.v" | cut -d' ' -f1)" "$bootdir" "$boot_saif" "$boot_sha" \
        "$finaldir" "$ASTRAEA_FLOW" "$(sha256sum "$ASTRAEA_FLOW/apr/scripts/apr.tcl" | cut -d' ' -f1)" \
        "$PIN_SCRIPT" "$(sha256sum "$REPO/$PIN_SCRIPT" | cut -d' ' -f1)" \
        "$(sha256sum "$REPO/apr/scripts/place_guides_sc_distribution.tcl" | cut -d' ' -f1)" \
        "$expected_pins" "$len_bus" "$guide_line" "$TB" "$(sha256sum "$REPO/$TB" | cut -d' ' -f1)" \
        "$ftb" "$(sha256sum "$REPO/$ftb" | cut -d' ' -f1)" "$ladder_name" "$ladder_def" "$CBSG_BATCHES" "$glargs")
    if [[ -e "$work/inputs.txt" ]]; then
        [[ "$(cat "$work/inputs.txt")" == "$manifest" ]] || { echo "[$arm] inputs changed; see $work/inputs.txt" >&2; exit 2; }
    else
        printf '%s\n' "$manifest" > "$work/inputs.txt"
    fi
    if [[ "$DRY_RUN" == 1 ]]; then
        echo "[$arm] DRY_RUN manifest:"; sed 's/^/    /' "$work/inputs.txt"
        (SYNTH_RUN="$synrun"; set +u; . "$REPO/apr/targets/$target"
         echo "[$arm] DRY_RUN target: TOP=$TOP PRE_PLACE_SCRIPT=$PRE_PLACE_SCRIPT SC_DIST_HIER_PREFIX=$SC_DIST_HIER_PREFIX SC_NH=$SC_NH SC_NW=$SC_NW SC_DISTRIBUTION_GUIDES=$SC_DISTRIBUTION_GUIDES"
         [[ "$TOP" == "$top" && "$PRE_PLACE_SCRIPT" == "$PIN_SCRIPT" ]])
        [[ ! -d "$finaldir" ]] || echo "[$arm] DRY_RUN note: $finaldir already exists (final_apr would refuse it without RETRY_FAILED=1)"
        # The first stage's pre-placement Tcl, run on the real port list and instance names.
        bash "$REPO/sweeps/cbsg/pin_dryrun/run_pin_dryrun.sh" "$arm" pins "$OUT/$arm/pin_dryrun_pins" | grep -E '^(SC_DISTRIBUTION_GUIDES|SC_PIN_PLACEMENT|PIN_DRYRUN)' | cut -c1-400
        grep -qxF "$guide_line" "$OUT/$arm/pin_dryrun_pins/dryrun.log"
        grep -Eq "^SC_PIN_PLACEMENT: fixed=$expected_pins .* len_bus=$len_bus LEN_W=8$" "$OUT/$arm/pin_dryrun_pins/dryrun.log"
        echo "[$arm] DRY_RUN first stage command (final_apr):"
        echo "    PRE_REPORT_SCRIPT=apr/scripts/check_popcount_placement.tcl APR_WORKLOAD_POWER_OPT=1 APR_ACTIVITY_FILE=$boot_saif APR_ACTIVITY_SCOPE=Top/dut APR_LEAKAGE_TO_DYNAMIC_RATIO=0.0 APR_DETAIL_WIRE_LENGTH_OPT_EFFORT=high SYNTH_RUN=$synrun RUN_NAME=$finalrun make apr TARGET=$target NTFY_CHNL= ASTRAEA_FLOW=$ASTRAEA_FLOW"
        echo "    (env: PRE_PLACE_SCRIPT=$PRE_PLACE_SCRIPT SC_DISTRIBUTION_GUIDES=$SC_DISTRIBUTION_GUIDES SC_DIST_HIER_PREFIX=$SC_DIST_HIER_PREFIX SC_NH=$SC_NH SC_NW=$SC_NW CORE_UTIL=$CORE_UTIL PERIOD=$PERIOD CLOCK_UNCERTAINTY=$CLOCK_UNCERTAINTY)"
        echo "[$arm] DRY_RUN GL approvals for this arm: '$(cbsg_approvals)' (used only after a strict audit failure, with $work/gl_validator_args_rationale.txt)"
    fi
    current_stage=final_apr;     stage "$current_stage" "$finaldir" do_apr
    current_stage=qualify;       stage "$current_stage" "$work/qualification.json" do_qualify
    current_stage=gate;          stage "$current_stage" "$work/basin/basin_gate.json" do_gate
    current_stage=final_sim;     stage "$current_stage" "$work/gl_final" do_sim "$work/gl_final" uniform
    current_stage=final_audit;   stage "$current_stage" "$work/gl_final/timing_qualification.json" do_audit "$work/gl_final" install
    current_stage=power;         stage "$current_stage" "$work/power_result" do_power
    current_stage=result;        stage "$current_stage" "$work/result.csv" do_result uniform
    current_stage=ladder_sim;    stage "$current_stage" "$work/gl_ladder" do_sim "$work/gl_ladder" ladder
    current_stage=ladder_audit;  stage "$current_stage" "$work/gl_ladder/timing_qualification.json" do_audit "$work/gl_ladder"
    current_stage=ladder_power;  stage "$current_stage" "$work/ladder/power_result" do_ladder_power
    current_stage=ladder_result; stage "$current_stage" "$work/ladder/result.csv" do_result ladder
    current_stage=routed_func;   stage "$current_stage" "$work/routed_func/summary.json" do_routed_func
    echo "[$arm] complete: $work/result.csv (uniform headline), $work/ladder/result.csv ($ladder_name)"
)

mkdir -p "$OUT"
pids=()
for arm in "${ARMS[@]}"; do run_arm "$arm" & pids+=("$!"); done
status=0
for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then :; else
        echo "[${ARMS[$i]}] Failed; inspect $OUT/${ARMS[$i]}/pinned/failures.log and stage logs" >&2
        status=1
    fi
done
if [[ "$DRY_RUN" == 1 ]]; then
    echo "DRY_RUN finished (status $status); scratch directory $OUT"
else
    python3 sweeps/cbsg/compare_cbsg_pinned.py "$OUT" || status=1
fi
exit "$status"
