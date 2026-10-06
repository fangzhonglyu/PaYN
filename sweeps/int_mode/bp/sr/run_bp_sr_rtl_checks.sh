#!/bin/bash
# RTL checks for the sub-ring BP variant (signed_segmented_csa_bp_sr): laps of
# LAP_G edges, the knob between the BP ring (LAP_G = 8, csa_bp_20261004_lap)
# and in-place doubling (LAP_G = 1, csa_bp_ipd_20261004).  The preflight for
# synthesizing TSMC22/PAYN_SC_CSA_BP_SR2 and _SR4.  Modelled on
# sweeps/int_mode/bp/ipd/run_bp_ipd_rtl_checks.sh; everything lands in
# build/rtl_preflight/bp_sr/ (OUT overrides).
#
# (a) sc: for every LAP_G in $LAP_GS: SC mode of the SR top (INT inputs tied
#     off, +define+PAYN_INT_PORTS), K8/M16/N8, LOW_W=9, T=128: full-array cosim
#     (run_array.sh) and the 384-batch streaming bench (run_power_array.sh),
#     each also with PAYN_INT_RAW_JUNK (random raw planes, int_prec and ring_in
#     every cycle, int_mode = 0).  All traces must equal the accepted CSA top's,
#     run fresh here (ref_csa*), byte for byte.  The default 9x9/K6 shape with
#     INT junk must equal the CSA top too (LAP_G does not divide 9 there: the
#     last sub-ring is shorter, irrelevant with ring_in gated off).
# (b) int: designs/payn/tb/test_payn_array_bp_ipd.sv compiled with
#     +define+BPT_DUT_SR+define+PAYN_LAP_G=<g> (real ports), run at
#     +LAP_LEN=<g>: the positive cases of the IPD matrix (INT8/W4A8/INT4,
#     extremes, near-limit lengths, multi-block, JUNK, MODE_AT=3, both shift
#     contracts).  Negative controls (CHECK: checker mismatch, TIMING: the
#     bench's [TIMING-FAIL], CONTRACT: the top's [BP-CONTRACT]): no lap
#     (LAP_LEN=0, NEG_NO_RING), short lap (LAP_LEN=g-1), long lap (g+1), double
#     lap (2g), the IPD schedule (LAP_LEN=1) and the BP schedule (LAP_LEN=8),
#     stray ring (one edge ahead of the first MAC, and mid-pass), lap on the
#     last MAC (NEG_NO_BUBBLE), wrong int_prec, live magnitudes, int_mode late.
#     Every drained tile and combiner word is checked against numpy int64 by
#     sweeps/int_mode/bp/check_bp_trace.py (unchanged); every passing case's
#     scheduled period must equal BW*NB + LAP_G*(BW-1) + 8.
# (c) xcheck: the parametric core collapses to both known designs.  The SR top
#     at LAP_G=1 (+LAP_LEN=1) must reproduce the IPD top's traces byte for byte,
#     and at LAP_G=8 (+LAP_LEN=8) the BP top's (the bench compiled with
#     +define+BPT_DUT_BP), on the same cases.
#
#   bash sweeps/int_mode/bp/sr/run_bp_sr_rtl_checks.sh                 # sc int xcheck, LAP_GS="2 4"
#   PARTS="int" LAP_GS="2" bash sweeps/int_mode/bp/sr/run_bp_sr_rtl_checks.sh
# Logs: build/rtl_preflight/bp_sr/{sc,int_g<g>,xcheck}/, summaries *_summary.log.
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
LAP_GS=${LAP_GS:-"2 4"}
MAX_JOBS=${MAX_JOBS:-16}
OUT=${OUT:-build/rtl_preflight/bp_sr}
mkdir -p "$OUT"
SRC=designs/payn/variants/signed_segmented_csa_bp_sr/payn_array_signed_segmented_csa_bp_sr.sv
TOPNAME=payn_array_signed_segmented_csa_bp_sr
CSA_SRC=designs/payn/variants/signed_segmented_csa/payn_array_signed_segmented_csa.sv
VCS_PP='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
SHAPE_DEF="+define+PAYN_ARRAY_EXTERNAL_RTL+define+PAYN_SEG_LOW_W=9+define+SC_K=8+define+SC_M=16+define+SC_NH=8+define+SC_NW=8+define+SC_OWIDTH=24+define+SC_T=128"
CSA_DEF="$SHAPE_DEF+define+PAYN_ARRAY_DUT=payn_array_signed_segmented_csa"
ARRAY_TRACE=designs/payn/tb/test_payn_array.sv/array_rtl.txt
STREAM_TRACE=designs/payn/power/power_payn_array.sv/array_streaming_rtl.txt
TB=designs/payn/tb/test_payn_array_bp_ipd.sv

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
run_sc() {
    local pids=() status=0 g def dflt="+define+PAYN_ARRAY_EXTERNAL_RTL+define+PAYN_ARRAY_DUT"
    rm -rf "$SC"; mkdir -p "$SC"
    sc_array ref_csa "$CSA_SRC" "$CSA_DEF" & pids+=("$!")
    sc_stream_n ref_csa_stream "$CSA_SRC" "$CSA_DEF" 384 & pids+=("$!")
    sc_stream_n ref_csa_stream_default "$CSA_SRC" "$dflt=payn_array_signed_segmented_csa" 64 & pids+=("$!")
    for g in $LAP_GS; do
        def="$SHAPE_DEF+define+PAYN_ARRAY_DUT=$TOPNAME+define+PAYN_INT_PORTS+define+PAYN_LAP_G=$g"
        sc_array "sr${g}_sc" "$SRC" "$def" & pids+=("$!")
        sc_array "sr${g}_sc_junk" "$SRC" "$def+define+PAYN_INT_RAW_JUNK" & pids+=("$!")
        sc_stream_n "sr${g}_sc_stream" "$SRC" "$def" 384 & pids+=("$!")
        sc_stream_n "sr${g}_sc_stream_junk" "$SRC" "$def+define+PAYN_INT_RAW_JUNK" 384 & pids+=("$!")
        sc_stream_n "sr${g}_sc_stream_default" "$SRC" \
            "$dflt=$TOPNAME+define+PAYN_INT_PORTS+define+PAYN_INT_RAW_JUNK+define+PAYN_LAP_G=$g" 64 & pids+=("$!")
    done
    for pid in "${pids[@]}"; do wait "$pid" || status=1; done
    (( status == 0 )) || return 1
    for g in $LAP_GS; do
        grep -q "signed_segmented_csa_bp_sr/inner_pe_core_signed_segmented_csa_sr.sv" "$SC/sr${g}_sc.log" \
            || grep -rq "inner_pe_core_signed_segmented_csa_sr" "$SC/sr${g}_sc" || { echo "sr$g did not read the SR core"; return 1; }
        cmp "$SC/sr${g}_sc/$ARRAY_TRACE" "$SC/ref_csa/$ARRAY_TRACE"
        cmp "$SC/sr${g}_sc_junk/$ARRAY_TRACE" "$SC/ref_csa/$ARRAY_TRACE"
        cmp "$SC/sr${g}_sc_stream/$STREAM_TRACE" "$SC/ref_csa_stream/$STREAM_TRACE"
        cmp "$SC/sr${g}_sc_stream_junk/$STREAM_TRACE" "$SC/ref_csa_stream/$STREAM_TRACE"
        cmp "$SC/sr${g}_sc_stream_default/$STREAM_TRACE" "$SC/ref_csa_stream_default/$STREAM_TRACE"
        echo "LAP_G=$g: SR top in SC mode (tied-off and INT junk): array and 384-batch streaming traces byte-identical to the CSA top; default 9x9/K6 shape with INT junk identical too"
    done
    if [[ -f build/rtl_preflight/bp_ipd/sc/ref_csa_stream/$STREAM_TRACE ]]; then
        cmp "$SC/ref_csa_stream/$STREAM_TRACE" "build/rtl_preflight/bp_ipd/sc/ref_csa_stream/$STREAM_TRACE"
        echo "fresh CSA streaming reference == the IPD task's ref_csa_stream"
    fi
    echo "trace sizes: array $(wc -l < "$SC/ref_csa/$ARRAY_TRACE") lines, streaming $(wc -l < "$SC/ref_csa_stream/$STREAM_TRACE") lines"
}

#------------------------------------------------------------ (b) INT mode --
# label BA BW L MROWS NCOLS DIST SEED FLAGS EXPECT  (FLAGS: comma-separated
# plusargs; the runner appends LAP_LEN=<g> unless the case sets LAP_LEN itself)
POS_CASES=$(cat <<'EOF'
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
neg_int8_noring_L256_m1n8        8 8     256 1  8 uniform    31 NEG_NO_RING      fail:TIMING
neg_int8_noring_L256_m1n8_lapring 8 8    256 1  8 uniform    38 NEG_NO_RING,LAP_RING_ONLY fail:CHECK
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

# Lap-length negatives for LAP_G = g: every LAP_LEN != g must fail.
lap_negatives() {   # g
    local g=$1 n
    local -a lens=(0 $((g - 1)) $((g + 1)) $((2 * g)) 1 8)
    for n in $(printf '%s\n' "${lens[@]}" | sort -nu); do
        (( n == g || n < 0 )) && continue
        echo "neg_int8_lap${n}_L256_m1n8_lapring 8 8 256 1 8 uniform $((60 + n)) LAP_LEN=$n,LAP_RING_ONLY fail:CHECK"
        echo "neg_int8_lap${n}_L256_m1n8 8 8 256 1 8 uniform $((70 + n)) LAP_LEN=$n fail:CHECK"
        echo "neg_int4_lap${n}_L256_m2n8_lapring 4 4 256 2 8 uniform $((80 + n)) LAP_LEN=$n,LAP_RING_ONLY fail:CHECK"
    done
}

with_lap() {   # g cases -> cases with LAP_LEN=g appended (unless set)
    local g=$1
    awk -v g="$g" 'NF { if ($9 ~ /LAP_LEN=/) {print; next}
                        $9 = ($9 == "-") ? "LAP_LEN=" g : $9 ",LAP_LEN=" g; print }' <<< "$2"
}

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

# Period table + lap coverage over the passing cases of one run directory.
period_table() {   # dir g
    python3 - "$1" "$2" <<'PY'
import json, re, sys
from pathlib import Path
g = int(sys.argv[2])
rows, bad = [], 0
cov = dict(cases=0, lap_edges=0, tile_laps=0, with_pending_carry=0, with_pending_borrow=0)
for d in sorted(Path(sys.argv[1]).iterdir()):
    s, c = d / "bpt_sched.txt", d / "check.json"
    if not (s.is_file() and c.is_file()) or json.loads(c.read_text())["status"] != "PASS":
        continue
    lines = s.read_text().split("\n")
    kv = dict(re.findall(r"(\w+)=(-?\d+)", lines[0]))
    starts = [int(l.split()[2]) for l in lines[1:] if l.startswith("DRAIN_START")]
    spacing = sorted({b - a for a, b in zip(starts, starts[1:])})
    nb, bw, lap, blk = int(kv["nb"]), int(kv["bw"]), int(kv["lap_len"]), int(kv["blk_len"])
    formula = bw * nb + g * (bw - 1) + 8
    ok = lap == g and blk == int(kv["formula"]) == formula and (not spacing or spacing == [blk])
    ring, ipd = bw * nb + 8 * (bw - 1) + 8, bw * nb + (bw - 1) + 8
    rows.append((d.name, lap, blk, formula, spacing or "-", f"{bw*nb/blk:.1%}", f"{bw*nb/ring:.1%}",
                 f"{bw*nb/ipd:.1%}", "OK" if ok else "MISMATCH"))
    bad += not ok
    m = re.search(r"LAP_COVERAGE (.*)", (d / "sim.log").read_text())
    if m:
        cov["cases"] += 1
        for k, v in re.findall(r"(\w+)=(\d+)", m[1]):
            cov[k] += int(v)
print(f"single-PE block periods, LAP_G={g} (passing cases): case lap_len block_len "
      f"formula(BW*NB+{g}*(BW-1)+8) measured_drain_spacing util_sr util_bp_ring util_ipd")
for r in rows:
    print("  " + " ".join(str(x) for x in r))
print(f"period rows: {len(rows)}, mismatches: {bad}")
print("  lap coverage (bit-exact cases; ring_q edges with a pending carry / borrow in a tile): "
      + ", ".join(f"{k} {v}" for k, v in cov.items()))
sys.exit(1 if bad or not rows or cov["with_pending_carry"] == 0 or cov["with_pending_borrow"] == 0 else 0)
PY
}

run_int_g() {   # g
    local g=$1 b="$OUT/int_build_g$1" d="$OUT/int_g$1" status=0 cases
    rm -rf "$d"; mkdir -p "$d"
    vcs_compile "$b" "$TB" Top +define+BPT_DUT_SR+define+PAYN_LAP_G=$g \
        || { echo "SR INT bench compile FAILED ($b/compile.log)"; return 1; }
    grep -q "signed_segmented_csa_bp_sr/inner_pe_core_signed_segmented_csa_sr.sv" "$b/compile.log" \
        || { echo "compile did not read the SR core"; return 1; }
    cases=$(with_lap "$g" "$POS_CASES"; lap_negatives "$g")
    run_case_list "$REPO/$b/simv" "$d" "$cases" || status=1
    echo "SR LAP_G=$g INT matrix: $(grep -c . <<< "$cases") cases, status $([[ $status == 0 ]] && echo PASS || echo FAIL)"
    period_table "$d" "$g" || status=1
    return "$status"
}

run_int() {
    local pids=() status=0 g
    for g in $LAP_GS; do run_int_g "$g" > "$OUT/int_g${g}_summary.log" 2>&1 & pids+=("$!"); done
    for pid in "${pids[@]}"; do wait "$pid" || status=1; done
    for g in $LAP_GS; do echo "LAP_G=$g: $(grep -c ': PASS' "$OUT/int_g${g}_summary.log") case lines PASS, $(grep -c ': FAIL' "$OUT/int_g${g}_summary.log") FAIL ($OUT/int_g${g}_summary.log)"; done
    return "$status"
}

#--------------------------------- (c) collapse cross-check (LAP_G = 1, 8) --
XCASES=$(cat <<'EOF'
int8_uniform_L384_m2n16          8 8     384 2 16 uniform     2 -                pass
int8_uniform_L4096_m1n8          8 8    4096 1  8 uniform     4 -                pass
int8_allmin_L1024_m1n8           8 8    1024 1  8 allmin      0 -                pass
int8_alternating_L1024_m2n8      8 8    1024 2  8 alternating 0 -                pass
int8_uniform_L256_m2n16_junk     8 8     256 2 16 uniform     6 JUNK             pass
int8_uniform_L256_m2n8_modeat3   8 8     256 2  8 uniform     7 MODE_AT=3        pass
int8_neg1xmin_L65408_m1n8_lapring 8 8  65408 1  8 neg1xmin    0 LAP_RING_ONLY    pass
w4a8_uniform_L1024_m2n16         8 4    1024 2 16 uniform    12 -                pass
w4a8_uniform_L256_m3n8_junk_lapring 8 4  256 3  8 uniform    13 JUNK,LAP_RING_ONLY pass
int4_uniform_L1024_m4n16_lapring 4 4    1024 4 16 uniform    22 LAP_RING_ONLY    pass
int4_uniform_L256_m2n16_junk     4 4     256 2 16 uniform    23 JUNK             pass
neg_int8_ringstray_L256_m1n8_lapring 8 8 256 1  8 uniform    37 NEG_RING_STRAY,LAP_RING_ONLY fail:CHECK
neg_int8_nobubble_L256_m1n8_lapring 8 8  256 1  8 uniform    48 NEG_NO_BUBBLE,LAP_RING_ONLY fail:CHECK
neg_int8_lap2_L256_m1n8_lapring  8 8     256 1  8 uniform    62 LAP_LEN=2,LAP_RING_ONLY fail:CHECK
EOF
)
run_xcheck() {
    local X="$OUT/xcheck" status=0 n g ref_def ref_name lab
    rm -rf "$X"; mkdir -p "$X"
    vcs_compile "$X/build_sr1" "$TB" Top +define+BPT_DUT_SR+define+PAYN_LAP_G=1 || { echo "SR1 compile FAILED"; return 1; }
    vcs_compile "$X/build_sr8" "$TB" Top +define+BPT_DUT_SR+define+PAYN_LAP_G=8 || { echo "SR8 compile FAILED"; return 1; }
    vcs_compile "$X/build_ipd" "$TB" Top || { echo "IPD compile FAILED"; return 1; }
    vcs_compile "$X/build_bp" "$TB" Top +define+BPT_DUT_BP || { echo "BP compile FAILED"; return 1; }
    grep -q "signed_segmented_csa_bp_ipd/inner_pe_core_signed_segmented_csa_ipd.sv" "$X/build_ipd/compile.log" || { echo "IPD build did not read the IPD core"; return 1; }
    grep -q "signed_segmented_csa_bp/payn_array_signed_segmented_csa_bp.sv" "$X/build_bp/compile.log" || { echo "BP build did not read the BP top"; return 1; }
    for g in 1 8; do
        local cases
        cases=$(with_lap "$g" "$XCASES")
        [[ $g == 1 ]] && ref_name=ipd || ref_name=bp
        run_case_list "$REPO/$X/build_sr$g/simv" "$X/sr$g" "$cases" || status=1
        run_case_list "$REPO/$X/build_$ref_name/simv" "$X/$ref_name" "$cases" || status=1
        n=0
        while read -r lab rest; do
            [[ -n "$lab" ]] || continue
            if cmp -s "$X/sr$g/$lab/bpt_trace.txt" "$X/$ref_name/$lab/bpt_trace.txt"; then n=$((n + 1)); else
                echo "$lab: FAIL (SR LAP_G=$g trace differs from the ${ref_name^^} top)"; status=1; fi
        done <<< "$cases"
        echo "collapse cross-check: SR top at LAP_G=$g vs the ${ref_name^^} top (+LAP_LEN=$g): $n/$(grep -c . <<< "$cases") traces byte-identical"
    done
    echo "collapse cross-check: status $([[ $status == 0 ]] && echo PASS || echo FAIL)"
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
    if [[ $p == xcheck ]]; then grep -v ': PASS' "$OUT/${p}_summary.log" || true; else cat "$OUT/${p}_summary.log"; fi
done
if [[ " $PARTS " == *" int "* ]]; then
    for g in $LAP_GS; do
        echo "== $OUT/int_g${g}_summary.log (non-PASS lines and the period table)"
        grep -v ': PASS' "$OUT/int_g${g}_summary.log" || true
    done
fi
echo "bp_sr RTL checks: $([[ $status == 0 ]] && echo PASS || echo FAIL)"
exit "$status"
