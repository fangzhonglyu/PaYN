#!/bin/bash
# [CBSG-AF-IPD COPY] of sweeps/cbsg/run_cbsg_apr.sh (unchanged; sha256 in
# designs/payn/variants/signed_segmented_csa_cbsg_af_ipd/copied_from.sha256): the BOOTSTRAP pass (floating pins,
# activity seed) of the route of the C-BSG AF + IPD INT variant, TSMC22/PAYN_SC_CSA_CBSG_AF_IPD, synthesis
# cbsg_af_ipd_20261005 (synthesized and post-synthesis GL verified outside this script with the PAYN_SC_CSA knobs;
# designs/payn/variants/signed_segmented_csa_cbsg_af_ipd/README.md).  The headline route is the pinned pass 2,
# sweeps/cbsg/af_ipd/run_af_ipd_pinned.sh, which needs this script's bootstrap_audit (the audited GL SAIF as the
# bootstrap route's activity/dut.saif) and the bootstrap apr.log.
#   bash sweeps/cbsg/af_ipd/run_af_ipd_bootstrap.sh
#   RETRY_FAILED=1 bash sweeps/cbsg/af_ipd/run_af_ipd_bootstrap.sh
#   DRY_RUN=1 bash sweeps/cbsg/af_ipd/run_af_ipd_bootstrap.sh
# Changes (marked [AF-IPD]):
#   * one arm, afipd (sweeps/cbsg/af_ipd/af_ipd_campaign_lib.sh, the campaign library plus that arm): SC power
#     bench designs/payn/power/power_payn_array_cbsg_af_ipd.sv (the AF bench on this top in SC mode, INT inputs
#     tied off; same schedule, operands, SAIF window, trace and checker), uniform L=128, 384 blocks;
#   * only the bootstrap stages run (bootstrap_apr, bootstrap_sim, bootstrap_audit): the task routes bootstrap ->
#     pinned pass 2.  The floating-pin final of the original (final_apr / final_sim / final_audit / power) is
#     available with FLOATING_FINAL=1 and is not part of the headline;
#   * the DRY_RUN pin/guide dry run is sweeps/cbsg/af_ipd/run_pin_dryrun_af_ipd.sh (the C-BSG mock, unchanged);
#   * outputs build/power_char/cbsg_20261005/af_ipd/bootstrap/.
# Everything else (modules, exports, knobs, guides, the qualifier extracted from run_popcount_apr.sh, the GL
# functions and the strict-then-approved audit) is the original's.
#
# Original header:
# C-BSG copy of sweeps/run_popcount_apr.sh (shared, unchanged): the matched K8/M16/N8, T=128 two-pass routed
# experiment through ASTRAEA for the two C-BSG variants of the carry-save array, bootstrap campaign.
#   bash sweeps/cbsg/run_cbsg_apr.sh                  # both arms in parallel (af rg)
#   bash sweeps/cbsg/run_cbsg_apr.sh af               # one arm
#   RETRY_FAILED=1 bash sweeps/cbsg/run_cbsg_apr.sh   # retry failed stages (completed stages are reused)
#   DRY_RUN=1 bash sweeps/cbsg/run_cbsg_apr.sh        # preflight + print the stages; nothing is run or written
#                                                     # into the campaign (scratch dir under $TMPDIR)
# Arms (definitions in sweeps/cbsg/cbsg_campaign_lib.sh): af = TSMC22/PAYN_SC_CSA_CBSG_AF, synthesis
# AF_SYNTH_RUN (cbsg_af_20261005); rg = TSMC22/PAYN_SC_CSA_CBSG_RG, synthesis RG_SYNTH_RUN (cbsg_rg_20261005).
# Both netlists were synthesized (and RTL / synthesized-netlist verified) outside this campaign with the
# PAYN_SC_CSA knobs, so no synthesis stage runs here: the exact netlists are routed.
#
# Same recipe as run_popcount_apr.sh (same module versions, exports, guides, two APR passes, qualifier):
#   bootstrap_apr    make apr <synth>_distguide: distribution guides (SC_DISTRIBUTION_GUIDES=1, the shared
#                    apr/scripts/place_guides_sc_distribution.tcl, whose a/w pipe globs match both C-BSG
#                    netlists -- see sweeps/cbsg/pin_dryrun/run_pin_dryrun.sh), floating pins, no workload power
#                    opt; qualified by run_popcount_apr.sh's check_apr 'bootstrap' (extracted from that file at
#                    run time, as run_pinned_pass2.sh and repair_popcount_apr.sh do).
#   bootstrap_sim    full-timing max-SDF GL of the bootstrap route with the arm's power bench (uniform L=128,
#                    384 blocks = 3,072 window clocks): bench PASS for the complete workload, trace header, drain
#                    recomputed bit-exactly by sweeps/cbsg/<arm>/check_power_trace.py (replaces cosim_streaming.py),
#                    SAIF validation; plus the routed-SDF clock audit (sweeps/cbsg/routed_sdf_clock_audit.py):
#                    the raw routed SDF is what was simulated and no clock gate's CK->ECK comes near the period, so
#                    the ideal-clock view the pre-layout GL needed is not used (and not needed) here.
#   bootstrap_audit  sweeps/validate_routed_gl.py strict; approvals only after a strict failure, opt-in, with a
#                    rationale file (cbsg_gl_audit in the library); then the audited SAIF becomes the route's
#                    activity/dut.saif (the seed of every pass 2).
#   final_apr        make apr <synth>_distguide_spp_fixed: floating pins, workload power opt from the bootstrap
#                    SAIF, leakage ratio 0, detail wire-length effort high; check_apr 'final' (strict).
#   final_sim / final_audit   as above on the floating final (its SAIF becomes its activity file).
#   power            make power_apr (PT-PX, routed SPEF, GL SAIF) + sweeps/validate_pt_power_coverage.py,
#                    result.csv (area, WNS, power, pJ/MAC from the window, first-level hierarchy).
# The floating final is the comparison point the pinned pass 2 is measured against (and its basin is
# not gated); the headline is sweeps/cbsg/run_cbsg_pinned_pass2.sh, which needs only bootstrap_audit's SAIF and
# the bootstrap apr.log here, so it may start as soon as bootstrap_audit has passed.
# Stages resume only from explicit PASS markers; a failed stage is preserved and RETRY_FAILED=1 moves its
# unfinished outputs aside before a new attempt.  Outputs: build/power_char/cbsg_20261005/<arm>/bootstrap/.
set -Eeuo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)   # [AF-IPD] one level deeper
cd "$REPO"
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
CAMPAIGN=${CAMPAIGN:-cbsg_20261005}
OUT=${OUT:-build/power_char/$CAMPAIGN}
RETRY_FAILED=${RETRY_FAILED:-0}
DRY_RUN=${DRY_RUN:-0}
[[ "$CAMPAIGN" =~ ^[A-Za-z0-9_]+$ ]] || { echo 'Invalid CAMPAIGN' >&2; exit 2; }
[[ "$RETRY_FAILED" == 0 || "$RETRY_FAILED" == 1 ]] || { echo 'RETRY_FAILED must be 0 or 1' >&2; exit 2; }
[[ "$DRY_RUN" == 0 || "$DRY_RUN" == 1 ]] || { echo 'DRY_RUN must be 0 or 1' >&2; exit 2; }
[[ "$OUT" == /* ]] || OUT="$REPO/$OUT"
[[ -f "$ASTRAEA_FLOW/Makefile" ]] || { echo 'ASTRAEA Makefile missing' >&2; exit 2; }
if [[ "$DRY_RUN" == 1 ]]; then
    OUT=$(mktemp -d "${TMPDIR:-/tmp}/cbsg_apr_dryrun.XXXXXX")
    echo "DRY_RUN: preflight only; scratch campaign directory $OUT"
fi
ARMS=(afipd)   # [AF-IPD] one arm
(($# == 0)) || { echo "run_af_ipd_bootstrap.sh takes no arguments (one arm, afipd)" >&2; exit 2; }
FLOATING_FINAL=${FLOATING_FINAL:-0}   # [AF-IPD]
[[ "$FLOATING_FINAL" == 0 || "$FLOATING_FINAL" == 1 ]] || { echo 'FLOATING_FINAL must be 0 or 1' >&2; exit 2; }
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
# ---- C-BSG additions (no effect on results) ----
export SNPSLMD_QUEUE=true PYTHONDONTWRITEBYTECODE=1   # wait for Synopsys licenses instead of failing
unset SC_PIN_SPAN SC_PIN_LAYERS_H SC_PIN_LAYERS_V SC_PIN_TRACK_UM SC_PIN_MIN_PITCH_TRACKS
unset SC_PIN_SOUTH_CTRL_STEP_UM SC_PIN_PLAN_FILE SC_DIST_GUIDE_BAND SC_DIST_GUIDE_MARGIN SC_DIST_GUIDE_DENSITY
source "$REPO/sweeps/cbsg/af_ipd/af_ipd_campaign_lib.sh"   # [AF-IPD]

# Each stage uses a new log. Success markers are never inferred from output
# existence: Innovus and PT can leave partial files after failed invocations.
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
    # Called outside any conditional so errexit remains active in each action.
    "$@" > "$log" 2>&1
    printf 'PASS\n' > "$marker"
    echo "[$arm] $name passed $(date -Is)"
}

# The exact qualification of run_popcount_apr.sh (its first python block), as
# run_pinned_pass2.sh and sweeps/repair_popcount_apr.sh also use it.
check_apr() {
    python3 - "$REPO/sweeps/run_popcount_apr.sh" "$1" "$top" "${2:-final}" <<'PY'
from pathlib import Path
import re,subprocess,sys
runner,path,top,qualification=sys.argv[1:]
blocks=re.findall(r"<<'PY'\n(.*?)\nPY",Path(runner).read_text(),re.S)
assert blocks and 'popcount_qualification.json' in blocks[0]
subprocess.run([sys.executable,'-c',blocks[0],path,top,qualification],check=True)
PY
}

do_apr() {
    local run=$1 pass=$2 path="$REPO/apr/build/$target/$1" make_status=0
    if [[ "$pass" == bootstrap ]]; then
        # summarize_run rejects residual seed geometry/antenna violations even
        # when Innovus finished correctly. Capture that status, then require
        # full tool completion, zero EDA errors, required outputs, and valid
        # connectivity/setup/hold through check_apr before accepting the seed.
        APR_WORKLOAD_POWER_OPT=0 SYNTH_RUN="$synrun" RUN_NAME="$run" \
            make apr TARGET="$target" NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" \
            || make_status=$?
    else
        PRE_REPORT_SCRIPT=apr/scripts/check_popcount_placement.tcl \
        APR_WORKLOAD_POWER_OPT=1 APR_ACTIVITY_FILE="$boot_saif" APR_ACTIVITY_SCOPE=Top/dut \
        APR_LEAKAGE_TO_DYNAMIC_RATIO=0.0 APR_DETAIL_WIRE_LENGTH_OPT_EFFORT=high \
        SYNTH_RUN="$synrun" RUN_NAME="$run" \
            make apr TARGET="$target" NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW"
        grep -q 'Enabling workload-aware dynamic-power optimization' "$path/apr.log"
        grep -q 'leakageToDynamicRatio=0.0 detail_wirelength_effort=high' "$path/apr.log"
        grep -Fq "INFO: activity_file=$boot_saif scope='Top/dut'" "$path/apr.log"
    fi
    # The shared distribution guides must have run with the counts the netlist predicts.
    grep -Fq "Running PRE_PLACE_SCRIPT script: $REPO/apr/scripts/place_guides_sc_distribution.tcl" "$path/apr.log"
    grep -Fq "$expected_guides" "$path/apr.log"
    check_apr "$path" "$pass"
    if [[ "$make_status" -ne 0 ]]; then
        echo "Bootstrap make apr returned $make_status; completed Innovus output passed the activity-seed qualifier. Physical diagnostics remain recorded."
    fi
}

do_sim() {   # run simdir
    cbsg_gl_sim "$1" "$2" uniform
}

do_audit() {   # simdir route_dir
    cbsg_gl_audit "$1"
    cbsg_install_saif "$1" "$2"
}

do_power() {
    local saved="$work/power_result"
    mkdir -p "$saved/prior_reports"
    # PT overwrites Innovus power reports. Preserve those, or prior failed PT
    # reports, before each attempt; no earlier log is silently discarded.
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
    python3 - "$arm" "$target" "$finalrun" "$finaldir" "$top" "$work" "$rng_insts" <<'PY'
import csv,json,re,sys
from pathlib import Path
arm,target,run,dirname,top,work,rng=sys.argv[1:]
p=Path(dirname); work=Path(work); report=(p/'reports'/'power.rpt').read_text()
m=re.search(r'Total Power\s*=\s*([0-9.eE+-]+)',report)
assert m, 'Missing PT total power'
power=float(m[1])*1e3; assert power>0
area=None
for line in (p/'reports'/'area.rpt').read_text().splitlines():
    fields=line.split()
    if fields and fields[0]==top: area=float(fields[2]); break
assert area is not None
hier={}
for line in (work/'power_result'/'cell_power.rpt').read_text().splitlines():
    h=re.match(r'^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+\(.*\)\s+h\s*$',line)
    if h and h[1] not in hier: hier[h[1]]=float(h[5])*1e3
rng=rng.split()
assert {'u_pe','u_peripheral',*rng} <= set(hier), hier
t=json.loads((work/'gl_final'/'trace_check.json').read_text())
window=t.get('window_edges',t.get('window_clocks')); blocks=t['blocks']
q=json.loads((p/'reports'/'popcount_qualification.json').read_text())
g=json.loads((work/'gl_final'/'timing_qualification.json').read_text()); assert g['status']=='PASS'
row=dict(arm=arm,target=target,run=run,pins='floating',workload=t['workload'],K=8,M=16,N=8,T=128,blocks=blocks,
         window_clocks=window,kernel_macs=blocks*512,area_um2=area,power_mW=power,
         pJ_MAC=power*window*2.5/(blocks*512),u_pe_mW=hier['u_pe'],u_peripheral_mW=hier['u_peripheral'],
         sobol_mW=sum(hier[k] for k in rng),
         other_top_children_mW=json.dumps({k:round(v,5) for k,v in hier.items() if k not in ('u_pe','u_peripheral',*rng)}),
         gl_approved_ndi_clamps=len(g['approved_negative_iopath_clamps']),
         gl_approved_iwsba=len(g['approved_annotated_interconnects']),**q,status='PASS')
with (work/'result.csv').open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=list(row));w.writeheader();w.writerow(row)
print(json.dumps(row,indent=2))
PY
}

run_arm() (
    local arm=$1 target top synrun TB trace_name checker rng_insts ftb ladder_def ladder_name ladder_wl glargs
    local bootrun finalrun syndir bootdir finaldir boot_sim final_sim boot_saif expected_guides
    local work="$OUT/af_ipd/bootstrap" current_stage=initialization   # [AF-IPD]
    cbsg_arm_config "$arm"
    mkdir -p "$work"
    exec 9>"$work/worker.lock"
    flock -n 9 || { echo "[$arm] Another worker owns this run" >&2; exit 2; }
    trap 'rc=$?; printf "FAILED stage=%s exit=%s time=%s\n" "$current_stage" "$rc" "$(date -Is)" >> "$work/failures.log"; exit "$rc"' ERR
    bootrun=${synrun}_distguide
    finalrun=${bootrun}_spp_fixed
    syndir="$REPO/syn/build/$target/$synrun"
    bootdir="$REPO/apr/build/$target/$bootrun"
    finaldir="$REPO/apr/build/$target/$finalrun"
    boot_sim="$work/gl_bootstrap"; final_sim="$work/gl_final"
    boot_saif="$bootdir/activity/dut.saif"
    [[ -s "$syndir/$top.syn.v" && -s "$syndir/$top.syn.sdc" ]]
    python3 - "$syndir/$top.syn.sdc" <<'PY'
import re,sys
s=open(sys.argv[1]).read()
delays=re.findall(r'^set_input_delay\b[^\n]*?\s([0-9]+(?:\.[0-9]+)?)\s+\[get_ports',s,re.M)
assert delays and all(float(x)==1.25 for x in delays), f'Unexpected input delays {delays}'
PY
    # The guide line the shared guide script must print for this netlist (its globs, counted on the netlist).
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
assert all(cnt(('a_bits_pipe',),h) for h in range(8)) and all(cnt(('w_bits_pipe',),v) for v in range(8))
print(f'SC_DISTRIBUTION_GUIDES: nh=8 nw=8 band=0.55 density=0.72 a_cells={a} w_cells={w} w_keep={k}')
PY
)
    [[ -n "$expected_guides" ]]
    # Record a readable contract. Direct comparison avoids accepting stale
    # markers under changed settings; campaign names identify immutable inputs.
    local manifest
    manifest=$(printf 'target=%s\ntop=%s\nsynthesis=%s netlist sha256=%s\nflow=%s apr.tcl sha256=%s\nbench=%s sha256=%s\nchecker=%s\nguides=%s (shared apr/scripts/place_guides_sc_distribution.tcl sha256=%s)\nK=8 M=16 NH=8 NW=8 OWIDTH=24 LOW_W=9 T=128 batches=%s period=2.5 input_delay=1.25 uncertainty=0.125 core_util=0.70 HPK=1 guides=1 APR_OPT_POWER=0 APR_MULTIBIT_FLOP_OPT=0\nglargs=%s\n' \
        "$target" "$top" "$syndir" "$(sha256sum "$syndir/$top.syn.v" | cut -d' ' -f1)" \
        "$ASTRAEA_FLOW" "$(sha256sum "$ASTRAEA_FLOW/apr/scripts/apr.tcl" | cut -d' ' -f1)" \
        "$TB" "$(sha256sum "$REPO/$TB" | cut -d' ' -f1)" "$checker" "$expected_guides" \
        "$(sha256sum "$REPO/apr/scripts/place_guides_sc_distribution.tcl" | cut -d' ' -f1)" "$CBSG_BATCHES" "$glargs")
    if [[ -e "$work/inputs.txt" ]]; then
        [[ "$(cat "$work/inputs.txt")" == "$manifest" ]] || { echo "[$arm] inputs changed; see $work/inputs.txt" >&2; exit 2; }
    else
        printf '%s\n' "$manifest" > "$work/inputs.txt"
    fi
    if [[ "$DRY_RUN" == 1 ]]; then
        echo "[$arm] DRY_RUN manifest:"; sed 's/^/    /' "$work/inputs.txt"
        # The APR target as make apr will source it, with this script's environment.
        (SYNTH_RUN="$synrun"; set +u; . "$REPO/apr/targets/$target"
         echo "[$arm] DRY_RUN target: TOP=$TOP PRE_PLACE_SCRIPT=$PRE_PLACE_SCRIPT SC_DIST_HIER_PREFIX=$SC_DIST_HIER_PREFIX SC_NH=$SC_NH SC_NW=$SC_NW POST_LOAD_SCRIPT=$POST_LOAD_SCRIPT"
         [[ "$TOP" == "$top" && "$PRE_PLACE_SCRIPT" == apr/scripts/place_guides_sc_distribution.tcl ]])
        [[ -d "$REPO/apr/build/$target/$bootrun" ]] && echo "[$arm] DRY_RUN note: $bootdir already exists (stage would refuse it without RETRY_FAILED=1)"
        check_apr_probe=$(python3 -c "import re,sys;from pathlib import Path;b=re.findall(r\"<<'PY'\\n(.*?)\\nPY\",Path('$REPO/sweeps/run_popcount_apr.sh').read_text(),re.S);print('ok' if b and 'popcount_qualification.json' in b[0] else 'BAD')")
        [[ "$check_apr_probe" == ok ]]
        echo "[$arm] DRY_RUN check_apr extraction from sweeps/run_popcount_apr.sh: $check_apr_probe"
        bash "$REPO/sweeps/cbsg/af_ipd/run_pin_dryrun_af_ipd.sh" guides "$OUT/af_ipd/pin_dryrun_guides" | grep -E '^(SC_DISTRIBUTION_GUIDES|PIN_DRYRUN)' | cut -c1-300   # [AF-IPD]
        grep -qxF "$expected_guides" "$OUT/af_ipd/pin_dryrun_guides/dryrun.log"
        echo "[$arm] DRY_RUN first stage command (bootstrap_apr):"
        echo "    APR_WORKLOAD_POWER_OPT=0 SYNTH_RUN=$synrun RUN_NAME=$bootrun make apr TARGET=$target NTFY_CHNL= ASTRAEA_FLOW=$ASTRAEA_FLOW"
        echo "    (env: SC_DISTRIBUTION_GUIDES=$SC_DISTRIBUTION_GUIDES SC_PLACE_GUIDES=$SC_PLACE_GUIDES SC_NH=$SC_NH SC_NW=$SC_NW CORE_UTIL=$CORE_UTIL PERIOD=$PERIOD CLOCK_UNCERTAINTY=$CLOCK_UNCERTAINTY TSMC22_HPK=$TSMC22_HPK APR_OPT_POWER=$APR_OPT_POWER APR_MULTIBIT_FLOP_OPT=$APR_MULTIBIT_FLOP_OPT APR_LEAN_OPT=$APR_LEAN_OPT)"
        echo "    expected guide line: $expected_guides"
    fi
    current_stage=bootstrap_apr
    stage "$current_stage" "$bootdir" do_apr "$bootrun" bootstrap
    current_stage=bootstrap_sim
    stage "$current_stage" "$boot_sim" do_sim "$bootrun" "$boot_sim"
    current_stage=bootstrap_audit
    stage "$current_stage" "$boot_sim/timing_qualification.json" do_audit "$boot_sim" "$bootdir"
    if [[ "$FLOATING_FINAL" == 0 ]]; then   # [AF-IPD] bootstrap only (the pinned pass 2 is the next script)
        echo "[$arm] bootstrap complete: $bootdir, activity seed $boot_saif"
        return 0
    fi
    current_stage=final_apr
    stage "$current_stage" "$finaldir" do_apr "$finalrun" final
    current_stage=final_sim
    stage "$current_stage" "$final_sim" do_sim "$finalrun" "$final_sim"
    current_stage=final_audit
    stage "$current_stage" "$final_sim/timing_qualification.json" do_audit "$final_sim" "$finaldir"
    current_stage=power
    stage "$current_stage" "$work/power_result" do_power
    echo "[$arm] complete: $work/result.csv"
)

mkdir -p "$OUT"
pids=()
for arm in "${ARMS[@]}"; do run_arm "$arm" & pids+=("$!"); done
status=0
for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then :; else
        echo "[${ARMS[$i]}] Failed; inspect $OUT/af_ipd/bootstrap/failures.log and stage logs" >&2   # [AF-IPD]
        status=1
    fi
done
[[ "$DRY_RUN" == 0 ]] || echo "DRY_RUN finished (status $status); scratch directory $OUT"
exit "$status"
