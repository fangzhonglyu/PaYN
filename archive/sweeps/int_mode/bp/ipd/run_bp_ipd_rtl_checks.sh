#!/bin/bash
# RTL checks for the in-place-doubling BP variant (signed_segmented_csa_bp_ipd,
# schedule T3), the preflight for synthesizing TSMC22/PAYN_SC_CSA_BP_IPD.
# Modelled on sweeps/run_csa_bp_rtl_checks.sh (unchanged); everything lands in
# build/rtl_preflight/bp_ipd/.
#
# (a) sc: SC mode of the IPD top (INT inputs tied off, +define+PAYN_INT_PORTS),
#     K8/M16/N8, LOW_W=9, T=128: full-array cosim (run_array.sh) and the
#     384-batch streaming power bench (run_power_array.sh), each also with
#     PAYN_INT_RAW_JUNK (random raw planes, int_prec and ring_in every cycle,
#     int_mode = 0).  All four traces must equal, byte for byte, the accepted
#     CSA top's traces from the benches' unchanged path (re-run here, ref_csa*).
#     Default shape (9x9, K6) streaming with INT junk vs the CSA top, and the
#     IPD top with no parameters must elaborate (default-parameter probe).
# (b) int: designs/payn/tb/test_payn_array_bp_ipd.sv on the IPD top, real
#     ports, 1-edge laps (+LAP_LEN default 1): INT8, W4A8, INT4; uniform (with
#     forced extremes), all-min, all-max, min x max, max x min, -1 x min,
#     alternating, ReLU; L = 128 .. 4096 plus near-limit lengths (INT8 65,408;
#     W4A8 / INT4 1,048,448); multi-block, back-to-back output blocks; JUNK;
#     MODE_AT=3; both shift contracts (shift_in on the lap edge too, and
#     LAP_RING_ONLY: shift_in on drain edges only).  Negative controls, each
#     with the failure it must show (CHECK: checker mismatch, TIMING: the
#     bench's [TIMING-FAIL], CONTRACT: the top's [BP-CONTRACT]):
#       no lap (LAP_LEN=0, and NEG_NO_RING), double lap (LAP_LEN=2), the BP
#       8-edge lap (LAP_LEN=8), stray ring (NEG_RING_STRAY one edge ahead of
#       the first MAC; NEG_RING_STRAY_MID in the middle of a pass), the lap on
#       the last MAC (NEG_NO_BUBBLE: one edge shorter per pass), wrong int_prec,
#       live comparator magnitudes, int_mode one edge late.
#     Every drained tile and combiner word is checked against numpy int64 by
#     sweeps/int_mode/bp/check_bp_trace.py (unchanged); the bench writes the
#     scheduled block period and drain-start edges to bpt_sched.txt, and the
#     summary compares them with BW*NB + LAP_LEN*(BW-1) + 8.
# (c) xcheck: the generalized bench is the original bench at LAP_LEN=8.  The
#     original bench (test_payn_array_bp.sv, its default compile) and the IPD
#     bench compiled with +define+BPT_DUT_BP (BP top) at +LAP_LEN=8 run the
#     same cases; their traces must be byte-identical and both pass the
#     checker.  Cross-discrimination: the BP top with the IPD schedule
#     (LAP_LEN=1) must FAIL.
#
#   bash sweeps/int_mode/bp/ipd/run_bp_ipd_rtl_checks.sh             # sc int xcheck
#   PARTS="int" bash sweeps/int_mode/bp/ipd/run_bp_ipd_rtl_checks.sh
# Logs: build/rtl_preflight/bp_ipd/{sc,int,xcheck}/, summaries *_summary.log.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
cd "$REPO"
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export USE_DW=1 NTFY_CHNL=
PARTS=${PARTS:-"sc int xcheck"}
MAX_JOBS=${MAX_JOBS:-12}
OUT=${OUT:-build/rtl_preflight/bp_ipd}   # opt-in override; default unchanged
mkdir -p "$OUT"
SRC=designs/payn/variants/signed_segmented_csa_bp_ipd/payn_array_signed_segmented_csa_bp_ipd.sv
TOPNAME=payn_array_signed_segmented_csa_bp_ipd
CSA_SRC=designs/payn/variants/signed_segmented_csa/payn_array_signed_segmented_csa.sv
VCS_PP='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
SHAPE_DEF="+define+PAYN_ARRAY_EXTERNAL_RTL+define+PAYN_SEG_LOW_W=9+define+SC_K=8+define+SC_M=16+define+SC_NH=8+define+SC_NW=8+define+SC_OWIDTH=24+define+SC_T=128"
DEF="$SHAPE_DEF+define+PAYN_ARRAY_DUT=$TOPNAME+define+PAYN_INT_PORTS"
CSA_DEF="$SHAPE_DEF+define+PAYN_ARRAY_DUT=payn_array_signed_segmented_csa"
ARRAY_TRACE=designs/payn/tb/test_payn_array.sv/array_rtl.txt
STREAM_TRACE=designs/payn/power/power_payn_array.sv/array_streaming_rtl.txt

vcs_compile() {   # out_dir tb top extra_defines... ; writes out_dir/simv, out_dir/compile.log
    local b=$1 tb=$2 top=$3; shift 3
    rm -rf "$b"; mkdir -p "$b"
    vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp +incdir+designs \
        -assert svaext -timescale=1ns/1ps "$@" -o "$b/simv" -Mdir="$b/obj" \
        -y "$SYNOPSYS/dw/sim_ver" +libext+.v+ +incdir+"$SYNOPSYS/dw/sim_ver" \
        "$tb" -top "$top" > "$b/compile.log" 2>&1
}

#------------------------------------------------------------ (a) SC mode --
SC=$OUT/sc
sc_array() {   # name src defines
    BUILD_DIR="$SC/$1" SIM_SRCS=$2 VCS_ARGS="$3" \
        bash designs/payn/cosim/run_array.sh NTFY_CHNL= "VCS=$VCS_PP" > "$SC/$1.log" 2>&1
    grep -q '\[PASS\]' "$SC/$1.log"
    echo "$1: array cosim PASS"
}
sc_stream_n() {  # name src defines batches
    BUILD_DIR="$SC/$1" SIM_SRCS=$2 \
        bash designs/payn/cosim/run_power_array.sh NTFY_CHNL= "VCS=$VCS_PP" \
        VCS_ARGS="$3+define+SC_BATCHES=$4" > "$SC/$1.log" 2>&1
    grep -q '\[PASS\]' "$SC/$1.log"
    echo "$1: streaming cosim PASS ($4 batches)"
}
sc_stream() { sc_stream_n "$1" "$2" "$3" 384; }
default_params() {
    local b="$SC/ipd_default_params"
    mkdir -p "$b"
    cat > "$b/tb_ipd_default_params.sv" <<'EOF'
`timescale 1ns/1ps
// Probe: the IPD top at its own default parameters (PAYN_K=6, 9x9) elaborates and starts.
`include "payn/variants/signed_segmented_csa_bp_ipd/payn_array_signed_segmented_csa_bp_ipd.sv"
module TbIpdDefaultParams;
    payn_array_signed_segmented_csa_bp_ipd dut (
        .clk(1'b0), .reset(1'b1), .rng_en(1'b0), .load_a(1'b0), .load_w(1'b0),
        .load_a_sign(1'b0), .load_w_sign(1'b0), .mac_en(1'b0), .shift_in(1'b0),
        .a_binary_in('0), .a_signs_in('0), .w_binary_in('0), .w_signs_in('0),
        .acc_in_west('0), .acc_out_east(),
        .int_mode(1'b0), .int_prec(1'b0), .ring_in(1'b0), .a_raw_in('0), .w_raw_in('0),
        .int_out(), .int_out_valid());
    initial begin #1; $display("DEFAULT_PARAMS_OK N_H=%0d N_W=%0d K=%0d", dut.N_H, dut.N_W, dut.K); $finish; end
endmodule
EOF
    vcs_compile "$b/build" "$b/tb_ipd_default_params.sv" TbIpdDefaultParams
    (cd "$b/build" && ./simv > sim.log 2>&1)
    grep -q DEFAULT_PARAMS_OK "$b/build/sim.log"
    echo "default-parameter probe: $(grep -o 'DEFAULT_PARAMS_OK.*' "$b/build/sim.log")"
}
run_sc() {
    local pids=() status=0
    local dflt="+define+PAYN_ARRAY_EXTERNAL_RTL+define+PAYN_ARRAY_DUT"
    rm -rf "$SC"; mkdir -p "$SC"
    sc_array ipd_sc "$SRC" "$DEF" & pids+=("$!")
    sc_array ipd_sc_junk "$SRC" "$DEF+define+PAYN_INT_RAW_JUNK" & pids+=("$!")
    sc_array ref_csa "$CSA_SRC" "$CSA_DEF" & pids+=("$!")
    sc_stream ipd_sc_stream "$SRC" "$DEF" & pids+=("$!")
    sc_stream ipd_sc_stream_junk "$SRC" "$DEF+define+PAYN_INT_RAW_JUNK" & pids+=("$!")
    sc_stream ref_csa_stream "$CSA_SRC" "$CSA_DEF" & pids+=("$!")
    sc_stream_n ipd_sc_stream_default "$SRC" \
        "$dflt=$TOPNAME+define+PAYN_INT_PORTS+define+PAYN_INT_RAW_JUNK" 64 & pids+=("$!")
    sc_stream_n ref_csa_stream_default "$CSA_SRC" "$dflt=payn_array_signed_segmented_csa" 64 & pids+=("$!")
    default_params & pids+=("$!")
    for pid in "${pids[@]}"; do wait "$pid" || status=1; done
    (( status == 0 )) || return 1
    cmp "$SC/ipd_sc/$ARRAY_TRACE" "$SC/ipd_sc_junk/$ARRAY_TRACE"
    cmp "$SC/ipd_sc_stream/$STREAM_TRACE" "$SC/ipd_sc_stream_junk/$STREAM_TRACE"
    echo "SC junk on raw planes / int_prec / ring_in: traces identical to the tied-off runs"
    cmp "$SC/ipd_sc/$ARRAY_TRACE" "$SC/ref_csa/$ARRAY_TRACE"
    cmp "$SC/ipd_sc_stream/$STREAM_TRACE" "$SC/ref_csa_stream/$STREAM_TRACE"
    cmp "$SC/ipd_sc_junk/$ARRAY_TRACE" "$SC/ref_csa/$ARRAY_TRACE"
    cmp "$SC/ipd_sc_stream_junk/$STREAM_TRACE" "$SC/ref_csa_stream/$STREAM_TRACE"
    echo "IPD top in SC mode (tied-off and junk): array and streaming traces byte-identical to the CSA top"
    cmp "$SC/ipd_sc_stream_default/$STREAM_TRACE" "$SC/ref_csa_stream_default/$STREAM_TRACE"
    echo "IPD top at the default 9x9/K6 shape, INT junk on: streaming trace identical to the CSA top"
    echo "trace sizes: array $(wc -l < "$SC/ipd_sc/$ARRAY_TRACE") lines, streaming $(wc -l < "$SC/ipd_sc_stream/$STREAM_TRACE") lines"
}

#------------------------------------------------------------ (b) INT mode --
TB=designs/payn/tb/test_payn_array_bp_ipd.sv
TB_ORIG=designs/payn/tb/test_payn_array_bp.sv
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
int8_uniform_L256_m1n8_lapring   8 8     256 1  8 uniform    33 LAP_RING_ONLY    pass
int8_uniform_L1024_m2n16_lapring 8 8    1024 2 16 uniform     3 LAP_RING_ONLY    pass
int8_uniform_L4096_m1n8_lapring  8 8    4096 1  8 uniform     4 LAP_RING_ONLY    pass
int8_alternating_L1024_m2n8_lapring 8 8 1024 2  8 alternating 0 LAP_RING_ONLY    pass
int8_uniform_L256_m2n16_junk_lapring 8 8 256 2 16 uniform     6 JUNK,LAP_RING_ONLY pass
int8_uniform_L256_m2n8_modeat3_lapring 8 8 256 2 8 uniform    7 MODE_AT=3,LAP_RING_ONLY pass
int8_neg1xmin_L65408_m1n8_lapring 8 8  65408 1  8 neg1xmin    0 LAP_RING_ONLY    pass
w4a8_uniform_L1024_m2n16_lapring 8 4    1024 2 16 uniform    12 LAP_RING_ONLY    pass
w4a8_uniform_L256_m3n8_junk_lapring 8 4  256 3  8 uniform    13 JUNK,LAP_RING_ONLY pass
int4_uniform_L1024_m4n16_lapring 4 4    1024 4 16 uniform    22 LAP_RING_ONLY    pass
int4_uniform_L256_m2n16_junk_lapring 4 4 256 2 16 uniform    23 JUNK,LAP_RING_ONLY pass
int4_allmin_L1048448_m2n8_lapring 4 4 1048448 2 8 allmin      0 LAP_RING_ONLY    pass
neg_int8_lap0_L256_m1n8          8 8     256 1  8 uniform    41 LAP_LEN=0        fail:CHECK
neg_int8_lap0_L256_m1n8_lapring  8 8     256 1  8 uniform    41 LAP_LEN=0,LAP_RING_ONLY fail:CHECK
neg_int8_noring_L256_m1n8        8 8     256 1  8 uniform    31 NEG_NO_RING      fail:TIMING
neg_int8_noring_L256_m1n8_lapring 8 8    256 1  8 uniform    38 NEG_NO_RING,LAP_RING_ONLY fail:CHECK
neg_int8_lap2_L256_m1n8          8 8     256 1  8 uniform    42 LAP_LEN=2        fail:CHECK
neg_int8_lap2_L256_m1n8_lapring  8 8     256 1  8 uniform    42 LAP_LEN=2,LAP_RING_ONLY fail:CHECK
neg_w4a8_lap2_L256_m1n8_lapring  8 4     256 1  8 uniform    43 LAP_LEN=2,LAP_RING_ONLY fail:CHECK
neg_int4_lap2_L256_m2n8_lapring  4 4     256 2  8 uniform    44 LAP_LEN=2,LAP_RING_ONLY fail:CHECK
neg_int8_lap8_L256_m1n8_lapring  8 8     256 1  8 uniform    45 LAP_LEN=8,LAP_RING_ONLY fail:CHECK
neg_int8_ringstray_L256_m1n8     8 8     256 1  8 uniform    36 NEG_RING_STRAY   fail:CHECK
neg_int8_ringstray_L256_m1n8_lapring 8 8 256 1  8 uniform    37 NEG_RING_STRAY,LAP_RING_ONLY fail:CHECK
neg_int8_ringstraymid_L1024_m1n8_lapring 8 8 1024 1 8 uniform 46 NEG_RING_STRAY_MID,LAP_RING_ONLY fail:CHECK
neg_int4_ringstraymid_L1024_m2n8_lapring 4 4 1024 2 8 uniform 47 NEG_RING_STRAY_MID,LAP_RING_ONLY fail:CHECK
neg_int8_nobubble_L256_m1n8_lapring 8 8  256 1  8 uniform    48 NEG_NO_BUBBLE,LAP_RING_ONLY fail:CHECK
neg_int8_nobubble_L1024_m2n8     8 8    1024 2  8 uniform    49 NEG_NO_BUBBLE    fail:CHECK
neg_w4a8_nobubble_L256_m1n8_lapring 8 4  256 1  8 uniform    50 NEG_NO_BUBBLE,LAP_RING_ONLY fail:CHECK
neg_int4_prec_L256_m2n8          4 4     256 2  8 uniform    32 NEG_PREC         fail:CHECK
neg_int8_mag_L256_m1n8           8 8     256 1  8 uniform    34 NEG_MAG          fail:CONTRACT
neg_int8_modeat4_L256_m1n8       8 8     256 1  8 uniform    35 MODE_AT=4        fail:CHECK
EOF
)

int_case() {   # simv dir label BA BW L MROWS NCOLS DIST SEED FLAGS EXPECT
    local simv=$1 base=$2 label=$3 ba=$4 bw=$5 L=$6 mrows=$7 ncols=$8 dist=$9 seed=${10} flags=${11} expect=${12}
    local dir="$base/$label" plus=() fl x rc=0 bench_pass=0 tag
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
    if (( L > 100000 )); then rm -f "$dir/bpt_a.hex" "$dir/bpt_w.hex"; fi
}

# Block-period table from bpt_sched.txt of the passing cases.
period_table() {   # dir
    python3 - "$1" <<'PY'
import json, re, sys
from pathlib import Path
rows = []
for d in sorted(Path(sys.argv[1]).iterdir()):
    s, c = d / "bpt_sched.txt", d / "check.json"
    if not (s.is_file() and c.is_file()):
        continue
    if json.loads(c.read_text())["status"] != "PASS":
        continue
    lines = s.read_text().split("\n")
    kv = dict(re.findall(r"(\w+)=(-?\d+)", lines[0]))
    starts = [int(l.split()[2]) for l in lines[1:] if l.startswith("DRAIN_START")]
    spacing = sorted({b - a for a, b in zip(starts, starts[1:])})
    nb, bw, lap = int(kv["nb"]), int(kv["bw"]), int(kv["lap_len"])
    ring = bw * nb + 8 * (bw - 1) + 8
    ok = int(kv["blk_len"]) == int(kv["formula"]) and (not spacing or spacing == [int(kv["blk_len"])])
    rows.append((d.name, lap, kv["blk_len"], kv["formula"], spacing or "-", ring,
                 f"{bw*nb/int(kv['blk_len']):.1%}", f"{bw*nb/ring:.1%}", "OK" if ok else "MISMATCH"))
print("single-PE block periods (passing cases): case lap_len block_len formula(BW*NB+LAP_LEN*(BW-1)+8) "
      "measured_drain_spacing bp_ring_formula util_ipd util_bp_ring")
bad = 0
for r in rows:
    print("  " + " ".join(str(x) for x in r))
    bad += r[-1] != "OK"
print(f"period rows: {len(rows)}, mismatches: {bad}")
sys.exit(1 if bad else 0)
PY
}

run_case_list() {   # simv dir cases
    local simv=$1 dir=$2 cases=$3 status=0
    while read -r label ba bw L mrows ncols dist seed flags expect; do
        [[ -n "$label" ]] || continue
        int_case "$simv" "$dir" "$label" "$ba" "$bw" "$L" "$mrows" "$ncols" "$dist" "$seed" "$flags" "$expect" &
        while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
    done <<< "$cases"
    while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done
    return "$status"
}

run_int() {
    local b="$OUT/int_build" status=0
    rm -rf "$OUT/int"; mkdir -p "$OUT/int"
    vcs_compile "$b" "$TB" Top || { echo "IPD INT bench compile FAILED ($b/compile.log)"; return 1; }
    grep -q "signed_segmented_csa_bp_ipd/inner_pe_core_signed_segmented_csa_ipd.sv" "$b/compile.log" \
        || { echo "compile did not read the IPD core"; return 1; }
    run_case_list "$REPO/$b/simv" "$OUT/int" "$CASES" || status=1
    echo "IPD INT matrix: $(grep -c . <<< "$CASES") cases, status $([[ $status == 0 ]] && echo PASS || echo FAIL)"
    # Lap coverage over the passing (bit-exact) cases: lap edges that folded a
    # pending carry / borrow into the doubled value.
    python3 - "$OUT/int" <<'PY' || status=1
import json, re, sys
from pathlib import Path
tot = dict(cases=0, lap_edges=0, tile_laps=0, with_pending_carry=0, with_pending_borrow=0)
for d in sorted(Path(sys.argv[1]).iterdir()):
    c = d / "check.json"
    if not c.is_file() or json.loads(c.read_text())["status"] != "PASS":
        continue
    m = re.search(r"LAP_COVERAGE (.*)", (d / "sim.log").read_text())
    if not m:
        continue
    tot["cases"] += 1
    for k, v in re.findall(r"(\w+)=(\d+)", m[1]):
        tot[k] += int(v)
print("  lap coverage (bit-exact cases): " + ", ".join(f"{k} {v}" for k, v in tot.items()))
sys.exit(0 if tot["with_pending_carry"] > 0 and tot["with_pending_borrow"] > 0 else 1)
PY
    period_table "$OUT/int" || status=1
    return "$status"
}

#------------------------------------------- (c) bench cross-check (BP top) --
# Same label/columns; FLAGS are the ORIGINAL bench's flags (the generalized
# bench adds +LAP_LEN=8).
XCASES=$(cat <<'EOF'
int8_uniform_L384_m2n16          8 8     384 2 16 uniform     2 -                pass
int8_uniform_L4096_m1n8          8 8    4096 1  8 uniform     4 -                pass
int8_uniform_L1024_m2n16         8 8    1024 2 16 uniform     3 -                pass
int8_alternating_L1024_m2n8      8 8    1024 2  8 alternating 0 -                pass
int8_uniform_L256_m2n16_junk     8 8     256 2 16 uniform     6 JUNK             pass
int8_uniform_L256_m2n8_modeat3   8 8     256 2  8 uniform     7 MODE_AT=3        pass
int8_neg1xmin_L65408_m1n8_lapring 8 8  65408 1  8 neg1xmin    0 LAP_RING_ONLY    pass
w4a8_uniform_L1024_m2n16         8 4    1024 2 16 uniform    12 -                pass
w4a8_uniform_L256_m3n8_junk_lapring 8 4  256 3  8 uniform    13 JUNK,LAP_RING_ONLY pass
int4_uniform_L1024_m4n16_lapring 4 4    1024 4 16 uniform    22 LAP_RING_ONLY    pass
int4_uniform_L256_m2n16_junk     4 4     256 2 16 uniform    23 JUNK             pass
neg_int4_prec_L256_m2n8          4 4     256 2  8 uniform    32 NEG_PREC         fail:CHECK
neg_int8_ringstray_L256_m1n8_lapring 8 8 256 1  8 uniform    37 NEG_RING_STRAY,LAP_RING_ONLY fail:CHECK
EOF
)
XNEG=$(cat <<'EOF'
bp_with_ipd_schedule_int8_L256_m1n8_lapring 8 8 256 1 8 uniform 33 LAP_LEN=1,LAP_RING_ONLY fail:CHECK
bp_with_ipd_schedule_int4_L256_m2n8        4 4 256 2 8 uniform 23 LAP_LEN=1             fail:CHECK
EOF
)
run_xcheck() {
    local X="$OUT/xcheck" status=0 gen orig n=0
    rm -rf "$X"; mkdir -p "$X"
    vcs_compile "$X/build_orig" "$TB_ORIG" Top || { echo "original bench compile FAILED"; return 1; }
    vcs_compile "$X/build_gen" "$TB" Top +define+BPT_DUT_BP || { echo "generalized bench (BP top) compile FAILED"; return 1; }
    grep -q "signed_segmented_csa_bp/payn_array_signed_segmented_csa_bp.sv" "$X/build_gen/compile.log" \
        || { echo "generalized bench did not read the BP top"; return 1; }
    gen=$(sed -E 's/^(\S+(\s+\S+){7}\s+)-(\s+)/\1LAP_LEN=8\3/; t; s/^(\S+(\s+\S+){7}\s+)(\S+)/\1\3,LAP_LEN=8/' <<< "$XCASES")
    run_case_list "$REPO/$X/build_orig/simv" "$X/orig" "$XCASES" || status=1
    run_case_list "$REPO/$X/build_gen/simv" "$X/gen_lap8" "$gen" || status=1
    while read -r label rest; do
        [[ -n "$label" ]] || continue
        if cmp -s "$X/orig/$label/bpt_trace.txt" "$X/gen_lap8/$label/bpt_trace.txt"; then
            n=$((n + 1))
        else
            echo "$label: FAIL (generalized bench at LAP_LEN=8 differs from the original bench)"; status=1
        fi
    done <<< "$XCASES"
    echo "bench cross-check on the BP top: $n/$(grep -c . <<< "$XCASES") traces byte-identical (original bench vs IPD bench +LAP_LEN=8)"
    run_case_list "$REPO/$X/build_gen/simv" "$X/bp_neg" "$XNEG" || status=1
    echo "bench cross-check: status $([[ $status == 0 ]] && echo PASS || echo FAIL)"
    return "$status"
}

status=0
pids=()
[[ " $PARTS " == *" sc "* ]] && { run_sc > "$OUT/sc_summary.log" 2>&1 & pids+=("$!"); }
[[ " $PARTS " == *" int "* ]] && { run_int > "$OUT/int_summary.log" 2>&1 & pids+=("$!"); }
[[ " $PARTS " == *" xcheck "* ]] && { run_xcheck > "$OUT/xcheck_summary.log" 2>&1 & pids+=("$!"); }
for pid in "${pids[@]}"; do wait "$pid" || status=1; done
for p in sc int xcheck; do
    [[ " $PARTS " == *" $p "* ]] || continue
    echo "== $OUT/${p}_summary.log"
    if [[ $p == sc ]]; then cat "$OUT/${p}_summary.log"; else
        grep -v '^  \|^single-PE block\|^period rows' "$OUT/${p}_summary.log" | sort
        grep '^single-PE block\|^  \|^period rows' "$OUT/${p}_summary.log" || true
    fi
done
echo "bp_ipd RTL checks: $([[ $status == 0 ]] && echo PASS || echo FAIL)"
exit "$status"
