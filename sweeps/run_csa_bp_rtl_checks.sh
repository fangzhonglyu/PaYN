#!/bin/bash
# RTL checks for the bit-plane INT variant (signed_segmented_csa_bp), the
# preflight for synthesizing TSMC22/PAYN_SC_CSA_BP.
#
# (a) SC regression of the BP top with its INT inputs tied off
#     (+define+PAYN_INT_PORTS), K8/M16/N8, LOW_W=9, T=128:
#       csa_bp_sc            full-array cosim vs sc_kernel.py (run_array.sh)
#       csa_bp_sc_stream     384-batch streaming power bench vs cosim_streaming.py
#     and the same two with PAYN_INT_RAW_JUNK (random raw planes, int_prec and
#     ring_in every cycle, int_mode = 0), whose traces must equal the tied-off
#     runs byte for byte.  The accepted CSA top also runs through both benches
#     WITHOUT the define (csa_bp_ref_csa*, the benches' unchanged path); the BP
#     traces must equal those byte for byte.  SC drop-in at the tops' default
#     shape (9x9, K6: the power bench's defaults), with INT junk: BP and CSA
#     streaming traces identical.  The reviewer's default-parameter probe
#     (BP top with no parameters) must elaborate and run.
# (b) INT matrix on designs/payn/tb/test_payn_array_bp.sv (real ports): INT8,
#     W4A8, INT4; uniform (with forced extremes), all-min, all-max, min x max,
#     max x min, -1 x min, alternating; L = 128 .. 4096 plus near-limit
#     lengths (INT8 65,408; W4A8 / INT4 1,048,448: tiles within 2^14 of 2^23,
#     outputs up to ~2^30), multi-block, back-to-back output blocks;
#     adversarial JUNK runs; the latest legal int_mode rise (MODE_AT=3); and
#     negative controls, each with the failure mode it must show (CHECK:
#     checker mismatch, TIMING: the bench's [TIMING-FAIL], CONTRACT: the top's
#     [BP-CONTRACT] simulation check).  Every drained tile and combiner word is
#     checked against numpy int64 by sweeps/int_mode/bp/check_bp_trace.py.
#     One compile serves all cases.
#
#   bash sweeps/run_csa_bp_rtl_checks.sh            # everything
#   PARTS=int bash sweeps/run_csa_bp_rtl_checks.sh  # only (b); PARTS=sc only (a)
# Logs: build/rtl_preflight/csa_bp_*.log, per-case dirs build/rtl_preflight/csa_bp_int/.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export USE_DW=1 NTFY_CHNL=
PARTS=${PARTS:-"sc int"}
MAX_JOBS=${MAX_JOBS:-8}
SRC=designs/payn/variants/signed_segmented_csa_bp/payn_array_signed_segmented_csa_bp.sv
VCS_PP='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
OUT=build/rtl_preflight
mkdir -p "$OUT"
SHAPE_DEF="+define+PAYN_ARRAY_EXTERNAL_RTL+define+PAYN_SEG_LOW_W=9+define+SC_K=8+define+SC_M=16+define+SC_NH=8+define+SC_NW=8+define+SC_OWIDTH=24+define+SC_T=128"
DEF="$SHAPE_DEF+define+PAYN_ARRAY_DUT=payn_array_signed_segmented_csa_bp+define+PAYN_INT_PORTS"
CSA_SRC=designs/payn/variants/signed_segmented_csa/payn_array_signed_segmented_csa.sv
CSA_DEF="$SHAPE_DEF+define+PAYN_ARRAY_DUT=payn_array_signed_segmented_csa"
ARRAY_TRACE=designs/payn/tb/test_payn_array.sv/array_rtl.txt
STREAM_TRACE=designs/payn/power/power_payn_array.sv/array_streaming_rtl.txt

#------------------------------------------------------------ (a) SC mode --
sc_array() {   # name src defines
    BUILD_DIR="$OUT/$1" SIM_SRCS=$2 VCS_ARGS="$3" \
        bash designs/payn/cosim/run_array.sh NTFY_CHNL= "VCS=$VCS_PP" > "$OUT/$1.log" 2>&1
    grep -q '\[PASS\]' "$OUT/$1.log"
    echo "$1: array cosim PASS"
}
sc_stream_n() {  # name src defines batches
    BUILD_DIR="$OUT/$1" SIM_SRCS=$2 \
        bash designs/payn/cosim/run_power_array.sh NTFY_CHNL= "VCS=$VCS_PP" \
        VCS_ARGS="$3+define+SC_BATCHES=$4" > "$OUT/$1.log" 2>&1
    grep -q '\[PASS\]' "$OUT/$1.log"
    echo "$1: streaming cosim PASS ($4 batches)"
}
sc_stream() { sc_stream_n "$1" "$2" "$3" 384; }   # name src defines
# The reviewer's probe: the BP top with no parameters at all (PAYN_K=6, 9x9).
default_params() {
    local b="$OUT/csa_bp_default_params"
    rm -rf "$b"; mkdir -p "$b"
    vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca +incdir+designs -assert svaext \
        -timescale=1ns/1ps -o "$b/simv" -Mdir="$b/obj" \
        -y "$SYNOPSYS/dw/sim_ver" +libext+.v+ +incdir+"$SYNOPSYS/dw/sim_ver" \
        sweeps/int_mode/bp/verify/tb_bp_default_params.sv -top TbBpDefaultParams > "$b/compile.log" 2>&1
    (cd "$b" && ./simv > sim.log 2>&1)
    grep -q DEFAULT_PARAMS_OK "$b/sim.log"
    echo "default-parameter probe: $(grep -o 'DEFAULT_PARAMS_OK.*' "$b/sim.log")"
}
run_sc() {
    local pids=() status=0
    local dflt="+define+PAYN_ARRAY_EXTERNAL_RTL+define+PAYN_ARRAY_DUT"
    sc_array csa_bp_sc "$SRC" "$DEF" & pids+=("$!")
    sc_array csa_bp_sc_junk "$SRC" "$DEF+define+PAYN_INT_RAW_JUNK" & pids+=("$!")
    sc_array csa_bp_ref_csa "$CSA_SRC" "$CSA_DEF" & pids+=("$!")
    sc_stream csa_bp_sc_stream "$SRC" "$DEF" & pids+=("$!")
    sc_stream csa_bp_sc_stream_junk "$SRC" "$DEF+define+PAYN_INT_RAW_JUNK" & pids+=("$!")
    sc_stream csa_bp_ref_csa_stream "$CSA_SRC" "$CSA_DEF" & pids+=("$!")
    # Default shape (no shape defines); 64 batches is enough for a drop-in check.
    sc_stream_n csa_bp_sc_stream_default "$SRC" \
        "$dflt=payn_array_signed_segmented_csa_bp+define+PAYN_INT_PORTS+define+PAYN_INT_RAW_JUNK" 64 & pids+=("$!")
    sc_stream_n csa_bp_ref_csa_stream_default "$CSA_SRC" "$dflt=payn_array_signed_segmented_csa" 64 & pids+=("$!")
    default_params & pids+=("$!")
    for pid in "${pids[@]}"; do wait "$pid" || status=1; done
    (( status == 0 )) || return 1
    cmp "$OUT/csa_bp_sc/$ARRAY_TRACE" "$OUT/csa_bp_sc_junk/$ARRAY_TRACE"
    cmp "$OUT/csa_bp_sc_stream/$STREAM_TRACE" "$OUT/csa_bp_sc_stream_junk/$STREAM_TRACE"
    echo "SC junk on raw planes / int_prec / ring_in: traces identical to the tied-off runs"
    cmp "$OUT/csa_bp_sc/$ARRAY_TRACE" "$OUT/csa_bp_ref_csa/$ARRAY_TRACE"
    cmp "$OUT/csa_bp_sc_stream/$STREAM_TRACE" "$OUT/csa_bp_ref_csa_stream/$STREAM_TRACE"
    echo "BP top in SC mode: both traces identical to the accepted CSA top run without PAYN_INT_PORTS"
    cmp "$OUT/csa_bp_sc_stream_default/$STREAM_TRACE" "$OUT/csa_bp_ref_csa_stream_default/$STREAM_TRACE"
    echo "BP top at the default 9x9/K6 shape, INT junk on: streaming trace identical to the CSA top"
}

#------------------------------------------------------------ (b) INT mode --
TB=designs/payn/tb/test_payn_array_bp.sv
INT_DIR=$OUT/csa_bp_int
# label BA BW L MROWS NCOLS DIST SEED FLAGS EXPECT   (FLAGS: comma-separated plusargs)
# EXPECT: pass | fail:CHECK | fail:TIMING | fail:CONTRACT
CASES=$(cat <<'EOF'
int8_uniform_L128_m1n8           8 8     128 1  8 uniform     1 -                pass
int8_uniform_L384_m2n16          8 8     384 2 16 uniform     2 -                pass
int8_uniform_L1024_m2n16         8 8    1024 2 16 uniform     3 -                pass
int8_uniform_L4096_m1n8          8 8    4096 1  8 uniform     4 -                pass
int8_relu_L1024_m1n8             8 8    1024 1  8 relu        5 -                pass
int8_allmin_L1024_m1n8           8 8    1024 1  8 allmin      0 -                pass
int8_allmax_L1024_m1n8           8 8    1024 1  8 allmax      0 -                pass
int8_minxmax_L1024_m1n16         8 8    1024 1 16 minxmax     0 -                pass
int8_maxxmin_L256_m2n8           8 8     256 2  8 maxxmin     0 -                pass
int8_alternating_L1024_m2n8      8 8    1024 2  8 alternating 0 -                pass
int8_uniform_L256_m2n16_junk     8 8     256 2 16 uniform     6 JUNK             pass
int8_uniform_L256_m2n8_modeat3   8 8     256 2  8 uniform     7 MODE_AT=3        pass
int8_allmin_L65408_m1n8          8 8   65408 1  8 allmin      0 -                pass
int8_neg1xmin_L65408_m1n8        8 8   65408 1  8 neg1xmin    0 -                pass
w4a8_uniform_L128_m1n8           8 4     128 1  8 uniform    11 -                pass
w4a8_uniform_L1024_m2n16         8 4    1024 2 16 uniform    12 -                pass
w4a8_allmin_L1024_m1n8           8 4    1024 1  8 allmin      0 -                pass
w4a8_allmax_L1024_m1n8           8 4    1024 1  8 allmax      0 -                pass
w4a8_minxmax_L1024_m1n8          8 4    1024 1  8 minxmax     0 -                pass
w4a8_alternating_L512_m1n16      8 4     512 1 16 alternating 0 -                pass
w4a8_uniform_L256_m3n8_junk      8 4     256 3  8 uniform    13 JUNK             pass
w4a8_neg1xmin_L1048448_m1n8      8 4 1048448 1  8 neg1xmin    0 -                pass
int4_uniform_L128_m2n8           4 4     128 2  8 uniform    21 -                pass
int4_uniform_L1024_m4n16         4 4    1024 4 16 uniform    22 -                pass
int4_allmin_L1024_m2n8           4 4    1024 2  8 allmin      0 -                pass
int4_allmax_L1024_m2n8           4 4    1024 2  8 allmax      0 -                pass
int4_minxmax_L1024_m2n8          4 4    1024 2  8 minxmax     0 -                pass
int4_alternating_L384_m4n8       4 4     384 4  8 alternating 0 -                pass
int4_uniform_L256_m2n16_junk     4 4     256 2 16 uniform    23 JUNK             pass
int4_allmin_L1048448_m2n8        4 4 1048448 2  8 allmin      0 -                pass
neg_int8_noring_L256_m1n8        8 8     256 1  8 uniform    31 NEG_NO_RING      fail:TIMING
neg_int4_prec_L256_m2n8          4 4     256 2  8 uniform    32 NEG_PREC         fail:CHECK
neg_int8_nolapshift_L256_m1n8    8 8     256 1  8 uniform    33 NEG_NO_LAP_SHIFT fail:CHECK
neg_int8_mag_L256_m1n8           8 8     256 1  8 uniform    34 NEG_MAG          fail:CONTRACT
neg_int8_modeat4_L256_m1n8       8 8     256 1  8 uniform    35 MODE_AT=4        fail:CHECK
EOF
)

int_case() {   # simv label BA BW L MROWS NCOLS DIST SEED FLAGS EXPECT
    local simv=$1 label=$2 ba=$3 bw=$4 L=$5 mrows=$6 ncols=$7 dist=$8 seed=$9 flags=${10} expect=${11}
    local dir="$INT_DIR/$label" plus=() fl x rc=0 bench_pass=0 tag
    if [[ "$flags" != - ]]; then
        IFS=, read -ra fl <<< "$flags"
        for x in "${fl[@]}"; do plus+=("+$x"); done
    fi
    rm -rf "$dir"; mkdir -p "$dir"
    python3 sweeps/int_mode/bp/gen_bp_workload.py --ba "$ba" --bw "$bw" --L "$L" \
        --mrows "$mrows" --ncols "$ncols" --dist "$dist" --seed "$seed" --out-dir "$dir" > "$dir/gen.log"
    (cd "$dir" && "$simv" +BA="$ba" +BW="$bw" +L="$L" +MROWS="$mrows" +NCOLS="$ncols" "${plus[@]}" \
        > sim.log 2>&1) || rc=$?
    if (( rc == 0 )) && grep -q '^PASS: BP INT bench' "$dir/sim.log"; then bench_pass=1; fi
    case "$expect" in
        fail:TIMING|fail:CONTRACT)
            tag=TIMING-FAIL
            [[ "$expect" == fail:CONTRACT ]] && tag=BP-CONTRACT
            if (( bench_pass == 0 )) && grep -q "\[$tag\]" "$dir/sim.log"; then
                echo "$label: PASS (negative control caught by [$tag]:$(grep -m1 "\[$tag\]" "$dir/sim.log" | sed 's/^.*\]//' | cut -c1-80))"
                return 0
            fi
            echo "$label: FAIL (expected [$tag], see $dir/sim.log)"; return 1 ;;
    esac
    (( bench_pass )) || { echo "$label: FAIL (simulation error, see $dir/sim.log)"; return 1; }
    if python3 sweeps/int_mode/bp/check_bp_trace.py "$dir" --json "$dir/check.json" > "$dir/check.log" 2>&1; then
        [[ "$expect" == pass ]] || { echo "$label: FAIL (negative control was not caught)"; return 1; }
        echo "$label: PASS $(tail -n 1 "$dir/check.log" | sed 's/^\[PASS\] //')"
    else
        grep -q '^\[FAIL\]' "$dir/check.log" || { echo "$label: FAIL (checker error, see $dir/check.log)"; return 1; }
        [[ "$expect" == fail:CHECK ]] || { echo "$label: FAIL $(tail -n 1 "$dir/check.log")"; return 1; }
        echo "$label: PASS (negative control caught by the checker: $(tail -n 1 "$dir/check.log" | sed 's/^\[FAIL\] //'))"
    fi
    # Near-limit operand files are ~10M lines; keep logs, trace and check.json.
    if (( L > 100000 )); then rm -f "$dir/bpt_a.hex" "$dir/bpt_w.hex"; fi
}

run_int() {
    local build="$OUT/csa_bp_int_build" simv status=0
    rm -rf "$INT_DIR"; mkdir -p "$INT_DIR" "$build/$TB"
    # The compile run executes the first case's operands in the build dir.
    python3 sweeps/int_mode/bp/gen_bp_workload.py --ba 8 --bw 8 --L 128 --mrows 1 --ncols 8 \
        --dist uniform --seed 1 --out-dir "$build/$TB" > /dev/null
    make sim TOP=Top TB="$TB" BUILD_DIR="$build" GL= TARGET= RTL_PREFLIGHT_CMD= \
        "VCS=$VCS_PP" > "$OUT/csa_bp_int_compile.log" 2>&1
    grep -q '^PASS: BP INT bench' "$OUT/csa_bp_int_compile.log"
    simv="$REPO/$build/$TB/simv"
    while read -r label ba bw L mrows ncols dist seed flags expect; do
        [[ -n "$label" ]] || continue
        int_case "$simv" "$label" "$ba" "$bw" "$L" "$mrows" "$ncols" "$dist" "$seed" "$flags" "$expect" &
        while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
    done <<< "$CASES"
    while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done
    local n_cases
    n_cases=$(grep -c . <<< "$CASES")
    echo "INT matrix: $n_cases cases, status $([[ $status == 0 ]] && echo PASS || echo FAIL)"
    return "$status"
}

status=0
pids=()
[[ " $PARTS " == *" sc "* ]] && { run_sc > "$OUT/csa_bp_sc_summary.log" 2>&1 & pids+=("$!"); }
[[ " $PARTS " == *" int "* ]] && { run_int > "$OUT/csa_bp_int.log" 2>&1 & pids+=("$!"); }
for pid in "${pids[@]}"; do wait "$pid" || status=1; done
if [[ " $PARTS " == *" sc "* ]]; then echo "== $OUT/csa_bp_sc_summary.log"; cat "$OUT/csa_bp_sc_summary.log"; fi
if [[ " $PARTS " == *" int "* ]]; then echo "== $OUT/csa_bp_int.log"; sort "$OUT/csa_bp_int.log"; fi
echo "csa_bp RTL checks: $([[ $status == 0 ]] && echo PASS || echo FAIL)"
exit "$status"
