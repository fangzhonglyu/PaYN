#!/bin/bash
# BP INT mode on a PE grid of the sub-ring PE (RTL), LAP_G-edge per-PE laps.
# Modelled on sweeps/int_mode/bp/ipd/run_bp_ipd_grid_checks.sh.
#
# Grid:    designs/payn/variants/signed_segmented_csa_bp_sr/inner_pe_grid_signed_segmented_csa_bp_sr.sv
# Bench:   designs/payn/tb/test_pe_grid_bp_ipd.sv compiled with +define+BPG_DUT_SR
#          +define+PAYN_LAP_G=<g> and run at +LAP_LEN=<g> (the bench's lap length
#          is a runtime knob; systolic skew applied by the bench, ring_in per PE
#          row with that row's A skew, global shift_in only for the final drain)
# Checker: sweeps/int_mode/bp/ipd/check_bp_ipd_grid_trace.py (unchanged: every
#          drained tile and combined output bit-exact vs numpy int64, drain edges,
#          every PE's lap runs from the RTL ring_q (LAP_LEN edges at offset r+c),
#          and the scheduled block period vs
#              BW*NB + LAP_LEN*(BW-1) + (P_R+P_C-2) + 8*P_C;
#          multi-block runs also measure the drain-start spacing).  This runner
#          also requires every passing run's lap_len to equal LAP_G.
#
# Builds (one compile per tag):
#   sr<shape>g<g>  the bench on the SR grid at LAP_G = g (every g in $LAP_GS; g = 1
#                  and 8 also for the collapse cross-check)
#   ipd<shape>     the bench on the IPD grid (default compile)
#   bp<shape>      the bench compiled with +define+BPG_DUT_BP (BP grid)
# Case kinds (column 2):
#   sr    run on sr<shape>g<g> for every g in $LAP_GS with LAP_LEN=g appended;
#         lap-length negatives are generated per g (LAP_LEN = 0, g-1, g+1, 2g,
#         1 and 8, except g itself)
#   xc    collapse cross-check: the SR grid at LAP_G=1 vs the IPD grid
#         (+LAP_LEN=1) and at LAP_G=8 vs the BP grid (+LAP_LEN=8); full traces
#         (header, drained tiles, lap runs) must be byte-identical
#
# Matrix: the positive and negative cases of the IPD grid matrix (shapes 4x1,
# 2x2, 2x3, 3x2, 4x4, 4x8; INT8, W4A8, INT4; multi-block, at L=4096 on 4x4 and
# 4x8; extremes; JUNK, which drives random west accumulators on lap edges too, so
# the head muxes must ignore them; RING_GATE_JUNK; GLOBAL_LAP_WAIT; row / column
# skew, global-lap, gap-short, drain-early, block-overlap, gate-bypass, stray
# ring and old-contract negatives).
#
#   bash sweeps/int_mode/bp/sr/run_bp_sr_grid_checks.sh
#   LAP_GS="2" SHAPES="2x2" bash sweeps/int_mode/bp/sr/run_bp_sr_grid_checks.sh   # subset
# Logs: build/rtl_preflight/bp_sr/grid/{summary.log,periods.txt,compile_<tag>.log,g<g>/<case>/,xc/<case>/}
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
OUT=$(realpath -m "${OUT:-build/rtl_preflight/bp_sr/grid}")
MAX_JOBS=${MAX_JOBS:-16}
SHAPES=${SHAPES:-"4x1 2x2 2x3 3x2 4x4 4x8"}
LAP_GS=${LAP_GS:-"2 4"}
TB=designs/payn/tb/test_pe_grid_bp_ipd.sv
CHK=sweeps/int_mode/bp/ipd/check_bp_ipd_grid_trace.py
mkdir -p "$OUT"

compile() {   # tag P_R P_C [defines]
    local tag=$1 pr=$2 pc=$3 def=${4:-} b="$OUT/build_$1"
    rm -rf "$b"; mkdir -p "$b"
    vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp \
        +incdir+designs -assert svaext -timescale=1ns/1ps \
        +define+BPG_PR=$pr+define+BPG_PC=$pc$def \
        -o "$b/simv" -Mdir="$b/obj" \
        -y "$SYNOPSYS/dw/sim_ver" +libext+.v+ +incdir+"$SYNOPSYS/dw/sim_ver" \
        "$TB" -top Top > "$OUT/compile_$tag.log" 2>&1 \
        || { echo "compile $tag FAILED: $OUT/compile_$tag.log"; return 1; }
}

# label kind shape BA BW L NIG NJG DIST SEED FLAGS EXPECT  (EXPECT: pass | fail)
# The IPD grid matrix without its LAP_LEN cases (lap negatives are per g below).
BASE_CASES=$(cat <<'EOF'
g4x1_int8_uniform_L256_b2x1        sr  4x1 8 8  256 2 1 uniform    81 JUNK                 pass
g4x1_w4a8_gatejunk_L384_b1x2       sr  4x1 8 4  384 1 2 uniform    82 RING_GATE_JUNK       pass
g4x1_int8_oldc_unforced_L256_b2x1  sr  4x1 8 8  256 2 1 uniform    83 OLDC_UNFORCED,JUNK   pass
g4x1_neg_drain_early               sr  4x1 8 8  256 1 1 uniform    84 NEG_DRAIN_EARLY      fail
g2x2_int8_uniform_L256_b2x1        sr  2x2 8 8  256 2 1 uniform     1 -                    pass
g2x2_int8_uniform_L384_b1x2_junk   sr  2x2 8 8  384 1 2 uniform     2 JUNK                 pass
g2x2_w4a8_uniform_L512_b2x1        sr  2x2 8 4  512 2 1 uniform     3 -                    pass
g2x2_int4_uniform_L256_b1x2        sr  2x2 4 4  256 1 2 uniform     4 -                    pass
g2x2_int8_allmin_L1024_b1x1        sr  2x2 8 8 1024 1 1 allmin      0 -                    pass
g2x2_int8_neg1xmin_L512_b2x1       sr  2x2 8 8  512 2 1 neg1xmin    0 -                    pass
g2x2_int8_globalwait_L256_b2x1     sr  2x2 8 8  256 2 1 uniform     5 GLOBAL_LAP_WAIT      pass
g2x2_neg_ring_no_row_skew          sr  2x2 8 8  256 1 1 uniform     6 NEG_RING_NO_ROW_SKEW fail
g2x2_neg_ring_no_col_skew          sr  2x2 8 8  256 1 1 uniform     7 NEG_RING_NO_COL_SKEW fail
g2x2_neg_global_lap                sr  2x2 8 8  256 1 1 uniform     8 NEG_GLOBAL_LAP       fail
g2x2_int8_gatejunk_L256_b2x1       sr  2x2 8 8  256 2 1 uniform     9 RING_GATE_JUNK,JUNK  pass
g2x2_neg_gap_short                 sr  2x2 8 8  256 1 1 uniform    61 NEG_GAP_SHORT        fail
g2x2_neg_drain_early               sr  2x2 8 8  256 1 1 uniform    62 NEG_DRAIN_EARLY      fail
g2x2_neg_block_overlap             sr  2x2 8 8  256 2 1 uniform    63 NEG_BLOCK_OVERLAP    fail
g2x2_neg_oldc_unforced             sr  2x2 8 8  256 1 1 uniform    85 OLDC_UNFORCED        fail
g2x2_neg_ring_stray                sr  2x2 8 8  256 1 1 uniform    94 NEG_RING_STRAY       fail
g2x3_int8_uniform_L256_b2x2        sr  2x3 8 8  256 2 2 uniform    11 -                    pass
g2x3_w4a8_minxmax_L384_b1x2        sr  2x3 8 4  384 1 2 minxmax     0 -                    pass
g2x3_int4_uniform_L384_b2x1_junk   sr  2x3 4 4  384 2 1 uniform    12 JUNK                 pass
g2x3_int8_alternating_L256_b1x1    sr  2x3 8 8  256 1 1 alternating 0 -                    pass
g2x3_int8_globalwait_L256_b1x2     sr  2x3 8 8  256 1 2 uniform    13 GLOBAL_LAP_WAIT      pass
g2x3_neg_ring_no_row_skew          sr  2x3 8 8  256 1 1 uniform    14 NEG_RING_NO_ROW_SKEW fail
g2x3_neg_ring_no_col_skew          sr  2x3 8 8  256 1 1 uniform    15 NEG_RING_NO_COL_SKEW fail
g2x3_neg_global_lap                sr  2x3 8 8  256 1 1 uniform    16 NEG_GLOBAL_LAP       fail
g2x3_int4_gatejunk_L256_b1x2       sr  2x3 4 4  256 1 2 uniform    17 RING_GATE_JUNK       pass
g2x3_neg_gate_bypass               sr  2x3 4 4  256 1 2 uniform    17 RING_GATE_JUNK,NEG_GATE_BYPASS fail
g2x3_neg_drain_early_int4          sr  2x3 4 4  256 1 1 uniform    64 NEG_DRAIN_EARLY      fail
g3x2_int8_uniform_L384_b2x1        sr  3x2 8 8  384 2 1 uniform    21 -                    pass
g3x2_w4a8_uniform_L256_b2x2        sr  3x2 8 4  256 2 2 uniform    22 -                    pass
g3x2_int4_minxmax_L256_b1x2        sr  3x2 4 4  256 1 2 minxmax     0 -                    pass
g3x2_int8_maxxmin_L256_b1x1_junk   sr  3x2 8 8  256 1 1 maxxmin     0 JUNK                 pass
g3x2_int8_globalwait_L256_b2x1     sr  3x2 8 8  256 2 1 uniform    23 GLOBAL_LAP_WAIT      pass
g3x2_neg_ring_no_row_skew          sr  3x2 8 8  256 1 1 uniform    24 NEG_RING_NO_ROW_SKEW fail
g3x2_neg_ring_no_col_skew          sr  3x2 8 8  256 1 1 uniform    25 NEG_RING_NO_COL_SKEW fail
g3x2_neg_global_lap                sr  3x2 8 8  256 1 1 uniform    26 NEG_GLOBAL_LAP       fail
g3x2_neg_gap_short_w4a8            sr  3x2 8 4  256 1 1 uniform    65 NEG_GAP_SHORT        fail
g4x4_int8_uniform_L256_b2x1        sr  4x4 8 8  256 2 1 uniform    31 -                    pass
g4x4_int8_uniform_L256_b1x2_junk   sr  4x4 8 8  256 1 2 uniform    32 JUNK                 pass
g4x4_w4a8_uniform_L384_b2x1        sr  4x4 8 4  384 2 1 uniform    33 -                    pass
g4x4_int4_uniform_L256_b2x1        sr  4x4 4 4  256 2 1 uniform    34 -                    pass
g4x4_int8_allmin_L512_b1x1         sr  4x4 8 8  512 1 1 allmin      0 -                    pass
g4x4_int8_uniform_L1024_b1x1       sr  4x4 8 8 1024 1 1 uniform    38 -                    pass
g4x4_int8_uniform_L1024_b1x2_junk  sr  4x4 8 8 1024 1 2 uniform    39 JUNK                 pass
g4x4_int8_uniform_L4096_b1x1       sr  4x4 8 8 4096 1 1 uniform    35 -                    pass
g4x4_int8_uniform_L4096_b2x1       sr  4x4 8 8 4096 2 1 uniform    40 -                    pass
g4x4_w4a8_uniform_L4096_b1x1       sr  4x4 8 4 4096 1 1 uniform    36 -                    pass
g4x4_int4_uniform_L4096_b1x1       sr  4x4 4 4 4096 1 1 uniform    37 -                    pass
g4x4_int8_globalwait_L4096_b1x1    sr  4x4 8 8 4096 1 1 uniform    35 GLOBAL_LAP_WAIT      pass
g4x4_neg_ring_no_row_skew          sr  4x4 8 8  256 1 1 uniform    41 NEG_RING_NO_ROW_SKEW fail
g4x4_neg_ring_no_col_skew          sr  4x4 8 8  256 1 1 uniform    42 NEG_RING_NO_COL_SKEW fail
g4x4_neg_global_lap                sr  4x4 8 8  256 1 1 uniform    43 NEG_GLOBAL_LAP       fail
g4x4_w4a8_gatejunk_L256_b2x2_junk  sr  4x4 8 4  256 2 2 uniform    44 RING_GATE_JUNK,JUNK  pass
g4x4_neg_gap_short                 sr  4x4 8 8  256 1 1 uniform    66 NEG_GAP_SHORT        fail
g4x4_neg_drain_early               sr  4x4 8 8  256 1 1 uniform    67 NEG_DRAIN_EARLY      fail
g4x4_neg_block_overlap             sr  4x4 8 8  256 1 2 uniform    68 NEG_BLOCK_OVERLAP    fail
g4x4_neg_ring_stray                sr  4x4 8 8  256 1 1 uniform    98 NEG_RING_STRAY       fail
g4x8_int8_uniform_L1024_b1x1       sr  4x8 8 8 1024 1 1 uniform    58 -                    pass
g4x8_int8_uniform_L4096_b1x1       sr  4x8 8 8 4096 1 1 uniform    51 -                    pass
g4x8_int8_uniform_L4096_b1x2       sr  4x8 8 8 4096 1 2 uniform    59 -                    pass
g4x8_int8_globalwait_L4096_b1x1    sr  4x8 8 8 4096 1 1 uniform    51 GLOBAL_LAP_WAIT      pass
g4x8_w4a8_uniform_L4096_b1x1       sr  4x8 8 4 4096 1 1 uniform    52 -                    pass
g4x8_int4_uniform_L4096_b1x1       sr  4x8 4 4 4096 1 1 uniform    53 -                    pass
g4x8_int8_uniform_L256_b1x1_junk   sr  4x8 8 8  256 1 1 uniform    54 JUNK                 pass
g4x8_int8_uniform_L256_b2x2_junk   sr  4x8 8 8  256 2 2 uniform    55 JUNK                 pass
g4x8_int4_uniform_L384_b2x1        sr  4x8 4 4  384 2 1 uniform    56 -                    pass
g4x8_w4a8_minxmax_L256_b1x2        sr  4x8 8 4  256 1 2 minxmax     0 -                    pass
g4x8_int8_gatejunk_L256_b2x1       sr  4x8 8 8  256 2 1 uniform    57 RING_GATE_JUNK       pass
g4x8_neg_gate_bypass               sr  4x8 8 8  256 2 1 uniform    57 RING_GATE_JUNK,NEG_GATE_BYPASS fail
g4x8_neg_gap_short                 sr  4x8 8 8  256 1 1 uniform    69 NEG_GAP_SHORT        fail
g4x8_neg_drain_early               sr  4x8 8 8  256 1 1 uniform    70 NEG_DRAIN_EARLY      fail
g4x8_neg_block_overlap             sr  4x8 8 8  256 2 1 uniform    71 NEG_BLOCK_OVERLAP    fail
g4x8_neg_oldc_unforced             sr  4x8 8 8  256 1 1 uniform    86 OLDC_UNFORCED        fail
g4x8_neg_ring_stray                sr  4x8 8 8  256 1 1 uniform   100 NEG_RING_STRAY       fail
EOF
)
XC_CASES=$(cat <<'EOF'
xc2x2_int8_uniform_L256_b2x1       xc  2x2 8 8  256 2 1 uniform     1 -                    pass
xc2x2_int8_uniform_L384_b1x2_junk  xc  2x2 8 8  384 1 2 uniform     2 JUNK                 pass
xc2x2_int8_globalwait_L256_b2x1    xc  2x2 8 8  256 2 1 uniform     5 GLOBAL_LAP_WAIT      pass
xc2x2_neg_gap_short                xc  2x2 8 8  256 1 1 uniform    61 NEG_GAP_SHORT        fail
xc2x3_int4_uniform_L384_b2x1_junk  xc  2x3 4 4  384 2 1 uniform    12 JUNK                 pass
xc4x4_int8_uniform_L4096_b1x1      xc  4x4 8 8 4096 1 1 uniform    35 -                    pass
xc4x4_w4a8_gatejunk_L256_b2x2_junk xc  4x4 8 4  256 2 2 uniform    42 RING_GATE_JUNK,JUNK  pass
xc4x4_neg_drain_early              xc  4x4 8 8  256 1 1 uniform    67 NEG_DRAIN_EARLY      fail
xc4x8_int8_uniform_L1024_b1x1      xc  4x8 8 8 1024 1 1 uniform    58 -                    pass
xc4x8_int8_uniform_L256_b2x2_junk  xc  4x8 8 8  256 2 2 uniform    55 JUNK                 pass
EOF
)

lap_negatives() {   # g -> lap-length negatives for LAP_G = g on 2x2, 4x4, 4x8 (+ INT4 on 2x3)
    local g=$1 n s
    for n in $(printf '%s\n' 0 $((g - 1)) $((g + 1)) $((2 * g)) 1 8 | sort -nu); do
        (( n == g || n < 0 )) && continue
        for s in 2x2 4x4 4x8; do
            echo "g${s}_neg_lap${n} sr ${s} 8 8 256 1 1 uniform $((90 + n)) LAP_LEN=$n fail"
        done
    done
    echo "g2x3_neg_lap$((g + 1))_int4 sr 2x3 4 4 256 1 1 uniform 95 LAP_LEN=$((g + 1)) fail"
}

# run one simulation + check; returns 0 if the outcome matches EXPECT, sets RESULT.
sim_check() {   # dir simv ba bw L mrows ncols dist seed flags expect lap_g
    local dir=$1 simv=$2 ba=$3 bw=$4 L=$5 mrows=$6 ncols=$7 dist=$8 seed=$9 flags=${10} expect=${11} lapg=${12}
    local plus=() fl x nm ll
    IFS=, read -ra fl <<< "$flags"
    for x in "${fl[@]}"; do [[ $x == - ]] || plus+=("+$x"); done
    rm -rf "$dir"; mkdir -p "$dir"
    python3 sweeps/int_mode/bp/gen_bp_workload.py --ba "$ba" --bw "$bw" --L "$L" \
        --mrows "$mrows" --ncols "$ncols" --dist "$dist" --seed "$seed" --out-dir "$dir" > "$dir/gen.log"
    (cd "$dir" && "$simv" +BA="$ba" +BW="$bw" +L="$L" +MROWS="$mrows" \
        +NCOLS="$ncols" "${plus[@]}" > sim.log 2>&1)
    grep -q '^PASS: BP grid bench' "$dir/sim.log" || { RESULT="FAIL (simulation error, $dir/sim.log)"; return 1; }
    if python3 "$CHK" "$dir" --json "$dir/check.json" > "$dir/check.log" 2>&1; then
        if [[ $expect == pass ]]; then
            ll=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['lap_len'])" "$dir/check.json")
            [[ $ll == "$lapg" ]] || { RESULT="FAIL (passing run with lap_len $ll != LAP_G $lapg)"; return 1; }
            RESULT="PASS  $(tail -1 "$dir/check.log" | sed 's/^\[PASS\] //')"; return 0
        fi
        RESULT="FAIL (negative control NOT caught)  $(tail -1 "$dir/check.log")"; return 1
    fi
    grep -q '^\[FAIL\]' "$dir/check.log" || { RESULT="FAIL (checker error, $dir/check.log)"; return 1; }
    if [[ $expect == fail ]]; then
        nm=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['n_mismatch'])" "$dir/check.json")
        (( nm > 0 )) || { RESULT="FAIL (failed without tile mismatches)  $(tail -1 "$dir/check.log")"; return 1; }
        RESULT="PASS (expected failure caught: $nm tile/output mismatches)"; return 0
    fi
    RESULT="FAIL  $(tail -1 "$dir/check.log")"; return 1
}

addlap() {   # flags g -> flags with LAP_LEN=g appended unless set
    if [[ $1 == *LAP_LEN=* ]]; then echo "$1"; elif [[ $1 == - ]]; then echo "LAP_LEN=$2"; else echo "$1,LAP_LEN=$2"; fi
}

one() {   # g label kind shape ba bw L nig njg dist seed flags expect
    local g=$1 label=$2 kind=$3 shape=$4 ba=$5 bw=$6 L=$7 nig=$8 njg=$9 dist=${10} seed=${11} flags=${12} expect=${13}
    local pr=${shape%x*} pc=${shape#*x} RESULT gg ref rc
    local rows_pe=$(( 8 / ba ))
    local mrows=$(( pr * rows_pe * nig )) ncols=$(( 8 * pc * njg ))
    case $kind in
        sr)
            sim_check "$OUT/g$g/$label" "$OUT/build_sr${shape}g$g/simv" "$ba" "$bw" "$L" "$mrows" "$ncols" \
                "$dist" "$seed" "$(addlap "$flags" "$g")" "$expect" "$g"
            rc=$?; echo "LAP_G=$g $label: $RESULT"; return $rc ;;
        xc)
            for gg in 1 8; do
                if [[ $gg == 1 ]]; then ref=ipd; else ref=bp; fi
                sim_check "$OUT/xc/$label/sr$gg" "$OUT/build_sr${shape}g$gg/simv" "$ba" "$bw" "$L" "$mrows" "$ncols" \
                    "$dist" "$seed" "$(addlap "$flags" $gg)" "$expect" "$gg" || { echo "$label: FAIL (SR LAP_G=$gg: $RESULT)"; return 1; }
                sim_check "$OUT/xc/$label/$ref" "$OUT/build_$ref$shape/simv" "$ba" "$bw" "$L" "$mrows" "$ncols" \
                    "$dist" "$seed" "$(addlap "$flags" $gg)" "$expect" "$gg" || { echo "$label: FAIL (${ref^^} grid: $RESULT)"; return 1; }
                cmp -s "$OUT/xc/$label/sr$gg/bpg_trace.txt" "$OUT/xc/$label/$ref/bpg_trace.txt" \
                    || { echo "$label: FAIL (SR LAP_G=$gg trace differs from the ${ref^^} grid)"; return 1; }
            done
            echo "$label: PASS (collapse cross-check: SR grid LAP_G=1 == IPD grid, LAP_G=8 == BP grid, full traces byte-identical; $RESULT)"
            return 0 ;;
    esac
}

status=0
pids=()
for s in $SHAPES; do
    for g in $LAP_GS; do
        compile "sr${s}g$g" "${s%x*}" "${s#*x}" "+define+BPG_DUT_SR+define+PAYN_LAP_G=$g" & pids+=("$!")
    done
    if grep -qE "^\S+\s+xc\s+$s\s" <<< "$XC_CASES"; then
        for g in 1 8; do
            [[ " $LAP_GS " == *" $g "* ]] || { compile "sr${s}g$g" "${s%x*}" "${s#*x}" "+define+BPG_DUT_SR+define+PAYN_LAP_G=$g" & pids+=("$!"); }
        done
        compile "ipd$s" "${s%x*}" "${s#*x}" & pids+=("$!")
        compile "bp$s" "${s%x*}" "${s#*x}" "+define+BPG_DUT_BP" & pids+=("$!")
    fi
done
for p in "${pids[@]}"; do wait "$p" || status=1; done
(( status == 0 )) || { echo "run_bp_sr_grid_checks: COMPILE FAILED"; exit 1; }
for f in "$OUT"/compile_sr*.log; do
    grep -q "signed_segmented_csa_bp_sr/inner_pe_core_signed_segmented_csa_sr.sv" "$f" \
        || { echo "$f did not compile the SR core"; exit 1; }
done

{
for g in $LAP_GS; do
    while read -r label kind shape ba bw L nig njg dist seed flags expect; do
        [[ -n "$label" ]] || continue
        [[ " $SHAPES " == *" $shape "* ]] || continue
        one "$g" "$label" "$kind" "$shape" "$ba" "$bw" "$L" "$nig" "$njg" "$dist" "$seed" "$flags" "$expect" &
        while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
    done <<< "$(echo "$BASE_CASES"; lap_negatives "$g")"
done
while read -r label kind shape ba bw L nig njg dist seed flags expect; do
    [[ -n "$label" ]] || continue
    [[ " $SHAPES " == *" $shape "* ]] || continue
    one 0 "$label" "$kind" "$shape" "$ba" "$bw" "$L" "$nig" "$njg" "$dist" "$seed" "$flags" "$expect" &
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
done <<< "$XC_CASES"
while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done
echo "run_bp_sr_grid_checks: $([[ $status == 0 ]] && echo ALL AS EXPECTED || echo UNEXPECTED RESULTS)"
} > "$OUT/summary.log" 2>&1
sort "$OUT/summary.log"
python3 - "$OUT" <<'PY' | tee "$OUT/periods.txt"
import json, sys
from pathlib import Path
rows = []
for p in sorted(Path(sys.argv[1]).glob("g*/g*/check.json")):
    d = json.loads(p.read_text())
    if d["status"] != "PASS":
        continue
    bw, nb = d["bw"], d["nb"]
    pr, pc = map(int, d["grid"].split("x"))
    S = pr + pc - 2
    ipd = bw * nb + (bw - 1) + S + 8 * pc
    rows.append((d["lap_len"], d["grid"], d["precision"], d["L"], d["blocks"], d["mode"], d["block_len"],
                 d["measured_periods"] or "-", d["formula_per_pe_laps"], d["formula_bp_ring_per_pe_laps"], ipd,
                 d["data_edge_utilization"], round(bw * nb / d["formula_bp_ring_per_pe_laps"], 4),
                 round(bw * nb / ipd, 4), p.parent.name))
print("\nSR grid block periods (passing runs; feasibility shown by the bit-exact run, multi-block runs also"
      " measure the drain-start spacing):\n  lap_g grid prec L blocks mode block_len measured"
      " formula(BW*NB+LAP_G*(BW-1)+S+8*P_C) bp_ring_formula ipd_formula util_sr util_bp_ring util_ipd case")
for r in sorted(rows):
    print("  " + " ".join(str(x) for x in r))
PY
grep -q 'ALL AS EXPECTED' "$OUT/summary.log"
