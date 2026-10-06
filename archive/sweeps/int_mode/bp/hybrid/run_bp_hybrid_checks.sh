#!/bin/bash
# Adversarial schedule review of the BP "execute through the reduction, then
# shift" study (T1 as built vs T2 BP-space): RTL runs on the UNCHANGED BP RTL
# (csa_bp_20261004_lap; no tile, PE or grid-wrapper change).
#
#  1. BP-hybrid (designs/payn/tb/test_pe_grid_bp_hybrid.sv): TA activation bits
#     and TW weight bits in TIME per tile, the rest in space.  TA > 1 puts
#     8/GA = TA activation rows on one PE (GA = BA/TA groups per row), so a
#     block holds TA x more outputs per drain + skew, at the cost of
#     TA+TW-2 laps instead of BW-1.  TA=1,TW=BW is T1; TA=TW=1 is T2 S=BW.
#     Checker: sweeps/int_mode/bp/hybrid/check_bp_hybrid_trace.py.
#  2. Extra T2 cases with fresh seeds / shapes not in the proof matrix (2x3,
#     3x2) on the proof's own bench test_pe_grid_bp_space.sv and checker,
#     compiled into this OUT (the proof's builds and results are not touched).
#
#   bash sweeps/int_mode/bp/hybrid/run_bp_hybrid_checks.sh      MAX_JOBS=<n>
# Logs: build/rtl_preflight/bp_hybrid/{summary.log,hyb/<case>,t2x/<case>,compile_*.log}
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
OUT=$(realpath -m "${OUT:-build/rtl_preflight/bp_hybrid}")
MAX_JOBS=${MAX_JOBS:-12}
TB_H=designs/payn/tb/test_pe_grid_bp_hybrid.sv
TB_S=designs/payn/tb/test_pe_grid_bp_space.sv
GEN=sweeps/int_mode/bp/space/gen_bp_space_workload.py
CHECK_H=sweeps/int_mode/bp/hybrid/check_bp_hybrid_trace.py
CHECK_S=sweeps/int_mode/bp/space/check_bp_space_trace.py
mkdir -p "$OUT/hyb" "$OUT/t2x"

vcs_build() {   # tag tb defines
    local tag=$1 tb=$2 def=$3 b="$OUT/build_$1"
    rm -rf "$b"; mkdir -p "$b"
    vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp \
        +incdir+designs -assert svaext -timescale=1ns/1ps $def \
        -o "$b/simv" -Mdir="$b/obj" \
        -y "$SYNOPSYS/dw/sim_ver" +libext+.v+ +incdir+"$SYNOPSYS/dw/sim_ver" \
        "$tb" -top Top > "$OUT/compile_$tag.log" 2>&1 \
        || { echo "compile $tag FAILED: $OUT/compile_$tag.log"; return 1; }
}

# label SHAPE BA BW TA TW L MROWS NCOLS DIST SEED FLAGS EXPECT
HCASES=$(cat <<'EOF'
h1x1_int8_ta4tw8_uniform_L4096_m8n16        1x1 8 8 4 8 4096  8 16 uniform     511 -                 pass
h1x1_int8_ta1tw8_uniform_L4096_m2n8         1x1 8 8 1 8 4096  2  8 uniform     512 -                 pass
h4x4_int8_ta1tw8_uniform_L4096_m4n64_T1     4x4 8 8 1 8 4096  4 64 uniform     541 -                 pass
h4x4_int8_ta1tw1_uniform_L4096_m4n8_T2S8    4x4 8 8 1 1 4096  4  8 uniform     542 -                 pass
h4x4_int8_ta4tw8_uniform_L4096_m16n64       4x4 8 8 4 8 4096 16 64 uniform     543 -                 pass
h4x4_int8_ta4tw8_uniform_L1024_m32n32       4x4 8 8 4 8 1024 32 32 uniform     544 -                 pass
h4x4_int8_ta4tw8_neg1xmin_L4096_m16n32      4x4 8 8 4 8 4096 16 32 neg1xmin      0 -                 pass
h4x4_int8_ta4tw8_allmin_L4096_m16n32_junk   4x4 8 8 4 8 4096 16 32 allmin        0 JUNK              pass
h4x4_int8_ta4tw8_relu_L1024_m16n64_junk     4x4 8 8 4 8 1024 16 64 relu        545 JUNK              pass
h4x4_int8_ta2tw8_uniform_L4096_m8n64        4x4 8 8 2 8 4096  8 64 uniform     546 -                 pass
h4x4_int8_ta2tw8_uniform_L1024_m16n32       4x4 8 8 2 8 1024 16 32 uniform     547 -                 pass
h4x4_int8_ta4tw4_uniform_L4096_m16n32       4x4 8 8 4 4 4096 16 32 uniform     548 -                 pass
h4x4_int8_ta4tw4_alternating_L1024_m32n16   4x4 8 8 4 4 1024 32 16 alternating   0 -                 pass
h4x4_int8_ta8tw8_uniform_L384_m32n64        4x4 8 8 8 8  384 32 64 uniform     549 -                 pass
h4x4_int4_ta4tw4_uniform_L4096_m32n64       4x4 4 4 4 4 4096 32 64 uniform     550 -                 pass
h4x4_int4_ta4tw4_allmin_L1024_m32n32        4x4 4 4 4 4 1024 32 32 allmin        0 -                 pass
h4x4_int4_ta1tw4_uniform_L4096_m8n64_T1     4x4 4 4 1 4 4096  8 64 uniform     551 -                 pass
h4x4_w4a8_ta8tw4_uniform_L4096_m32n64       4x4 8 4 8 4 4096 32 64 uniform     552 -                 pass
h4x4_w4a8_ta8tw4_minxmax_L4096_m32n32       4x4 8 4 8 4 4096 32 32 minxmax       0 -                 pass
h4x4_w4a8_ta4tw4_uniform_L1024_m16n64       4x4 8 4 4 4 1024 16 64 uniform     553 -                 pass
h4x8_int8_ta4tw8_uniform_L4096_m16n128      4x8 8 8 4 8 4096 16 128 uniform    581 -                 pass
h4x8_int8_ta4tw8_uniform_L1024_m32n64       4x8 8 8 4 8 1024 32 64 uniform     582 -                 pass
h4x8_int4_ta4tw4_maxxmin_L1024_m32n64       4x8 4 4 4 4 1024 32 64 maxxmin       0 -                 pass
h2x3_int8_ta4tw8_uniform_L1024_m16n24_junk  2x3 8 8 4 8 1024 16 24 uniform     531 JUNK              pass
h2x3_int4_ta2tw4_gauss_L2048_m16n48         2x3 4 4 2 4 2048 16 48 gauss       532 -                 pass
h2x3_w4a8_ta8tw4_uniform_L1024_m16n24       2x3 8 4 8 4 1024 16 24 uniform     533 -                 pass
h4x4_neg_asignheld_int8_ta4tw8              4x4 8 8 4 8  256 16 32 uniform     591 NEG_ASIGN_HELD    fail
h4x4_neg_gapshort_int8_ta4tw8               4x4 8 8 4 8  256 16 32 uniform     592 NEG_GAP_SHORT     fail
h4x4_neg_drainearly_int8_ta4tw8             4x4 8 8 4 8  256 16 32 uniform     593 NEG_DRAIN_EARLY   fail
h4x4_neg_overlap_int8_ta4tw8                4x4 8 8 4 8  256 16 64 uniform     594 NEG_BLOCK_OVERLAP fail
h2x3_neg_asignheld_int4_ta2tw4              2x3 4 4 2 4  256 16 24 uniform     595 NEG_ASIGN_HELD    fail
h2x3_neg_overlap_w4a8_ta8tw4                2x3 8 4 8 4  256 16 48 uniform     596 NEG_BLOCK_OVERLAP fail
EOF
)
# label SHAPE BA BW S L MROWS NCOLS DIST SEED FLAGS EXPECT   (proof's T2 bench, fresh seeds/shapes)
SCASES=$(cat <<'EOF'
t2x_2x3_int8_s8_uniform_L1024_m4n6          2x3 8 8 8 1024  4  6 uniform    7001 -                 pass
t2x_2x3_int8_s8_alternating_L4096_m2n6_junk 2x3 8 8 8 4096  2  6 alternating   0 JUNK              pass
t2x_2x3_int4_s4_uniform_L4096_m4n12         2x3 4 4 4 4096  4 12 uniform    7002 -                 pass
t2x_2x3_int8_s2_gauss_L1024_m2n24           2x3 8 8 2 1024  2 24 gauss      7004 -                 pass
t2x_3x2_w4a8_s2_relu_L1024_m3n16            3x2 8 4 2 1024  3 16 relu       7003 -                 pass
t2x_3x2_int8_s8_neg1xmin_L4096_m3n4         3x2 8 8 8 4096  3  4 neg1xmin      0 -                 pass
t2x_4x4_int8_s8_uniform_L4096_m8n8          4x4 8 8 8 4096  8  8 uniform    7005 -                 pass
t2x_4x4_int8_s8_gauss_L1024_m4n8_junk       4x4 8 8 8 1024  4  8 gauss      7006 JUNK              pass
t2x_3x2_neg_overlap_int8_s8                 3x2 8 8 8  256  3  4 uniform    7091 NEG_BLOCK_OVERLAP fail
t2x_3x2_neg_drainearly_int8_s8              3x2 8 8 8  256  3  4 uniform    7092 NEG_DRAIN_EARLY   fail
EOF
)

one() {   # kind label shape ba bw x y L mrows ncols dist seed flags expect   (kind h: x,y=TA,TW; s: x=S)
    local kind=$1 label=$2 shape=$3 ba=$4 bw=$5 x=$6 y=$7 L=$8 mrows=$9 ncols=${10} dist=${11} seed=${12} flags=${13} expect=${14}
    local sub simv check plus=() fl f dir
    if [[ $kind == h ]]; then sub=hyb; simv="$OUT/build_h$shape/simv"; check=$CHECK_H; plus=(+TA="$x" +TW="$y")
    else sub=t2x; simv="$OUT/build_s$shape/simv"; check=$CHECK_S; plus=(+S="$x"); fi
    dir="$OUT/$sub/$label"
    if [[ "$flags" != - ]]; then IFS=, read -ra fl <<< "$flags"; for f in "${fl[@]}"; do plus+=("+$f"); done; fi
    rm -rf "$dir"; mkdir -p "$dir"
    python3 "$GEN" --ba "$ba" --bw "$bw" --L "$L" --mrows "$mrows" --ncols "$ncols" \
        --dist "$dist" --seed "$seed" --out-dir "$dir" > "$dir/gen.log" || { echo "$label: FAIL (generator)"; return 1; }
    (cd "$dir" && "$simv" +BA="$ba" +BW="$bw" +L="$L" +MROWS="$mrows" +NCOLS="$ncols" "${plus[@]}" > sim.log 2>&1)
    grep -q '^PASS: BP' "$dir/sim.log" || { echo "$label: FAIL (simulation error, $dir/sim.log)"; return 1; }
    local rc=0
    python3 "$check" "$dir" --json "$dir/check.json" > "$dir/check.log" 2>&1 || rc=$?
    rm -f "$dir/bpt_a.hex" "$dir/bpt_w.hex"
    if (( rc == 0 )); then
        [[ $expect == pass ]] && { echo "$label: PASS  $(tail -1 "$dir/check.log" | sed 's/^\[PASS\] //')"; return 0; }
        echo "$label: FAIL (negative control NOT caught)"; return 1
    fi
    grep -q '^\[FAIL\]' "$dir/check.log" || { echo "$label: FAIL (checker error, $dir/check.log)"; return 1; }
    if [[ $expect == fail ]]; then
        local nm
        nm=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['n_mismatch'])" "$dir/check.json")
        (( nm > 0 )) || { echo "$label: FAIL (failed without tile/output mismatches)"; return 1; }
        echo "$label: PASS (expected failure caught: $nm tile/output mismatches; $(tail -1 "$dir/check.log" | sed 's/^\[FAIL\] [^:]*: //'))"
        return 0
    fi
    echo "$label: FAIL  $(tail -1 "$dir/check.log")"; return 1
}

# 3. Bench self-consistency: the hybrid bench with TA=1, TW=BW (the T1 mapping)
#    must give D / R records byte-identical to the EXISTING grid bench
#    (designs/payn/tb/test_pe_grid_bp.sv, compiled fresh here) on the same operands.
xref_t1() {   # label BA BW L MROWS NCOLS DIST SEED   (4x4)
    local label=$1 ba=$2 bw=$3 L=$4 mrows=$5 ncols=$6 dist=$7 seed=$8 d="$OUT/xref/$1" n
    rm -rf "$d"; mkdir -p "$d/new" "$d/old"
    python3 sweeps/int_mode/bp/gen_bp_workload.py --ba "$ba" --bw "$bw" --L "$L" --mrows "$mrows" \
        --ncols "$ncols" --dist "$dist" --seed "$seed" --out-dir "$d/old" > "$d/old/gen.log"
    cp "$d/old/bpt_a.hex" "$d/old/bpt_w.hex" "$d/new/"
    (cd "$d/old" && "$OUT/build_xref4x4/simv" +BA="$ba" +BW="$bw" +L="$L" +MROWS="$mrows" +NCOLS="$ncols" > sim.log 2>&1)
    (cd "$d/new" && "$OUT/build_h4x4/simv" +BA="$ba" +BW="$bw" +TA=1 +TW="$bw" +L="$L" +MROWS="$mrows" +NCOLS="$ncols" > sim.log 2>&1)
    grep -q '^PASS: BP' "$d/old/sim.log" && grep -q '^PASS: BP hybrid' "$d/new/sim.log" \
        || { echo "$label: FAIL (simulation error)"; return 1; }
    python3 "$CHECK_H" "$d/new" --json "$d/new/check.json" > "$d/new/check.log" 2>&1 \
        || { echo "$label: FAIL (hybrid T1-mode run does not check)"; return 1; }
    n=$(grep -c '^[DR] ' "$d/old/bpg_trace.txt")
    if cmp -s <(grep '^[DR] ' "$d/new/bpg_trace.txt" | sort) <(grep '^[DR] ' "$d/old/bpg_trace.txt" | sort); then
        echo "$label: PASS (hybrid bench TA=1 TW=$bw: $n D/R records byte-identical to test_pe_grid_bp.sv)"
    else
        echo "$label: FAIL (records differ from test_pe_grid_bp.sv)"; return 1
    fi
}

status=0
pids=()
mkdir -p "$OUT/xref"
vcs_build xref4x4 designs/payn/tb/test_pe_grid_bp.sv "+define+BPG_PR=4+define+BPG_PC=4" & pids+=("$!")
for s in 1x1 2x3 4x4 4x8; do
    vcs_build "h$s" "$TB_H" "+define+BPG_PR=${s%x*}+define+BPG_PC=${s#*x}" & pids+=("$!")
done
for s in 2x3 3x2 4x4; do
    vcs_build "s$s" "$TB_S" "+define+BPG_PR=${s%x*}+define+BPG_PC=${s#*x}" & pids+=("$!")
done
for p in "${pids[@]}"; do wait "$p" || status=1; done
(( status == 0 )) || { echo "run_bp_hybrid_checks: COMPILE FAILED"; exit 1; }

{
while read -r label shape ba bw ta tw L mrows ncols dist seed flags expect; do
    [[ -n "$label" ]] || continue
    one h "$label" "$shape" "$ba" "$bw" "$ta" "$tw" "$L" "$mrows" "$ncols" "$dist" "$seed" "$flags" "$expect" &
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
done <<< "$HCASES"
while read -r label shape ba bw s L mrows ncols dist seed flags expect; do
    [[ -n "$label" ]] || continue
    one s "$label" "$shape" "$ba" "$bw" "$s" - "$L" "$mrows" "$ncols" "$dist" "$seed" "$flags" "$expect" &
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
done <<< "$SCASES"
xref_t1 xref_t1_4x4_int8_L4096 8 8 4096 4 32 uniform 35 &
xref_t1 xref_t1_4x4_int4_L1024 4 4 1024 8 64 uniform 36 &
while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done
echo "run_bp_hybrid_checks: $([[ $status == 0 ]] && echo ALL AS EXPECTED || echo UNEXPECTED RESULTS)"
} > "$OUT/summary.log" 2>&1
grep -v -i zoxide "$OUT/summary.log" | grep -v '^$' | sort
python3 sweeps/int_mode/bp/hybrid/hybrid_periods.py "$OUT" > "$OUT/periods.txt" || status=1
grep -q 'ALL AS EXPECTED' "$OUT/summary.log" && ! grep -q ': FAIL' "$OUT/summary.log"
