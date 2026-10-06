#!/bin/bash
# Routed functional GL of the all-bits-in-time INT schedule (+MODE=abit of designs/payn/tb/test_payn_array_cbsg_af_ipd.sv)
# on the qualified AF-IPD route, beyond the energy bench: junk on every don't-care input, extremes, a parked AF counter,
# and negative controls, on the routed netlist with the RAW routed SDF (max corner, +neg_tchk +sdfverbose, timing checks
# on).  Derived from the int part of sweeps/cbsg/af_ipd/run_routed_gl_checks.sh (same netlist compile, same RTL
# reference compile, same audit): every case runs on the routed netlist and on RTL with the same inputs; the GL trace
# must be byte-identical to the RTL trace, the checker (sweeps/cbsg/af_ipd/abit/check_abit_trace.py) must PASS (or
# CATCH a negative control), and every GL log goes through cbsg_gl_audit (validate_routed_gl.py strict first;
# approvals only after a strict failure, AFIPD_GL_VALIDATOR_ARGS, rationale file $OUT/gl_validator_args_rationale.txt).
#   AFIPD_GL_VALIDATOR_ARGS=--approve-annotated-interconnect bash sweeps/cbsg/af_ipd/abit/run_abit_routed_func.sh
# Output: build/power_char/cbsg_20261005/af_ipd/abit_routed_func/<ROUTE_RUN>/{runs.log,<label>/}.
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
builtin cd "$REPO"
RUN=${ROUTE_RUN:-cbsg_af_ipd_20261005_distguide_spp_pins_postfill}
OUT=${OUT:-build/power_char/cbsg_20261005/af_ipd/abit_routed_func/$RUN}; [[ "$OUT" == /* ]] || OUT="$REPO/$OUT"
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
work=$OUT                         # cbsg_gl_audit: rationale file and gl_validator_args.txt live there
TARGET=$target; TOP=$top; TB=$ftb
ROUTE=apr/build/$TARGET/$RUN
GOLD=build/cbsg/golden
A=sweeps/cbsg/af_ipd/abit
MAX_JOBS=${MAX_JOBS:-8}
VCS_GL="vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -licwait 60 \$(VCS_ARGS) +incdir+\$(DESIGNS_DIR) -assert svaext"
VCS_RTL="vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -licwait 60 -debug_access+pp \$(VCS_ARGS) +incdir+\$(DESIGNS_DIR) -assert svaext"
[[ -s "$ROUTE/outputs/$TOP.apr.v" && -s "$ROUTE/outputs/$TOP.apr.sdf" ]] || { echo "missing routed netlist/SDF in $ROUTE" >&2; exit 2; }
mkdir -p "$OUT"
{
    echo "route=$ROUTE"
    for f in "outputs/$TOP.apr.v" "outputs/$TOP.apr.sdf"; do echo "$(sha256sum "$ROUTE/$f" | cut -d' ' -f1)  $f"; done
    echo "bench=$TB sha256=$(sha256sum "$TB" | cut -d' ' -f1)"
    echo "script sha256=$(sha256sum "$0" | cut -d' ' -f1)"
    echo "validator_args=${AFIPD_GL_VALIDATOR_ARGS:-}"
} > "$OUT/inputs.txt"

# label BA BW L MROWS NCOLS DIST SEED FLAGS EXPECT (pass | caught); the rows of run_abit_rtl.sh's single-PE matrix.
CASES=$(cat <<'EOF'
int8_uniform_L384_m16n16          8 8  384 16 16 uniform      3 -                       pass
int8_uniform_L384_m24n16_junk     8 8  384 24 16 uniform      4 JUNK                    pass
int8_allmin_L384_m8n8             8 8  384  8  8 allmin       0 -                       pass
int8_minxmax_L384_m8n8            8 8  384  8  8 minxmax      0 -                       pass
int8_uniform_L256_m8n16_park      8 8  256  8 16 uniform      8 PARK_CYC0,MODE_AT=2     pass
int6_uniform_L1024_m16n8_junk     6 6 1024 16  8 uniform     24 JUNK                    pass
int6_allmin_L4096_m8n8            6 6 4096  8  8 allmin       0 -                       pass
int4_uniform_L4096_m8n8           4 4 4096  8  8 uniform     33 -                       pass
int4_uniform_L1024_m8n16_junk     4 4 1024  8 16 uniform     34 JUNK                    pass
w4a8_uniform_L512_m8n8_junk       8 4  512  8  8 uniform     42 JUNK                    pass
w6a8_minxmax_L1024_m8n8           8 6 1024  8  8 minxmax      0 -                       pass
neg_int8_nolap_mid_L128           8 8  128  8  8 uniform     52 NEG_ABIT_NO_LAP=7       caught
neg_int8_extralap_L128            8 8  128  8  8 uniform     57 NEG_ABIT_EXTRA_LAP=7    caught
neg_int6_sign_a0_L1024            6 6 1024  8  8 uniform     63 NEG_ABIT_SIGN=1         caught
neg_int8_order_lsb_L128           8 8  128  8  8 uniform     66 NEG_ABIT_ORDER=1        caught
neg_int8_overlap_L256_m8n16       8 8  256  8 16 uniform     74 NEG_ABIT_OVERLAP        caught
EOF
)

plus_of() { local x fl; [[ "$1" == - ]] && return 0; IFS=, read -ra fl <<< "$1"; for x in "${fl[@]}"; do echo "+$x"; done; }
compile_bench() {   # rtl|apr builddir (run_routed_gl_checks.sh's compile, its SC smoke case included)
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

one_case() {   # label ba bw L mrows ncols dist seed flags expect
    local label=$1 ba=$2 bw=$3 L=$4 mrows=$5 ncols=$6 dist=$7 seed=$8 flags=$9 expect=${10}
    local dir="$OUT/$label" ok=1 note chk aud
    local -a plus
    mapfile -t plus < <(plus_of "$flags")
    rm -rf "$dir"; mkdir -p "$dir/rtl"
    python3 "$A/gen_abit_workload.py" --ba "$ba" --bw "$bw" --L "$L" --mrows "$mrows" --ncols "$ncols" --dist "$dist" \
        --seed "$seed" --out-dir "$dir" > "$dir/gen.log"
    cp "$dir/bpt_a.hex" "$dir/bpt_w.hex" "$dir/rtl/"
    local run=(+vcs+lic+wait +MODE=abit +BA="$ba" +BW="$bw" +L="$L" +MROWS="$mrows" +NCOLS="$ncols" +SEED="$seed" "${plus[@]}")
    (builtin cd "$dir" && "$(simv_of apr)" "${run[@]}" > sim.log 2>&1)
    (builtin cd "$dir/rtl" && "$(simv_of rtl)" "${run[@]}" > sim.log 2>&1)
    grep -q '^PASS: ABIT INT bench' "$dir/sim.log" || { ok=0; note="GL bench did not finish; "; }
    grep -q '^PASS: ABIT INT bench' "$dir/rtl/sim.log" || { ok=0; note+="RTL bench did not finish; "; }
    if grep -qE 'Error-\[|\[TIMEOUT\]|\[X-FAIL\]|\[TIMING-FAIL\]' "$dir/sim.log"; then ok=0; note+="GL error tag; "; fi
    if cmp -s "$dir/abit_trace.txt" "$dir/rtl/abit_trace.txt"; then note+="GL trace == RTL trace"
    else ok=0; note+="GL trace DIFFERS from RTL trace"; fi
    if [[ "$expect" == caught ]]; then
        python3 "$A/check_abit_trace.py" "$dir" --json "$dir/check.json" --expect-fail > "$dir/check.log" 2>&1 || ok=0
    else
        python3 "$A/check_abit_trace.py" "$dir" --json "$dir/check.json" > "$dir/check.log" 2>&1 || ok=0
    fi
    { sed '/Running gate-level simulation/q' "$OUT/build_apr/compile.log"; cat "$dir/sim.log"; } > "$dir/simulation.log"
    if cbsg_gl_audit "$dir" "PASS: ABIT INT bench" > "$dir/audit.log" 2>&1; then
        aud="audit PASS ($(python3 -c 'import json,sys; q=json.load(open(sys.argv[1])); s=json.load(open(sys.argv[2])); print("strict" if s["status"]=="PASS" else "strict FAIL "+str(s["rejection_reasons"])+" -> approvals "+str(len(q["approved_annotated_interconnects"]))+" IWSBA", "| post-reset viol", q["post_reset_timing_violations"])' "$dir/timing_qualification.json" "$dir/timing_qualification_strict.json"))"
    else
        ok=0; aud="audit FAIL ($(tail -n 2 "$dir/audit.log" | tr '\n' ' ' | cut -c1-200))"
    fi
    echo "$label: $( ((ok)) && echo PASS || echo FAIL) [$expect] ${flags} | ${note} | $(tail -n 1 "$dir/check.log" | cut -c1-170) | $aud"
    (( ok ))
}

status=0
echo "compiling the functional bench: routed netlist (raw max SDF) and RTL"
compile_bench apr "$OUT/build_apr" & p1=$!
compile_bench rtl "$OUT/build_rtl" & p2=$!
wait "$p1" || { echo "routed compile FAILED ($OUT/build_apr/compile.log)"; exit 1; }
wait "$p2" || { echo "RTL compile FAILED ($OUT/build_rtl/compile.log)"; exit 1; }
: > "$OUT/runs.log"
while read -r label ba bw L mrows ncols dist seed flags expect; do
    [[ -n "$label" ]] || continue
    one_case "$label" "$ba" "$bw" "$L" "$mrows" "$ncols" "$dist" "$seed" "$flags" "$expect" >> "$OUT/runs.log" &
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
done <<< "$CASES"
while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done
sort -o "$OUT/runs.log" "$OUT/runs.log"
cat "$OUT/runs.log"
echo "routed functional abit GL: $(grep -c ': PASS' "$OUT/runs.log") / $(grep -c . <<< "$CASES") PASS"
exit "$status"
