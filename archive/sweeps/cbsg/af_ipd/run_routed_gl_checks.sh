#!/bin/bash
# Routed functional GL of the C-BSG AF + IPD INT variant (TSMC22/PAYN_SC_CSA_CBSG_AF_IPD) on one route: the
# routed_func stage of sweeps/cbsg/af_ipd/run_af_ipd_pinned.sh.  Derived from this variant's post-synthesis checks
# (sweeps/cbsg/af_ipd/run_syn_gl_checks.sh: same bench, case lists, RTL reference and pass criteria) and the AF
# pinned driver's do_routed_func (sweeps/cbsg/run_cbsg_pinned_pass2.sh, AF branch: three golden cases at
# +RESET_SETTLE=2 and =0, raw routed SDF, every log through the strict audit).  Differences from the post-synthesis
# SDF runs: the netlist is the routed apr.v with the RAW routed SDF (max corner, +neg_tchk +sdfverbose, timing
# checks on, propagated clock tree, no ideal-clock view, no X squash), and each log is qualified by the campaign's
# cbsg_gl_audit (sweeps/validate_routed_gl.py strict; approvals only after a strict failure, opt-in
# AFIPD_GL_VALIDATOR_ARGS, with a rationale file citing every flag), not by the post-synthesis SDFCOM_CFTC rule.
# One bench, designs/payn/tb/test_payn_array_cbsg_af_ipd.sv, compiled twice: RTL (fresh compile, the reference) and
# the routed netlist (compiled with +define+CAI_RESET_SETTLE=2; +RESET_SETTLE=n overrides per run).  Every run plays
# the same inputs on both:
# (sc)     golden cases (+MODE=sc); the GL RESULT line must equal the RTL one; passing runs need 0 drains wrong,
#          negative controls must FAIL with [CHECK] and the RTL's count.  The AF routed_func triple (plain_u128,
#          chunked_rung, calls_av257) runs at settle 2 AND settle 0 (is the 2-edge settle still needed after CTS?).
# (int)    +MODE=int INT8 / W4A8 / INT4 blocks with 1-edge in-place laps; GL trace byte-identical to RTL and bit-exact
#          (sweeps/cbsg/af_ipd/check_bp_trace.py); negative controls FAIL the checker; gl-only controls (live AF
#          magnitudes) stop RTL at [BP-CONTRACT] and must FAIL the checker in GL.
# (switch) +MODE=switch SC cases and INT blocks on one DUT without reset (INT-first and SC-first sequences, and all 43
#          SC cases interleaved with 43 INT blocks); SC RESULT fields equal and every INT trace byte-identical.
#   OUT_DIR=<dir> GL_RATIONALE=<work>/gl_validator_args_rationale.txt \
#       bash sweeps/cbsg/af_ipd/run_routed_gl_checks.sh ROUTE_RUN ICG_AUDIT_JSON
# ICG_AUDIT_JSON: the route's uniform GL sdf_clock_audit.json (routed CK->ECK evidence for the summary).
# Drain sampling: SC and switch runs (GL and RTL alike) pass +DRAIN_SAMPLE_LATE_PS=$DRAIN_SAMPLE_LATE_PS (default 50):
# the bench reads acc_out_east 50 ps before the shift edge that consumes it -- the SDC output-delay point
# (OUTPUT_DELAY = 0.05 ns) -- instead of at the preceding negedge, the AF bench's convenience point.  On this route
# the drain rail settles up to 1.45 ns after the edge (PT: tile (0,7) pending_borrow -> 15-bit +-1 ripple -> XOR3 ->
# acc_out_east[23]; AF route 1.19 ns), i.e. after the 1.25 ns negedge but with +1.00 ns slack against the SDC; at the
# negedge calls_prot reads 2 MSBs unsettled although every tile register equals the unit-delay run's at every edge
# (build/cbsg/af_ipd/route_debug/).  DRAIN_SAMPLE_LATE_PS=0 restores the negedge.
# Writes OUT_DIR/{runs.log,runs.tsv,summary.json}; exit 0 iff every run PASSes.
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$REPO"
RUN=${1:?route run}; ICG_JSON=${2:?sdf_clock_audit.json}
OUT=${OUT_DIR:?OUT_DIR}; [[ "$OUT" == /* ]] || OUT="$REPO/$OUT"
RAT=${GL_RATIONALE:?GL_RATIONALE}
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export NTFY_CHNL= PYTHONDONTWRITEBYTECODE=1 SNPSLMD_QUEUE=true USE_DW=1
export TSMC22_CELL_TIER=sc7mcpp140z TSMC22_LIB_FLAVORS=svt_c30 TSMC22_HPK_FLAVORS=svt_c30 TSMC22_HPK=1
unset NETLIST_FILE SDC_FILE SDF_FILE VCS_ARGS NO_SDF
source "$REPO/sweeps/cbsg/af_ipd/af_ipd_campaign_lib.sh"
arm=afipd
cbsg_arm_config afipd
work=$(dirname "$RAT")            # cbsg_gl_audit: rationale file and gl_validator_args.txt live there
TARGET=$target; TOP=$top; TB=$ftb
ROUTE=apr/build/$TARGET/$RUN
GOLD=build/cbsg/golden
EXTRA=build/cbsg/af_ipd/golden_extra
RV=build/cbsg/af_ipd/golden_rv
D=sweeps/cbsg/af_ipd
GEN=$D/gen_bp_workload.py
CHK=$D/check_bp_trace.py
MAX_JOBS=${MAX_JOBS:-12}
DRAIN_SAMPLE_LATE_PS=${DRAIN_SAMPLE_LATE_PS:-50}
[[ "$DRAIN_SAMPLE_LATE_PS" =~ ^[0-9]+$ ]] || { echo "DRAIN_SAMPLE_LATE_PS must be a non-negative integer" >&2; exit 2; }
DRAINARG=(); (( DRAIN_SAMPLE_LATE_PS == 0 )) || DRAINARG=("+DRAIN_SAMPLE_LATE_PS=$DRAIN_SAMPLE_LATE_PS")
LICWAIT_MIN=${LICWAIT_MIN:-60}
VCS_GL="vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -licwait $LICWAIT_MIN \$(VCS_ARGS) +incdir+\$(DESIGNS_DIR) -assert svaext"
VCS_RTL="vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -licwait $LICWAIT_MIN -debug_access+pp \$(VCS_ARGS) +incdir+\$(DESIGNS_DIR) -assert svaext"
[[ -s "$ROUTE/outputs/$TOP.apr.v" && -s "$ROUTE/outputs/$TOP.apr.sdf" ]] || { echo "missing routed netlist/SDF in $ROUTE" >&2; exit 2; }
for d in "$GOLD" "$EXTRA" "$RV"; do [[ -d "$d" ]] || { echo "missing $d" >&2; exit 2; }; done
mkdir -p "$OUT"
{
    echo "route=$ROUTE"
    for f in "outputs/$TOP.apr.v" "outputs/$TOP.apr.sdf"; do echo "$(sha256sum "$ROUTE/$f" | cut -d' ' -f1)  $f"; done
    echo "bench=$TB sha256=$(sha256sum "$TB" | cut -d' ' -f1)"
    echo "script sha256=$(sha256sum "$0" | cut -d' ' -f1)"
    echo "drain_sample_late_ps=$DRAIN_SAMPLE_LATE_PS"
} > "$OUT/inputs.txt"

#------------------------------------------------------------------ case lists --
# SC: label  cases  plusargs(comma list or -)  settle  expect(pass|fail)
SC_RUNS=$(cat <<'CASES'
settle2_plain_u128        plain_u128      -                     2 pass
settle2_chunked_rung      chunked_rung    -                     2 pass
settle2_calls_av257       calls_av257     -                     2 pass
settle0_plain_u128        plain_u128      -                     0 pass
settle0_chunked_rung      chunked_rung    -                     0 pass
settle0_calls_av257       calls_av257     -                     0 pass
calls_prot                calls_prot      -                     2 pass
calls_prot_intjunk        calls_prot      INT_JUNK              2 pass
plain_ladder              plain_ladder    -                     2 pass
af_calls_mixed            af_calls_mixed  -                     2 pass
rv_tiny_calls             rv_tiny_calls   -                     2 pass
chain_golden_combo_s10    @golden         NO_SLICE_START,STALL,JUNK_BUS,GAPS,RNG_GAP_LOW,MAC_EXACT,LOOSE_DRAIN,FULL_CYCLES,INT_JUNK,SEED=10 2 pass
chain_all_no_ss_intjunk   @all            NO_SLICE_START,INT_JUNK 2 pass
neg_short_u97             plain_u97       NEG_SHORT_BLOCK       2 fail
neg_next_early_rung       chunked_rung    NEG_NEXT_EARLY        2 fail
CASES
)
# INT: label  BA BW L MROWS NCOLS DIST SEED FLAGS  expect(pass | fail:CHECK | glonly:CHECK)  (the post-synthesis SDF list)
INT_RUNS=$(cat <<'CASES'
int8_uniform_L1024_m2n16_lapring 8 8 1024 2 16 uniform     3 LAP_RING_ONLY pass
int8_uniform_L256_m2n16_junk     8 8  256 2 16 uniform     6 JUNK        pass
int8_allmin_L1024_m1n8           8 8 1024 1  8 allmin      0 -           pass
int8_allmax_L1024_m1n8           8 8 1024 1  8 allmax      0 -           pass
w4a8_uniform_L1024_m2n16_lapring 8 4 1024 2 16 uniform    12 LAP_RING_ONLY pass
w4a8_minxmax_L1024_m1n8          8 4 1024 1  8 minxmax     0 -           pass
int4_uniform_L1024_m4n16_lapring 4 4 1024 4 16 uniform    22 LAP_RING_ONLY pass
int4_uniform_L256_m2n16_junk     4 4  256 2 16 uniform    23 JUNK        pass
int8_park_cyc0_L256_m2n8         8 8  256 2  8 uniform    61 PARK_CYC0,MODE_AT=3 pass
neg_int8_ringstray_L256_m1n8_lapring 8 8 256 1 8 uniform  37 NEG_RING_STRAY,LAP_RING_ONLY fail:CHECK
neg_w4a8_lap2_L256_m1n8_lapring  8 4  256 1  8 uniform    43 LAP_LEN=2,LAP_RING_ONLY fail:CHECK
neg_int4_prec_L256_m2n8          4 4  256 2  8 uniform    32 NEG_PREC    fail:CHECK
neg_int8_mag_w_L256_m1n8         8 8  256 1  8 uniform    67 NEG_MAG_W   glonly:CHECK
CASES
)
# switch: label | flags | expect (pass | fail:CHECK) | items (case name or i:BA:BW:L:MROWS:NCOLS:MODE_AT:JUNK:LAPRING:DIST:SEED)
SW_RUNS=$(cat <<'CASES'
sw_sdf_mixed_intjunk | INT_JUNK | pass | i:8:8:256:1:8:3:0:1:uniform:81 plain_u128 i:8:4:384:1:8:1:1:0:uniform:82 calls_prot i:4:4:256:2:8:2:0:1:uniform:83 plain_ladder
sw_mixed_intjunk_sc_first | INT_JUNK | pass | plain_u128 i:8:8:256:1:8:0:0:1:uniform:61 plain_u97 i:8:4:384:1:8:1:1:0:uniform:62 calls_prot i:4:4:256:2:8:2:0:1:uniform:63 af_perhead
all_interleaved | INT_JUNK,SEED=5 | pass | @ALL
neg_sw_sdf_no_reload | NEG_SW_NO_RELOAD | fail:CHECK | i:8:8:256:1:8:3:0:1:uniform:84 plain_u97
CASES
)

resolve() {   # comma list of case names / @golden / @all -> comma list of absolute dirs
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
res_fields() {
    grep -m1 '^RESULT' "$1" | sed -E 's/^RESULT cases=([0-9]+) calls=([0-9]+) blocks=([0-9]+) drains=([0-9]+) edges=([0-9]+) \| drain values ([0-9]+) bad ([0-9]+) .*stalls ([0-9]+) stray loads ([0-9]+).*/\1 \2 \3 \4 \5 \6 \7 \8 \9/'
}
compile_bench() {   # rtl|apr builddir
    local mode=$1 b=$2
    rm -rf "$b"; mkdir -p "$b/$TB"
    echo "$REPO/$GOLD/plain_u128" > "$b/$TB/cbsg_cases.txt"
    case "$mode" in
        rtl) make sim TOP=Top TB="$TB" BUILD_DIR="$b" GL= TARGET= RTL_PREFLIGHT_CMD= USE_DW=1 \
                 "VCS=$VCS_RTL" > "$b/compile.log" 2>&1 ;;
        apr) make sim GL=apr TARGET="$TARGET" RUN="$RUN" TB="$TB" BUILD_DIR="$b" SDF_CORNER=max NO_SDF= \
                 RTL_PREFLIGHT_CMD=true "VCS=$VCS_GL" VCS_ARGS="+neg_tchk +sdfverbose +define+CAI_RESET_SETTLE=2" \
                 NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" > "$b/compile.log" 2>&1 ;;
    esac
    grep -q '^PASS: CBSG AF-IPD bench' "$b/compile.log"
}
simv_of() { echo "$OUT/build_$1/$TB/simv"; }
audit() {   # dir expected-pass -> AUD (PASS/FAIL + reasons)
    local dir=$1 ep=$2
    { sed '/Running gate-level simulation/q' "$OUT/build_apr/compile.log"; cat "$dir/sim.log"; } > "$dir/simulation.log"
    if cbsg_gl_audit "$dir" "$ep" > "$dir/audit.log" 2>&1; then
        AUD="audit PASS ($(python3 -c 'import json,sys; q=json.load(open(sys.argv[1])); print("strict" if not q["approved_negative_iopath_clamps"] and not q["approved_annotated_interconnects"] else "APPROVALS", "post-reset viol", q["post_reset_timing_violations"], "sdf warn", q["sdf_warning_categories"])' "$dir/timing_qualification.json"))"
        return 0
    fi
    AUD="audit FAIL ($(tail -n 2 "$dir/audit.log" | tr '\n' ' ' | cut -c1-200))"; return 1
}

sc_case() {   # label cases plusargs settle expect
    local label=$1 cases=$2 plus=$3 settle=$4 expect=$5
    local dir="$OUT/sc/$label" args=() list gl rtl ok=1 t0 dt
    rm -rf "$dir"; mkdir -p "$dir/rtl"
    mapfile -t args < <(plus_of "$plus")
    args+=("+RESET_SETTLE=$settle" "${DRAINARG[@]}")
    list=$(resolve "$cases") || { echo "sc $label: FAIL (cannot resolve $cases)"; return 1; }
    t0=$SECONDS
    (cd "$dir" && "$(simv_of apr)" +vcs+lic+wait +MODE=sc "+CASES=$list" "${args[@]}" > sim.log 2>&1)
    dt=$((SECONDS - t0))
    (cd "$dir/rtl" && "$(simv_of rtl)" +vcs+lic+wait +MODE=sc "+CASES=$list" "${args[@]}" > sim.log 2>&1)
    gl=$(res_fields "$dir/sim.log"); rtl=$(res_fields "$dir/rtl/sim.log")
    if [[ -z "$gl" || -z "$rtl" || "$gl" == RESULT* || "$rtl" == RESULT* ]]; then
        echo "sc $label: FAIL [$expect] settle $settle (missing RESULT; see $dir)"; return 1
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
    local ep="PASS: CBSG AF-IPD bench"; [[ "$expect" != fail ]] || ep="RESULT cases="
    audit "$dir" "$ep" || ok=0
    echo "sc $label: $( ((ok)) && echo PASS || echo FAIL) [$expect] settle $settle ${plus} | drains $dbad/$dvals wrong, $edges edges, stalls $stalls, stray $stray | GL == RTL: $([[ "$gl" == "$rtl" ]] && echo yes || echo "NO (GL $gl / RTL $rtl)") | ${dt}s | $AUD"
    (( ok ))
}

int_case() {   # label BA BW L MROWS NCOLS DIST SEED FLAGS EXPECT
    local label=$1 ba=$2 bw=$3 L=$4 mrows=$5 ncols=$6 dist=$7 seed=$8 flags=$9 expect=${10}
    local dir="$OUT/int/$label" ok=1 msg="" t0 dt rtl_note
    local -a plus
    mapfile -t plus < <(plus_of "$flags")
    rm -rf "$dir"; mkdir -p "$dir/rtl"
    python3 "$GEN" --ba "$ba" --bw "$bw" --L "$L" --mrows "$mrows" --ncols "$ncols" --dist "$dist" \
        --seed "$seed" --out-dir "$dir" > "$dir/gen.log"
    cp "$dir/bpt_a.hex" "$dir/bpt_w.hex" "$dir/rtl/"
    local run=(+vcs+lic+wait +MODE=int +BA="$ba" +BW="$bw" +L="$L" +MROWS="$mrows" +NCOLS="$ncols" "${plus[@]}")
    t0=$SECONDS
    (cd "$dir" && "$(simv_of apr)" "${run[@]}" > sim.log 2>&1)
    dt=$((SECONDS - t0))
    (cd "$dir/rtl" && "$(simv_of rtl)" "${run[@]}" > sim.log 2>&1)
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
    audit "$dir" "PASS: BP INT bench" || ok=0
    echo "int $label: $( ((ok)) && echo PASS || echo FAIL) [$expect] ${flags} | ${msg}${rtl_note}; checker: $(tail -n 1 "$dir/check.log" | cut -c1-150) | ${dt}s | $AUD"
    (( ok ))
}

sw_case() {   # label flags expect items
    local label=$1 flags=$2 expect=$3 items=$4 dir="$OUT/switch/$1" seq=() rseq=() it n=0 f ok=1 msg=""
    local -a plus parts
    local t0 dt gl rtl
    mapfile -t plus < <(plus_of "$flags")
    plus+=("${DRAINARG[@]}")
    rm -rf "$dir"; mkdir -p "$dir/rtl"
    for it in $items; do
        if [[ $it == i:* ]]; then
            IFS=: read -ra parts <<< "$it"
            mkdir -p "$dir/i$n" "$dir/rtl/i$n"
            python3 "$GEN" --ba "${parts[1]}" --bw "${parts[2]}" --L "${parts[3]}" --mrows "${parts[4]}" \
                --ncols "${parts[5]}" --dist "${parts[9]}" --seed "${parts[10]}" --out-dir "$dir/i$n" > "$dir/i$n/gen.log"
            echo "${parts[1]} ${parts[2]} ${parts[3]} ${parts[4]} ${parts[5]} ${parts[6]} ${parts[7]} ${parts[8]}" > "$dir/i$n/bpt_cfg.txt"
            cp "$dir/i$n/bpt_a.hex" "$dir/i$n/bpt_w.hex" "$dir/i$n/bpt_cfg.txt" "$dir/rtl/i$n/"
            seq+=("int:$dir/i$n"); rseq+=("int:$dir/rtl/i$n")
            n=$((n + 1))
        else
            local r; r=$(resolve "$it") || { echo "switch $label: FAIL (case $it)"; return 1; }
            seq+=("sc:$r"); rseq+=("sc:$r")
        fi
    done
    t0=$SECONDS
    (cd "$dir" && "$(simv_of apr)" +vcs+lic+wait +MODE=switch "+SWITCH=$(IFS=,; echo "${seq[*]}")" "${plus[@]}" > sim.log 2>&1)
    dt=$((SECONDS - t0))
    (cd "$dir/rtl" && "$(simv_of rtl)" +vcs+lic+wait +MODE=switch "+SWITCH=$(IFS=,; echo "${rseq[*]}")" "${plus[@]}" > sim.log 2>&1)
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
    local ep="PASS: CBSG AF-IPD switch bench"; [[ "$expect" == pass ]] || ep="SWITCH_RESULT"
    audit "$dir" "$ep" || ok=0
    read -r _ _ blocks drains edges dvals dbad _ _ <<< "$gl"
    echo "switch $label: $( ((ok)) && echo PASS || echo FAIL) [$expect] ${flags} | SC blocks $blocks, drains $dbad/$dvals wrong; $n INT segments; $(grep -m1 '^SWITCH_RESULT' "$dir/sim.log" | sed 's/^SWITCH_RESULT //')${msg:+ | $msg}| ${dt}s | $AUD"
    (( ok ))
}

#-------------------------------------------------------------------- driver --
status=0
pids=()
compile_bench rtl "$OUT/build_rtl" & pids+=("$!")
compile_bench apr "$OUT/build_apr" & pids+=("$!")
for p in "${pids[@]}"; do wait "$p" || status=1; done
(( status == 0 )) || { echo "bench compile FAILED ($OUT/build_rtl/compile.log, $OUT/build_apr/compile.log)"; exit 1; }
grep -q 'sdf corner = max' "$OUT/build_apr/compile.log" && grep -Fq '[INFO] $sdf_annotate(' "$OUT/build_apr/compile.log" \
    || { echo "no routed SDF annotation in $OUT/build_apr/compile.log"; exit 1; }
echo "routed GL: compiled $(grep -o 'netlist = .*' "$OUT/build_apr/compile.log" | head -1 | sed "s#$REPO/##")"
: > "$OUT/runs.log"
while read -r label c plus settle expect; do
    [[ -n "$label" ]] || continue
    sc_case "$label" "$c" "$plus" "$settle" "$expect" >> "$OUT/runs.log" &
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
done <<< "$SC_RUNS"
while read -r label ba bw L mr nc dist seed flags expect; do
    [[ -n "$label" ]] || continue
    int_case "$label" "$ba" "$bw" "$L" "$mr" "$nc" "$dist" "$seed" "$flags" "$expect" >> "$OUT/runs.log" &
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
done <<< "$INT_RUNS"
cfgs=("8:8:256:1:8:0:0:1" "8:4:384:1:8:1:1:0" "4:4:256:2:8:2:0:1" "8:8:128:1:16:3:1:1" "4:4:384:2:8:0:1:0" "8:4:128:1:8:0:0:0")
all=""; k=0
for c in "$GOLD"/*/ "$EXTRA"/*/ "$RV"/*/; do all+="$(basename "$c") i:${cfgs[$((k % 6))]}:uniform:$((100 + k)) "; k=$((k + 1)); done
while IFS='|' read -r label flags expect items; do
    label=$(echo $label); flags=$(echo $flags); expect=$(echo $expect); items=$(echo $items)
    [[ -n "$label" ]] || continue
    [[ "$items" == @ALL ]] && items=$all
    sw_case "$label" "$flags" "$expect" "$items" >> "$OUT/runs.log" &
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
done <<< "$SW_RUNS"
while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done
sort -o "$OUT/runs.log" "$OUT/runs.log"
cat "$OUT/runs.log"
total=$(( $(grep -c . <<< "$SC_RUNS") + $(grep -c . <<< "$INT_RUNS") + $(grep -c . <<< "$SW_RUNS") ))
python3 - "$OUT/runs.log" "$ICG_JSON" "$OUT/summary.json" "$total" <<'PY'
import json, re, sys
lines = [l for l in open(sys.argv[1]).read().splitlines() if l.strip()]
icg = json.load(open(sys.argv[2])); total = int(sys.argv[4])
runs = []
for l in lines:
    m = re.match(r'^(sc|int|switch) (\S+): (PASS|FAIL) \[([^\]]+)\]', l)
    if m: runs.append(dict(kind=m[1], label=m[2], status=m[3], expect=m[4], strict='audit PASS (strict' in l, line=l))
ok = lambda pred: all(r['status'] == 'PASS' for r in runs if pred(r))
settle2 = ok(lambda r: r['label'].startswith('settle2_'))
out = dict(arm='afipd', total=total, ran=len(runs), passed=sum(r['status'] == 'PASS' for r in runs),
           strict_audits=sum(r['strict'] for r in runs),
           by_kind={k: f"{sum(r['status']=='PASS' for r in runs if r['kind']==k)}/{sum(r['kind']==k for r in runs)}" for k in ('sc', 'int', 'switch')},
           ideal_clock_view_needed=not (icg['status'] == 'PASS' and settle2),
           reset_settle_needed=not ok(lambda r: r['label'].startswith('settle0_')),
           worst_icg_ck_eck_ns=icg['worst_icg_iopath_ns'], icg_cells=icg['icg_cells'],
           note="settle 0 = first load on the first edge after reset (the RTL suite's tightest schedule); "
                "SC-first switch runs also load on the first edge after reset", runs=runs)
json.dump(out, open(sys.argv[3], 'w'), indent=2)
print(json.dumps({k: v for k, v in out.items() if k != 'runs'}))
sys.exit(0 if out['passed'] == total == len(runs) else 1)
PY
rc=$?
(( status == 0 && rc == 0 )) && echo "routed GL checks: PASS" || { echo "routed GL checks: FAIL"; exit 1; }
