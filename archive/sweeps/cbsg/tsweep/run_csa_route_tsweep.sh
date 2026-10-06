#!/bin/bash
# CSA energy versus stream length T, and the CSA "ladder-equivalent" run, measured on the finished pinned CSA route
# apr/build/TSMC22/PAYN_SC_CSA/csa_20261002_distguide_spp_pins (the C-BSG campaign's CSA baseline; headline T=128:
# 15.72648 mW, 0.6143 pJ/MAC).  Every point is characterized on the route itself -- nothing is interpolated.
#
# Points (384 blocks each; block = c clocks; kernel MACs = 384 x 512):
#   T16 .. T128   designs/payn/power/power_payn_array.sv unchanged (the headline bench), SC_T = T, SC_BATCHES = 384,
#                 c = T/16 for every block; checked by designs/payn/cosim/cosim_streaming.py
#   ladder        designs/payn/power/power_payn_array_csa_vart.sv with the A-first C-BSG ladder run's exact operands
#                 and per-block cycles c_b = ceil(max row L / 16) (stimulus
#                 build/power_char/cbsg_20261005/tsweep/csa/stim/ladder_from_af.stim.txt, made by
#                 make_csa_vart_stim.py from the AF pinned-postfill GL ladder trace); checked by
#                 sweeps/cbsg/tsweep/cosim_streaming_vart.py incl. operands/cycles == the AF trace
#   repro         the vart bench replaying the headline T=128 run's operands with c = 8: the bench-copy control
#                 (its SAIF must equal the headline SAIF, so its power must equal the headline exactly)
#
# Per point, the method of the headline (sweeps/run_pinned_pass2.sh do_sim/do_power) and of the C-BSG measurement
# (sweeps/cbsg/af/run_af_route_measure.sh):
#   sim      full-timing max-SDF GL on the routed netlist (+neg_tchk +sdfverbose), bench PASS line, max-corner SDF
#            annotation, trace header, bit-exact drain, SAIF validation (sweeps/validate_sc_power_saif.py), routed-SDF
#            clock-gate audit (sweeps/cbsg/routed_sdf_clock_audit.py: the raw route SDF was simulated)
#   audit    sweeps/validate_routed_gl.py strict (no approvals).  A strict failure stops the point unless
#            CSA_GL_VALIDATOR_ARGS (only --approve-* flags) is given with a rationale file citing each flag
#            (OUT/gl_validator_args_rationale.txt); the outcome is logged to OUT/gl_validator_args.txt
#   power    PT-PX with the routed SPEF on a PT-only view apr/build/TSMC22/PAYN_SC_CSA/<route>_ptview_tsweep_<point>
#            (symlinks to the route's netlist, SPEF, SDC; make power_apr writes its SAIF snapshot and reports there),
#            drain excluded (the benches stop the SAIF before the drain), coverage validated
#            (sweeps/validate_pt_power_coverage.py)
#   classes  the C-BSG campaign's per-class split (sweeps/cbsg/af/run_pt_power_classes.sh ... csa), which must
#            reproduce the point's PT total
#   result   OUT/<point>/result.json
# The route directory is never written.  Gate: the T128 point must reproduce the headline (PT total, SAIF apart
# from its DATE line, trace) before any other point runs; then the rest run MAX_JOBS at a time.
#
#   bash sweeps/cbsg/tsweep/run_csa_route_tsweep.sh [POINT ...]     # default: T128 (gate), then the rest
#   MAX_JOBS=3 RETRY_FAILED=1 ...
# Outputs: build/power_char/cbsg_20261005/tsweep/csa/<point>/, results.csv, results.txt
set -Eeuo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$REPO"
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
OUT=$REPO/build/power_char/cbsg_20261005/tsweep/csa
MAX_JOBS=${MAX_JOBS:-3}
RETRY_FAILED=${RETRY_FAILED:-0}
POINTS=("$@")
((${#POINTS[@]})) || POINTS=(T128 T16 T32 T48 T64 T80 T96 T112 ladder repro)
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
# ---- the headline's environment (sweeps/run_pinned_pass2.sh; sweeps/cbsg/af/run_af_route_measure.sh) ----
export SYNOPSYS=${SYNOPSYS:-/usr/caen/synopsys-synth-2021.06-SP1}
export ZERO_PINLESS_NET_ACTIVITY=1
export USE_DW=1 NTFY_CHNL=
export TSMC22_CELL_TIER=sc7mcpp140z TSMC22_LIB_FLAVORS=svt_c30
export TSMC22_HPK_FLAVORS=svt_c30 TSMC22_HPK=1
export CORE_UTIL=0.70 CORE_ASPECT=1.000 PERIOD=2.5 INPUT_DELAY=1.25 OUTPUT_DELAY=0.05
export CLOCK_UNCERTAINTY=0.125 SC_PLACE_GUIDES=0 SC_NH=8 SC_NW=8
export APR_OPT_POWER=0 APR_MULTIBIT_FLOP_OPT=0 APR_LEAN_OPT=0
unset NETLIST_FILE SDC_FILE SDF_FILE PRE_PLACE_SCRIPT POST_LOAD_SCRIPT
unset APR_ACTIVITY_FILE APR_ACTIVITY_SCOPE APR_POWER_ANALYSIS_VIEW
unset APR_WORKLOAD_POWER_OPT APR_LEAKAGE_TO_DYNAMIC_RATIO APR_DETAIL_WIRE_LENGTH_OPT_EFFORT
unset SC_DIST_HIER_PREFIX SC_TILE_HIER_PREFIX NO_SDF VCS_ARGS
VCS_CMD='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
export SNPSLMD_QUEUE=true PYTHONDONTWRITEBYTECODE=1

target=TSMC22/PAYN_SC_CSA
top=payn_array_signed_segmented_csa
RUN=csa_20261002_distguide_spp_pins
route="$REPO/apr/build/$target/$RUN"
BLOCKS=384
HEAD="$REPO/build/power_char/pinned_pass2_20261004/csa"
HEAD_POWER="$HEAD/power_result/power.rpt"
HEAD_TRACE="$HEAD/gl_final/designs/payn/power/power_payn_array.sv/array_streaming_rtl.txt"
HEAD_SAIF="$route/activity/dut.saif"     # the audited headline GL SAIF installed by do_sim
HEAD_CLASSES="$REPO/build/power_char/cbsg_20261005/af/csa_baseline_power_classes/power_classes.json"
STIM="$OUT/stim"
AF_TRACE="$REPO/build/power_char/cbsg_20261005/af/pinned_fix/postfill/measure/gl_ladder/designs/payn/power/power_payn_array_cbsg_af.sv/array_streaming_cbsg_af_rtl.txt"
OTB=designs/payn/power/power_payn_array.sv
VTB=designs/payn/power/power_payn_array_csa_vart.sv
GLBASE="+define+PAYN_ARRAY_DUT=$top+define+SC_K=8+define+SC_M=16+define+SC_NH=8+define+SC_NW=8+define+SC_OWIDTH=24+define+SC_BATCHES=$BLOCKS"
for f in "outputs/$top.apr.v" "outputs/$top.spef" "outputs/$top.apr.sdf" "$top.syn.sdc"; do
    [[ -s "$route/$f" ]] || { echo "route file missing: $route/$f" >&2; exit 2; }
done
[[ "$(sha256sum "$HEAD_SAIF" | cut -d' ' -f1)" == 124ca4e7a15f475b59d6b53e83960e620f920791ba3112bf2d6ecef6bce84d55 ]] || {
    echo "route activity file is not the headline SAIF the class split used" >&2; exit 2; }
mkdir -p "$OUT" "$STIM"

point_config() {   # point -> tb glargs pass trace stim t
    stim=""; t=""
    case "$1" in
        T16|T32|T48|T64|T80|T96|T112|T128)
            t=${1#T}; tb=$OTB
            glargs="$GLBASE+define+SC_T=$t +neg_tchk +sdfverbose"
            pass="PASS: streaming SC SAIF captured; $BLOCKS batches x $((t / 16)) cycles"
            trace=array_streaming_rtl.txt;;
        ladder|repro)
            tb=$VTB
            [[ "$1" == ladder ]] && stim="$STIM/ladder_from_af.stim.txt" || stim="$STIM/repro_T128_from_headline.stim.txt"
            glargs="$GLBASE +neg_tchk +sdfverbose"
            pass="PASS: streaming SC vart SAIF captured; $BLOCKS batches, "   # + window clocks, checked below
            trace=array_streaming_csa_vart_rtl.txt;;
        *) echo "unknown point $1" >&2; return 2;;
    esac
}

make_stims() {
    python3 sweeps/cbsg/tsweep/make_csa_vart_stim.py --from-af "$AF_TRACE" --out "$STIM/ladder_from_af.stim.txt" \
        --json "$STIM/ladder_from_af.json" > /dev/null
    python3 sweeps/cbsg/tsweep/make_csa_vart_stim.py --from-csa "$HEAD_TRACE" \
        --out "$STIM/repro_T128_from_headline.stim.txt" --json "$STIM/repro_T128_from_headline.json" > /dev/null
}

# Commands run as plain statements (never inside if/||): bash ignores errexit in functions called from a
# conditional context, and every check below relies on errexit.  A failure exits the point's subshell; its ERR
# trap names the failing command.
stage() {   # P name artifact cmd...
    local P=$1 name=$2 artifact=$3 marker attempt=1 log
    shift 3
    marker="$P/$name.status"
    if [[ -f "$marker" && "$(cat "$marker")" == PASS && -e "$artifact" ]]; then echo "[$(basename "$P")] reuse $name"; return; fi
    while [[ -e "$P/$name.attempt_$attempt.log" ]]; do attempt=$((attempt+1)); done
    if (( attempt > 1 )) && [[ "$RETRY_FAILED" != 1 ]]; then
        echo "[$(basename "$P")] $name failed before ($P/$name.attempt_$((attempt-1)).log); RETRY_FAILED=1 to retry" >&2; return 1
    fi
    [[ ! -e "$artifact" ]] || mv "$artifact" "${artifact}.failed_$(date +%Y%m%d_%H%M%S)_${BASHPID}"
    log="$P/$name.attempt_$attempt.log"
    CUR_LOG=$log
    echo "[$(basename "$P")] $name started $(date -Is)"
    "$@" > "$log" 2>&1
    printf 'PASS\n' > "$marker"
    echo "[$(basename "$P")] $name passed $(date -Is)"
}

do_sim() {   # point P
    local pt=$1 P=$2 simdir="$2/gl" line window
    point_config "$pt"
    mkdir -p "$simdir/$tb"
    if [[ -n "$stim" ]]; then cp "$stim" "$simdir/$tb/csa_vart_stim.txt"; fi
    make sim GL=apr TARGET="$target" RUN="$RUN" TB="$tb" BUILD_DIR="$simdir" \
        SDF_CORNER=max NO_SDF= RTL_PREFLIGHT_CMD=true VCS_ARGS="$glargs" "VCS=$VCS_CMD" \
        NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" > "$simdir/simulation.log" 2>&1
    line=$(grep -F "$pass" "$simdir/simulation.log" | head -n 1 || true)
    [[ -n "$line" ]] || { echo "bench PASS line missing in $simdir/simulation.log" >&2; return 1; }
    printf '%s\n' "$line" > "$simdir/expected_pass.txt"
    grep -q 'sdf corner = max' "$simdir/simulation.log"
    grep -Fq '[INFO] $sdf_annotate(' "$simdir/simulation.log"
    local tr="$simdir/$tb/$trace" saif="$simdir/$tb/dut.saif"
    [[ -s "$tr" && -s "$saif" ]]
    if [[ -n "$t" ]]; then
        [[ "$(head -n 1 "$tr")" == "STREAMCFG 8 16 8 8 8 24 $t $BLOCKS 0" ]]
        python3 designs/payn/cosim/cosim_streaming.py "$tr" > "$simdir/cosim.log" 2>&1
        grep -q '\[PASS\]' "$simdir/cosim.log"
        python3 sweeps/cbsg/tsweep/cosim_streaming_vart.py "$tr" --json "$simdir/trace_check.json" > "$simdir/trace_check.log" 2>&1
    else
        [[ "$(head -n 1 "$tr")" == "STREAMCFGV 8 16 8 8 8 24 $BLOCKS 0" ]]
        local extra=()
        [[ "$pt" != ladder ]] || extra=(--af-trace "$AF_TRACE")
        python3 sweeps/cbsg/tsweep/cosim_streaming_vart.py "$tr" --stim "$simdir/$tb/csa_vart_stim.txt" "${extra[@]}" \
            --json "$simdir/trace_check.json" > "$simdir/trace_check.log" 2>&1
        cmp -s "$stim" "$simdir/$tb/csa_vart_stim.txt"
    fi
    grep -q '\[PASS\]' "$simdir/trace_check.log"
    window=$(python3 -c 'import json,sys; j=json.load(open(sys.argv[1])); assert not j["errors"] and j["blocks"]==int(sys.argv[2]); print(j["window_clocks"])' \
        "$simdir/trace_check.json" "$BLOCKS")
    if [[ -n "$t" ]]; then [[ "$window" == $((BLOCKS * t / 16)) ]]
    else grep -Fq "$pass$window window clocks, drain dumped" "$simdir/simulation.log"; fi
    python3 sweeps/validate_sc_power_saif.py "$saif" --expected-period-ns 2.5 > "$simdir/saif_validation.log" 2>&1
    python3 sweeps/cbsg/routed_sdf_clock_audit.py "$route/outputs/$top.apr.sdf" --period-ns 2.5 \
        --sim-log "$simdir/simulation.log" --json "$simdir/sdf_clock_audit.json" > "$simdir/sdf_clock_audit.log" 2>&1
    cat "$simdir/trace_check.log" "$simdir/saif_validation.log" "$simdir/sdf_clock_audit.log"
}

do_audit() {   # P   (cbsg_gl_audit, CSA flavour)
    local simdir="$1/gl" pass strict=PASS used="" rationale="$OUT/gl_validator_args_rationale.txt" tok prev=""
    pass=$(cat "$simdir/expected_pass.txt")
    python3 sweeps/validate_routed_gl.py "$simdir/simulation.log" --expected-pass "$pass" \
        --json "$simdir/timing_qualification_strict.json" > "$simdir/timing_validation_strict.log" 2>&1 || strict=FAIL
    if [[ "$strict" == PASS ]]; then
        cp -p "$simdir/timing_qualification_strict.json" "$simdir/timing_qualification.json"
    else
        used=${CSA_GL_VALIDATOR_ARGS:-}
        python3 -c 'import json,sys; print("strict audit FAILED:", json.load(open(sys.argv[1]))["rejection_reasons"])' \
            "$simdir/timing_qualification_strict.json" >&2 || true
        [[ -n "$used" ]] || { echo "No approvals given; investigate, write $rationale, rerun with CSA_GL_VALIDATOR_ARGS" >&2; return 1; }
        [[ -s "$rationale" ]] || { echo "approvals need $rationale" >&2; return 1; }
        for tok in $used; do
            if [[ "$tok" == --approve-* ]]; then grep -qF -- "$tok" "$rationale" || { echo "$rationale does not cite $tok" >&2; return 1; }
            elif [[ "$prev" != --approve-negative-iopath-clamp-ps || ! "$tok" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                echo "only --approve-* flags accepted (got '$tok')" >&2; return 1; fi
            prev=$tok
        done
        # shellcheck disable=SC2086
        python3 sweeps/validate_routed_gl.py "$simdir/simulation.log" --expected-pass "$pass" $used \
            --json "$simdir/timing_qualification.json" > "$simdir/timing_validation.log" 2>&1 || true
    fi
    python3 - "$simdir" "$strict" "$used" >> "$OUT/gl_validator_args.txt" <<'PY'
import json,sys,datetime
simdir,strict,used=sys.argv[1:]
s=json.load(open(f'{simdir}/timing_qualification_strict.json')); q=json.load(open(f'{simdir}/timing_qualification.json'))
print(f"{datetime.datetime.now().isoformat(timespec='seconds')} {simdir} strict={strict} strict_reasons={s['rejection_reasons']} "
      f"approvals_used='{used}' sdf_warnings={q['sdf_warning_categories']} ndi_clamps={len(q['approved_negative_iopath_clamps'])} "
      f"iwsba={len(q['approved_annotated_interconnects'])} post_reset_violations={q['post_reset_timing_violations']} status={q['status']}")
PY
    tail -n 1 "$OUT/gl_validator_args.txt"
    python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["status"]=="PASS" else 1)' "$simdir/timing_qualification.json"
}

do_power() {   # point P   (run_af_route_measure.sh do_pt_view, CSA route)
    local pt=$1 P=$2 vrun="${RUN}_ptview_tsweep_$1" view saif saved="$2/power" f
    point_config "$pt"
    view="$REPO/apr/build/$target/$vrun"; saif="$P/gl/$tb/dut.saif"
    [[ ! -e "$view" ]] || mv "$view" "${view}.old_$(date +%Y%m%d_%H%M%S)_${BASHPID}"
    mkdir -p "$view/outputs" "$saved"
    ln -s "$route/outputs/$top.apr.v" "$view/outputs/$top.apr.v"
    ln -s "$route/outputs/$top.spef" "$view/outputs/$top.spef"
    ln -s "$route/$top.syn.sdc" "$view/$top.syn.sdc"
    {
        echo "PT-only view of $route (CSA T-sweep point $pt), written by sweeps/cbsg/tsweep/run_csa_route_tsweep.sh;"
        echo "the route's own reports and activity file are untouched."
        for f in "outputs/$top.apr.v" "outputs/$top.spef" "$top.syn.sdc"; do echo "$(sha256sum "$route/$f" | cut -d' ' -f1)  $f"; done
    } > "$view/VIEW_OF.txt"
    POWER_SAIF_VALIDATOR="$REPO/sweeps/validate_sc_power_saif.py" \
        make power_apr TARGET="$target" RUN="$vrun" SAIF="$saif" SAIF_STRIP_PATH=Top/dut NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW"
    [[ -s "$view/reports/power.rpt" && -s "$view/reports/saif_coverage.rpt" && -s "$view/reports/parasitics_coverage.rpt" ]]
    grep -q 'Report : Averaged Power' "$view/reports/power.rpt"
    python3 sweeps/validate_pt_power_coverage.py "$view/reports" --power-log "$view/power_apr.log" \
        --json "$view/reports/power_coverage.json"
    cmp -s "$saif" "$view/activity/dut.saif"
    cp -p "$view/power_apr.log" "$view/reports/power_coverage.json" "$view/VIEW_OF.txt" "$saved/"
    cp -p "$view"/reports/*.rpt "$saved/"
}

do_classes() {   # point P
    point_config "$1"
    bash sweeps/cbsg/af/run_pt_power_classes.sh "$route" "$top" csa "$2/gl/$tb/dut.saif" "$2/power/power.rpt" "$2/classes"
}

# The headline reproduction checks (T128 and repro): PT total string-identical to the headline power.rpt, SAIF
# identical apart from the DATE line, trace identical (T128: byte for byte; repro: operands and drain), and the
# class split row for row equal to the C-BSG campaign's CSA baseline split.
do_gate() {   # point P
    point_config "$1"
    local P=$2 saif="$2/gl/$tb/dut.saif" tr="$2/gl/$tb/$trace"
    local a b
    a=$(grep -E '^Total Power' "$HEAD_POWER"); b=$(grep -E '^Total Power' "$P/power/power.rpt")
    echo "headline: $a"; echo "point   : $b"
    [[ "$a" == "$b" ]]
    diff <(grep -v '^(DATE ' "$HEAD_SAIF") <(grep -v '^(DATE ' "$saif") > "$P/saif_vs_headline.diff"
    echo "SAIF identical to the headline SAIF apart from its DATE line"
    if [[ "$1" == T128 ]]; then cmp "$HEAD_TRACE" "$tr"; echo "trace identical to the headline trace"
    else diff <(grep -vE '^(STREAMCFG|BATCH)' "$HEAD_TRACE") <(grep -vE '^(STREAMCFGV|BATCH|WINDOW)' "$tr"); echo "operands + drain identical to the headline trace"; fi
    python3 - "$HEAD_CLASSES" "$P/classes/power_classes.json" <<'PY'
import json,sys
a=json.load(open(sys.argv[1]))['rows_mW']; b=json.load(open(sys.argv[2]))['rows_mW']
assert a.keys()==b.keys() and all(abs(a[k]-b[k])<=1e-12 for k in a), {k:(a[k],b.get(k)) for k in a if abs(a[k]-b.get(k,0))>1e-12}
print('class split identical to the C-BSG campaign CSA baseline split:', round(b['total'],5), 'mW')
PY
}

do_result() {   # point P
    point_config "$1"
    python3 - "$1" "$2" "$t" "$RUN" "$target" <<'PY'
import json,re,sys
from pathlib import Path
pt,P,t,run,target=sys.argv[1:]; P=Path(P)
rpt=(P/'power'/'power.rpt').read_text()
g=lambda n: float(re.search(n+r'\s*=\s*([0-9.eE+-]+)',rpt)[1])*1e3
c=json.loads((P/'gl'/'trace_check.json').read_text())
q=json.loads((P/'gl'/'timing_qualification.json').read_text())
s=json.loads((P/'gl'/'timing_qualification_strict.json').read_text())
a=json.loads((P/'gl'/'sdf_clock_audit.json').read_text())
k=json.loads((P/'classes'/'power_classes.json').read_text())
cov=json.loads((P/'power'/'power_coverage.json').read_text())
sv=(P/'gl'/'saif_validation.log').read_text().strip().splitlines()[-1]
window,blocks=c['window_clocks'],c['blocks']
p=g('Total Power')
row=dict(point=pt,T=(int(t) if t else None),workload=('uniform T=%s'%t if t else ('ladder-equivalent (AF ladder operands, c_b = ceil(max row L/16))' if pt=='ladder' else 'repro (vart bench, headline operands, c=8)')),
         target=target,run=run,blocks=blocks,window_clocks=window,cycles_per_block=window/blocks,
         cycle_histogram=json.dumps(c['cycle_histogram']),kernel_macs=blocks*512,
         power_mW=p,internal_mW=g('Cell Internal Power'),switching_mW=g('Net Switching Power'),leakage_mW=g('Cell Leakage Power'),
         pJ_per_MAC=p*window*2.5/(blocks*512),pJ_per_block=p*window*2.5/blocks,nJ_window=p*window*2.5/1e3,
         drain_bit_exact=(not c['errors'] and c['wrong']==0),gl_strict=s['status'],gl_status=q['status'],
         gl_approvals_ndi=len(q['approved_negative_iopath_clamps']),gl_approvals_iwsba=len(q['approved_annotated_interconnects']),
         gl_post_reset_violations=q['post_reset_timing_violations'],gl_sdf_warnings=json.dumps(q['sdf_warning_categories'],sort_keys=True),
         worst_icg_ck_eck_ns=a['worst_icg_iopath_ns'],sdf_audit=a['status'],pt_coverage=cov.get('status','?'),saif_validation=sv[:160],
         **{f'hier_{kk}_mW':vv for kk,vv in k['hier_attr_mW'].items()},
         **{f'cls_{kk}_mW':vv for kk,vv in k['rows_mW'].items()})
(P/'result.json').write_text(json.dumps(row,indent=2)+'\n')
print(f"{pt}: {p:.5f} mW, {row['pJ_per_MAC']:.4f} pJ/MAC, {row['pJ_per_block']:.2f} pJ/block, {window} window clocks, "
      f"drain bit-exact {row['drain_bit_exact']}, GL strict {row['gl_strict']}")
PY
}

run_point() (
    local pt=$1 P="$OUT/$1"
    CUR_LOG=""
    mkdir -p "$P"
    trap 'echo "[$pt] FAILED: $BASH_COMMAND (line $LINENO) $(date -Is); log ${CUR_LOG:-none}" >> "$P/failures.log"' ERR
    point_config "$pt"
    exec 9>"$P/worker.lock"; flock -n 9
    {
        echo "point=$pt route=$route top=$top tb=$tb sha256=$(sha256sum "$REPO/$tb" | cut -d' ' -f1)"
        echo "glargs=$glargs"
        [[ -z "$stim" ]] || echo "stim=$stim sha256=$(sha256sum "$stim" | cut -d' ' -f1)"
        for f in "outputs/$top.apr.v" "outputs/$top.spef" "outputs/$top.apr.sdf" "$top.syn.sdc"; do
            echo "$(sha256sum "$route/$f" | cut -d' ' -f1)  $f"; done
        echo "route qualification: $(tr -d '\n ' < "$route/reports/popcount_qualification.json")"
    } > "$P/inputs.$(date +%Y%m%d_%H%M%S).txt"
    stage "$P" sim "$P/gl" do_sim "$pt" "$P"
    stage "$P" audit "$P/gl/timing_qualification.json" do_audit "$P"
    stage "$P" power "$P/power" do_power "$pt" "$P"
    stage "$P" classes "$P/classes/power_classes.json" do_classes "$pt" "$P"
    if [[ "$pt" == T128 || "$pt" == repro ]]; then stage "$P" gate "$P/saif_vs_headline.diff" do_gate "$pt" "$P"; fi
    stage "$P" result "$P/result.json" do_result "$pt" "$P"
    cat "$(ls -1 "$P"/result.attempt_*.log | tail -n 1)"
)

make_stims
status=0
if printf '%s\n' "${POINTS[@]}" | grep -qx T128; then
    run_point T128 &                      # background: errexit stays active inside the point
    wait $! || { echo "T128 headline gate FAILED: no other point runs" >&2; tail -n 3 "$OUT/T128/failures.log" >&2; exit 1; }
    echo "T128 reproduces the headline exactly; running the remaining points"
fi
for pt in "${POINTS[@]}"; do
    [[ "$pt" != T128 ]] || continue
    [[ -f "$OUT/T128/gate.status" ]] || { echo "T128 gate has not passed; refusing $pt" >&2; exit 1; }
    run_point "$pt" &
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
done
while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done
for pt in "${POINTS[@]}"; do
    [[ -f "$OUT/$pt/result.status" ]] || echo "[$pt] not complete: $(tail -n 1 "$OUT/$pt/failures.log" 2>/dev/null)" >&2
done

python3 - "$OUT" <<'PY'
import csv,json,sys
from pathlib import Path
out=Path(sys.argv[1])
order=['T16','T32','T48','T64','T80','T96','T112','T128','ladder','repro']
rows=[json.loads((out/p/'result.json').read_text()) for p in order if (out/p/'result.json').exists()]
if rows:
    keys=list(dict.fromkeys(k for r in rows for k in r))
    with (out/'results.csv').open('w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=keys); w.writeheader(); w.writerows(rows)
    lines=[f"{'point':7s} {'win':>5s} {'c/blk':>5s} {'mW':>8s} {'pJ/MAC':>7s} {'pJ/blk':>7s} {'u_pe':>7s} {'a_edge':>6s} {'w_edge':>6s} {'w_bank':>6s} {'clkbuf':>6s} drain GL"]
    for r in rows:
        lines.append(f"{r['point']:7s} {r['window_clocks']:5d} {r['cycles_per_block']:5.2f} {r['power_mW']:8.4f} {r['pJ_per_MAC']:7.4f} "
                     f"{r['pJ_per_block']:7.2f} {r['cls_u_pe_mW']:7.4f} {r['cls_a_edge_mW']:6.4f} {r['cls_w_edge_mW']:6.4f} "
                     f"{r['cls_w_bank_mW']:6.4f} {r['cls_clock_buffers_all_mW']:6.4f} {r['drain_bit_exact']} {r['gl_strict']}")
    (out/'results.txt').write_text('\n'.join(lines)+'\n'); print('\n'.join(lines))
PY
exit $status
