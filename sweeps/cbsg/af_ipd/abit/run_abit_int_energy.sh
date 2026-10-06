#!/bin/bash
# [ABIT COPY] of sweeps/cbsg/af_ipd/run_af_ipd_int_energy.sh (sha256 fba87369...3f61 at copy time, 2026-10-06):
# routed INT energy of the ALL-BITS-IN-TIME schedule (doc/cbsg_handoff.md section 5) on the qualified AF-IPD route
# cbsg_af_ipd_20261005_distguide_spp_pins_postfill, with current-schedule controls on the same operands, measured
# exactly as the current schedule was: same route gate, RTL snapshot, full-library max-SDF GL (+neg_tchk
# +sdfverbose), routed-timing audit strict first with approvals only after a strict failure (cbsg_gl_audit of
# sweeps/cbsg/af_ipd/af_ipd_campaign_lib.sh, rationale file $OUT/gl_validator_args_rationale.txt), bit-exact drains
# on RTL and GL, GL trace and window record byte-identical to RTL, SAIF validation (validate_sc_power_saif.py) and
# the INT SAIF audit (af_ipd_saif_int_audit.py), then PT-PX with extracted parasitics through a PT-only view
# directory apr/build/TSMC22/PAYN_SC_CSA_CBSG_AF_IPD/${TAG}_<label> (symlinked outputs/ and SDC; the route directory
# is never written) and validate_pt_power_coverage.py.  Changes (marked [ABIT]):
#   * points, defines, PASS lines and checkers from sweeps/cbsg/af_ipd/abit/abit_int_energy_lib.sh: abit points run
#     the abit energy bench (designs/payn/power/power_payn_array_cbsg_af_ipd_int_abit.sv, checker
#     sweeps/cbsg/af_ipd/abit/check_abit_power_trace.py), cur points the unchanged current-schedule bench and
#     checker on the same operands;
#   * operands from sweeps/cbsg/af_ipd/abit/gen_abit_workload.py --dist plain (= gen_bitplane_workload.py's bytes);
#   * row writer sweeps/cbsg/af_ipd/abit/abit_int_energy_row.py (exact MAC accounting for any BA x BW, schedule and
#     block-period columns);
#   * optional per-class split (CLASSES="label ..."): sweeps/cbsg/af_ipd/run_pt_power_classes_af_ipd.sh on the point's
#     GL SAIF, must reproduce the point's PT total; output $OUT/<label>/classes/;
#   * TAG default abitAFIPD, OUT default build/power_char/cbsg_20261005/af_ipd/abit_int_energy/<ROUTE_RUN>.
#   bash sweeps/cbsg/af_ipd/abit/run_abit_int_energy.sh
#   POINTS="abit_int8_uniform_L384_dr" bash sweeps/cbsg/af_ipd/abit/run_abit_int_energy.sh
#   RETRY_FAILED=1 / LIST_POINTS=1 / DRY_RUN=1   as the original
set -Eeuo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
builtin cd "$REPO"
# shellcheck source=abit_int_energy_lib.sh
source sweeps/cbsg/af_ipd/abit/abit_int_energy_lib.sh   # [ABIT]

ROUTE_RUN=${ROUTE_RUN:-cbsg_af_ipd_20261005_distguide_spp_pins_postfill}
APR_CAMPAIGN_WORK=${APR_CAMPAIGN_WORK:-build/power_char/cbsg_20261005/af_ipd/pinned}
TAG=${TAG:-abitAFIPD}
OUT=${OUT:-build/power_char/cbsg_20261005/af_ipd/abit_int_energy/$ROUTE_RUN}
MAX_JOBS=${MAX_JOBS:-4}
RETRY_FAILED=${RETRY_FAILED:-0}
DRY_RUN=${DRY_RUN:-0}
LIST_POINTS=${LIST_POINTS:-0}
CLASSES=${CLASSES:-}
AFIPD_GL_VALIDATOR_ARGS=${AFIPD_GL_VALIDATOR_ARGS:-}   # approvals only after a strict failure
GL_VALIDATOR_ARGS=$AFIPD_GL_VALIDATOR_ARGS
POINTS=${POINTS:-$ABIT_DEFAULT_POINTS}
[[ "$OUT" == /* ]] || OUT="$REPO/$OUT"
[[ "$APR_CAMPAIGN_WORK" == /* ]] || APR_CAMPAIGN_WORK="$REPO/$APR_CAMPAIGN_WORK"
target=TSMC22/PAYN_SC_CSA_CBSG_AF_IPD
top=payn_array_signed_segmented_csa_cbsg_af_ipd
PERIOD=2.5
route="$REPO/apr/build/$target/$ROUTE_RUN"
SNAP="$OUT/rtl_snapshot"

usage_error() { echo "[usage] $*" >&2; exit 2; }
refuse() { echo "[refused] $*" >&2; exit 3; }

#--------------------------------------------------------------- arguments --
[[ "$ROUTE_RUN" =~ ^[A-Za-z0-9_]+$ ]] || usage_error "ROUTE_RUN='$ROUTE_RUN' must match [A-Za-z0-9_]+"
[[ "$TAG" =~ ^[A-Za-z0-9_]+$ ]] || usage_error "TAG='$TAG' must match [A-Za-z0-9_]+"
[[ "$MAX_JOBS" =~ ^[1-9][0-9]*$ ]] || usage_error "MAX_JOBS='$MAX_JOBS' must be a positive integer"
for flag in RETRY_FAILED DRY_RUN LIST_POINTS; do
    [[ "${!flag}" == 0 || "${!flag}" == 1 ]] || usage_error "$flag must be 0 or 1 (got '${!flag}')"
done
read -r -a VALIDATOR_ARGS <<< "$GL_VALIDATOR_ARGS"
for ((i = 0; i < ${#VALIDATOR_ARGS[@]}; i++)); do
    case "${VALIDATOR_ARGS[$i]}" in
        --approve-negative-iopath-clamp-ps)
            v=${VALIDATOR_ARGS[$((i + 1))]:-}
            [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] || usage_error "--approve-negative-iopath-clamp-ps needs a number of ps (got '$v')"
            i=$((i + 1));;
        --approve-annotated-interconnect) ;;
        *) usage_error "GL_VALIDATOR_ARGS: '${VALIDATOR_ARGS[$i]}' is not a validate_routed_gl.py approval";;
    esac
done
declare -A SEEN=()
LABELS=()
for label in $POINTS; do
    [[ ! -v SEEN[$label] ]] || usage_error "point $label listed twice"
    SEEN[$label]=1
    abit_point_config "$label" || usage_error "invalid point $label"
    LABELS+=("$label")
done
((${#LABELS[@]})) || usage_error "no points"
for label in $CLASSES; do [[ -v SEEN[$label] ]] || usage_error "CLASSES names $label, not a point of this run"; done

if [[ "$LIST_POINTS" == 1 ]]; then
    printf '%-28s %4s %2s %2s %5s %5s %5s %6s %4s %6s\n' label sched BA BW L MROWS NCOLS blocks mode active
    for label in "${LABELS[@]}"; do
        abit_point_config "$label"
        printf '%-28s %4s %2s %2s %5s %5s %5s %6s %4s %6s\n' "$label" "$SCHED" "$BA" "$BW" "$L" "$MROWS" "$NCOLS" \
            "$NBLK" "$MODE" "$ACTIVE"
    done
    echo "${#LABELS[@]} points"
    exit 0
fi

#--------------------------------------------------------------- route gate (the original's) --
status_file="$APR_CAMPAIGN_WORK/final_apr.status"
[[ -f "$status_file" ]] || refuse "no final_apr status at $status_file"
[[ "$(< "$status_file")" == PASS ]] || refuse "final_apr status at $status_file is not PASS"
campaign_inputs="$APR_CAMPAIGN_WORK/inputs.txt"
[[ -f "$campaign_inputs" ]] || refuse "missing $campaign_inputs"
grep -qx "target=$target" "$campaign_inputs" && grep -qx "top=$top" "$campaign_inputs" \
    || refuse "$campaign_inputs is not a $target / $top campaign"
campaign_syn=$(sed -n 's/^synthesis=//p' "$campaign_inputs")
campaign_route="$(basename "$campaign_syn")_distguide_spp_fixed"
explicit_route=$(sed -n 's/^final_route=//p' "$campaign_inputs")
[[ -z "$explicit_route" ]] || campaign_route=$(basename "$explicit_route")
[[ "$campaign_route" == "$ROUTE_RUN" ]] \
    || refuse "the campaign in $APR_CAMPAIGN_WORK routed $campaign_route, not ROUTE_RUN=$ROUTE_RUN"
for f in "outputs/$top.apr.v" "outputs/$top.apr.sdf" "outputs/$top.spef" "$top.syn.sdc" reports/popcount_qualification.json; do
    [[ -s "$route/$f" ]] || refuse "route $route lacks $f"
done
python3 - "$route/reports/popcount_qualification.json" <<'PY' || refuse "route $route is not final-qualified"
import json, sys
q = json.load(open(sys.argv[1]))
sys.exit(0 if q.get('qualification') == 'final' and q.get('setup_wns_ns', -1) >= 0 and q.get('hold_wns_ns', -1) >= 0 else 1)
PY
for st in qualify gate; do
    [[ -f "$APR_CAMPAIGN_WORK/$st.status" && "$(< "$APR_CAMPAIGN_WORK/$st.status")" == PASS ]] \
        || refuse "$APR_CAMPAIGN_WORK/$st.status is not PASS"
done
python3 - "$APR_CAMPAIGN_WORK/basin/basin_gate.json" "$APR_CAMPAIGN_WORK/qualification.json" <<'PY' || refuse "route $ROUTE_RUN is not in the grid basin or not final-qualified by the campaign"
import json, sys
b = json.load(open(sys.argv[1])); q = json.load(open(sys.argv[2]))
ok = b['gate']['basin'] == 'grid' and b['gate']['status'] == 'PASS' and b.get('pin_proof', {}).get('status') == 'PASS' \
     and q['qualification'] == 'final'
sys.exit(0 if ok else 1)
PY
final_sim_status=missing
[[ ! -f "$APR_CAMPAIGN_WORK/final_sim.status" ]] || final_sim_status=$(< "$APR_CAMPAIGN_WORK/final_sim.status")
campaign_approvals=none
[[ ! -s "$APR_CAMPAIGN_WORK/gl_validator_args.txt" ]] || campaign_approvals=$(tail -n 1 "$APR_CAMPAIGN_WORK/gl_validator_args.txt")
campaign_note="campaign final_sim status: $final_sim_status; campaign GL validator approvals: $campaign_approvals"
for label in "${LABELS[@]}"; do
    view="$REPO/apr/build/$target/${TAG}_${label}"
    [[ "$view" != "$route" ]] || refuse "view ${TAG}_${label} would be the route itself"
    if [[ -e "$view" || -L "$view/outputs" ]]; then
        [[ -L "$view/outputs" && "$(readlink -f "$view/outputs")" == "$(readlink -f "$route/outputs")" ]] \
            || refuse "view $view exists but is not a view of $ROUTE_RUN; choose another TAG"
    fi
done

if [[ "$DRY_RUN" == 1 ]]; then
    echo "DRY RUN: route $ROUTE_RUN qualified (final_apr PASS in $APR_CAMPAIGN_WORK)"
    echo "out=$OUT tag=$TAG max_jobs=$MAX_JOBS retry_failed=$RETRY_FAILED classes='$CLASSES'"
    echo "validator args: ${VALIDATOR_ARGS[*]:-(none)}"
    echo "$campaign_note"
    for label in "${LABELS[@]}"; do
        abit_point_config "$label"
        printf '%s: %s BA=%s BW=%s L=%s MROWS=%s NCOLS=%s blocks=%s mode=%s active=%s TB=%s\n  expect "%s"\n' \
            "$label" "$SCHED" "$BA" "$BW" "$L" "$MROWS" "$NCOLS" "$NBLK" "$MODE" "$ACTIVE" "$TB" "$(abit_pass_line)"
    done
    exit 0
fi

#--------------------------------------------------------------- run --
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
export SYNOPSYS=${SYNOPSYS:-/usr/caen/synopsys-synth-2021.06-SP1}
export ZERO_PINLESS_NET_ACTIVITY=1
export USE_DW=1 NTFY_CHNL=
export TSMC22_CELL_TIER=sc7mcpp140z TSMC22_LIB_FLAVORS=svt_c30
export TSMC22_HPK_FLAVORS=svt_c30 TSMC22_HPK=1
export PERIOD
unset NETLIST_FILE SDC_FILE SDF_FILE NO_SDF VCS_ARGS
VCS_CMD='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
export SNPSLMD_QUEUE=true PYTHONDONTWRITEBYTECODE=1
source "$REPO/sweeps/cbsg/af_ipd/af_ipd_campaign_lib.sh"
arm=afipd

run_point() (
    local label=$1 SCHED BA BW L MROWS NCOLS DIST SEED MODE NBLK NB ROWS_PE ACTIVE TB TRACE WINFILE
    abit_point_config "$label"
    local work="$OUT/$label" simdir="$OUT/$label/gl" rtldir="$OUT/$label/rtl"
    local view_run="${TAG}_${label}" view="$REPO/apr/build/$target/${TAG}_${label}"
    local defs pass
    defs=$(abit_defs)
    pass=$(abit_pass_line)
    local glargs="+define+PAYN_ARRAY_DUT=$top$defs +neg_tchk +sdfverbose"

    if [[ -f "$work/status" && "$(cat "$work/status")" == PASS ]]; then
        grep -qx "route=$route" "$work/inputs.txt" \
            || { echo "[$label] completed point belongs to another route; use another OUT" >&2; exit 1; }
        echo "[$label] reuse completed point"; exit 0
    fi
    if [[ -e "$work" ]]; then
        [[ "$RETRY_FAILED" == 1 ]] || { echo "[$label] unfinished point preserved; RETRY_FAILED=1 to redo" >&2; exit 1; }
        mv "$work" "$work.failed_$(date +%Y%m%d_%H%M%S)_$BASHPID"
    fi
    mkdir -p "$work/stim" "$simdir/$TB" "$rtldir/$TB"
    exec 9>"$work/worker.lock"; flock -n 9
    trap 'rc=$?; printf "FAILED label=%s exit=%s time=%s\n" "$label" "$rc" "$(date -Is)" >> "$work/failures.log"; exit "$rc"' ERR
    printf 'label=%s\nschedule=%s\ntarget=%s\nroute=%s\nview=%s\ncampaign=%s (final_apr %s; %s)\nBA=%s BW=%s L=%s MROWS=%s NCOLS=%s blocks=%s NB=%s\ndist=%s seed=%s saif_mode=%s active_intervals=%s\nbench=%s\nglargs=%s\nvalidator_args=%s\nrtl_snapshot=%s\nstarted=%s\n' \
        "$label" "$SCHED" "$target" "$route" "$view" "$APR_CAMPAIGN_WORK" "$(cat "$status_file")" "$campaign_note" \
        "$BA" "$BW" "$L" "$MROWS" "$NCOLS" "$NBLK" "$NB" "$DIST" "$SEED" "$MODE" "$ACTIVE" "$TB" \
        "$glargs" "${VALIDATOR_ARGS[*]:-}" "$SNAP" "$(date -Is)" > "$work/inputs.txt"

    abit_gen_stim "$work/stim" "$rtldir/$TB" "$simdir/$TB"

    echo "[$label] RTL preflight"
    make sim TOP=Top BUILD_DIR="$rtldir" TB="$TB" USE_DW=1 NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" \
        VCS_ARGS="+incdir+$SNAP ${defs//+define/ +define}" > "$rtldir/simulation.log" 2>&1
    grep -Fq "$pass" "$rtldir/simulation.log"
    abit_check "$rtldir/$TB" "$rtldir/check.json" > "$rtldir/check.log" 2>&1
    grep -q '^\[PASS\]' "$rtldir/check.log"
    rm -rf "$rtldir/$TB.obj" "$rtldir/$TB/simv.daidir" "$rtldir/$TB/simv" "$rtldir/$TB/dut.saif"

    echo "[$label] GL started"
    make sim GL=apr TARGET="$target" RUN="$ROUTE_RUN" TB="$TB" BUILD_DIR="$simdir" \
        SDF_CORNER=max NO_SDF= RTL_PREFLIGHT_CMD=true VCS_ARGS="$glargs" "VCS=$VCS_CMD" \
        NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" > "$simdir/simulation.log" 2>&1
    grep -Fq "$pass" "$simdir/simulation.log"
    grep -q 'sdf corner = max' "$simdir/simulation.log"
    grep -Fq '[INFO] $sdf_annotate(' "$simdir/simulation.log"
    ( work=$OUT; cbsg_gl_audit "$simdir" "$pass" ) > "$simdir/timing_audit.log" 2>&1
    local saif="$simdir/$TB/dut.saif"
    [[ -s "$saif" ]]
    abit_check "$simdir/$TB" "$simdir/check.json" > "$simdir/check.log" 2>&1
    grep -q '^\[PASS\]' "$simdir/check.log"
    cmp -s "$rtldir/$TB/$TRACE" "$simdir/$TB/$TRACE"
    cmp -s "$rtldir/$TB/$WINFILE" "$simdir/$TB/$WINFILE"
    python3 sweeps/validate_sc_power_saif.py "$saif" --expected-period-ns "$PERIOD" \
        > "$simdir/saif_validation.log" 2>&1
    python3 sweeps/cbsg/af_ipd/af_ipd_saif_int_audit.py "$saif" --json "$simdir/saif_int_audit.json" \
        > "$simdir/saif_int_audit.log" 2>&1
    rm -rf "$simdir/$TB.obj"
    echo "[$label] GL passed; PT-PX started"

    mkdir -p "$view/activity" "$view/reports"
    [[ -e "$view/outputs" ]] || ln -s "../$ROUTE_RUN/outputs" "$view/outputs"
    [[ -e "$view/$top.syn.sdc" ]] || ln -s "../$ROUTE_RUN/$top.syn.sdc" "$view/$top.syn.sdc"
    [[ "$(readlink -f "$view/outputs")" == "$(readlink -f "$route/outputs")" ]]
    POWER_SAIF_VALIDATOR="$REPO/sweeps/validate_sc_power_saif.py" \
        make power_apr TARGET="$target" RUN="$view_run" SAIF="$saif" SAIF_STRIP_PATH=Top/dut \
        NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" > "$work/power_make.log" 2>&1
    grep -q 'Report : Averaged Power' "$view/reports/power.rpt"
    python3 sweeps/validate_pt_power_coverage.py "$view/reports" \
        --power-log "$view/power_apr.log" --json "$view/reports/power_coverage.json" \
        > "$work/power_coverage.log" 2>&1
    mkdir -p "$work/power"
    cp -p "$view/power_apr.log" "$view"/reports/*.rpt "$view/reports/power_coverage.json" "$work/power/"

    python3 sweeps/cbsg/af_ipd/abit/abit_int_energy_row.py "$work" "$label" --period-ns "$PERIOD" \
        --route "$ROUTE_RUN" > "$work/row.log" 2>&1
    if [[ " $CLASSES " == *" $label "* ]]; then   # [ABIT] per-class split, read-only on the route
        echo "[$label] per-class split"
        bash sweeps/cbsg/af_ipd/run_pt_power_classes_af_ipd.sh "$route" "$top" "$saif" "$work/power/power.rpt" \
            "$work/classes" > "$work/classes.log" 2>&1
    fi
    printf 'PASS\n' > "$work/status"
    echo "[$label] complete: $(tail -n 1 "$work/row.csv")"
)

echo "route $ROUTE_RUN qualified; $campaign_note; validator args: ${VALIDATOR_ARGS[*]:-(none)}"
mkdir -p "$OUT"
bpe_snapshot "$SNAP"
status=0
for label in "${LABELS[@]}"; do
    run_point "$label" &
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
done
while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done

python3 - "$OUT" <<'PY'
import csv, sys
from pathlib import Path
out = Path(sys.argv[1])
rows = [next(csv.DictReader(p.open())) for p in sorted(out.glob('*/row.csv'))
        if (p.parent / 'status').is_file() and (p.parent / 'status').read_text().strip() == 'PASS']
rows.sort(key=lambda r: (r['schedule'], r['precision'], int(r['L']), int(r['saif_mode'])))
if rows:
    with (out / 'results.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader(); writer.writerows(rows)
    print(f"{len(rows)} qualified points -> {out / 'results.csv'}")
PY
exit "$status"
