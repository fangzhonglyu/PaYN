#!/bin/bash
# Post-synthesis gate-level checks for TSMC22/PAYN_SC_CSA_CBSG_AF_IPD (designs/payn/variants/signed_segmented_csa_cbsg_af_ipd)
# on the synthesized netlist of RUN (default cbsg_af_ipd_20261005).  Recipe of sweeps/cbsg/af/run_syn_gl_checks.sh (SC part,
# unit then ideal-clock SDF, same qualification) and sweeps/int_mode/bp/ipd/run_bp_ipd_syn_gl_checks.sh (INT part); both
# unchanged.  One bench, designs/payn/tb/test_payn_array_cbsg_af_ipd.sv, compiled three times: RTL (fresh compile, the
# reference), netlist unit delay, netlist with the ideal-clock SDF.  Every run plays the same inputs on the RTL and on the
# netlist:
# (sc)     +MODE=sc golden cases; the GL RESULT line must equal the RTL one (cases, calls, blocks, drains, edges, drained
#          values, drains wrong, stalls, stray loads); passing runs need 0 drains wrong, negative controls must FAIL with
#          [CHECK] and exactly the RTL's count.  Under GL_SIM the bench compares drains only (no hierarchical peeks, no
#          contract count).  +INT_JUNK drives random a_raw_in / w_raw_in / int_prec / ring_in in SC.
# (int)    +MODE=int bit-plane INT8 / W4A8 / INT4 blocks (1-edge in-place laps); the GL trace bpt_trace.txt must be
#          byte-identical to the RTL trace, and sweeps/cbsg/af_ipd/check_bp_trace.py must PASS it (negative controls: FAIL).
#          gl-only controls (NEG_MAG_A / NEG_MAG_W: live AF magnitudes in INT mode) stop the RTL run at [BP-CONTRACT], a
#          simulation monitor that is not in the netlist, so the GL trace has no RTL twin; the checker must FAIL the GL trace
#          (the AF streams really corrupt the INT result when the magnitude zero-load is skipped).
# (switch) +MODE=switch SC cases and INT blocks on one DUT without reset; GL vs RTL: SC RESULT fields equal and every INT
#          segment's trace byte-identical; positive runs need the bench PASS and every segment bit-exact.
# Delay modes:
# (unit)   netlist, NO_SDF, unit delay, ARM_UD_MODEL + ARM_EN_X_SQUASH, timing checks off (functional proof: clock gating,
#          multibit banking, register merging, reset mapping); SC on the tightest schedule (+RESET_SETTLE=0).
# (sdf)    the synthesis SDF in its ideal-clock view (sweeps/cbsg/af/sdf_ideal_clock.py, invoked read-only: only the ICG
#          CK->ECK IOPATHs zeroed, the clock model DC timed with), max corner, +neg_tchk +sdfverbose, timing checks ON, full
#          library models, no X squash; each log qualified by sweeps/validate_routed_gl.py (annotation complete, no
#          post-reset timing violation) whose only accepted rejection is SDFCOM_CFTC when every instance is the DFFRPQ*
#          async-reset removal check (DC writes it as HOLD).  Reset settle as AF: SC runs (GL and RTL alike) wait
#          +RESET_SETTLE=2 idle edges; INT runs already idle more than two edges before the first load; switch runs start with an INT segment at
#          MODE_AT=3 (first load on edge 3), because the switch mode loads on the first edge after reset otherwise.
#
#   bash sweeps/cbsg/af_ipd/run_syn_gl_checks.sh                 # RUN=cbsg_af_ipd_20261005, PARTS="unit sdf"
#   PARTS=unit bash sweeps/cbsg/af_ipd/run_syn_gl_checks.sh
# Outputs: build/cbsg/af_ipd/gl/<RUN>/ (summary syn_gl_checks_summary.log; per run <mode>/<kind>/<label>/{sim.log,rtl/...}).
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$REPO"
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
export NTFY_CHNL= PYTHONDONTWRITEBYTECODE=1 SNPSLMD_QUEUE=true
unset NETLIST_FILE SDC_FILE SDF_FILE VCS_ARGS
TARGET=TSMC22/PAYN_SC_CSA_CBSG_AF_IPD
RUN=${RUN:-cbsg_af_ipd_20261005}
TOP=payn_array_signed_segmented_csa_cbsg_af_ipd
SYN=syn/build/$TARGET/$RUN
OUT=build/cbsg/af_ipd/gl/$RUN
GOLD=build/cbsg/golden
EXTRA=build/cbsg/af_ipd/golden_extra
RV=build/cbsg/af_ipd/golden_rv
TB=designs/payn/tb/test_payn_array_cbsg_af_ipd.sv
D=sweeps/cbsg/af_ipd
GEN=$D/gen_bp_workload.py
CHK=$D/check_bp_trace.py
PARTS=${PARTS:-"unit sdf"}
MAX_JOBS=${MAX_JOBS:-12}
LICWAIT_MIN=${LICWAIT_MIN:-60}
VCS_GL="vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -licwait $LICWAIT_MIN \$(VCS_ARGS) +incdir+\$(DESIGNS_DIR) -assert svaext"
VCS_RTL="vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -licwait $LICWAIT_MIN -debug_access+pp \$(VCS_ARGS) +incdir+\$(DESIGNS_DIR) -assert svaext"
UNITDEF="+define+ARM_UD_MODEL+define+ARM_EN_X_SQUASH +delay_mode_unit +notimingcheck"
SDFDEF="+neg_tchk +sdfverbose"
UNIT_SETTLE=${UNIT_SETTLE:-0}
SDF_SETTLE=${SDF_SETTLE:-2}
[[ -s "$SYN/$TOP.syn.v" && -s "$SYN/$TOP.syn.sdf" ]] || { echo "missing netlist/SDF in $SYN" >&2; exit 2; }
for d in "$GOLD" "$EXTRA" "$RV"; do
    [[ -d "$d" ]] || { echo "missing $d (run sweeps/cbsg/af_ipd/run_rtl_checks.sh ref first)" >&2; exit 2; }
done
mkdir -p "$OUT"
SUMMARY=$OUT/syn_gl_checks_summary.log
IDEAL=$OUT/idealclk_view            # SYN_DIR for the SDF builds: $IDEAL/$TARGET/$RUN/{netlist -> run, ideal-clock SDF}

#------------------------------------------------------------------ case lists --
# SC: label  cases  plusargs(comma list or -)  expect(pass|fail)
SC_UNIT=$(cat <<'EOF'
plain_u128                plain_u128      -                     pass
plain_u97                 plain_u97       -                     pass
plain_ladder              plain_ladder    -                     pass
plain_extreme             plain_extreme   -                     pass
chunked_rung              chunked_rung    -                     pass
chunked_100               chunked_100     -                     pass
chunked_tail5             chunked_tail5   -                     pass
perhead_64                perhead_64      -                     pass
calls_prot                calls_prot      -                     pass
calls_av257               calls_av257     -                     pass
af_calls_mixed            af_calls_mixed  -                     pass
af_calls_odd              af_calls_odd    -                     pass
af_uL_001_032             af_uL_001_032   -                     pass
af_lad_chunk_0            af_lad_chunk_0  -                     pass
af_perhead                af_perhead      -                     pass
af_extreme_max            af_extreme_max  -                     pass
af_av2048                 af_av2048       -                     pass
rv_tiny_calls             rv_tiny_calls   -                     pass
rv_cd8                    rv_cd8          -                     pass
rv_c1_chain               rv_c1_chain     -                     pass
rv_plain_randL            rv_plain_randL  -                     pass
chain_all_no_ss           @all            NO_SLICE_START        pass
chain_all_no_ss_intjunk   @all            NO_SLICE_START,INT_JUNK pass
chain_all_combo_s10       @all            NO_SLICE_START,STALL,JUNK_BUS,MID_RESET,GAPS,RNG_GAP_LOW,MAC_EXACT,LOOSE_DRAIN,FULL_CYCLES,INT_JUNK,SEED=10 pass
chain_golden_idle_s4      @golden         RNG_LOW_IDLE,INT_JUNK,SEED=4 pass
neg_short_u97             plain_u97       NEG_SHORT_BLOCK       fail
neg_next_early_rung       chunked_rung    NEG_NEXT_EARLY        fail
neg_stall_nomac           plain_u97,calls_prot NEG_STALL_NOMAC,SEED=3 fail
EOF
)
SC_SDF=$(cat <<'EOF'
plain_u128                plain_u128      -                     pass
plain_ladder              plain_ladder    -                     pass
chunked_rung              chunked_rung    -                     pass
calls_av257               calls_av257     -                     pass
af_calls_mixed            af_calls_mixed  -                     pass
rv_tiny_calls             rv_tiny_calls   -                     pass
chain_golden_combo_s10    @golden         NO_SLICE_START,STALL,JUNK_BUS,GAPS,RNG_GAP_LOW,MAC_EXACT,LOOSE_DRAIN,FULL_CYCLES,INT_JUNK,SEED=10 pass
chain_all_no_ss_intjunk   @all            NO_SLICE_START,INT_JUNK pass
neg_short_u97             plain_u97       NEG_SHORT_BLOCK       fail
neg_next_early_rung       chunked_rung    NEG_NEXT_EARLY        fail
EOF
)
# INT: label  BA BW L MROWS NCOLS DIST SEED FLAGS  expect(pass | fail:CHECK | fail:TIMING | glonly:CHECK)
# Labels and operands as sweeps/cbsg/af_ipd/run_rtl_checks.sh.
INT_UNIT=$(cat <<'EOF'
int8_uniform_L1024_m2n16         8 8 1024 2 16 uniform     3 -           pass
int8_allmin_L1024_m1n8           8 8 1024 1  8 allmin      0 -           pass
int8_allmax_L1024_m1n8           8 8 1024 1  8 allmax      0 -           pass
int8_alternating_L1024_m2n8      8 8 1024 2  8 alternating 0 -           pass
int8_uniform_L256_m2n16_junk     8 8  256 2 16 uniform     6 JUNK        pass
int8_uniform_L256_m2n8_modeat3   8 8  256 2  8 uniform     7 MODE_AT=3   pass
int8_neg1xmin_L65408_m1n8        8 8 65408 1 8 neg1xmin    0 -           pass
w4a8_uniform_L1024_m2n16         8 4 1024 2 16 uniform    12 -           pass
w4a8_minxmax_L1024_m1n8          8 4 1024 1  8 minxmax     0 -           pass
w4a8_uniform_L256_m3n8_junk      8 4  256 3  8 uniform    13 JUNK        pass
int4_uniform_L1024_m4n16         4 4 1024 4 16 uniform    22 -           pass
int4_allmin_L1024_m2n8           4 4 1024 2  8 allmin      0 -           pass
int4_uniform_L256_m2n16_junk     4 4  256 2 16 uniform    23 JUNK        pass
int8_uniform_L1024_m2n16_lapring 8 8 1024 2 16 uniform     3 LAP_RING_ONLY pass
int8_uniform_L4096_m1n8_lapring  8 8 4096 1  8 uniform     4 LAP_RING_ONLY pass
int8_uniform_L256_m2n16_junk_lapring 8 8 256 2 16 uniform  6 JUNK,LAP_RING_ONLY pass
w4a8_uniform_L1024_m2n16_lapring 8 4 1024 2 16 uniform    12 LAP_RING_ONLY pass
int4_uniform_L1024_m4n16_lapring 4 4 1024 4 16 uniform    22 LAP_RING_ONLY pass
int4_uniform_L256_m2n16_junk_lapring 4 4 256 2 16 uniform 23 JUNK,LAP_RING_ONLY pass
int8_park_cyc0_L256_m2n8         8 8  256 2  8 uniform    61 PARK_CYC0,MODE_AT=3 pass
int8_park_cyc0_L1024_m1n8_lapring 8 8 1024 1  8 uniform   62 PARK_CYC0,MODE_AT=2,LAP_RING_ONLY pass
int4_park_cyc0_L256_m2n8_junk    4 4  256 2  8 uniform    63 PARK_CYC0,MODE_AT=3,JUNK pass
w4a8_uniform_L512_m2n8_junk_modeat2 8 4 512 2 8 uniform   64 JUNK,MODE_AT=2,LAP_RING_ONLY pass
int8_park_cyc0_L256_m1n8_lendc255 8 8 256 1  8 uniform    71 PARK_CYC0,MODE_AT=2,INT_LEN_DC=255 pass
neg_int8_ringstray_L256_m1n8_lapring 8 8 256 1 8 uniform  37 NEG_RING_STRAY,LAP_RING_ONLY fail:CHECK
neg_w4a8_lap2_L256_m1n8_lapring  8 4  256 1  8 uniform    43 LAP_LEN=2,LAP_RING_ONLY fail:CHECK
neg_int4_prec_L256_m2n8          4 4  256 2  8 uniform    32 NEG_PREC    fail:CHECK
neg_int8_noring_L256_m1n8        8 8  256 1  8 uniform    31 NEG_NO_RING fail:TIMING
neg_int8_mag_a_park_L256_m1n8    8 8  256 1  8 uniform    65 PARK_CYC0,MODE_AT=3,NEG_MAG_A glonly:CHECK
neg_int8_mag_w_L256_m1n8         8 8  256 1  8 uniform    67 NEG_MAG_W   glonly:CHECK
EOF
)
INT_SDF=$(cat <<'EOF'
int8_uniform_L1024_m2n16_lapring 8 8 1024 2 16 uniform     3 LAP_RING_ONLY pass
int8_uniform_L256_m2n16_junk     8 8  256 2 16 uniform     6 JUNK        pass
int8_allmin_L1024_m1n8           8 8 1024 1  8 allmin      0 -           pass
w4a8_uniform_L1024_m2n16_lapring 8 4 1024 2 16 uniform    12 LAP_RING_ONLY pass
w4a8_minxmax_L1024_m1n8          8 4 1024 1  8 minxmax     0 -           pass
int4_uniform_L1024_m4n16_lapring 4 4 1024 4 16 uniform    22 LAP_RING_ONLY pass
int4_uniform_L256_m2n16_junk     4 4  256 2 16 uniform    23 JUNK        pass
int8_park_cyc0_L256_m2n8         8 8  256 2  8 uniform    61 PARK_CYC0,MODE_AT=3 pass
neg_int8_ringstray_L256_m1n8_lapring 8 8 256 1 8 uniform  37 NEG_RING_STRAY,LAP_RING_ONLY fail:CHECK
neg_w4a8_lap2_L256_m1n8_lapring  8 4  256 1  8 uniform    43 LAP_LEN=2,LAP_RING_ONLY fail:CHECK
neg_int4_prec_L256_m2n8          4 4  256 2  8 uniform    32 NEG_PREC    fail:CHECK
neg_int8_mag_w_L256_m1n8         8 8  256 1  8 uniform    67 NEG_MAG_W   glonly:CHECK
EOF
)
# switch: label | flags | expect (pass | fail:CHECK | fail:TIMING) | items (case name or i:BA:BW:L:MROWS:NCOLS:MODE_AT:JUNK:LAPRING:DIST:SEED)
SW_UNIT=$(cat <<'EOF'
sw_mixed_intjunk | INT_JUNK | pass | plain_u128 i:8:8:256:1:8:0:0:1:uniform:61 plain_u97 i:8:4:384:1:8:1:1:0:uniform:62 calls_prot i:4:4:256:2:8:2:0:1:uniform:63 af_perhead
sw_int_first_idle | INT_JUNK,RNG_LOW_IDLE,INT_LEN_DC=255 | pass | i:8:8:256:1:8:3:0:1:uniform:71 rv_c1_chain i:4:4:256:2:8:0:0:0:uniform:72 af_uL_001_032 i:8:4:256:1:8:2:0:1:uniform:73 plain_ladder
all_interleaved | INT_JUNK,SEED=5 | pass | @ALL
neg_sw_no_reload | NEG_SW_NO_RELOAD | fail:CHECK | plain_u128 i:8:8:256:1:8:0:0:1:uniform:65 plain_u97
neg_sw_early_int | NEG_SW_EARLY_INT | fail:TIMING | plain_u128 i:8:8:256:1:8:0:0:1:uniform:61 plain_u97
EOF
)
SW_SDF=$(cat <<'EOF'
sw_sdf_mixed_intjunk | INT_JUNK | pass | i:8:8:256:1:8:3:0:1:uniform:81 plain_u128 i:8:4:384:1:8:1:1:0:uniform:82 calls_prot i:4:4:256:2:8:2:0:1:uniform:83 plain_ladder
neg_sw_sdf_no_reload | NEG_SW_NO_RELOAD | fail:CHECK | i:8:8:256:1:8:3:0:1:uniform:84 plain_u97
EOF
)

resolve() {   # comma list of case names / @golden / @extra / @rv / @all -> comma list of absolute dirs
    local out=() x d xs
    IFS=, read -ra xs <<< "$1"
    for x in "${xs[@]}"; do
        case "$x" in
            @golden) for d in "$GOLD"/*/; do out+=("$REPO/${d%/}"); done ;;
            @all)    for d in "$GOLD"/*/ "$EXTRA"/*/ "$RV"/*/; do out+=("$REPO/${d%/}"); done ;;
            *) if [[ -d "$GOLD/$x" ]]; then out+=("$REPO/$GOLD/$x");
               elif [[ -d "$EXTRA/$x" ]]; then out+=("$REPO/$EXTRA/$x");
               elif [[ -d "$RV/$x" ]]; then out+=("$REPO/$RV/$x");
               else echo "unknown case $x" >&2; return 1; fi ;;
        esac
    done
    (IFS=,; echo "${out[*]}")
}
plus_of() { local x fl; [[ "$1" == - ]] && return 0; IFS=, read -ra fl <<< "$1"; for x in "${fl[@]}"; do echo "+$x"; done; }

prep_ideal() {
    local d="$IDEAL/$TARGET/$RUN"
    rm -rf "$IDEAL"; mkdir -p "$d"
    ln -s "$REPO/$SYN/$TOP.syn.v" "$d/$TOP.syn.v"
    python3 sweeps/cbsg/af/sdf_ideal_clock.py "$SYN/$TOP.syn.sdf" "$d/$TOP.syn.sdf" --report "$IDEAL/idealclk_report.txt"
}

qualify_sdf() {   # log json -> 0 if validate_routed_gl passed, or failed only on DFFRPQ* removal-check SDFCOM_CFTC
    python3 - "$1" "$2" <<'PY2'
import json, re, sys
log = open(sys.argv[1], errors="replace").read()
d = json.load(open(sys.argv[2]))
reasons = [r for r in d["rejection_reasons"] if r != "unapproved SDF warnings: SDFCOM_CFTC"]
blocks = re.findall(r"Warning-\[SDFCOM_CFTC\](.*?)(?=\n\s*\n|\Z)", log, re.S)
bad = [b for b in blocks if not (re.search(r"module: DFFRPQ\w+", b)
                                 and re.search(r"\$hold\(posedge CK[^,]*,\s*negedge R", " ".join(b.split())))]
if bad:
    reasons.append(f"{len(bad)} SDFCOM_CFTC not of the async-reset removal kind")
print("timing violations %d (post-reset %d), SDF errors %s, SDF warnings %s, %d SDFCOM_CFTC all DFFRPQ removal checks%s"
      % (d["timing_violation_reports"], d["post_reset_timing_violations"], d["sdf_errors"],
         d["sdf_warning_categories"] or "{}", len(blocks), "; REJECT: " + "; ".join(reasons) if reasons else ""))
sys.exit(1 if reasons else 0)
PY2
}

sdf_validate() {   # dir expected-pass -> sets VAL, returns 1 on reject
    local dir=$1 ep=$2
    { sed '/Running gate-level simulation/q' "$OUT/build_sdf/compile.log"; cat "$dir/sim.log"; } > "$dir/validation_input.log"
    python3 sweeps/validate_routed_gl.py "$dir/validation_input.log" --expected-pass "$ep" \
        --json "$dir/timing_qualification.json" > "$dir/timing_validation.log" 2>&1
    if VAL=$(qualify_sdf "$dir/validation_input.log" "$dir/timing_qualification.json"); then
        VAL="; timing view OK: $VAL"; return 0
    fi
    VAL="; timing view FAIL: $VAL"; return 1
}

# RESULT line -> "cases calls blocks drains edges drain_values drain_bad stalls stray"
res_fields() {
    grep -m1 '^RESULT' "$1" | sed -E 's/^RESULT cases=([0-9]+) calls=([0-9]+) blocks=([0-9]+) drains=([0-9]+) edges=([0-9]+) \| drain values ([0-9]+) bad ([0-9]+) .*stalls ([0-9]+) stray loads ([0-9]+).*/\1 \2 \3 \4 \5 \6 \7 \8 \9/'
}

compile_bench() {   # mode builddir -> simv for TB (rtl | unit | sdf); the compile run plays plain_u128 (+MODE=sc)
    local mode=$1 b=$2
    rm -rf "$b"; mkdir -p "$b/$TB"
    echo "$REPO/$GOLD/plain_u128" > "$b/$TB/cbsg_cases.txt"
    case "$mode" in
        rtl)  make sim TOP=Top TB="$TB" BUILD_DIR="$REPO/$b" GL= TARGET= RTL_PREFLIGHT_CMD= USE_DW=1 \
                  "VCS=$VCS_RTL" > "$b/compile.log" 2>&1 ;;
        unit) make sim GL=syn TARGET="$TARGET" RUN="$RUN" TB="$TB" BUILD_DIR="$REPO/$b" NO_SDF=1 \
                  RTL_PREFLIGHT_CMD=true "VCS=$VCS_GL" VCS_ARGS="$UNITDEF +define+CAI_RESET_SETTLE=$UNIT_SETTLE" > "$b/compile.log" 2>&1 ;;
        sdf)  make sim GL=syn TARGET="$TARGET" RUN="$RUN" TB="$TB" BUILD_DIR="$REPO/$b" SDF_CORNER=max NO_SDF= \
                  SYN_DIR="$REPO/$IDEAL" RTL_PREFLIGHT_CMD=true "VCS=$VCS_GL" VCS_ARGS="$SDFDEF +define+CAI_RESET_SETTLE=$SDF_SETTLE" > "$b/compile.log" 2>&1 ;;
    esac
    grep -q '^PASS: CBSG AF-IPD bench' "$b/compile.log"
}

simv_of() { echo "$REPO/$OUT/build_$1/$TB/simv"; }

#----------------------------------------------------------------------- (sc) --
sc_case() {   # mode label cases plusargs expect
    local mode=$1 label=$2 cases=$3 plus=$4 expect=$5
    local dir="$OUT/$mode/sc/$label" args=() list gl rtl ok=1 t0 dt settle
    rm -rf "$dir"; mkdir -p "$dir/rtl"
    mapfile -t args < <(plus_of "$plus")
    settle=$UNIT_SETTLE; [[ "$mode" == sdf ]] && settle=$SDF_SETTLE
    args+=("+RESET_SETTLE=$settle")
    list=$(resolve "$cases") || { echo "$mode sc $label: FAIL (cannot resolve $cases)"; return 1; }
    t0=$SECONDS
    (cd "$dir" && "$(simv_of "$mode")" +vcs+lic+wait +MODE=sc "+CASES=$list" "${args[@]}" > sim.log 2>&1)
    dt=$((SECONDS - t0))
    (cd "$dir/rtl" && "$(simv_of rtl)" +vcs+lic+wait +MODE=sc "+CASES=$list" "${args[@]}" > sim.log 2>&1)
    gl=$(res_fields "$dir/sim.log"); rtl=$(res_fields "$dir/rtl/sim.log")
    if [[ -z "$gl" || -z "$rtl" || "$gl" == RESULT* || "$rtl" == RESULT* ]]; then
        echo "$mode sc $label: FAIL (missing RESULT; see $dir)"; return 1
    fi
    [[ "$gl" == "$rtl" ]] || ok=0
    read -r _ _ _ _ edges dvals dbad stalls stray <<< "$gl"
    case "$expect" in
        pass) grep -q '^PASS: CBSG AF-IPD bench' "$dir/sim.log" && grep -q '^PASS: CBSG AF-IPD bench' "$dir/rtl/sim.log" \
                  && (( dbad == 0 )) || ok=0 ;;
        fail) grep -q '^FAIL: CBSG AF-IPD bench' "$dir/sim.log" && grep -q '^FAIL: CBSG AF-IPD bench' "$dir/rtl/sim.log" \
                  && grep -q '^\[CHECK\] [0-9]' "$dir/sim.log" && (( dbad > 0 )) || ok=0 ;;
    esac
    if grep -qE 'Error-\[|\[TIMEOUT\]|\$fatal|Fatal:|\[X-FAIL\]' "$dir/sim.log"; then ok=0; fi
    VAL=""
    if [[ "$mode" == sdf ]]; then
        local ep="PASS: CBSG AF-IPD bench"; [[ "$expect" != fail ]] || ep="RESULT cases="
        sdf_validate "$dir" "$ep" || ok=0
    fi
    echo "$mode sc $label: $( ((ok)) && echo PASS || echo FAIL) [$expect] ${plus} | drains $dbad/$dvals wrong, $edges edges, stalls $stalls, stray $stray | GL == RTL: $([[ "$gl" == "$rtl" ]] && echo yes || echo "NO (GL $gl / RTL $rtl)") | ${dt}s$VAL"
    (( ok ))
}

#---------------------------------------------------------------------- (int) --
int_case() {   # mode label BA BW L MROWS NCOLS DIST SEED FLAGS EXPECT
    local mode=$1 label=$2 ba=$3 bw=$4 L=$5 mrows=$6 ncols=$7 dist=$8 seed=$9 flags=${10} expect=${11}
    local dir="$OUT/$mode/int/$label" ok=1 msg="" t0 dt rtl_note
    local -a plus
    mapfile -t plus < <(plus_of "$flags")
    rm -rf "$dir"; mkdir -p "$dir/rtl"
    python3 "$GEN" --ba "$ba" --bw "$bw" --L "$L" --mrows "$mrows" --ncols "$ncols" --dist "$dist" \
        --seed "$seed" --out-dir "$dir" > "$dir/gen.log"
    cp "$dir/bpt_a.hex" "$dir/bpt_w.hex" "$dir/rtl/"
    local run=(+vcs+lic+wait +MODE=int +BA="$ba" +BW="$bw" +L="$L" +MROWS="$mrows" +NCOLS="$ncols" "${plus[@]}")
    t0=$SECONDS
    (cd "$dir" && "$(simv_of "$mode")" "${run[@]}" > sim.log 2>&1)
    dt=$((SECONDS - t0))
    (cd "$dir/rtl" && "$(simv_of rtl)" "${run[@]}" > sim.log 2>&1)
    case "$expect" in
        fail:TIMING)
            if grep -q '\[TIMING-FAIL\]' "$dir/sim.log" && grep -q '\[TIMING-FAIL\]' "$dir/rtl/sim.log" \
               && ! grep -q '^PASS:' "$dir/sim.log"; then
                [[ "$(grep -m1 '\[TIMING-FAIL\]' "$dir/sim.log")" == "$(grep -m1 '\[TIMING-FAIL\]' "$dir/rtl/sim.log")" ]] \
                    || { ok=0; msg="GL and RTL [TIMING-FAIL] lines differ"; }
                (( ok )) && msg="negative control caught by [TIMING-FAIL] in GL and RTL (same line):$(grep -m1 '\[TIMING-FAIL\]' "$dir/sim.log" | sed 's/^.*\]//' | cut -c1-70)"
            else ok=0; msg="expected [TIMING-FAIL] in GL and RTL"; fi
            echo "$mode int $label: $( ((ok)) && echo PASS || echo FAIL) [$expect] $msg | ${dt}s"
            (( ok )); return ;;
    esac
    grep -q '^PASS: BP INT bench' "$dir/sim.log" || { ok=0; msg="GL bench did not finish (see $dir/sim.log); "; }
    if grep -qE 'Error-\[|\[TIMEOUT\]|\[X-FAIL\]|\[TIMING-FAIL\]' "$dir/sim.log"; then ok=0; msg+="GL error tag; "; fi
    if [[ "$expect" == glonly:* ]]; then
        if grep -q '\[BP-CONTRACT\]' "$dir/rtl/sim.log" && ! grep -q '^PASS:' "$dir/rtl/sim.log"; then
            rtl_note="RTL stopped by [BP-CONTRACT] (monitor not in the netlist)"
        else ok=0; rtl_note="RTL did not stop at [BP-CONTRACT]"; fi
    else
        grep -q '^PASS: BP INT bench' "$dir/rtl/sim.log" || { ok=0; msg+="RTL bench did not finish; "; }
        if cmp -s "$dir/bpt_trace.txt" "$dir/rtl/bpt_trace.txt"; then rtl_note="GL trace == RTL trace"
        else ok=0; rtl_note="GL trace DIFFERS from RTL trace"; fi
    fi
    python3 "$CHK" "$dir" --json "$dir/check.json" > "$dir/check.log" 2>&1; local chk=$?
    case "$expect" in
        pass) (( chk == 0 )) || ok=0 ;;
        fail:CHECK|glonly:CHECK) { (( chk != 0 )) && grep -q '^\[FAIL\]' "$dir/check.log"; } || ok=0 ;;
    esac
    VAL=""
    [[ "$mode" == sdf ]] && { sdf_validate "$dir" "PASS: BP INT bench" || ok=0; }
    echo "$mode int $label: $( ((ok)) && echo PASS || echo FAIL) [$expect] ${flags} | ${msg}${rtl_note}; checker: $(tail -n 1 "$dir/check.log" | cut -c1-150) | ${dt}s$VAL"
    (( L > 100000 )) && rm -f "$dir/bpt_a.hex" "$dir/bpt_w.hex" "$dir/rtl/bpt_a.hex" "$dir/rtl/bpt_w.hex"
    (( ok ))
}

#------------------------------------------------------------------- (switch) --
sw_case() {   # mode label flags expect items
    local mode=$1 label=$2 flags=$3 expect=$4 items=$5 dir="$OUT/$1/switch/$2" seq=() rseq=() it n=0 f ok=1 msg=""
    local -a plus parts
    local settle_note="" t0 dt gl rtl
    mapfile -t plus < <(plus_of "$flags")
    rm -rf "$dir"; mkdir -p "$dir/rtl"
    for it in $items; do
        if [[ $it == i:* ]]; then
            IFS=: read -ra parts <<< "$it"
            mkdir -p "$dir/i$n" "$dir/rtl/i$n"
            python3 "$GEN" --ba "${parts[1]}" --bw "${parts[2]}" --L "${parts[3]}" --mrows "${parts[4]}" \
                --ncols "${parts[5]}" --dist "${parts[9]}" --seed "${parts[10]}" --out-dir "$dir/i$n" > "$dir/i$n/gen.log"
            echo "${parts[1]} ${parts[2]} ${parts[3]} ${parts[4]} ${parts[5]} ${parts[6]} ${parts[7]} ${parts[8]}" > "$dir/i$n/bpt_cfg.txt"
            cp "$dir/i$n/bpt_a.hex" "$dir/i$n/bpt_w.hex" "$dir/i$n/bpt_cfg.txt" "$dir/rtl/i$n/"
            seq+=("int:$REPO/$dir/i$n"); rseq+=("int:$REPO/$dir/rtl/i$n")
            n=$((n + 1))
        else
            local r; r=$(resolve "$it") || { echo "$mode switch $label: FAIL (case $it)"; return 1; }
            seq+=("sc:$r"); rseq+=("sc:$r")
        fi
    done
    t0=$SECONDS
    (cd "$dir" && "$(simv_of "$mode")" +vcs+lic+wait +MODE=switch "+SWITCH=$(IFS=,; echo "${seq[*]}")" "${plus[@]}" > sim.log 2>&1)
    dt=$((SECONDS - t0))
    (cd "$dir/rtl" && "$(simv_of rtl)" +vcs+lic+wait +MODE=switch "+SWITCH=$(IFS=,; echo "${rseq[*]}")" "${plus[@]}" > sim.log 2>&1)
    case "$expect" in
        fail:TIMING)
            if grep -q '\[TIMING-FAIL\]' "$dir/sim.log" && grep -q '\[TIMING-FAIL\]' "$dir/rtl/sim.log" && ! grep -q '^PASS:' "$dir/sim.log"; then
                [[ "$(grep -m1 '\[TIMING-FAIL\]' "$dir/sim.log")" == "$(grep -m1 '\[TIMING-FAIL\]' "$dir/rtl/sim.log")" ]] || ok=0
                msg="negative control caught by [TIMING-FAIL] in GL and RTL$( ((ok)) || echo ' (lines differ)')"
            else ok=0; msg="expected [TIMING-FAIL] in GL and RTL"; fi
            echo "$mode switch $label: $( ((ok)) && echo PASS || echo FAIL) [$expect] $msg | ${dt}s"
            (( ok )); return ;;
    esac
    gl=$(res_fields "$dir/sim.log"); rtl=$(res_fields "$dir/rtl/sim.log")
    [[ -n "$gl" && "$gl" == "$rtl" && "$gl" != RESULT* ]] || { ok=0; msg+="SC RESULT GL != RTL ($gl / $rtl); "; }
    for ((f = 0; f < n; f++)); do
        cmp -s "$dir/i$f/bpt_trace.txt" "$dir/rtl/i$f/bpt_trace.txt" || { ok=0; msg+="segment $f trace differs; "; }
        python3 "$CHK" "$dir/i$f" --json "$dir/i$f/check.json" > "$dir/i$f/check.log" 2>&1 || { ok=0; msg+="segment $f not bit-exact; "; }
    done
    if grep -qE 'Error-\[|\[TIMEOUT\]|\[X-FAIL\]|\[TIMING-FAIL\]' "$dir/sim.log"; then ok=0; msg+="GL error tag; "; fi
    case "$expect" in
        pass) grep -q '^PASS: CBSG AF-IPD switch bench' "$dir/sim.log" && grep -q '^PASS: CBSG AF-IPD switch bench' "$dir/rtl/sim.log" || { ok=0; msg+="no bench PASS; "; } ;;
        fail:CHECK) grep -q '^FAIL: CBSG AF-IPD switch bench' "$dir/sim.log" && grep -q '^\[CHECK\] [0-9]' "$dir/sim.log" \
                        && grep -q '^FAIL: CBSG AF-IPD switch bench' "$dir/rtl/sim.log" || { ok=0; msg+="negative control not caught; "; } ;;
    esac
    VAL=""
    if [[ "$mode" == sdf ]]; then
        local ep="PASS: CBSG AF-IPD switch bench"; [[ "$expect" == pass ]] || ep="SWITCH_RESULT"
        sdf_validate "$dir" "$ep" || ok=0
    fi
    read -r _ _ blocks drains edges dvals dbad _ _ <<< "$gl"
    echo "$mode switch $label: $( ((ok)) && echo PASS || echo FAIL) [$expect] ${flags} | SC blocks $blocks, drains $dbad/$dvals wrong; $n INT segments, traces GL == RTL$( [[ $msg == *differs* ]] && echo ' NO'); $(grep -m1 '^SWITCH_RESULT' "$dir/sim.log" | sed 's/^SWITCH_RESULT //')${msg:+ | $msg}| ${dt}s$VAL"
    (( ok ))
}

#-------------------------------------------------------------------- driver --
run_mode() {   # mode
    local mode=$1 status=0 sc ic sw label c plus expect ba bw L mr nc dist seed flags items all="" k=0 cfgs
    compile_bench "$mode" "$OUT/build_$mode" || { echo "$mode: bench compile FAILED ($OUT/build_$mode/compile.log)"; return 1; }
    if [[ "$mode" == sdf ]]; then
        grep -q 'sdf corner = max' "$OUT/build_sdf/compile.log" && grep -Fq '[INFO] $sdf_annotate(' "$OUT/build_sdf/compile.log" \
            || { echo "sdf: no SDF annotation in the compile run ($OUT/build_sdf/compile.log)"; return 1; }
        sc=$SC_SDF; ic=$INT_SDF; sw=$SW_SDF
    else
        sc=$SC_UNIT; ic=$INT_UNIT; sw=$SW_UNIT
    fi
    echo "$mode: compiled $(grep -o 'netlist = .*' "$OUT/build_$mode/compile.log" | head -1 | sed "s#$REPO/##")"
    : > "$OUT/${mode}_runs.log"
    while read -r label c plus expect; do
        [[ -n "$label" ]] || continue
        sc_case "$mode" "$label" "$c" "$plus" "$expect" >> "$OUT/${mode}_runs.log" &
        while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
    done <<< "$sc"
    while read -r label ba bw L mr nc dist seed flags expect; do
        [[ -n "$label" ]] || continue
        int_case "$mode" "$label" "$ba" "$bw" "$L" "$mr" "$nc" "$dist" "$seed" "$flags" "$expect" >> "$OUT/${mode}_runs.log" &
        while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
    done <<< "$ic"
    cfgs=("8:8:256:1:8:0:0:1" "8:4:384:1:8:1:1:0" "4:4:256:2:8:2:0:1" "8:8:128:1:16:3:1:1" "4:4:384:2:8:0:1:0" "8:4:128:1:8:0:0:0")
    for c in "$GOLD"/*/ "$EXTRA"/*/ "$RV"/*/; do
        all+="$(basename "$c") i:${cfgs[$((k % 6))]}:uniform:$((100 + k)) "; k=$((k + 1))
    done
    while IFS='|' read -r label flags expect items; do
        label=$(echo $label); flags=$(echo $flags); expect=$(echo $expect); items=$(echo $items)
        [[ -n "$label" ]] || continue
        [[ "$items" == @ALL ]] && items=$all
        sw_case "$mode" "$label" "$flags" "$expect" "$items" >> "$OUT/${mode}_runs.log" &
        while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
    done <<< "$sw"
    while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done
    sort "$OUT/${mode}_runs.log"
    local total; total=$(( $(grep -c . <<< "$sc") + $(grep -c . <<< "$ic") + $(grep -c . <<< "$sw") ))
    echo "$mode: $(grep -c ': PASS \[' "$OUT/${mode}_runs.log")/$total runs PASS (sc $(grep -c '^'"$mode"' sc .*: PASS \[' "$OUT/${mode}_runs.log")/$(grep -c . <<< "$sc"), int $(grep -c '^'"$mode"' int .*: PASS \[' "$OUT/${mode}_runs.log")/$(grep -c . <<< "$ic"), switch $(grep -c '^'"$mode"' switch .*: PASS \[' "$OUT/${mode}_runs.log")/$(grep -c . <<< "$sw"))"
    [[ $(grep -c ': PASS \[' "$OUT/${mode}_runs.log") == "$total" ]] || status=1
    return "$status"
}

status=0
: > "$SUMMARY"
echo "C-BSG AF-IPD post-synthesis GL checks $(date -Iseconds): $SYN (git $(git rev-parse --short HEAD), uncommitted tree)" >> "$SUMMARY"
if [[ " $PARTS " == *" sdf "* ]]; then
    prep_ideal >> "$SUMMARY" 2>&1 || { echo "ideal-clock SDF view FAILED" | tee -a "$SUMMARY"; exit 1; }
fi
compile_bench rtl "$OUT/build_rtl" || { echo "RTL bench compile FAILED ($OUT/build_rtl/compile.log)" | tee -a "$SUMMARY"; exit 1; }
pids=()
for m in unit sdf; do
    [[ " $PARTS " == *" $m "* ]] || continue
    run_mode "$m" > "$OUT/${m}_summary.log" 2>&1 & pids+=("$!")
done
for p in "${pids[@]}"; do wait "$p" || status=1; done
for m in unit sdf; do
    [[ " $PARTS " == *" $m "* ]] || continue
    echo "== ($m)" >> "$SUMMARY"; cat "$OUT/${m}_summary.log" >> "$SUMMARY"
done
echo "C-BSG AF-IPD post-synthesis GL checks: $([[ $status == 0 ]] && echo PASS || echo FAIL)" >> "$SUMMARY"
cat "$SUMMARY"
exit "$status"
