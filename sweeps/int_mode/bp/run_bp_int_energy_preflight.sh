#!/bin/bash
# Validation of the BP INT energy bench and its routed driver that needs no
# routed netlist (the route TSMC22/PAYN_SC_CSA_BP/csa_bp_20261003b_distguide_spp_fixed
# is produced separately).
#   bash sweeps/int_mode/bp/run_bp_int_energy_preflight.sh             # rtl syngl dry rowtest
#   PARTS="rtl" POINTS="int8_uniform_L1024_dr" bash sweeps/int_mode/bp/run_bp_int_energy_preflight.sh
#
#   rtl     every point of sweeps/int_mode/bp/bp_int_energy_lib.sh (45 by default)
#           on the working-tree RTL (LOW_W=9, DesignWare), configured by the same
#           compile-time defines the routed driver uses: the bench's exact PASS
#           line, every drained tile and combiner word bit-exact and the SAIF
#           window counts exact (check_bp_power_trace.py); the operands equal
#           the emulation campaign's (build/power_char/int_mode_energy_20261003/
#           bitplane/<label>/stim, where present); and the three window modes of
#           each (precision, dist, L) give byte-identical traces (windowing does
#           not perturb the run).
#   syngl   SYN_POINTS on the synthesized netlist (RUN=csa_bp_20261003b), NO_SDF,
#           unit delay, timing checks off, ARM_UD_MODEL + ARM_EN_X_SQUASH, as
#           sweeps/run_csa_bp_syn_gl_checks.sh: PASS line, bit-exact check, trace
#           and window record byte-identical to the RTL run of the same point,
#           SAIF captured, sweeps/validate_sc_power_saif.py and
#           sweeps/int_mode/bp/bp_saif_int_audit.py passing (and the audit
#           rejecting the SC streaming SAIF of the same netlist).  Unit
#           delay puts every flop output exactly on the +1 ps window marks, so
#           these SAIFs prove the mechanics (window, X-freeness, validator), not
#           the per-class attribution; power numbers come only from the routed
#           max-SDF runs.
#   dry     run_bp_int_energy.sh argument and refusal logic, without the route
#           (expected exit codes: 0 listed, 2 argument error, 3 refused), and
#           proof that no view directory or output was created.
#   rowtest bp_int_energy_row.py on fixture PT reports (the emulation
#           campaign's int8_uniform_L1024_dr reports plus an injected u_combiner
#           line) with an RTL check.json: a parser test, not a measurement.
# Logs: build/rtl_preflight/csa_bp_power_{rtl,syngl,dry,rowtest}.log, per-point
# dirs build/rtl_preflight/csa_bp_power_{rtl,syngl}/<label>/.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$REPO"
# shellcheck source=bp_int_energy_lib.sh
source sweeps/int_mode/bp/bp_int_energy_lib.sh
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
export SYNOPSYS=${SYNOPSYS:-/usr/caen/synopsys-synth-2021.06-SP1}
export USE_DW=1 NTFY_CHNL=
export TSMC22_CELL_TIER=sc7mcpp140z TSMC22_LIB_FLAVORS=svt_c30
export TSMC22_HPK_FLAVORS=svt_c30 TSMC22_HPK=1
unset NETLIST_FILE SDC_FILE SDF_FILE NO_SDF VCS_ARGS
PARTS=${PARTS:-"rtl syngl dry rowtest"}
POINTS=${POINTS:-$BPE_DEFAULT_POINTS}
SYN_POINTS=${SYN_POINTS:-"int8_uniform_L49152_d int8_uniform_L1024_dr int8_uniform_L1024_all int4_gauss_L1024_dr w4a8_relu_L98304_d"}
SYN_RUN=${SYN_RUN:-csa_bp_20261003b}
MAX_JOBS=${MAX_JOBS:-8}
TB=$BPE_TB
OUT=build/rtl_preflight
EMU=build/power_char/int_mode_energy_20261003/bitplane
TARGET=TSMC22/PAYN_SC_CSA_BP
TOP=payn_array_signed_segmented_csa_bp
VCS_GL='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
GLDEF="+define+ARM_UD_MODEL+define+ARM_EN_X_SQUASH +delay_mode_unit +notimingcheck"
mkdir -p "$OUT"

#------------------------------------------------------------------ rtl --
rtl_point() (
    local label=$1 BA BW L MROWS NCOLS DIST SEED MODE NBLK NB ROWS_PE ACTIVE
    bpe_point_config "$label"
    local dir="$OUT/csa_bp_power_rtl/$label" defs pass note=""
    defs=$(bpe_defs)
    pass=$(bpe_pass_line)
    rm -rf "$dir"; mkdir -p "$dir/$TB"
    bpe_gen_stim "$dir/stim" "$dir/$TB"
    make sim TOP=Top BUILD_DIR="$dir" TB="$TB" USE_DW=1 NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" \
        VCS_ARGS="${defs//+define/ +define}" > "$dir/simulation.log" 2>&1 \
        || { echo "$label: FAIL (simulation error, see $dir/simulation.log)"; exit 1; }
    grep -Fq "$pass" "$dir/simulation.log" || { echo "$label: FAIL (no '$pass')"; exit 1; }
    python3 sweeps/int_mode/bp/check_bp_power_trace.py "$dir/$TB" --json "$dir/check.json" > "$dir/check.log" 2>&1 \
        || { echo "$label: FAIL $(tail -n 1 "$dir/check.log")"; exit 1; }
    if [[ -f "$EMU/$label/stim/intb_a.hex" ]]; then
        cmp -s "$dir/stim/intb_a.hex" "$EMU/$label/stim/intb_a.hex" && cmp -s "$dir/stim/intb_w.hex" "$EMU/$label/stim/intb_w.hex" \
            || { echo "$label: FAIL (operands differ from the emulation campaign's)"; exit 1; }
        note=" [operands = emulation campaign's]"
    fi
    rm -rf "$dir/$TB.obj" "$dir/$TB/simv" "$dir/$TB/simv.daidir" "$dir/$TB/dut.saif"
    echo "$label: PASS $(tail -n 1 "$dir/check.log" | sed 's/^\[PASS\] //')$note"
)

run_rtl() {
    local status=0 label key
    declare -A first=()
    for label in $POINTS; do
        bpe_point_config "$label" || return 1
        rtl_point "$label" &
        while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
    done
    while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done
    # Window modes of one (precision, dist, L) triple: identical traces.
    local groups=0
    for label in $POINTS; do
        key=${label%_*}
        [[ -f "$OUT/csa_bp_power_rtl/$label/$TB/bpt_trace.txt" ]] || continue
        if [[ -v first[$key] ]]; then
            if cmp -s "$OUT/csa_bp_power_rtl/${first[$key]}/$TB/bpt_trace.txt" "$OUT/csa_bp_power_rtl/$label/$TB/bpt_trace.txt"; then
                echo "  trace $label == ${first[$key]}"
            else
                echo "  FAIL: trace $label differs from ${first[$key]}"; status=1
            fi
        else
            first[$key]=$label; groups=$((groups + 1))
        fi
    done
    echo "RTL: $(wc -w <<< "$POINTS") points in $groups (precision, dist, L) groups, status $([[ $status == 0 ]] && echo PASS || echo FAIL)"
    return "$status"
}

#---------------------------------------------------------------- syngl --
syngl_point() (
    local label=$1 BA BW L MROWS NCOLS DIST SEED MODE NBLK NB ROWS_PE ACTIVE
    bpe_point_config "$label"
    local dir="$OUT/csa_bp_power_syngl/$label" rtl="$OUT/csa_bp_power_rtl/$label/$TB" defs pass
    defs=$(bpe_defs)
    pass=$(bpe_pass_line)
    rm -rf "$dir"; mkdir -p "$dir/$TB"
    bpe_gen_stim "$dir/stim" "$dir/$TB"
    make sim GL=syn TARGET="$TARGET" RUN="$SYN_RUN" TB="$TB" BUILD_DIR="$dir" NO_SDF=1 \
        RTL_PREFLIGHT_CMD=true "VCS=$VCS_GL" VCS_ARGS="+define+PAYN_ARRAY_DUT=$TOP$defs $GLDEF" \
        NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" > "$dir/simulation.log" 2>&1 \
        || { echo "$label: FAIL (GL simulation error, see $dir/simulation.log)"; exit 1; }
    grep -Fq "$pass" "$dir/simulation.log" || { echo "$label: FAIL (no '$pass')"; exit 1; }
    if grep -nE '\[X-FAIL\]|\[TIMING-FAIL\]|TIMEOUT @|Error-\[' "$dir/simulation.log" > "$dir/errors.txt"; then
        echo "$label: FAIL (errors in log, see $dir/errors.txt)"; exit 1
    fi
    python3 sweeps/int_mode/bp/check_bp_power_trace.py "$dir/$TB" --json "$dir/check.json" > "$dir/check.log" 2>&1 \
        || { echo "$label: FAIL $(tail -n 1 "$dir/check.log")"; exit 1; }
    cmp -s "$dir/$TB/bpt_trace.txt" "$rtl/bpt_trace.txt" || { echo "$label: FAIL (GL trace differs from RTL)"; exit 1; }
    cmp -s "$dir/$TB/bpe_saif.txt" "$rtl/bpe_saif.txt" || { echo "$label: FAIL (GL window record differs from RTL)"; exit 1; }
    [[ -s "$dir/$TB/dut.saif" ]] || { echo "$label: FAIL (no SAIF)"; exit 1; }
    python3 sweeps/validate_sc_power_saif.py "$dir/$TB/dut.saif" --expected-period-ns 2.5 \
        > "$dir/saif_validation.log" 2>&1 || { echo "$label: FAIL (SAIF validator: $(tail -n 1 "$dir/saif_validation.log"))"; exit 1; }
    python3 sweeps/int_mode/bp/bp_saif_int_audit.py "$dir/$TB/dut.saif" --json "$dir/saif_int_audit.json" \
        > "$dir/saif_int_audit.log" 2>&1 || { echo "$label: FAIL (INT SAIF audit: $(tail -n 1 "$dir/saif_int_audit.log"))"; exit 1; }
    rm -rf "$dir/$TB.obj" "$dir/$TB/simv" "$dir/$TB/simv.daidir"
    echo "$label: PASS (GL trace and window identical to RTL) $(tail -n 1 "$dir/check.log" | sed 's/^\[PASS\] //')"
    echo "    $(cat "$dir/saif_validation.log")"
    echo "    $(tail -n 1 "$dir/saif_int_audit.log")"
)

run_syngl() {
    local status=0 label
    [[ -s "syn/build/$TARGET/$SYN_RUN/$TOP.syn.v" ]] || { echo "missing netlist for $SYN_RUN"; return 1; }
    for label in $SYN_POINTS; do
        [[ -f "$OUT/csa_bp_power_rtl/$label/$TB/bpt_trace.txt" ]] || { echo "$label: run PARTS=rtl first"; status=1; continue; }
        syngl_point "$label" &
        while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
    done
    while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done
    # Negative control for the INT audit: the SC streaming SAIF of the same
    # netlist (sweeps/run_csa_bp_syn_gl_checks.sh) must be rejected.
    local sc_saif="$OUT/csa_bp_syn_gl_sc_stream/designs/payn/power/power_payn_array.sv/dut.saif"
    if [[ -s "$sc_saif" ]]; then
        if python3 sweeps/int_mode/bp/bp_saif_int_audit.py "$sc_saif" > "$OUT/csa_bp_power_syngl/sc_saif_audit.log" 2>&1; then
            echo "INT SAIF audit negative control: FAIL (accepted the SC-mode SAIF $sc_saif)"; status=1
        else
            echo "INT SAIF audit negative control: PASS (SC-mode SAIF rejected: $(tail -n 1 "$OUT/csa_bp_power_syngl/sc_saif_audit.log" | cut -c1-160)...)"
        fi
    else
        echo "INT SAIF audit negative control: SKIPPED (no $sc_saif; run sweeps/run_csa_bp_syn_gl_checks.sh)"
    fi
    echo "post-synthesis GL: $(wc -w <<< "$SYN_POINTS") points, status $([[ $status == 0 ]] && echo PASS || echo FAIL)"
    return "$status"
}

#------------------------------------------------------------------ dry --
DRIVER=sweeps/int_mode/bp/run_bp_int_energy.sh
DRY=$OUT/csa_bp_power_dry
dry_case() {   # name expected_rc expected_regex env...   (DRIVER_PATH overrides the driver)
    local name=$1 want=$2 regex=$3 rc=0
    shift 3
    env -u ROUTE_RUN -u APR_CAMPAIGN_WORK -u TAG -u OUT -u POINTS -u GL_VALIDATOR_ARGS \
        -u DRY_RUN -u LIST_POINTS -u MAX_JOBS -u RETRY_FAILED "$@" bash "${DRIVER_PATH:-$DRIVER}" \
        > "$DRY/$name.log" 2>&1 || rc=$?
    if [[ "$rc" == "$want" ]] && grep -Eq "$regex" "$DRY/$name.log"; then
        echo "$name: PASS (exit $rc: $(grep -Em1 "$regex" "$DRY/$name.log" | cut -c1-150))"
    else
        echo "$name: FAIL (exit $rc, expected $want and /$regex/; see $DRY/$name.log)"; return 1
    fi
}

run_dry() {
    local status=0 camp views_before views_after out_probe
    rm -rf "$DRY"; mkdir -p "$DRY"
    out_probe="$REPO/$DRY/out_must_not_exist"
    views_before=$(compgen -G "apr/build/$TARGET/intBP_*" | sort || true)
    # Fake campaign work dirs (workspace only) for the marker / provenance cases.
    for camp in fail pass_other pass_match; do mkdir -p "$DRY/campaign_$camp"; done
    printf 'FAIL\n' > "$DRY/campaign_fail/final_apr.status"
    printf 'PASS\n' > "$DRY/campaign_pass_other/final_apr.status"
    printf 'PASS\n' > "$DRY/campaign_pass_match/final_apr.status"
    for camp in fail pass_other pass_match; do
        local syn=csa_bp_20261003b
        [[ "$camp" != pass_other ]] || syn=csa_bp_20261003
        printf 'target=%s\ntop=%s\nsynthesis=%s/syn/build/%s/%s\n' "$TARGET" "$TOP" "$REPO" "$TARGET" "$syn" \
            > "$DRY/campaign_$camp/inputs.txt"
    done
    dry_case list_default 0 '^45 points$' LIST_POINTS=1 || status=1
    dry_case list_subset_with_approvals 0 '^2 points$' LIST_POINTS=1 \
        POINTS="w4a8_relu_L1024_all int4_gauss_L98304_d" \
        GL_VALIDATOR_ARGS="--approve-negative-iopath-clamp-ps 10 --approve-annotated-interconnect" || status=1
    dry_case bad_precision 2 'bad precision' POINTS=int2_uniform_L1024_d || status=1
    dry_case bad_window 2 'bad window' POINTS=int8_uniform_L1024_x || status=1
    dry_case bad_L 2 'not a multiple of 128' POINTS=int8_uniform_L1000_d || status=1
    dry_case overflow_L 2 'overflow the 24-bit tiles' POINTS=int8_uniform_L65536_d || status=1
    dry_case duplicate_point 2 'listed twice' POINTS="int8_gauss_L1024_d int8_gauss_L1024_d" || status=1
    dry_case bad_validator_flag 2 'not a validate_routed_gl.py approval' GL_VALIDATOR_ARGS="--no-timing-checks" || status=1
    dry_case bad_validator_value 2 'needs a number of ps' GL_VALIDATOR_ARGS="--approve-negative-iopath-clamp-ps ten" || status=1
    dry_case bad_route_name 2 'ROUTE_RUN=.* must match' ROUTE_RUN="csa_bp;rm" || status=1
    dry_case bad_max_jobs 2 'MAX_JOBS' MAX_JOBS=0 || status=1
    dry_case bad_dry_flag 2 'DRY_RUN must be 0 or 1' DRY_RUN=yes || status=1
    # Refusals: the real campaign state now, then fake markers.
    dry_case refuse_real_campaign 3 'no final_apr status' OUT="$out_probe" || status=1
    dry_case refuse_real_campaign_dry 3 'no final_apr status' DRY_RUN=1 OUT="$out_probe" || status=1
    dry_case refuse_status_fail 3 "status .* is 'FAIL'" APR_CAMPAIGN_WORK="$DRY/campaign_fail" OUT="$out_probe" || status=1
    dry_case refuse_other_route 3 'routed csa_bp_20261003_distguide_spp_fixed, not ROUTE_RUN' \
        APR_CAMPAIGN_WORK="$DRY/campaign_pass_other" OUT="$out_probe" || status=1
    dry_case refuse_renamed_route 3 'not ROUTE_RUN=csa_bp_20261003b_distguide' \
        APR_CAMPAIGN_WORK="$DRY/campaign_pass_match" ROUTE_RUN=csa_bp_20261003b_distguide OUT="$out_probe" || status=1
    if [[ -s "apr/build/$TARGET/csa_bp_20261003b_distguide_spp_fixed/outputs/$TOP.spef" ]]; then
        echo "route_outputs_missing: SKIPPED (the route now exists; run DRY_RUN=1 against the real campaign instead)"
    else
        dry_case refuse_route_outputs_missing 3 'lacks outputs/' \
            APR_CAMPAIGN_WORK="$DRY/campaign_pass_match" OUT="$out_probe" || status=1
    fi
    views_after=$(compgen -G "apr/build/$TARGET/intBP_*" | sort || true)
    if [[ "$views_before" == "$views_after" && -z "$views_after" && ! -e "$out_probe" ]]; then
        echo "no view directory (apr/build/$TARGET/intBP_*) and no output directory created"
    else
        echo "FAIL: dry runs created files (views: '$views_after', out probe exists: $([[ -e "$out_probe" ]] && echo yes || echo no))"
        status=1
    fi
    # Positive route gate, in a sandbox repo root under $DRY: byte-identical
    # copies of the driver and lib, a PASS campaign marker and a fake final
    # route (dummy outputs).  The real apr/build is never written.
    local sb="$REPO/$DRY/sandbox" rr=csa_bp_20261003b_distguide_spp_fixed
    local sroute="$sb/apr/build/$TARGET/$rr"
    mkdir -p "$sb/sweeps/int_mode/bp" "$sroute/outputs" "$sroute/reports" "$sb/campaign"
    cp -p "$DRIVER" sweeps/int_mode/bp/bp_int_energy_lib.sh "$sb/sweeps/int_mode/bp/"
    if ! cmp -s "$DRIVER" "$sb/$DRIVER" || ! cmp -s sweeps/int_mode/bp/bp_int_energy_lib.sh "$sb/sweeps/int_mode/bp/bp_int_energy_lib.sh"; then
        echo "FAIL: sandbox copies differ"; return 1
    fi
    for f in "outputs/$TOP.apr.v" "outputs/$TOP.apr.sdf" "outputs/$TOP.spef" "$TOP.syn.sdc"; do echo dummy > "$sroute/$f"; done
    printf '{"qualification": "final", "setup_wns_ns": 0.012, "hold_wns_ns": 0.004}\n' > "$sroute/reports/popcount_qualification.json"
    printf 'PASS\n' > "$sb/campaign/final_apr.status"
    printf 'PASS\n' > "$sb/campaign/final_sim.status"
    printf 'GL_VALIDATOR_ARGS=--approve-negative-iopath-clamp-ps 10 (fixture)\n' > "$sb/campaign/gl_validator_args.txt"
    cp -p "$DRY/campaign_pass_match/inputs.txt" "$sb/campaign/inputs.txt"
    local sbenv=(APR_CAMPAIGN_WORK="$sb/campaign" POINTS="int8_uniform_L49152_d int8_uniform_L1024_dr")
    DRIVER_PATH="$sb/$DRIVER" dry_case sandbox_dry_plan 0 '^DRY RUN: route csa_bp_20261003b_distguide_spp_fixed qualified' \
        DRY_RUN=1 GL_VALIDATOR_ARGS="--approve-negative-iopath-clamp-ps 10" "${sbenv[@]}" || status=1
    grep -q 'expect "PASS: BP INT SAIF captured; BA=8 BW=8 L=1024 blocks=48 mode=0 active=5760 drained=384 combined=384"' \
        "$DRY/sandbox_dry_plan.log" && grep -q 'validator args: --approve-negative-iopath-clamp-ps 10' "$DRY/sandbox_dry_plan.log" \
        && grep -q 'campaign final_sim status: PASS; campaign GL validator approvals: GL_VALIDATOR_ARGS=--approve-negative-iopath-clamp-ps 10' \
            "$DRY/sandbox_dry_plan.log" \
        && echo "  plan lists the expected PASS line, view apr/build/$TARGET/intBP_<label>, the validator approval and the campaign's final_sim note" \
        || { echo "  FAIL: plan incomplete"; status=1; }
    if [[ -e "$sb/build" ]] || compgen -G "$sb/apr/build/$TARGET/intBP_*" > /dev/null; then
        echo "  FAIL: sandbox dry run created an output or view directory"; status=1
    else
        echo "  sandbox dry run created no output or view directory"
    fi
    printf '{"qualification": "bootstrap", "setup_wns_ns": 0.012, "hold_wns_ns": 0.004}\n' > "$sroute/reports/popcount_qualification.json"
    DRIVER_PATH="$sb/$DRIVER" dry_case sandbox_not_final 3 'is not final-qualified' DRY_RUN=1 "${sbenv[@]}" || status=1
    printf '{"qualification": "final", "setup_wns_ns": -0.003, "hold_wns_ns": 0.004}\n' > "$sroute/reports/popcount_qualification.json"
    DRIVER_PATH="$sb/$DRIVER" dry_case sandbox_negative_setup 3 'is not final-qualified' DRY_RUN=1 "${sbenv[@]}" || status=1
    printf '{"qualification": "final", "setup_wns_ns": 0.012, "hold_wns_ns": 0.004}\n' > "$sroute/reports/popcount_qualification.json"
    mkdir -p "$sb/apr/build/$TARGET/other_route/outputs" "$sb/apr/build/$TARGET/intBP_int8_uniform_L1024_dr"
    ln -s ../other_route/outputs "$sb/apr/build/$TARGET/intBP_int8_uniform_L1024_dr/outputs"
    DRIVER_PATH="$sb/$DRIVER" dry_case sandbox_foreign_view 3 'is not a view of csa_bp_20261003b_distguide_spp_fixed' DRY_RUN=1 "${sbenv[@]}" || status=1
    DRIVER_PATH="$sb/$DRIVER" dry_case sandbox_foreign_view_other_tag 0 '^DRY RUN: route' DRY_RUN=1 TAG=intBPb "${sbenv[@]}" || status=1
    rm "$sb/apr/build/$TARGET/intBP_int8_uniform_L1024_dr/outputs"
    ln -s "../$rr/outputs" "$sb/apr/build/$TARGET/intBP_int8_uniform_L1024_dr/outputs"
    DRIVER_PATH="$sb/$DRIVER" dry_case sandbox_own_view_reused 0 'intBP_int8_uniform_L1024_dr\(exists\)' DRY_RUN=1 "${sbenv[@]}" || status=1
    echo "driver dry checks: status $([[ $status == 0 ]] && echo PASS || echo FAIL)"
    return "$status"
}

#-------------------------------------------------------------- rowtest --
run_rowtest() {
    local fx="$OUT/csa_bp_power_rowtest" src="$EMU/int8_uniform_L1024_dr"
    local chk="$OUT/csa_bp_power_rtl/int8_uniform_L1024_dr/check.json"
    [[ -f "$chk" && -d "$src/power" ]] || { echo "rowtest needs $chk and $src/power"; return 1; }
    rm -rf "$fx"; mkdir -p "$fx/gl" "$fx/power"
    cp -p "$chk" "$fx/gl/check.json"
    cp -p "$src/gl/timing_qualification.json" "$fx/gl/"
    cp -p "$src/gl/saif_validation.log" "$fx/gl/"
    cp -p "$src/power/power.rpt" "$fx/power/"
    # Inject a u_combiner hierarchy (0.123456 mW) into both hierarchy reports.
    awk '{print} /^u_peripheral /{print "u_combiner              5.000000e-05         6.000000e-05         1.345600e-05         1.234560e-04        ( 1.07%)   h"}' \
        "$src/power/cell_power.rpt" > "$fx/power/cell_power.rpt"
    awk '{print} /^  u_peripheral \(/{print "  u_combiner (PaynBpCombiner_N_H8_OWIDTH24_OUT_W32) 5.00e-05 6.00e-05 1.35e-05 1.23e-04   1.1"}' \
        "$src/power/power_hier.rpt" > "$fx/power/power_hier.rpt"
    python3 sweeps/int_mode/bp/bp_int_energy_row.py "$fx" int8_uniform_L1024_dr --route fixture > "$fx/row.log" 2>&1 \
        || { echo "rowtest: FAIL $(tail -n 1 "$fx/row.log")"; return 1; }
    python3 - "$fx/row.csv" <<'PY'
import csv, sys
r = next(csv.DictReader(open(sys.argv[1])))
f = {k: float(r[k]) for k in ('power_mW', 'u_pe_mW', 'u_peripheral_mW', 'u_combiner_mW', 'sobol_mW',
                             'toplevel_mW', 'mac_per_cycle', 'pJ_MAC', 'array_pJ_MAC')}
assert abs(f['u_combiner_mW'] - 0.123456) < 1e-9, f
assert abs(f['u_pe_mW'] - 11.25321) < 1e-6 and abs(f['sobol_mW'] - (0.02432767 + 0.01302335)) < 1e-9, f
assert abs(f['mac_per_cycle'] - 3072 * 128 / 5760) < 1e-12, f
assert abs(f['pJ_MAC'] - f['power_mW'] * 2.5 / f['mac_per_cycle']) < 1e-12, f
assert abs(f['array_pJ_MAC'] - f['u_pe_mW'] * 2.5 / f['mac_per_cycle']) < 1e-12, f
parts = f['u_pe_mW'] + f['u_peripheral_mW'] + f['u_combiner_mW'] + f['sobol_mW'] + f['toplevel_mW']
assert abs(parts - f['power_mW']) < 1e-9, f
print(f"rowtest: PASS (u_combiner {f['u_combiner_mW']} mW, u_pe {f['u_pe_mW']} mW, MAC/cycle "
      f"{f['mac_per_cycle']:.4f}, pJ/MAC {f['pJ_MAC']:.5f} / array {f['array_pJ_MAC']:.5f}, parts sum to total)")
PY
    # A report without u_combiner must be rejected.
    cp -p "$src/power/cell_power.rpt" "$fx/power/cell_power.rpt"
    if python3 sweeps/int_mode/bp/bp_int_energy_row.py "$fx" int8_uniform_L1024_dr > "$fx/row_neg.log" 2>&1; then
        echo "rowtest: FAIL (accepted reports without u_combiner)"; return 1
    fi
    echo "rowtest: reports without u_combiner rejected: $(tail -n 1 "$fx/row_neg.log" | cut -c1-120)"
}

status=0
for part in $PARTS; do
    case "$part" in
        rtl) run_rtl > "$OUT/csa_bp_power_rtl.log" 2>&1 || status=1; log=$OUT/csa_bp_power_rtl.log;;
        syngl) run_syngl > "$OUT/csa_bp_power_syngl.log" 2>&1 || status=1; log=$OUT/csa_bp_power_syngl.log;;
        dry) run_dry > "$OUT/csa_bp_power_dry.log" 2>&1 || status=1; log=$OUT/csa_bp_power_dry.log;;
        rowtest) run_rowtest > "$OUT/csa_bp_power_rowtest.log" 2>&1 || status=1; log=$OUT/csa_bp_power_rowtest.log;;
        *) echo "unknown part $part" >&2; exit 2;;
    esac
    echo "== $log"; cat "$log"
done
echo "csa_bp power preflight ($PARTS): $([[ $status == 0 ]] && echo PASS || echo FAIL)"
exit "$status"
