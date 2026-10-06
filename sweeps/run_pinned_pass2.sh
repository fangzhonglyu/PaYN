#!/bin/bash
# APR pass 2 with FIXED grid-matched IO pins, BP and CSA control in parallel.
#   bash sweeps/run_pinned_pass2.sh                 # csa_bp and csa
#   bash sweeps/run_pinned_pass2.sh csa_bp          # one arm
#   RETRY_FAILED=1 bash sweeps/run_pinned_pass2.sh  # retry failed stages
#   bash sweeps/run_pinned_pass2.sh csa_bp_lap      # per-PE lap-enable BP netlist
#
# Arm csa_bp_lap (2026-10-04): the same recipe on the bit-plane netlist with the
# per-PE lap enable (synthesis BP_LAP_SYNTH_RUN, default csa_bp_20261004_lap),
# seeded by its own bootstrap route <synth>_distguide from
#   BP_SYNTH_RUN=<synth> CAMPAIGN=<synth> bash sweeps/run_popcount_apr.sh csa_bp
# It runs alone (no mixing with csa / csa_bp) into its own campaign directory,
# default build/power_char/pinned_pass2_<synth> (an OUT naming the 20261004
# campaign is refused, so that campaign is never touched), takes the guide line
# it must reproduce from its bootstrap route's apr.log (same guide script, same
# target branch; the csa / csa_bp arms keep reading their floating-pin final's),
# and ends with sweeps/int_mode/bp/compare_pinned_lap.py, which compares it with
# the csa_bp and csa pinned finals of build/power_char/pinned_pass2_20261004
# (read only) instead of compare.py.
#
# Pass 2 is exactly run_popcount_apr.sh do_apr 'final' (same module versions,
# exports, PRE_REPORT_SCRIPT, workload power opt from the arm's own bootstrap
# SAIF, leakage ratio 0, detail wire-length effort high) except for the
# placement pre-script:
#   PRE_PLACE_SCRIPT=apr/scripts/place_pins_and_guides_sc.tcl, which sources
#   the unchanged distribution guides and then fixes every top-level pin to
#   the 8x8 grid (A/raw-A/acc_out_east on E by row, W/raw-W on N by column,
#   acc_in_west on W by row, control/int_out on S).
# The target files export PRE_PLACE_SCRIPT=place_guides_sc_distribution.tcl
# whenever SC_DISTRIBUTION_GUIDES=1 and would override it, so this driver sets
# SC_DISTRIBUTION_GUIDES=0 and exports PRE_PLACE_SCRIPT, SC_NH/SC_NW and
# SC_DIST_HIER_PREFIX (the values the target would have exported) itself.
# apr.log is checked for the guide line (same cell counts as the earlier
# finals), the pin plan line and GigaPlace's '#fixedPin=N, #floatPin=0'.
#
# Stages per arm (PASS markers, attempt logs; failed stages are preserved):
#   final_apr   make apr (new run <bootstrap>_spp_pins)
#   qualify     run_popcount_apr.sh check_apr 'final'; if the only defects are
#               residual geometry-DRC / antenna markers, sweeps/
#               repair_popcount_apr.sh (targeted, in place: the original route
#               is archived under before_legalization_*), then check_apr again
#   gate        basin QoR gate (corr(tile x, column) >= 0.8, mean |a-w skew|
#               <= 50 ps) plus proof that every pin in the final DEF is FIXED
#               at its planned layer/location. A collapsed verdict is recorded,
#               not hidden; GL and power still run so the layout is measured.
#   final_sim   full-timing max-SDF GL (+neg_tchk +sdfverbose, PAYN_INT_PORTS
#               for BP), routed-GL audit, streaming cosim, SAIF validation.
#               The audit runs strictly first; only if that fails is the arm's
#               previously justified approval set applied (GL_VALIDATOR_ARGS
#               overrides it); every approval used is listed in
#               timing_qualification.json and gl_validator_args.txt and must be
#               reviewed before the result is quoted.
#   power       make power_apr (PT-PX, routed SPEF, GL SAIF) + coverage audit
#   result      result.csv row (area, WNS, power, pJ/MAC, hierarchy, wire, basin)
# Outputs: build/power_char/pinned_pass2_20261004/<arm>/, results.csv and
# comparison.txt (against the earlier floating-pin finals) at the top.
set -Eeuo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
BASE_TAG=pinned_pass2_20261004
BP_LAP_SYNTH_RUN=${BP_LAP_SYNTH_RUN:-csa_bp_20261004_lap}
[[ "$BP_LAP_SYNTH_RUN" =~ ^[A-Za-z0-9_]+$ ]] || { echo 'Invalid BP_LAP_SYNTH_RUN' >&2; exit 2; }
RETRY_FAILED=${RETRY_FAILED:-0}
[[ "$RETRY_FAILED" == 0 || "$RETRY_FAILED" == 1 ]] || { echo 'RETRY_FAILED must be 0 or 1' >&2; exit 2; }
[[ -f "$ASTRAEA_FLOW/Makefile" ]] || { echo 'ASTRAEA Makefile missing' >&2; exit 2; }
ARMS=("$@")
((${#ARMS[@]})) || ARMS=(csa_bp csa)
LAP_ONLY=0
for arm in "${ARMS[@]}"; do
    case "$arm" in csa|csa_bp) ;; csa_bp_lap) LAP_ONLY=1;; *) echo "Unknown arm: $arm" >&2; exit 2;; esac
done
if [[ "$LAP_ONLY" == 1 ]]; then
    [[ "${#ARMS[@]}" == 1 ]] || { echo 'csa_bp_lap runs alone (its own campaign directory)' >&2; exit 2; }
    TAG=pinned_pass2_$BP_LAP_SYNTH_RUN
else
    TAG=$BASE_TAG
fi
OUT=${OUT:-$REPO/build/power_char/$TAG}
[[ "$OUT" == /* ]] || OUT="$REPO/$OUT"
if [[ "$LAP_ONLY" == 1 && "$(realpath -m "$OUT")" == "$(realpath -m "$REPO/build/power_char/$BASE_TAG")" ]]; then
    echo "csa_bp_lap must not write into the $BASE_TAG campaign; choose another OUT" >&2; exit 2
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
TB=designs/payn/power/power_payn_array.sv
VCS_CMD='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
# ---- the only deviation: the pre-placement script ----
PIN_SCRIPT=apr/scripts/place_pins_and_guides_sc.tcl
export SC_DISTRIBUTION_GUIDES=0 PRE_PLACE_SCRIPT=$PIN_SCRIPT SC_DIST_HIER_PREFIX=u_pe/u_array_core
unset SC_PIN_SPAN SC_PIN_LAYERS_H SC_PIN_LAYERS_V SC_PIN_TRACK_UM SC_PIN_MIN_PITCH_TRACKS
unset SC_PIN_SOUTH_CTRL_STEP_UM SC_PIN_PLAN_FILE SC_DIST_GUIDE_BAND SC_DIST_GUIDE_MARGIN SC_DIST_GUIDE_DENSITY

stage() {
    local name=$1 artifact=$2
    shift 2
    local marker="$work/$name.status" attempt=1 log
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
    npins=$(awk '/^SC_PIN_PLACEMENT: fixed=/{sub(/^SC_PIN_PLACEMENT: fixed=/,""); print $1; exit}' "$log")
    [[ "$npins" == "$expected_pins" ]]
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
    bash sweeps/pinned_pass2/run_basin_gate.sh "$finaldir" "$top" "$work/basin" "${arm}_pinned" \
        "$work/sc_pin_plan.tsv" || rc=$?
    [[ "$rc" == 0 || "$rc" == 3 ]]
    python3 - "$work/basin/basin_gate.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1]))
print('basin', j['gate']['basin'], 'corr', round(j['corr_x_col'],3), 'skew_ps', round(j['abs_skew_mean_ps'],1),
      'pin_proof', j['pin_proof']['status'], 'fixed', j['pin_proof']['fixed_in_def'], 'mismatches', j['pin_proof']['mismatches'])
PY
}

do_sim() {
    local simdir="$work/gl_final" pass strict=PASS
    pass="PASS: streaming SC SAIF captured; $batches batches x $mac_cycles cycles"
    mkdir -p "$simdir"
    make sim GL=apr TARGET="$target" RUN="$finalrun" TB="$TB" BUILD_DIR="$simdir" \
        SDF_CORNER=max NO_SDF= RTL_PREFLIGHT_CMD=true VCS_ARGS="$glargs" "VCS=$VCS_CMD" \
        NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" > "$simdir/simulation.log" 2>&1
    grep -Fq "$pass" "$simdir/simulation.log"
    grep -q 'sdf corner = max' "$simdir/simulation.log"
    grep -Fq '[INFO] $sdf_annotate(' "$simdir/simulation.log"
    # Strict audit first: no approvals.
    python3 sweeps/validate_routed_gl.py "$simdir/simulation.log" --expected-pass "$pass" \
        --json "$simdir/timing_qualification_strict.json" > "$simdir/timing_validation_strict.log" 2>&1 || strict=FAIL
    local used=""
    if [[ "$strict" == PASS ]]; then
        cp -p "$simdir/timing_qualification_strict.json" "$simdir/timing_qualification.json"
    else
        used=${GL_VALIDATOR_ARGS:-$approval_args}
        # shellcheck disable=SC2086
        python3 sweeps/validate_routed_gl.py "$simdir/simulation.log" --expected-pass "$pass" $used \
            --json "$simdir/timing_qualification.json" > "$simdir/timing_validation.log" 2>&1
    fi
    python3 - "$simdir" "$strict" "$used" >> "$work/gl_validator_args.txt" <<'PY'
import json,sys,datetime
simdir,strict,used=sys.argv[1:]
s=json.load(open(f'{simdir}/timing_qualification_strict.json'))
q=json.load(open(f'{simdir}/timing_qualification.json'))
print(f"{datetime.datetime.now().isoformat(timespec='seconds')} strict={strict} strict_reasons={s['rejection_reasons']} "
      f"approvals_used='{used}' sdf_warnings={q['sdf_warning_categories']} "
      f"ndi_clamps={len(q['approved_negative_iopath_clamps'])} "
      f"worst_clamp_ps={min([c['most_negative_ps'] for c in q['approved_negative_iopath_clamps']] or [0])} "
      f"iwsba={len(q['approved_annotated_interconnects'])} post_reset_violations={q['post_reset_timing_violations']} status={q['status']}")
PY
    tail -n 1 "$work/gl_validator_args.txt"
    local trace="$simdir/$TB/array_streaming_rtl.txt" saif="$simdir/$TB/dut.saif"
    [[ -s "$trace" && -s "$saif" ]]
    [[ "$(head -n 1 "$trace")" == "STREAMCFG $K $M $N $N 8 24 128 $batches 0" ]]
    python3 designs/payn/cosim/cosim_streaming.py "$trace" > "$simdir/cosim.log" 2>&1
    grep -q '\[PASS\]' "$simdir/cosim.log"
    python3 sweeps/validate_sc_power_saif.py "$saif" --expected-period-ns 2.5 \
        > "$simdir/saif_validation.log" 2>&1
    mkdir -p "$finaldir/activity"
    [[ ! -e "$finaldir/activity/dut.saif" ]] || \
        cp -p "$finaldir/activity/dut.saif" "$simdir/previous_route_activity.saif"
    cp "$saif" "$finaldir/activity/dut.saif"
    cat "$simdir/cosim.log" "$simdir/saif_validation.log"
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
    [[ -s "$finaldir/reports/power.rpt" && -s "$finaldir/reports/saif_coverage.rpt" \
        && -s "$finaldir/reports/parasitics_coverage.rpt" ]]
    grep -q 'Report : Averaged Power' "$finaldir/reports/power.rpt"
    python3 sweeps/validate_pt_power_coverage.py "$finaldir/reports" \
        --power-log "$finaldir/power_apr.log" --json "$finaldir/reports/power_coverage.json"
    cp -p "$finaldir/power_apr.log" "$finaldir/reports/power_coverage.json" "$saved/"
    cp -p "$finaldir"/reports/*.rpt "$saved/"
}

do_result() {
    python3 - "$arm" "$target" "$finalrun" "$finaldir" "$top" "$work" "$K" "$M" "$N" <<'PY'
import csv,json,re,sys
from pathlib import Path
arm,target,run,dirname,top,work,K,M,N=sys.argv[1:]
K,M,N=int(K),int(M),int(N); work=Path(work)
mac_per_cycle=K*M*N*N/128
p=work/'power_result'; report=(p/'power.rpt').read_text()
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
assert {'u_pe','u_peripheral','u_a_rng','u_w_rng'} <= set(hier), hier
q=json.loads((work/'qualification.json').read_text())
g=json.loads((work/'basin'/'basin_gate.json').read_text())
t=json.loads((work/'gl_final'/'timing_qualification.json').read_text())
assert t['status']=='PASS'
power=total('Total Power')
row=dict(arm=arm,target=target,run=run,K=K,M=M,N=N,T=128,area_um2=area,
         setup_wns_ns=q['setup_wns_ns'],hold_wns_ns=q['hold_wns_ns'],
         power_mW=power,internal_mW=total('Cell Internal Power'),switching_mW=total('Net Switching Power'),
         leakage_mW=total('Cell Leakage Power'),pJ_MAC=power*2.5/mac_per_cycle,
         u_pe_mW=hier['u_pe'],u_peripheral_mW=hier['u_peripheral'],sobol_mW=hier['u_a_rng']+hier['u_w_rng'],
         other_top_children_mW=json.dumps({k:round(v,5) for k,v in hier.items() if k not in ('u_pe','u_peripheral','u_a_rng','u_w_rng')}),
         wire_mm=g['wire_mm'],corr_x_col=g['corr_x_col'],corr_y_negrow=g['corr_y_negrow'],d_col_um=g['d_col_um'],
         d_row_um=g['d_row_um'],tile_radius_um=g['tile_radius_um'],mean_abs_aw_skew_ps=g['abs_skew_mean_ps'],
         p90_abs_aw_skew_ps=g['abs_skew_p90_ps'],basin=g['gate']['basin'],pin_proof=g['pin_proof']['status'],
         pins_fixed=g['pin_proof']['fixed_in_def'],targeted_repair=q['targeted_repair'],
         gl_approved_ndi_clamps=len(t['approved_negative_iopath_clamps']),
         gl_approved_iwsba=len(t['approved_annotated_interconnects']),
         gl_sdf_warnings=json.dumps(t['sdf_warning_categories'],sort_keys=True),
         geometry_drc=q['geometry_drc'],antenna_violations=q['antenna_violations'],
         placement_overlapping_instances=q['placement_overlapping_instances'],
         qualification=q['qualification'],status='PASS')
with (work/'result.csv').open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=list(row)); w.writeheader(); w.writerow(row)
print(json.dumps(row,indent=2))
PY
}

run_arm() (
    local arm=$1 target top synrun bootrun finalrun syndir bootdir finaldir boot_saif glargs
    local approval_args guide_line expected_pins current_stage=initialization
    local work="$OUT/$arm" K=8 M=16 N=8 mac_cycles batches intports=""
    case "$arm" in
        csa_bp) target=TSMC22/PAYN_SC_CSA_BP; top=payn_array_signed_segmented_csa_bp
                synrun=csa_bp_20261003b; intports="+define+PAYN_INT_PORTS"
                # gl_validator_args_rationale.txt of popcount_apr_csa_bp_20261003
                approval_args="--approve-annotated-interconnect --approve-negative-iopath-clamp-ps 12";;
        csa)    target=TSMC22/PAYN_SC_CSA; top=payn_array_signed_segmented_csa
                synrun=csa_20261002
                # gl_validator_args_rationale.txt of popcount_apr_20261002/csa
                approval_args="--approve-negative-iopath-clamp-ps 10";;
        csa_bp_lap)
                target=TSMC22/PAYN_SC_CSA_BP; top=payn_array_signed_segmented_csa_bp
                synrun=$BP_LAP_SYNTH_RUN; intports="+define+PAYN_INT_PORTS"
                # Candidates only (applied after a strict-audit failure): the BP
                # set, justified for this netlist's routes in
                # popcount_apr_<synth>/gl_validator_args_rationale.txt.
                approval_args="--approve-annotated-interconnect --approve-negative-iopath-clamp-ps 12";;
    esac
    mac_cycles=$((128 / M)); batches=$((3072 / mac_cycles))
    bootrun=${synrun}_distguide
    finalrun=${bootrun}_spp_pins
    syndir="$REPO/syn/build/$target/$synrun"
    bootdir="$REPO/apr/build/$target/$bootrun"
    finaldir="$REPO/apr/build/$target/$finalrun"
    boot_saif="$bootdir/activity/dut.saif"
    glargs="+define+PAYN_ARRAY_DUT=$top+define+SC_K=$K+define+SC_M=$M+define+SC_NH=$N+define+SC_NW=$N+define+SC_OWIDTH=24+define+SC_T=128+define+SC_BATCHES=$batches$intports +neg_tchk +sdfverbose"
    mkdir -p "$work"
    exec 9>"$work/worker.lock"
    flock -n 9 || { echo "[$arm] Another worker owns this run" >&2; exit 2; }
    trap 'rc=$?; printf "FAILED stage=%s exit=%s time=%s\n" "$current_stage" "$rc" "$(date -Is)" >> "$work/failures.log"; exit "$rc"' ERR
    [[ -s "$syndir/$top.syn.v" && -s "$syndir/$top.syn.sdc" && -s "$boot_saif" ]]
    # The earlier pass-2 final of this arm applied the same guides: same counts.
    # csa_bp_lap: its bootstrap route (same guide script, target branch on).
    if [[ "$arm" == csa_bp_lap ]]; then
        guide_line=$(awk '/^SC_DISTRIBUTION_GUIDES:/{print; exit}' "$bootdir/apr.log")
    else
        guide_line=$(awk '/^SC_DISTRIBUTION_GUIDES:/{print; exit}' "$REPO/apr/build/$target/${bootrun}_spp_fixed"/before_legalization_*/apr.log)
    fi
    [[ -n "$guide_line" ]]
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
    local manifest
    manifest=$(printf 'target=%s\ntop=%s\nsynthesis=%s\nbootstrap_route=%s\nbootstrap_saif=%s sha256=%s\nfinal_route=%s\nflow=%s apr.tcl sha256=%s\npre_place_script=%s sha256=%s\nguide_script sha256=%s\nexpected_pins=%s\nguides=%s\nK=%s M=%s NH=%s NW=%s OWIDTH=24 LOW_W=9 T=128 batches=%s period=2.5 input_delay=1.25 uncertainty=0.125 core_util=0.70 HPK=1 APR_OPT_POWER=0 APR_MULTIBIT_FLOP_OPT=0 APR_LEAN_OPT=0 workload_power_opt=1 leakage_ratio=0.0 wirelength_effort=high SC_DISTRIBUTION_GUIDES=0(target branch off; guides sourced by the pin script)\nglargs=%s\ncandidate_gl_approvals=%s\n' \
        "$target" "$top" "$syndir" "$bootdir" "$boot_saif" "$(sha256sum "$boot_saif" | cut -d' ' -f1)" "$finaldir" \
        "$ASTRAEA_FLOW" "$(sha256sum "$ASTRAEA_FLOW/apr/scripts/apr.tcl" | cut -d' ' -f1)" \
        "$PIN_SCRIPT" "$(sha256sum "$REPO/$PIN_SCRIPT" | cut -d' ' -f1)" \
        "$(sha256sum "$REPO/apr/scripts/place_guides_sc_distribution.tcl" | cut -d' ' -f1)" \
        "$expected_pins" "$guide_line" "$K" "$M" "$N" "$N" "$batches" "$glargs" "$approval_args")
    if [[ -e "$work/inputs.txt" ]]; then
        [[ "$(cat "$work/inputs.txt")" == "$manifest" ]] || { echo "[$arm] inputs changed; see $work/inputs.txt" >&2; exit 2; }
    else
        printf '%s\n' "$manifest" > "$work/inputs.txt"
    fi
    current_stage=final_apr;  stage "$current_stage" "$finaldir" do_apr
    current_stage=qualify;    stage "$current_stage" "$work/qualification.json" do_qualify
    current_stage=gate;       stage "$current_stage" "$work/basin/basin_gate.json" do_gate
    current_stage=final_sim;  stage "$current_stage" "$work/gl_final" do_sim
    current_stage=power;      stage "$current_stage" "$work/power_result" do_power
    current_stage=result;     stage "$current_stage" "$work/result.csv" do_result
    echo "[$arm] complete: $work/result.csv"
)

mkdir -p "$OUT"
pids=()
for arm in "${ARMS[@]}"; do run_arm "$arm" & pids+=("$!"); done
status=0
for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then :; else
        echo "[${ARMS[$i]}] Failed; inspect $OUT/${ARMS[$i]}/failures.log and stage logs" >&2
        status=1
    fi
done
if [[ "$LAP_ONLY" == 1 ]]; then
    python3 sweeps/int_mode/bp/compare_pinned_lap.py "$OUT" || status=1
else
    python3 sweeps/pinned_pass2/compare.py "$OUT" || status=1
fi
exit "$status"
