# [CBSG-AF-IPD COPY] of sweeps/cbsg/cbsg_campaign_lib.sh (unchanged; sha256 in
# designs/payn/variants/signed_segmented_csa_cbsg_af_ipd/copied_from.sha256) for the route of the C-BSG AF + IPD
# INT variant.  Sourced by sweeps/cbsg/af_ipd/run_af_ipd_bootstrap.sh, run_af_ipd_pinned.sh and
# run_af_ipd_int_energy.sh.  Changes (marked [AF-IPD]): one arm, afipd, added to cbsg_arm_config /
# cbsg_workload_name / cbsg_header / cbsg_pass_regex; the af and rg arms are kept verbatim, so every helper below
# (cbsg_gl_sim, cbsg_gl_audit, cbsg_install_saif, cbsg_repair_accepts) is the campaign's own, byte for byte.
#   afipd  TSMC22/PAYN_SC_CSA_CBSG_AF_IPD  payn_array_signed_segmented_csa_cbsg_af_ipd  synthesis AFIPD_SYNTH_RUN
#          (cbsg_af_ipd_20261005); bench designs/payn/power/power_payn_array_cbsg_af_ipd.sv (the AF power bench on
#          the AF-IPD top in SC mode, INT inputs tied off; same schedule, operands, SAIF window and trace file as
#          the AF bench, so the AF checker sweeps/cbsg/af/check_power_trace.py and header apply); ladder workload
#          +define+CBSG_PWR_LADDER (the AF ladder, same stimulus).  Its PASS line names the top:
#          "PASS: streaming C-BSG AF SAIF captured (AF-IPD top, SC mode); workload ...".
#
# Original header:
# Arm definitions and GL helpers shared by sweeps/cbsg/run_cbsg_apr.sh and sweeps/cbsg/run_cbsg_pinned_pass2.sh.
# Sourced (not executed) after REPO, ASTRAEA_FLOW and VCS_CMD are set; the helpers expect the caller's per-arm
# locals (arm, work, target, top, TB, glargs, ...) from cbsg_arm_config.
#
# Arms (single PE, K8 M16 N8, TSMC22, 400 MHz, PAYN_SC_CSA knobs, INT ports absent):
#   af  TSMC22/PAYN_SC_CSA_CBSG_AF  payn_array_signed_segmented_csa_cbsg_af  synthesis AF_SYNTH_RUN (cbsg_af_20261005)
#       bench designs/payn/power/power_payn_array_cbsg_af.sv, checker sweeps/cbsg/af/check_power_trace.py
#       ladder workload +define+CBSG_PWR_LADDER (per-(row, 128-column chunk) L from the 14B target-48 ladder)
#   rg  TSMC22/PAYN_SC_CSA_CBSG_RG  payn_array_signed_segmented_csa_cbsg_rg  synthesis RG_SYNTH_RUN (cbsg_rg_20261005)
#       bench designs/payn/power/power_payn_array_cbsg_rg.sv, checker sweeps/cbsg/rg/check_power_trace.py
#       ladder workload RG_LADDER=rowmix (default: +define+CBSG_WL_LADDER, the same per-(row, chunk) draw as AF's)
#       or RG_LADDER=rowgrouped (+define+CBSG_WL_LADDER_GROUPED, one L per chunk for all 8 rows)
# Workload size: SC_BATCHES=384 blocks, i.e. 3,072 window clocks at L=128 -- the baseline's 384 batches x 8
# cycles -- and 196,608 kernel MACs (64 MAC/cycle).  Both benches settle two idle edges after reset, load inside
# the SAIF window and drain after $toggle_stop (headline power excludes the drain).

CBSG_BATCHES=384
CBSG_SEED_DEC=3735928559          # SC_SEED default 32'hDEAD_BEEF, as the RG trace header prints it
CBSG_GOLDEN="$REPO/build/cbsg/golden"

cbsg_arm_config() {   # arm -> target top synrun TB trace_name checker rng_insts ftb ladder_def ladder_name ladder_wl
    case "$1" in
        af) target=TSMC22/PAYN_SC_CSA_CBSG_AF; top=payn_array_signed_segmented_csa_cbsg_af
            synrun=${AF_SYNTH_RUN:-cbsg_af_20261005}
            TB=designs/payn/power/power_payn_array_cbsg_af.sv
            trace_name=array_streaming_cbsg_af_rtl.txt
            checker=sweeps/cbsg/af/check_power_trace.py
            rng_insts="u_rng"
            ftb=designs/payn/tb/test_payn_array_cbsg_af.sv
            ladder_def="+define+CBSG_PWR_LADDER"; ladder_name=ladder; ladder_wl=1;;
        rg) target=TSMC22/PAYN_SC_CSA_CBSG_RG; top=payn_array_signed_segmented_csa_cbsg_rg
            synrun=${RG_SYNTH_RUN:-cbsg_rg_20261005}
            TB=designs/payn/power/power_payn_array_cbsg_rg.sv
            trace_name=cbsg_rg_streaming_rtl.txt
            checker=sweeps/cbsg/rg/check_power_trace.py
            rng_insts="u_a_rng"
            ftb=designs/payn/tb/test_payn_array_cbsg_rg.sv
            case "${RG_LADDER:-rowmix}" in
                rowmix)     ladder_def="+define+CBSG_WL_LADDER"; ladder_name=ladder_rowmix; ladder_wl=1;;
                rowgrouped) ladder_def="+define+CBSG_WL_LADDER_GROUPED"; ladder_name=ladder_rowgrouped; ladder_wl=2;;
                *) echo "RG_LADDER must be rowmix or rowgrouped" >&2; return 2;;
            esac;;
        afipd) target=TSMC22/PAYN_SC_CSA_CBSG_AF_IPD; top=payn_array_signed_segmented_csa_cbsg_af_ipd   # [AF-IPD]
            synrun=${AFIPD_SYNTH_RUN:-cbsg_af_ipd_20261005}
            TB=designs/payn/power/power_payn_array_cbsg_af_ipd.sv
            trace_name=array_streaming_cbsg_af_rtl.txt
            checker=sweeps/cbsg/af/check_power_trace.py
            rng_insts="u_rng"
            ftb=designs/payn/tb/test_payn_array_cbsg_af_ipd.sv
            ladder_def="+define+CBSG_PWR_LADDER"; ladder_name=ladder; ladder_wl=1;;
        *) echo "Unknown arm: $1" >&2; return 2;;
    esac
    # The power benches' defines; PAYN_INT_PORTS is deliberately absent (the C-BSG tops have no INT ports).
    glargs="+define+PAYN_ARRAY_DUT=$top+define+SC_K=8+define+SC_M=16+define+SC_NH=8+define+SC_NW=8+define+SC_OWIDTH=24+define+SC_BATCHES=$CBSG_BATCHES +neg_tchk +sdfverbose"
}

cbsg_workload_name() {   # uniform|ladder -> the bench's workload name
    if [[ "$1" == uniform ]]; then
        [[ "$arm" == af || "$arm" == afipd ]] && echo "uniform L=128" || echo "uniform_L128"   # [AF-IPD] afipd
    else
        echo "$ladder_name"
    fi
}

cbsg_header() {   # workload number -> expected first trace line
    if [[ "$arm" == af || "$arm" == afipd ]]; then   # [AF-IPD] afipd: the AF trace file and header
        echo "CBSGAFSTREAM 8 16 8 8 24 $CBSG_BATCHES 16 $1"
    else
        echo "CBSGRG_STREAMCFG 8 16 8 8 24 $CBSG_BATCHES $1 16 $CBSG_SEED_DEC"
    fi
}

cbsg_pass_regex() {   # workload name -> ERE of the bench PASS line; group 1 = window clocks
    local w=$1
    if [[ "$arm" == afipd ]]; then   # [AF-IPD]
        echo "^PASS: streaming C-BSG AF SAIF captured \\(AF-IPD top, SC mode\\); workload ${w}, ${CBSG_BATCHES} blocks, ([0-9]+) window edges, drain dumped -> check_power_trace\\.py\$"
    elif [[ "$arm" == af ]]; then
        echo "^PASS: streaming C-BSG AF SAIF captured; workload ${w}, ${CBSG_BATCHES} blocks, ([0-9]+) window edges, drain dumped -> check_power_trace\.py\$"
    else
        echo "^PASS: CBSG-RG streaming SAIF captured; workload ${w}, ${CBSG_BATCHES} blocks, ([0-9]+) window clocks \($((CBSG_BATCHES * 512)) MACs\), drain dumped -> check_power_trace\.py\$"
    fi
}

cbsg_approvals() {   # the arm's opt-in GL approvals (AF_/RG_GL_VALIDATOR_ARGS, else GL_VALIDATOR_ARGS)
    local v="${arm^^}_GL_VALIDATOR_ARGS"
    echo "${!v:-${GL_VALIDATOR_ARGS:-}}"
}

# Full-timing max-SDF GL of the routed run with the arm's power bench, and every functional check of the
# original do_sim (bench PASS for the complete workload, max-corner SDF annotation, trace header, bit-exact drain
# recomputed by the trace checker, SAIF validation), plus: the trace's window equals the PASS line's, and the
# routed SDF is the one simulated, raw (no ideal-clock view), with every clock gate's CK->ECK well below the period.
# The timing audit is the separate stage cbsg_gl_audit.
#   cbsg_gl_sim RUN SIMDIR uniform|ladder
cbsg_gl_sim() {
    local run=$1 simdir=$2 wl=$3 route="$REPO/apr/build/$target/$1" defs="" wlname wlnum re line window
    wlname=$(cbsg_workload_name "$wl")
    wlnum=0
    if [[ "$wl" == ladder ]]; then defs=" $ladder_def"; wlnum=$ladder_wl; fi
    re=$(cbsg_pass_regex "$wlname")
    mkdir -p "$simdir"
    make sim GL=apr TARGET="$target" RUN="$run" TB="$TB" BUILD_DIR="$simdir" \
        SDF_CORNER=max NO_SDF= RTL_PREFLIGHT_CMD=true VCS_ARGS="$glargs$defs" "VCS=$VCS_CMD" \
        NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" > "$simdir/simulation.log" 2>&1
    line=$(grep -E "$re" "$simdir/simulation.log" | head -n 1 || true)
    [[ -n "$line" ]] || { echo "bench PASS line for workload '$wlname' missing in $simdir/simulation.log" >&2; return 1; }
    window=$(sed -E "s/$re/\\1/" <<< "$line")
    if [[ "$wl" == uniform && "$window" != $((CBSG_BATCHES * 8)) ]]; then
        echo "uniform workload ran $window window clocks, expected $((CBSG_BATCHES * 8))" >&2; return 1
    fi
    printf '%s\n' "$line" > "$simdir/expected_pass.txt"
    grep -q 'sdf corner = max' "$simdir/simulation.log"
    grep -Fq '[INFO] $sdf_annotate(' "$simdir/simulation.log"
    local trace="$simdir/$TB/$trace_name" saif="$simdir/$TB/dut.saif"
    [[ -s "$trace" && -s "$saif" ]]
    [[ "$(head -n 1 "$trace")" == "$(cbsg_header "$wlnum")" ]] || {
        echo "trace header '$(head -n 1 "$trace")' != '$(cbsg_header "$wlnum")'" >&2; return 1; }
    python3 "$checker" "$trace" --json "$simdir/trace_check.json" > "$simdir/trace_check.log" 2>&1
    grep -q '\[PASS\]' "$simdir/trace_check.log"
    python3 - "$simdir/trace_check.json" "$window" "$CBSG_BATCHES" <<'PY'
import json,sys
j=json.load(open(sys.argv[1])); window,blocks=int(sys.argv[2]),int(sys.argv[3])
w=j.get('window_edges', j.get('window_clocks'))
assert w==window and j['blocks']==blocks and not j['errors'], (w, window, j['blocks'], j['errors'])
print(f"trace check: {j['workload']}, {j['blocks']} blocks, {w} window clocks, drain bit-exact")
PY
    python3 sweeps/validate_sc_power_saif.py "$saif" --expected-period-ns 2.5 > "$simdir/saif_validation.log" 2>&1
    python3 sweeps/cbsg/routed_sdf_clock_audit.py "$route/outputs/$top.apr.sdf" --period-ns 2.5 \
        --sim-log "$simdir/simulation.log" --json "$simdir/sdf_clock_audit.json" > "$simdir/sdf_clock_audit.log" 2>&1
    cat "$simdir/trace_check.log" "$simdir/saif_validation.log" "$simdir/sdf_clock_audit.log"
}

# Routed-GL timing audit, strict first (no approvals).  Only if the strict audit fails are approvals applied, and
# only the arm's opt-in set (AF_GL_VALIDATOR_ARGS / RG_GL_VALIDATOR_ARGS, else GL_VALIDATOR_ARGS), only --approve-*
# flags, and only with a rationale file beside the run ($work/gl_validator_args_rationale.txt) that cites every
# flag used -- the practice of the earlier campaigns.  Every outcome is appended to $work/gl_validator_args.txt and
# recorded in SIMDIR/timing_qualification.json (approvals listed there must be reviewed before quoting a result).
#   cbsg_gl_audit SIMDIR [EXPECTED_PASS]   (default: SIMDIR/expected_pass.txt)
cbsg_gl_audit() {
    local simdir=$1 pass=${2:-} strict=PASS used rationale="$work/gl_validator_args_rationale.txt" tok prev=""
    [[ -n "$pass" ]] || pass=$(cat "$simdir/expected_pass.txt")
    python3 sweeps/validate_routed_gl.py "$simdir/simulation.log" --expected-pass "$pass" \
        --json "$simdir/timing_qualification_strict.json" > "$simdir/timing_validation_strict.log" 2>&1 || strict=FAIL
    used=""
    if [[ "$strict" == PASS ]]; then
        cp -p "$simdir/timing_qualification_strict.json" "$simdir/timing_qualification.json"
    else
        used=$(cbsg_approvals)
        python3 -c 'import json,sys; print("strict audit FAILED:", json.load(open(sys.argv[1]))["rejection_reasons"])' \
            "$simdir/timing_qualification_strict.json" >&2 || true
        if [[ -z "$used" ]]; then
            echo "No approvals given. Investigate, write $rationale, then rerun with ${arm^^}_GL_VALIDATOR_ARGS='...' RETRY_FAILED=1 (the simulation stage is reused)." >&2
            return 1
        fi
        [[ -s "$rationale" ]] || { echo "Approvals '$used' need a rationale file: $rationale" >&2; return 1; }
        for tok in $used; do
            if [[ "$tok" == --approve-* ]]; then
                grep -qF -- "$tok" "$rationale" || { echo "$rationale does not cite $tok" >&2; return 1; }
            elif [[ "$prev" != --approve-negative-iopath-clamp-ps || ! "$tok" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                echo "Only --approve-* validator flags are accepted as approvals (got '$tok')" >&2; return 1
            fi
            prev=$tok
        done
        # shellcheck disable=SC2086
        # The verdict is read from the JSON below, after the outcome is recorded.
        python3 sweeps/validate_routed_gl.py "$simdir/simulation.log" --expected-pass "$pass" $used \
            --json "$simdir/timing_qualification.json" > "$simdir/timing_validation.log" 2>&1 || true
    fi
    python3 - "$simdir" "$strict" "$used" >> "$work/gl_validator_args.txt" <<'PY'
import json,sys,datetime
simdir,strict,used=sys.argv[1:]
s=json.load(open(f'{simdir}/timing_qualification_strict.json'))
q=json.load(open(f'{simdir}/timing_qualification.json'))
print(f"{datetime.datetime.now().isoformat(timespec='seconds')} {simdir} strict={strict} strict_reasons={s['rejection_reasons']} "
      f"approvals_used='{used}' sdf_warnings={q['sdf_warning_categories']} "
      f"ndi_clamps={len(q['approved_negative_iopath_clamps'])} "
      f"worst_clamp_ps={min([c['most_negative_ps'] for c in q['approved_negative_iopath_clamps']] or [0])} "
      f"iwsba={len(q['approved_annotated_interconnects'])} post_reset_violations={q['post_reset_timing_violations']} status={q['status']}")
PY
    tail -n 1 "$work/gl_validator_args.txt"
    python3 -c 'import json,sys; q=json.load(open(sys.argv[1])); sys.exit(0 if q["status"]=="PASS" else 1)' \
        "$simdir/timing_qualification.json"
}

# Install an audited GL SAIF as the route's activity file (as the original do_sim did, after the audit here).
cbsg_install_saif() {   # SIMDIR ROUTE_DIR
    local saif="$1/$TB/dut.saif" route=$2
    mkdir -p "$route/activity"
    [[ ! -e "$route/activity/dut.saif" ]] || cp -p "$route/activity/dut.saif" "$1/previous_route_activity.saif"
    cp "$saif" "$route/activity/dut.saif"
    echo "installed $saif -> $route/activity/dut.saif"
}

# Does sweeps/repair_popcount_apr.sh accept this target?  (Its target case list predates the C-BSG targets.)
cbsg_repair_accepts() {   # target
    grep -E '^case "\$TARGET" in ' "$REPO/sweeps/repair_popcount_apr.sh" | head -n 1 \
        | sed -E 's/^case "\$TARGET" in ([^)]*)\).*/\1/' | tr '|' '\n' | grep -qxF "$1"
}
