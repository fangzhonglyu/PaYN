#!/bin/bash
# BP-space (T2: weight bits in space, "execute through the reduction dimension,
# then shift") on the UNCHANGED BP RTL (csa_bp_20261004_lap), RTL simulation.
#
# Benches (new; the existing BP benches are not touched):
#   designs/payn/tb/test_payn_array_bp_space.sv  single-PE top
#       payn_array_signed_segmented_csa_bp (K8 M16 8x8 LOW_W9, the target's
#       shape), real INT ports, east-edge combiner words checked
#   designs/payn/tb/test_pe_grid_bp_space.sv     PE grid
#       inner_pe_grid_signed_segmented_csa_bp.sv, shapes 1x1 2x2 4x4 4x8
# Generator: sweeps/int_mode/bp/space/gen_bp_space_workload.py (the
# distributions of gen_bp_workload.py).  Checker:
# sweeps/int_mode/bp/space/check_bp_space_trace.py (numpy int64: every drained
# tile, every combined output, the single-PE combiner words and their Horner
# accumulate, drain edges, ring runs, block period vs formula and vs the
# model's T2 period from sweeps/int_mode/bp/model_lap_schedules.py).
#
# Matrix:
#   * INT8 S=8 (one output per PE, no lap, no ring), W4A8 S=4 (2 outputs per
#     PE) and INT4 S=4 (4 outputs per PE), INT8 S=2 (4 passes with the 8-edge
#     per-PE laps), plus INT8 S=4, W4A8 S=2, INT4 S=2; random (uniform with
#     forced extremes), all-min, all-max, min x max, max x min, -1 x min,
#     alternating, relu; JUNK; multi-block back to back; L = 128, 1024, 4096;
#     a range case beyond T1's 24-bit limit (INT8 S=8 all-min,
#     L = 8,388,480: tile 2^23 - 128).
#   * Period cases: every T2 cell of the model's table (INT8 S=2/4/8, W4A8
#     S=2/4, INT4 S=2/4) x {1 PE, 4x4, 4x8} x L = {1024, 4096}, two blocks
#     each, so the drain-start spacing is measured.
#   * Negative controls (must FAIL with tile / output mismatches): wrong
#     column sign word (NEG_WSIGN), a stray ring pulse (NEG_RING_STRAY), a
#     missing drain edge (NEG_DRAIN_MISS); tightness controls, one edge
#     shorter (NEG_DRAIN_EARLY, NEG_BLOCK_OVERLAP; NEG_GAP_SHORT for S=2).
#   * S=1 cross-check: the new benches with S=1 run the as-built T1 schedule;
#     their D / C (single PE) and D / R (grid) records must be byte-identical
#     to the EXISTING benches' (test_payn_array_bp.sv +LAP_RING_ONLY,
#     test_pe_grid_bp.sv), compiled and run fresh here on the same operands.
#   * RTL identity: the simulated BP top / PE / tile / combiner / peripheral
#     are code-identical (comments stripped) to the routed
#     csa_bp_20261004_lap RTL snapshot.
#
#   bash sweeps/int_mode/bp/space/run_bp_space_checks.sh
#   SHAPES="p1 2x2" bash ...   (subset; p1 = single-PE top)   MAX_JOBS=<n>
# Logs: build/rtl_preflight/bp_space/{summary.log,periods.txt,periods.json,
#       p1/<case>/, grid/<case>/, xref/, compile_*.log}
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
OUT=$(realpath -m "${OUT:-build/rtl_preflight/bp_space}")
MAX_JOBS=${MAX_JOBS:-16}
SHAPES=${SHAPES:-"p1 1x1 2x2 4x4 4x8"}
TB_P1=designs/payn/tb/test_payn_array_bp_space.sv
TB_G=designs/payn/tb/test_pe_grid_bp_space.sv
GEN=sweeps/int_mode/bp/space/gen_bp_space_workload.py
CHECK=sweeps/int_mode/bp/space/check_bp_space_trace.py
SNAP=build/power_char/int_mode_energy_20261004_lap/bp/csa_bp_20261004_lap_distguide_spp_pins/rtl_snapshot
mkdir -p "$OUT/p1" "$OUT/grid" "$OUT/xref"

vcs_build() {   # tag tb [defines]
    local tag=$1 tb=$2 def=${3:-} b="$OUT/build_$1"
    rm -rf "$b"; mkdir -p "$b"
    vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp \
        +incdir+designs -assert svaext -timescale=1ns/1ps $def \
        -o "$b/simv" -Mdir="$b/obj" \
        -y "$SYNOPSYS/dw/sim_ver" +libext+.v+ +incdir+"$SYNOPSYS/dw/sim_ver" \
        "$tb" -top Top > "$OUT/compile_$tag.log" 2>&1 \
        || { echo "compile $tag FAILED: $OUT/compile_$tag.log"; return 1; }
}

#------------------------------------------------------------------ cases --
# label SHAPE BA BW S L MROWS NCOLS DIST SEED FLAGS EXPECT   (SHAPE p1 = single-PE top)
CASES=$(cat <<'EOF'
p1_int8_s8_uniform_L128_m1n8             p1  8 8 8  128 1  8 uniform     1 -                 pass
p1_int8_s8_uniform_L1024_m2n3            p1  8 8 8 1024 2  3 uniform     3 -                 pass
p1_int8_s8_uniform_L4096_m1n2            p1  8 8 8 4096 1  2 uniform     4 -                 pass
p1_int8_s8_relu_L1024_m1n2               p1  8 8 8 1024 1  2 relu        5 -                 pass
p1_int8_s8_allmin_L1024_m1n2             p1  8 8 8 1024 1  2 allmin      0 -                 pass
p1_int8_s8_allmax_L1024_m1n1             p1  8 8 8 1024 1  1 allmax      0 -                 pass
p1_int8_s8_minxmax_L1024_m1n2            p1  8 8 8 1024 1  2 minxmax     0 -                 pass
p1_int8_s8_maxxmin_L256_m2n1             p1  8 8 8  256 2  1 maxxmin     0 -                 pass
p1_int8_s8_neg1xmin_L1024_m1n2           p1  8 8 8 1024 1  2 neg1xmin    0 -                 pass
p1_int8_s8_alternating_L1024_m2n2        p1  8 8 8 1024 2  2 alternating 0 -                 pass
p1_int8_s8_uniform_L1024_m2n3_junk       p1  8 8 8 1024 2  3 uniform     6 JUNK              pass
p1_int8_s8_allmin_L1024_m1n2_junk        p1  8 8 8 1024 1  2 allmin      0 JUNK              pass
p1_int8_s8_allmin_L8388480_m1n1_range    p1  8 8 8 8388480 1 1 allmin    0 -                 pass
p1_w4a8_s4_uniform_L1024_m2n4            p1  8 4 4 1024 2  4 uniform    11 -                 pass
p1_w4a8_s4_minxmax_L1024_m1n4            p1  8 4 4 1024 1  4 minxmax     0 -                 pass
p1_w4a8_s4_allmin_L4096_m1n2             p1  8 4 4 4096 1  2 allmin      0 -                 pass
p1_w4a8_s4_uniform_L256_m3n2_junk        p1  8 4 4  256 3  2 uniform    13 JUNK              pass
p1_int4_s4_uniform_L1024_m4n4            p1  4 4 4 1024 4  4 uniform    21 -                 pass
p1_int4_s4_allmin_L1024_m2n2             p1  4 4 4 1024 2  2 allmin      0 -                 pass
p1_int4_s4_maxxmin_L4096_m2n2            p1  4 4 4 4096 2  2 maxxmin     0 -                 pass
p1_int4_s4_uniform_L1024_m4n4_junk       p1  4 4 4 1024 4  4 uniform    23 JUNK              pass
p1_int8_s2_uniform_L1024_m2n8            p1  8 8 2 1024 2  8 uniform    41 -                 pass
p1_int8_s2_allmin_L1024_m1n4             p1  8 8 2 1024 1  4 allmin      0 -                 pass
p1_int8_s2_alternating_L4096_m1n4        p1  8 8 2 4096 1  4 alternating 0 -                 pass
p1_int8_s2_uniform_L256_m2n8_junk        p1  8 8 2  256 2  8 uniform    42 JUNK              pass
p1_int8_s4_uniform_L1024_m2n4            p1  8 8 4 1024 2  4 uniform    43 -                 pass
p1_w4a8_s2_uniform_L1024_m1n8            p1  8 4 2 1024 1  8 uniform    44 -                 pass
p1_int4_s2_minxmax_L512_m2n8             p1  4 4 2  512 2  8 minxmax     0 -                 pass
p1_neg_wsign_int8_s8                     p1  8 8 8  256 1  2 uniform    91 NEG_WSIGN         fail
p1_neg_ringstray_int8_s8                 p1  8 8 8  256 1  2 uniform    92 NEG_RING_STRAY    fail
p1_neg_drainmiss_int8_s8                 p1  8 8 8  256 1  2 uniform    93 NEG_DRAIN_MISS    fail
p1_neg_drainearly_int8_s8                p1  8 8 8  256 1  2 uniform    94 NEG_DRAIN_EARLY   fail
p1_neg_overlap_int8_s8                   p1  8 8 8  256 1  2 uniform    95 NEG_BLOCK_OVERLAP fail
p1_neg_overlap_int8_s8_L128              p1  8 8 8  128 1  3 uniform    96 NEG_BLOCK_OVERLAP fail
p1_neg_wsign_int4_s4                     p1  4 4 4  256 2  2 uniform    97 NEG_WSIGN         fail
p1_neg_wsign_int8_s2                     p1  8 8 2  256 1  4 uniform    98 NEG_WSIGN         fail
g1x1_int8_s8_uniform_L1024_m2n2          1x1 8 8 8 1024 2  2 uniform   101 -                 pass
g1x1_int4_s4_uniform_L1024_m4n4_junk     1x1 4 4 4 1024 4  4 uniform   102 JUNK              pass
g1x1_neg_overlap_int8_s8                 1x1 8 8 8  256 1  2 uniform   103 NEG_BLOCK_OVERLAP fail
g1x1_neg_drainearly_int8_s8              1x1 8 8 8  256 1  2 uniform   104 NEG_DRAIN_EARLY   fail
g2x2_int8_s8_uniform_L128_m4n4           2x2 8 8 8  128 4  4 uniform   201 -                 pass
g2x2_int8_s8_uniform_L1024_m4n4_junk     2x2 8 8 8 1024 4  4 uniform   202 JUNK              pass
g2x2_int8_s8_allmin_L1024_m2n2           2x2 8 8 8 1024 2  2 allmin      0 -                 pass
g2x2_int8_s8_allmax_L256_m2n2            2x2 8 8 8  256 2  2 allmax      0 -                 pass
g2x2_int8_s8_minxmax_L1024_m2n2          2x2 8 8 8 1024 2  2 minxmax     0 -                 pass
g2x2_int8_s8_maxxmin_L256_m2n2           2x2 8 8 8  256 2  2 maxxmin     0 -                 pass
g2x2_int8_s8_neg1xmin_L1024_m2n2         2x2 8 8 8 1024 2  2 neg1xmin    0 -                 pass
g2x2_int8_s8_alternating_L1024_m4n2      2x2 8 8 8 1024 4  2 alternating 0 -                 pass
g2x2_w4a8_s4_uniform_L1024_m4n4          2x2 8 4 4 1024 4  4 uniform   203 -                 pass
g2x2_w4a8_s4_minxmax_L256_m2n4_junk      2x2 8 4 4  256 2  4 minxmax     0 JUNK              pass
g2x2_int4_s4_uniform_L1024_m4n8          2x2 4 4 4 1024 4  8 uniform   204 -                 pass
g2x2_int4_s4_allmin_L1024_m4n4           2x2 4 4 4 1024 4  4 allmin      0 -                 pass
g2x2_int8_s2_uniform_L1024_m2n16         2x2 8 8 2 1024 2 16 uniform   205 -                 pass
g2x2_int8_s2_minxmax_L256_m2n8_junk      2x2 8 8 2  256 2  8 minxmax     0 JUNK              pass
g2x2_neg_wsign_int8_s8                   2x2 8 8 8  256 2  2 uniform   291 NEG_WSIGN         fail
g2x2_neg_ringstray_int8_s8               2x2 8 8 8  256 2  2 uniform   292 NEG_RING_STRAY    fail
g2x2_neg_drainmiss_int8_s8               2x2 8 8 8  256 2  2 uniform   293 NEG_DRAIN_MISS    fail
g2x2_neg_drainearly_int8_s8              2x2 8 8 8  256 2  2 uniform   294 NEG_DRAIN_EARLY   fail
g2x2_neg_overlap_int8_s8                 2x2 8 8 8  256 2  4 uniform   295 NEG_BLOCK_OVERLAP fail
g2x2_neg_gapshort_int8_s2                2x2 8 8 2  256 2  8 uniform   296 NEG_GAP_SHORT     fail
g2x2_neg_wsign_int4_s4                   2x2 4 4 4  256 4  4 uniform   297 NEG_WSIGN         fail
g4x4_int8_s8_uniform_L128_m8n4           4x4 8 8 8  128 8  4 uniform   401 -                 pass
g4x4_int8_s8_uniform_L1024_m8n8_junk     4x4 8 8 8 1024 8  8 uniform   402 JUNK              pass
g4x4_int8_s8_allmin_L1024_m4n4           4x4 8 8 8 1024 4  4 allmin      0 -                 pass
g4x4_int8_s8_alternating_L256_m4n4       4x4 8 8 8  256 4  4 alternating 0 -                 pass
g4x4_int8_s8_neg1xmin_L4096_m4n4         4x4 8 8 8 4096 4  4 neg1xmin    0 -                 pass
g4x4_w4a8_s4_maxxmin_L1024_m4n8          4x4 8 4 4 1024 4  8 maxxmin     0 -                 pass
g4x4_int4_s4_uniform_L1024_m16n8_junk    4x4 4 4 4 1024 16 8 uniform   403 JUNK              pass
g4x4_neg_wsign_int8_s8                   4x4 8 8 8  256 4  4 uniform   491 NEG_WSIGN         fail
g4x4_neg_ringstray_int8_s8               4x4 8 8 8  256 4  4 uniform   492 NEG_RING_STRAY    fail
g4x4_neg_drainmiss_int8_s8               4x4 8 8 8  256 4  4 uniform   493 NEG_DRAIN_MISS    fail
g4x4_neg_drainearly_int8_s8              4x4 8 8 8  256 4  4 uniform   494 NEG_DRAIN_EARLY   fail
g4x4_neg_overlap_int8_s8                 4x4 8 8 8  256 4  8 uniform   495 NEG_BLOCK_OVERLAP fail
g4x4_neg_gapshort_int8_s2                4x4 8 8 2  256 4 16 uniform   496 NEG_GAP_SHORT     fail
g4x8_int8_s8_uniform_L128_m4n16          4x8 8 8 8  128 4 16 uniform   801 -                 pass
g4x8_int8_s8_uniform_L1024_m8n8_junk     4x8 8 8 8 1024 8  8 uniform   802 JUNK              pass
g4x8_int8_s8_minxmax_L1024_m4n8          4x8 8 8 8 1024 4  8 minxmax     0 -                 pass
g4x8_int8_s8_allmin_L4096_m4n8           4x8 8 8 8 4096 4  8 allmin      0 -                 pass
g4x8_int4_s4_alternating_L1024_m8n16     4x8 4 4 4 1024 8 16 alternating 0 -                 pass
g4x8_int8_s2_uniform_L256_m4n32_junk     4x8 8 8 2  256 4 32 uniform   803 JUNK              pass
g4x8_neg_wsign_int8_s8                   4x8 8 8 8  256 4  8 uniform   891 NEG_WSIGN         fail
g4x8_neg_ringstray_int8_s8               4x8 8 8 8  256 4  8 uniform   892 NEG_RING_STRAY    fail
g4x8_neg_drainmiss_int8_s8               4x8 8 8 8  256 4  8 uniform   893 NEG_DRAIN_MISS    fail
g4x8_neg_drainearly_int8_s8              4x8 8 8 8  256 4  8 uniform   894 NEG_DRAIN_EARLY   fail
g4x8_neg_overlap_int8_s8                 4x8 8 8 8  256 4 16 uniform   895 NEG_BLOCK_OVERLAP fail
EOF
)
# Period cases: every T2 cell of the model table, two blocks (NIG=1, NJG=2).
PER=""
seed=1000
for shape in p1 4x4 4x8; do
    if [[ $shape == p1 ]]; then pr=1; pc=1; else pr=${shape%x*}; pc=${shape#*x}; fi
    for cfg in "int8 8 8 8" "int8 8 8 4" "int8 8 8 2" "w4a8 8 4 4" "w4a8 8 4 2" "int4 4 4 4" "int4 4 4 2"; do
        read -r pn ba bw s <<< "$cfg"
        for L in 1024 4096; do
            seed=$((seed + 1))
            mrows=$(( pr * (8 / ba) )); ncols=$(( 2 * pc * (8 / s) ))
            tag=${shape/p1/p1}; [[ $shape != p1 ]] && tag=g$shape
            PER+="${tag}_per_${pn}_s${s}_L${L} $shape $ba $bw $s $L $mrows $ncols uniform $seed - pass"$'\n'
        done
    done
done
CASES+=$'\n'"$PER"

one() {   # label shape ba bw s L mrows ncols dist seed flags expect
    local label=$1 shape=$2 ba=$3 bw=$4 s=$5 L=$6 mrows=$7 ncols=$8 dist=$9 seed=${10} flags=${11} expect=${12}
    local sub=grid simv="$OUT/build_$shape/simv" plus=() fl x
    [[ $shape == p1 ]] && sub=p1
    local dir="$OUT/$sub/$label"
    if [[ "$flags" != - ]]; then IFS=, read -ra fl <<< "$flags"; for x in "${fl[@]}"; do plus+=("+$x"); done; fi
    rm -rf "$dir"; mkdir -p "$dir"
    python3 "$GEN" --ba "$ba" --bw "$bw" --L "$L" --mrows "$mrows" --ncols "$ncols" \
        --dist "$dist" --seed "$seed" --out-dir "$dir" > "$dir/gen.log" || { echo "$label: FAIL (generator)"; return 1; }
    (cd "$dir" && "$simv" +BA="$ba" +BW="$bw" +S="$s" +L="$L" +MROWS="$mrows" +NCOLS="$ncols" \
        "${plus[@]}" > sim.log 2>&1)
    grep -q '^PASS: BP space' "$dir/sim.log" || { echo "$label: FAIL (simulation error, $dir/sim.log)"; return 1; }
    local rc=0
    python3 "$CHECK" "$dir" --json "$dir/check.json" > "$dir/check.log" 2>&1 || rc=$?
    if (( L > 100000 )); then rm -f "$dir/bpt_a.hex" "$dir/bpt_w.hex"; fi
    if (( rc == 0 )); then
        [[ $expect == pass ]] && { echo "$label: PASS  $(tail -1 "$dir/check.log" | sed 's/^\[PASS\] //')"; return 0; }
        echo "$label: FAIL (negative control NOT caught)  $(tail -1 "$dir/check.log")"; return 1
    fi
    grep -q '^\[FAIL\]' "$dir/check.log" || { echo "$label: FAIL (checker error, $dir/check.log)"; return 1; }
    if [[ $expect == fail ]]; then
        local nm
        nm=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['n_mismatch'])" "$dir/check.json")
        (( nm > 0 )) || { echo "$label: FAIL (failed without tile/output mismatches)  $(tail -1 "$dir/check.log")"; return 1; }
        echo "$label: PASS (expected failure caught: $nm tile/output mismatches; $(tail -1 "$dir/check.log" | sed 's/^\[FAIL\] [^:]*: //'))"
        return 0
    fi
    echo "$label: FAIL  $(tail -1 "$dir/check.log")"; return 1
}

#---------------------------------------------- S=1 cross-check (existing) --
# label  existing-bench  shape  BA BW L MROWS NCOLS DIST SEED  (operands as the existing matrices)
XREF=$(cat <<'EOF'
xref_p1_int8_L1024_m2n16    p1  8 8 1024 2 16 uniform  3
xref_p1_w4a8_L1024_m2n16    p1  8 4 1024 2 16 uniform 12
xref_p1_int4_L1024_m4n16    p1  4 4 1024 4 16 uniform 22
xref_g2x2_int8_L256_m4n16   2x2 8 8  256 4 16 uniform  1
xref_g4x4_int8_L4096_m4n32  4x4 8 8 4096 4 32 uniform 35
xref_g4x4_int4_L4096_m8n32  4x4 4 4 4096 8 32 uniform 37
EOF
)
xref_one() {   # label shape ba bw L mrows ncols dist seed
    local label=$1 shape=$2 ba=$3 bw=$4 L=$5 mrows=$6 ncols=$7 dist=$8 seed=$9
    local d="$OUT/xref/$label" new old rec
    rm -rf "$d"; mkdir -p "$d/new" "$d/old"
    python3 "$GEN" --ba "$ba" --bw "$bw" --L "$L" --mrows "$mrows" --ncols "$ncols" \
        --dist "$dist" --seed "$seed" --out-dir "$d/new" > "$d/new/gen.log"
    python3 sweeps/int_mode/bp/gen_bp_workload.py --ba "$ba" --bw "$bw" --L "$L" --mrows "$mrows" \
        --ncols "$ncols" --dist "$dist" --seed "$seed" --out-dir "$d/old" > "$d/old/gen.log"
    cmp -s "$d/new/bpt_a.hex" "$d/old/bpt_a.hex" && cmp -s "$d/new/bpt_w.hex" "$d/old/bpt_w.hex" \
        || { echo "$label: FAIL (generators disagree)"; return 1; }
    local plus=(+BA="$ba" +BW="$bw" +L="$L" +MROWS="$mrows" +NCOLS="$ncols")
    if [[ $shape == p1 ]]; then
        (cd "$d/new" && "$OUT/build_p1/simv" "${plus[@]}" +S=1 > sim.log 2>&1)
        (cd "$d/old" && "$OUT/build_xref_p1/simv" "${plus[@]}" +LAP_RING_ONLY > sim.log 2>&1)
        new=$d/new/bps_trace.txt; old=$d/old/bpt_trace.txt; rec='^[DC] '
    else
        (cd "$d/new" && "$OUT/build_$shape/simv" "${plus[@]}" +S=1 > sim.log 2>&1)
        (cd "$d/old" && "$OUT/build_xref_$shape/simv" "${plus[@]}" > sim.log 2>&1)
        new=$d/new/bpg_trace.txt; old=$d/old/bpg_trace.txt; rec='^[DR] '
    fi
    grep -q '^PASS: BP space' "$d/new/sim.log" && grep -q '^PASS: BP' "$d/old/sim.log" \
        || { echo "$label: FAIL (simulation error)"; return 1; }
    python3 "$CHECK" "$d/new" --json "$d/new/check.json" > "$d/new/check.log" 2>&1 \
        || { echo "$label: FAIL (S=1 run does not check: $(tail -1 "$d/new/check.log"))"; return 1; }
    local n
    n=$(grep -c "$rec" "$old")
    if cmp -s <(grep "$rec" "$new") <(grep "$rec" "$old"); then
        echo "$label: PASS (S=1 on the new bench: $n D/C|R records byte-identical to the existing bench; $(tail -1 "$d/new/check.log" | grep -o 'block period [0-9]*'))"
    else
        echo "$label: FAIL (records differ from the existing bench)"; return 1
    fi
}

#------------------------------------------------------------ RTL identity --
rtl_identity() {
    local f d st=0
    for f in signed_segmented_csa_bp/payn_array_signed_segmented_csa_bp.sv \
             signed_segmented_csa_bp/inner_pe_signed_segmented_csa_bp.sv \
             signed_segmented_csa_bp/bp_combiner.sv signed_segmented_csa_bp/pe_peripheral_bp.sv \
             signed_segmented_csa/inner_pe_signed_segmented_csa.sv \
             signed_segmented_csa/inner_tile_signed_segmented_csa.sv; do
        if [[ ! -f "$SNAP/payn/variants/$f" ]]; then echo "rtl_identity: $f missing from $SNAP"; st=1; continue; fi
        d=$(diff <(sed 's#//.*##' "$SNAP/payn/variants/$f" | tr -s ' \n') \
                 <(sed 's#//.*##' "designs/payn/variants/$f" | tr -s ' \n') | wc -l)
        if (( d == 0 )); then echo "rtl_identity: $f code-identical to the csa_bp_20261004_lap snapshot (md5 $(md5sum < "designs/payn/variants/$f" | cut -c1-12))"
        else echo "rtl_identity: $f DIFFERS in code from the snapshot ($d diff lines)"; st=1; fi
    done
    echo "rtl_identity: grid wrapper (not synthesized, no snapshot) md5 $(md5sum < designs/payn/variants/signed_segmented_csa_bp/inner_pe_grid_signed_segmented_csa_bp.sv | cut -c1-12)"
    return $st
}

#--------------------------------------------------------------------- run --
status=0
pids=()
for s in $SHAPES; do
    if [[ $s == p1 ]]; then
        vcs_build p1 "$TB_P1" & pids+=("$!")
        vcs_build xref_p1 designs/payn/tb/test_payn_array_bp.sv & pids+=("$!")
    else
        vcs_build "$s" "$TB_G" "+define+BPG_PR=${s%x*}+define+BPG_PC=${s#*x}" & pids+=("$!")
        if [[ $s == 2x2 || $s == 4x4 ]]; then
            vcs_build "xref_$s" designs/payn/tb/test_pe_grid_bp.sv "+define+BPG_PR=${s%x*}+define+BPG_PC=${s#*x}" & pids+=("$!")
        fi
    fi
done
for p in "${pids[@]}"; do wait "$p" || status=1; done
(( status == 0 )) || { echo "run_bp_space_checks: COMPILE FAILED"; exit 1; }

{
rtl_identity || status=1
while read -r label shape ba bw s L mrows ncols dist seed flags expect; do
    [[ -n "$label" ]] || continue
    [[ " $SHAPES " == *" $shape "* ]] || continue
    one "$label" "$shape" "$ba" "$bw" "$s" "$L" "$mrows" "$ncols" "$dist" "$seed" "$flags" "$expect" &
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
done <<< "$CASES"
while read -r label shape ba bw L mrows ncols dist seed; do
    [[ -n "$label" ]] || continue
    [[ " $SHAPES " == *" $shape "* ]] || continue
    xref_one "$label" "$shape" "$ba" "$bw" "$L" "$mrows" "$ncols" "$dist" "$seed" &
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
done <<< "$XREF"
while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done
echo "run_bp_space_checks: $([[ $status == 0 ]] && echo ALL AS EXPECTED || echo UNEXPECTED RESULTS)"
} > "$OUT/summary.log" 2>&1
sort "$OUT/summary.log"
python3 sweeps/int_mode/bp/space/bp_space_periods.py "$OUT" | tee "$OUT/periods.txt"
grep -q 'ALL AS EXPECTED' "$OUT/summary.log" && ! grep -q ': FAIL' "$OUT/summary.log"
