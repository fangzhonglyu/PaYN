#!/bin/bash
# BP-space (T2) INT on the post-synthesis netlist of the UNCHANGED BP top
# (TSMC22/PAYN_SC_CSA_BP, RUN=csa_bp_20261004_lap): the bench
# designs/payn/tb/test_payn_array_bp_space.sv, NO_SDF, unit delay, timing
# checks off, ARM_UD_MODEL + ARM_EN_X_SQUASH (the recipe of
# sweeps/run_csa_bp_syn_gl_checks.sh, which is not changed).  A few cases of
# the RTL matrix (same labels, operands and plusargs as
# run_bp_space_checks.sh), each checked by check_bp_space_trace.py; every GL
# trace must equal the RTL trace of the same case (build/rtl_preflight/bp_space/p1/<label>/,
# ring records excluded: the netlist has no ring_q name to monitor).
# Functional only: timing is signed off by STA on the routed design.
#
#   bash sweeps/int_mode/bp/space/run_bp_space_syn_gl.sh
#   PHASE=compile | PHASE=run   (default both; compiling reads the ARM cell
#   library from AFS and needs a token: kinit && aklog)
# Logs: build/rtl_preflight/bp_space/syn_gl/
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
cd "$REPO"
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
export NTFY_CHNL=
unset NETLIST_FILE SDC_FILE SDF_FILE VCS_ARGS
TARGET=TSMC22/PAYN_SC_CSA_BP
RUN=${RUN:-csa_bp_20261004_lap}
TOP=payn_array_signed_segmented_csa_bp
PHASE=${PHASE:-"compile run"}
OUT=build/rtl_preflight/bp_space/syn_gl
RTL_DIR=build/rtl_preflight/bp_space/p1
TB=designs/payn/tb/test_payn_array_bp_space.sv
BUILD=$OUT/build
VCS_GL='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
GLDEF="+define+ARM_UD_MODEL+define+ARM_EN_X_SQUASH +delay_mode_unit +notimingcheck"
NETLIST="syn/build/$TARGET/$RUN/$TOP.syn.v"
[[ -s "$NETLIST" ]] || { echo "missing netlist $NETLIST" >&2; exit 2; }
mkdir -p "$OUT"

if [[ " $PHASE " == *" compile "* ]]; then
    rm -rf "$BUILD"; mkdir -p "$BUILD/$TB"
    # The flow runs the simv once after compiling (default plusargs: INT8 S=8 L=128, 8 blocks).
    python3 sweeps/int_mode/bp/space/gen_bp_space_workload.py --ba 8 --bw 8 --L 128 --mrows 1 --ncols 8 \
        --dist uniform --seed 1 --out-dir "$BUILD/$TB" > /dev/null
    make sim GL=syn TARGET="$TARGET" RUN="$RUN" TB="$TB" BUILD_DIR="$BUILD" NO_SDF=1 \
        RTL_PREFLIGHT_CMD=true "VCS=$VCS_GL" VCS_ARGS="+define+PAYN_ARRAY_DUT=$TOP $GLDEF" \
        > "$OUT/compile.log" 2>&1
    grep -q '^PASS: BP space bench' "$OUT/compile.log" || { echo "GL compile/run FAILED: $OUT/compile.log"; exit 1; }
    grep -q "$NETLIST" "$OUT/compile.log" || { echo "GL compile did not read $NETLIST"; exit 1; }
    echo "GL compile: PASS ($NETLIST)"
fi
[[ " $PHASE " == *" run "* ]] || exit 0

# label BA BW S L MROWS NCOLS DIST SEED FLAGS EXPECT  (labels as in run_bp_space_checks.sh)
CASES=$(cat <<'CASES_EOF'
p1_int8_s8_uniform_L1024_m2n3          8 8 8 1024 2 3 uniform     3 -           pass
p1_int8_s8_allmin_L1024_m1n2_junk      8 8 8 1024 1 2 allmin      0 JUNK        pass
p1_w4a8_s4_minxmax_L1024_m1n4          8 4 4 1024 1 4 minxmax     0 -           pass
p1_int4_s4_uniform_L1024_m4n4_junk     4 4 4 1024 4 4 uniform    23 JUNK        pass
p1_int8_s2_uniform_L1024_m2n8          8 8 2 1024 2 8 uniform    41 -           pass
p1_neg_wsign_int8_s8                   8 8 8  256 1 2 uniform    91 NEG_WSIGN   fail
CASES_EOF
)
simv="$REPO/$BUILD/$TB/simv"
[[ -x "$simv" ]] || { echo "no GL simv: run PHASE=compile first"; exit 1; }
status=0
while read -r label ba bw s L mrows ncols dist seed flags expect; do
    [[ -n "$label" ]] || continue
    dir="$OUT/$label"; plus=()
    if [[ "$flags" != - ]]; then IFS=, read -ra fl <<< "$flags"; for x in "${fl[@]}"; do plus+=("+$x"); done; fi
    rm -rf "$dir"; mkdir -p "$dir"
    python3 sweeps/int_mode/bp/space/gen_bp_space_workload.py --ba "$ba" --bw "$bw" --L "$L" \
        --mrows "$mrows" --ncols "$ncols" --dist "$dist" --seed "$seed" --out-dir "$dir" > "$dir/gen.log"
    (cd "$dir" && "$simv" +BA="$ba" +BW="$bw" +S="$s" +L="$L" +MROWS="$mrows" +NCOLS="$ncols" \
        "${plus[@]}" > sim.log 2>&1)
    if ! grep -q '^PASS: BP space bench' "$dir/sim.log"; then echo "$label: FAIL (simulation error, $dir/sim.log)"; status=1; continue; fi
    python3 sweeps/int_mode/bp/space/check_bp_space_trace.py "$dir" --json "$dir/check.json" --no-ring-monitor > "$dir/check.log" 2>&1
    rc=$?
    same="no RTL trace to compare"
    if [[ -f "$RTL_DIR/$label/bps_trace.txt" ]]; then
        if cmp -s <(grep -v '^R ' "$dir/bps_trace.txt") <(grep -v '^R ' "$RTL_DIR/$label/bps_trace.txt"); then
            same="GL trace identical to RTL"
        else
            echo "$label: FAIL (GL trace differs from the RTL trace)"; status=1; continue
        fi
    fi
    if [[ $expect == pass ]]; then
        if (( rc == 0 )); then echo "$label: PASS ($same) $(tail -1 "$dir/check.log" | sed 's/^\[PASS\] //')"
        else echo "$label: FAIL $(tail -1 "$dir/check.log")"; status=1; fi
    else
        if (( rc != 0 )) && grep -q '^\[FAIL\]' "$dir/check.log"; then
            echo "$label: PASS (negative control caught, $same: $(tail -1 "$dir/check.log" | sed 's/^\[FAIL\] //'))"
        else echo "$label: FAIL (negative control not caught)"; status=1; fi
    fi
done <<< "$CASES" | tee "$OUT/summary.log"
grep -q FAIL "$OUT/summary.log" && status=1
echo "BP-space post-synthesis GL: $([[ $status == 0 ]] && echo PASS || echo FAIL)" | tee -a "$OUT/summary.log"
exit $status
