#!/bin/bash
# [CBSG-AF-IPD COPY] of sweeps/int_mode/bp/run_bp_int_energy.sh (sha256 at copy time in
# designs/payn/variants/signed_segmented_csa_cbsg_af_ipd/copied_from.sha256; the original is being edited by another
# session, this copy is frozen): INT energy of the ROUTED C-BSG AF + IPD INT design
# (payn_array_signed_segmented_csa_cbsg_af_ipd, TSMC22/PAYN_SC_CSA_CBSG_AF_IPD), driven through its real INT ports
# with the AF-IPD INT energy bench designs/payn/power/power_payn_array_cbsg_af_ipd_int.sv (the BP bench adapted to
# this top: 1-edge in-place laps, shift_in on drains only, AF-only inputs quiet).
#   bash sweeps/cbsg/af_ipd/run_af_ipd_int_energy.sh                  # the 7 points of the routed BP lap campaign
#   POINTS="int8_uniform_L1024_dr" bash sweeps/cbsg/af_ipd/run_af_ipd_int_energy.sh
#   RETRY_FAILED=1 / LIST_POINTS=1 / DRY_RUN=1   as the original
# Changes (marked [AF-IPD]):
#   * points, defines and PASS lines from sweeps/cbsg/af_ipd/af_ipd_int_energy_lib.sh (BPE_LAP_LEN=1,
#     BPE_LAP_RING_ONLY=1, the AF-IPD bench; default points = the BP lap campaign's seven);
#   * route gate: ROUTE_RUN (default cbsg_af_ipd_20261005_distguide_spp_pins_postfill) must be the final route of the
#     pinned campaign APR_CAMPAIGN_WORK (default build/power_char/cbsg_20261005/af_ipd/pinned: final_apr, qualify
#     and gate PASS, inputs.txt naming this target / top / final_route), final-qualified, and in the GRID basin;
#   * GL audit strict first, approvals only after a strict failure (the campaign library's cbsg_gl_audit: opt-in
#     AFIPD_GL_VALIDATOR_ARGS, rationale file $OUT/gl_validator_args_rationale.txt citing every flag; every outcome
#     in $OUT/gl_validator_args.txt and per point in gl/timing_qualification.json), as the AF and BP pinned
#     campaigns' SC GL, instead of the original's up-front GL_VALIDATOR_ARGS;
#   * checks: sweeps/cbsg/af_ipd/check_bp_power_trace.py --lap-len 1 --lap-ring-only (the variant's copy, identical
#     to the original modulo provenance); the INT SAIF audit sweeps/cbsg/af_ipd/af_ipd_saif_int_audit.py (the AF
#     edge instead of the Sobol edge: magnitudes, per-row L, kA encoder outputs and AF block-clock outputs at 0 /
#     static, bypass transparent per bit, int_mode high); the row writer sweeps/cbsg/af_ipd/af_ipd_int_energy_row.py
#     (u_rng instead of u_a_rng + u_w_rng);
#   * the RTL snapshot is the include closure of the AF-IPD top;
#   * view directories apr/build/TSMC22/PAYN_SC_CSA_CBSG_AF_IPD/${TAG}_<label>, TAG default intAFIPD;
#   * outputs build/power_char/cbsg_20261005/af_ipd/int_energy/<ROUTE_RUN>/ (results.csv; the comparison with the BP
#     lap campaign is sweeps/cbsg/af_ipd/compare_af_ipd_route.py, not summarize_bitplane_energy.py, which assumes
#     the Sobol banks).
#
# Original header:
# Bit-plane INT energy of the ROUTED bit-plane design (payn_array_signed_segmented_csa_bp,
# TSMC22/PAYN_SC_CSA_BP), driven through its real INT ports.
#   bash sweeps/int_mode/bp/run_bp_int_energy.sh                    # all 45 points
#   POINTS="int8_uniform_L1024_dr" bash sweeps/int_mode/bp/run_bp_int_energy.sh
#   RETRY_FAILED=1 bash sweeps/int_mode/bp/run_bp_int_energy.sh     # redo failed points
#   LIST_POINTS=1 ...   print the point table and exit (no route needed)
#   DRY_RUN=1 ...       every argument and route check, print the plan, create nothing
#   BPE_LAP_RING_ONLY=1 ...  per-PE lap-enable contract (csa_bp_20261004_lap
#                       routes): shift_in on drain edges only, laps on ring_q
#                       alone; default 0 = shift_in on lap edges too (the
#                       csa_bp_20261003b contract, still legal on one PE)
#
# The measured counterpart of sweeps/int_mode/run_bitplane_energy.sh (which
# emulated BP on the unchanged CSA route with forces): same points, operands,
# SAIF windows and result columns, plus u_combiner.  Bench:
# designs/payn/power/power_payn_array_bp_int.sv (header: mapping, contract,
# schedule, window modes); points: sweeps/int_mode/bp/bp_int_energy_lib.sh.
#
# Route gate (checked before anything else runs; exit 3 = refused):
#   * ROUTE_RUN (default csa_bp_20261003b_distguide_spp_fixed) must be the final
#     route of the APR campaign whose work dir is APR_CAMPAIGN_WORK (default
#     build/power_char/popcount_apr_csa_bp_20261003/csa_bp): its final_apr.status
#     must read PASS, and its inputs.txt must name this target/top and a
#     synthesis run whose _distguide_spp_fixed route is ROUTE_RUN;
#   * the route must hold outputs/<top>.apr.v/.apr.sdf/.spef, <top>.syn.sdc and
#     reports/popcount_qualification.json with qualification "final";
#   * an existing view directory must point at this route.
# Argument errors exit 2.
#
# Each point reuses the routed checkpoint through its own lightweight APR view
# directory apr/build/TSMC22/PAYN_SC_CSA_BP/${TAG}_<label> (TAG=intBP; symlinked
# outputs/ and <top>.syn.sdc, its own activity/ and reports/), exactly like
# sweeps/run_csa_t_sweep.sh, and gets the routed campaign's final qualification:
#   1. RTL preflight on an RTL snapshot ($OUT/rtl_snapshot, the include closure
#      of the BP top, pinned at the first run), LOW_W=9, DesignWare heap: every
#      drained tile and combiner word bit-exact (check_bp_power_trace.py, which
#      runs check_bp_trace.py unchanged) and the SAIF window counts exact
#   2. full-library max-SDF GL with +neg_tchk +sdfverbose; routed-timing audit
#      (sweeps/validate_routed_gl.py --expected-pass <the bench's PASS line>,
#      plus GL_VALIDATOR_ARGS, e.g. "--approve-negative-iopath-clamp-ps 10",
#      only the validator's two opt-in approvals are accepted, and they are
#      recorded); the same bit-exact check; GL trace and window record
#      byte-identical to RTL
#   3. SAIF validation with sweeps/validate_sc_power_saif.py.  It is the
#      validator the emulation campaign used, and none of its checks is SC-only:
#      clock TC and period (the 1 ps window marks keep duration / clock TC
#      exact), operand TC (the a_bits / w_bits nets, which in INT mode carry the
#      raw planes through the bypass OR; random_values stays static because the
#      Sobol banks are frozen), accumulator X-freeness (the tile accumulators are
#      the SC ones) and non-persistent X within one reporter quantum.  The
#      INT-only facts it cannot see are checked separately: window class counts
#      and combiner outputs by the bench and check_bp_power_trace.py, and the
#      contract's quiet SC side by sweeps/int_mode/bp/bp_saif_int_audit.py on
#      the same SAIF (magnitude inputs, comparator outputs, rng_en, acc_in_west
#      held at 0; Sobol outputs static and only clock nets toggling in the
#      banks; int_mode high; bypass output toggling exactly like the raw
#      planes, bit for bit).  Then PT-PX with
#      extracted parasitics (make power_apr on the view dir, the same validator
#      as POWER_SAIF_VALIDATOR) and sweeps/validate_pt_power_coverage.py
#   4. row.csv (sweeps/int_mode/bp/bp_int_energy_row.py): totals, u_pe /
#      u_peripheral / u_combiner / Sobol powers, MAC/cycle, pJ/MAC (full, array)
# Results: $OUT/results.csv, then sweeps/int_mode/summarize_bitplane_energy.py
# $OUT (the emulation campaign's reporting format: peak / +ring / +drain and the
# per-cycle-class energy split; its "toplevel" column includes u_combiner).
set -Eeuo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$REPO"
# shellcheck source=af_ipd_int_energy_lib.sh
source sweeps/cbsg/af_ipd/af_ipd_int_energy_lib.sh   # [AF-IPD]

ROUTE_RUN=${ROUTE_RUN:-cbsg_af_ipd_20261005_distguide_spp_pins_postfill}   # [AF-IPD]
APR_CAMPAIGN_WORK=${APR_CAMPAIGN_WORK:-build/power_char/cbsg_20261005/af_ipd/pinned}
TAG=${TAG:-intAFIPD}
OUT=${OUT:-build/power_char/cbsg_20261005/af_ipd/int_energy/$ROUTE_RUN}
MAX_JOBS=${MAX_JOBS:-4}
RETRY_FAILED=${RETRY_FAILED:-0}
DRY_RUN=${DRY_RUN:-0}
LIST_POINTS=${LIST_POINTS:-0}
AFIPD_GL_VALIDATOR_ARGS=${AFIPD_GL_VALIDATOR_ARGS:-}   # [AF-IPD] approvals only after a strict failure
GL_VALIDATOR_ARGS=$AFIPD_GL_VALIDATOR_ARGS
POINTS=${POINTS:-$BPE_DEFAULT_POINTS}
LAPCHK=(--lap-ring-only --lap-len "$BPE_LAP_LEN")   # [AF-IPD] lap_ring_only=1 lap_len=1 (the lib allows nothing else)
[[ "$OUT" == /* ]] || OUT="$REPO/$OUT"
[[ "$APR_CAMPAIGN_WORK" == /* ]] || APR_CAMPAIGN_WORK="$REPO/$APR_CAMPAIGN_WORK"
target=TSMC22/PAYN_SC_CSA_CBSG_AF_IPD   # [AF-IPD]
top=payn_array_signed_segmented_csa_cbsg_af_ipd
TB=$BPE_TB
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
# Validator approvals: only validate_routed_gl.py's two opt-in flags.
read -r -a VALIDATOR_ARGS <<< "$GL_VALIDATOR_ARGS"
for ((i = 0; i < ${#VALIDATOR_ARGS[@]}; i++)); do
    case "${VALIDATOR_ARGS[$i]}" in
        --approve-negative-iopath-clamp-ps)
            v=${VALIDATOR_ARGS[$((i + 1))]:-}
            [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] || usage_error "GL_VALIDATOR_ARGS: --approve-negative-iopath-clamp-ps needs a number of ps (got '$v')"
            i=$((i + 1));;
        --approve-annotated-interconnect) ;;
        *) usage_error "GL_VALIDATOR_ARGS: '${VALIDATOR_ARGS[$i]}' is not a validate_routed_gl.py approval (allowed: --approve-negative-iopath-clamp-ps PS, --approve-annotated-interconnect)";;
    esac
done
declare -A SEEN=()
LABELS=()
for label in $POINTS; do
    [[ ! -v SEEN[$label] ]] || usage_error "point $label listed twice"
    SEEN[$label]=1
    bpe_point_config "$label" || usage_error "invalid point $label"
    LABELS+=("$label")
done
((${#LABELS[@]})) || usage_error "no points"

if [[ "$LIST_POINTS" == 1 ]]; then
    printf '%-26s %2s %2s %6s %5s %5s %6s %4s %6s\n' label BA BW L MROWS NCOLS blocks mode active
    for label in "${LABELS[@]}"; do
        bpe_point_config "$label"
        printf '%-26s %2s %2s %6s %5s %5s %6s %4s %6s\n' "$label" "$BA" "$BW" "$L" "$MROWS" "$NCOLS" "$NBLK" "$MODE" "$ACTIVE"
    done
    echo "${#LABELS[@]} points"
    exit 0
fi

#--------------------------------------------------------------- route gate --
status_file="$APR_CAMPAIGN_WORK/final_apr.status"
[[ -f "$status_file" ]] || refuse "no final_apr status at $status_file: the routed campaign has not passed final_apr; not running on $ROUTE_RUN"
final_status=$(< "$status_file")
[[ "$final_status" == PASS ]] || refuse "final_apr status at $status_file is '$final_status', not PASS; not running on $ROUTE_RUN"
campaign_inputs="$APR_CAMPAIGN_WORK/inputs.txt"
[[ -f "$campaign_inputs" ]] || refuse "missing $campaign_inputs: cannot tell which route the PASS marker qualifies"
grep -qx "target=$target" "$campaign_inputs" && grep -qx "top=$top" "$campaign_inputs" \
    || refuse "$campaign_inputs is not a $target / $top campaign"
campaign_syn=$(sed -n 's/^synthesis=//p' "$campaign_inputs")
campaign_route="$(basename "$campaign_syn")_distguide_spp_fixed"
# Campaigns that name their final route explicitly (e.g. the pinned pass 2,
# build/power_char/pinned_pass2_20261004) qualify that route instead.
explicit_route=$(sed -n 's/^final_route=//p' "$campaign_inputs")
[[ -z "$explicit_route" ]] || campaign_route=$(basename "$explicit_route")
[[ "$campaign_route" == "$ROUTE_RUN" ]] \
    || refuse "the campaign in $APR_CAMPAIGN_WORK routed $campaign_route, not ROUTE_RUN=$ROUTE_RUN: its final_apr PASS does not qualify $ROUTE_RUN"
for f in "outputs/$top.apr.v" "outputs/$top.apr.sdf" "outputs/$top.spef" "$top.syn.sdc" reports/popcount_qualification.json; do
    [[ -s "$route/$f" ]] || refuse "route $route lacks $f"
done
python3 - "$route/reports/popcount_qualification.json" <<'PY' || refuse "route $route is not final-qualified (reports/popcount_qualification.json)"
import json, sys
q = json.load(open(sys.argv[1]))
sys.exit(0 if q.get('qualification') == 'final' and q.get('setup_wns_ns', -1) >= 0 and q.get('hold_wns_ns', -1) >= 0 else 1)
PY
# [AF-IPD] the pinned campaign's qualify and gate stages must have passed, the route must be in the grid basin.
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
# Informational: the campaign's own SC GL qualification of this route, and any
# validator approvals it was given (they are NOT inherited: pass them again in
# GL_VALIDATOR_ARGS after reading the campaign's timing_qualification.json).
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
    echo "out=$OUT tag=$TAG max_jobs=$MAX_JOBS retry_failed=$RETRY_FAILED lap_ring_only=$BPE_LAP_RING_ONLY"
    echo "validator args: ${VALIDATOR_ARGS[*]:-(none)}"
    echo "$campaign_note"
    for label in "${LABELS[@]}"; do
        bpe_point_config "$label"
        view="$REPO/apr/build/$target/${TAG}_${label}"
        state=new
        [[ ! -f "$OUT/$label/status" ]] || state="status=$(< "$OUT/$label/status")"
        [[ -f "$OUT/$label/status" || ! -e "$OUT/$label" ]] || state=unfinished
        printf '%s: BA=%s BW=%s L=%s MROWS=%s NCOLS=%s blocks=%s mode=%s active=%s view=%s(%s) %s\n  expect "%s"\n' \
            "$label" "$BA" "$BW" "$L" "$MROWS" "$NCOLS" "$NBLK" "$MODE" "$ACTIVE" "${view#"$REPO"/}" \
            "$([[ -e "$view" ]] && echo exists || echo to-create)" "$state" "$(bpe_pass_line)"
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
export SNPSLMD_QUEUE=true PYTHONDONTWRITEBYTECODE=1   # [AF-IPD] as the C-BSG drivers
# [AF-IPD] cbsg_gl_audit (strict first, approvals only after a strict failure, with a rationale file in $OUT).
source "$REPO/sweeps/cbsg/af_ipd/af_ipd_campaign_lib.sh"
arm=afipd

run_point() (
    local label=$1 BA BW L MROWS NCOLS DIST SEED MODE NBLK NB ROWS_PE ACTIVE
    bpe_point_config "$label"
    local work="$OUT/$label" simdir="$OUT/$label/gl" rtldir="$OUT/$label/rtl"
    local view_run="${TAG}_${label}" view="$REPO/apr/build/$target/${TAG}_${label}"
    local defs pass
    defs=$(bpe_defs)
    pass=$(bpe_pass_line)
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
    printf 'label=%s\ntarget=%s\nroute=%s\nview=%s\ncampaign=%s (final_apr %s; %s)\nBA=%s BW=%s L=%s MROWS=%s NCOLS=%s blocks=%s NB=%s\ndist=%s seed=%s saif_mode=%s active_intervals=%s\nlap_ring_only=%s\nglargs=%s\nvalidator_args=%s\nrtl_snapshot=%s\nstarted=%s\n' \
        "$label" "$target" "$route" "$view" "$APR_CAMPAIGN_WORK" "$(cat "$status_file")" "$campaign_note" \
        "$BA" "$BW" "$L" "$MROWS" "$NCOLS" "$NBLK" "$NB" "$DIST" "$SEED" "$MODE" "$ACTIVE" \
        "$BPE_LAP_RING_ONLY" "$glargs" "${VALIDATOR_ARGS[*]:-}" "$SNAP" "$(date -Is)" > "$work/inputs.txt"

    bpe_gen_stim "$work/stim" "$rtldir/$TB" "$simdir/$TB"

    echo "[$label] RTL preflight"
    make sim TOP=Top BUILD_DIR="$rtldir" TB="$TB" USE_DW=1 NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" \
        VCS_ARGS="+incdir+$SNAP ${defs//+define/ +define}" > "$rtldir/simulation.log" 2>&1
    grep -Fq "$pass" "$rtldir/simulation.log"
    python3 sweeps/cbsg/af_ipd/check_bp_power_trace.py "$rtldir/$TB" --json "$rtldir/check.json" \
        "${LAPCHK[@]}" > "$rtldir/check.log" 2>&1
    grep -q '^\[PASS\]' "$rtldir/check.log"
    rm -rf "$rtldir/$TB.obj" "$rtldir/$TB/simv.daidir" "$rtldir/$TB/simv" "$rtldir/$TB/dut.saif"

    echo "[$label] GL started"
    make sim GL=apr TARGET="$target" RUN="$ROUTE_RUN" TB="$TB" BUILD_DIR="$simdir" \
        SDF_CORNER=max NO_SDF= RTL_PREFLIGHT_CMD=true VCS_ARGS="$glargs" "VCS=$VCS_CMD" \
        NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" > "$simdir/simulation.log" 2>&1
    grep -Fq "$pass" "$simdir/simulation.log"
    grep -q 'sdf corner = max' "$simdir/simulation.log"
    grep -Fq '[INFO] $sdf_annotate(' "$simdir/simulation.log"
    # [AF-IPD] strict first; approvals only after a strict failure (AFIPD_GL_VALIDATOR_ARGS + rationale file).
    ( work=$OUT; cbsg_gl_audit "$simdir" "$pass" ) > "$simdir/timing_audit.log" 2>&1
    local saif="$simdir/$TB/dut.saif"
    [[ -s "$saif" ]]
    python3 sweeps/cbsg/af_ipd/check_bp_power_trace.py "$simdir/$TB" --json "$simdir/check.json" \
        "${LAPCHK[@]}" > "$simdir/check.log" 2>&1
    grep -q '^\[PASS\]' "$simdir/check.log"
    cmp -s "$rtldir/$TB/bpt_trace.txt" "$simdir/$TB/bpt_trace.txt"
    cmp -s "$rtldir/$TB/bpe_saif.txt" "$simdir/$TB/bpe_saif.txt"
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

    python3 sweeps/cbsg/af_ipd/af_ipd_int_energy_row.py "$work" "$label" --period-ns "$PERIOD" \
        --route "$ROUTE_RUN" > "$work/row.log" 2>&1
    printf 'PASS\n' > "$work/status"
    echo "[$label] complete: $(tail -n 1 "$work/row.csv")"
)

echo "route $ROUTE_RUN qualified; $campaign_note; validator args: ${VALIDATOR_ARGS[*]:-(none)}; lap_ring_only=$BPE_LAP_RING_ONLY"
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
rows.sort(key=lambda r: (r['precision'], r['dist'], int(r['L']), int(r['saif_mode'])))
if rows:
    with (out / 'results.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader(); writer.writerows(rows)
    print(f"{len(rows)} qualified points -> {out / 'results.csv'}")
PY
[[ ! -s "$OUT/results.csv" ]] || cat "$OUT/results.csv"   # [AF-IPD] summary: sweeps/cbsg/af_ipd/compare_af_ipd_route.py
exit "$status"
