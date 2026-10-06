#!/bin/bash
# BP INT mode on a PE grid of the in-place-doubling PE (RTL), 1-edge per-PE laps.
# Modelled on sweeps/int_mode/bp/run_bp_grid_checks.sh (unchanged).
#
# Grid:    designs/payn/variants/signed_segmented_csa_bp_ipd/inner_pe_grid_signed_segmented_csa_bp_ipd.sv
# Bench:   designs/payn/tb/test_pe_grid_bp_ipd.sv (copy of the BP grid bench with +LAP_LEN,
#          default 1, and +NEG_RING_STRAY; systolic skew applied by the bench,
#          ring_in per PE row with that row's A skew, global shift_in only for
#          the final drain)
# Checker: sweeps/int_mode/bp/ipd/check_bp_ipd_grid_trace.py (every drained tile
#          and every combined output bit-exact vs numpy int64, drain edges, every
#          PE's lap runs from the RTL ring_q (1 edge at offset r+c), and the
#          scheduled block period vs
#              BW*NB + 1*(BW-1) + (P_R+P_C-2) + 8*P_C;
#          multi-block runs also measure the drain-start spacing).
#
# Builds (one compile per tag):
#   ipd<shape>   the IPD bench on the IPD grid (the matrix)
#   bp<shape>    the IPD bench compiled with +define+BPG_DUT_BP (BP grid)
#   orig<shape>  the original bench test_pe_grid_bp.sv (BP grid)
# Case kinds (column 2):
#   ipd   run on ipd<shape>
#   bp    run on bp<shape>  (cross-discrimination: the BP grid with the IPD
#         schedule must FAIL)
#   xc    bench cross-check: run on orig<shape> with FLAGS and on bp<shape>
#         with FLAGS + LAP_LEN=8; the drained tiles and lap runs (every trace
#         line after the header) must be byte-identical, the headers equal up
#         to the added LAP_LEN field, and both checkers must agree with EXPECT
#
# Matrix: shapes 4x1, 2x2, 2x3, 3x2, 4x4, 4x8; INT8, W4A8, INT4; multi-block
# back to back (4x8 included, and at L=4096 on 4x4 / 4x8 so the measured
# drain-start spacing covers the table rows); extremes; JUNK (random west
# accumulators on every non-drain edge, lap edges included: the doubling mux
# must ignore them); RING_GATE_JUNK; L=1024 and L=4096 for the utilization table.
# Positive control: GLOBAL_LAP_WAIT (forced broadcast ring, 1-edge global laps
# waiting S).  Negative controls (must fail with tile mismatches):
#   LAP_LEN=0 (no lap), LAP_LEN=2 (double lap), LAP_LEN=8 (the BP ring's lap),
#   NEG_RING_STRAY (one stray ring_in[0] pulse mid-pass),
#   NEG_RING_NO_ROW_SKEW, NEG_RING_NO_COL_SKEW, NEG_GLOBAL_LAP,
#   NEG_GAP_SHORT (lap on the last MAC: no bubble), NEG_DRAIN_EARLY,
#   NEG_BLOCK_OVERLAP (tightness of every term), NEG_GATE_BYPASS,
#   OLDC_UNFORCED for P_C > 1 (passes on 4x1).
#
#   bash sweeps/int_mode/bp/ipd/run_bp_ipd_grid_checks.sh
#   SHAPES="2x2" bash sweeps/int_mode/bp/ipd/run_bp_ipd_grid_checks.sh   # subset
# Logs: build/rtl_preflight/bp_ipd/grid/{summary.log,periods.txt,compile_<tag>.log,<case>/}
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
OUT=$(realpath -m "${OUT:-build/rtl_preflight/bp_ipd/grid}")
MAX_JOBS=${MAX_JOBS:-12}
SHAPES=${SHAPES:-"4x1 2x2 2x3 3x2 4x4 4x8"}
TB=designs/payn/tb/test_pe_grid_bp_ipd.sv
TB_ORIG=designs/payn/tb/test_pe_grid_bp.sv
CHK=sweeps/int_mode/bp/ipd/check_bp_ipd_grid_trace.py
CHK_ORIG=sweeps/int_mode/bp/check_bp_grid_trace.py
mkdir -p "$OUT"

compile() {   # tag P_R P_C tb [defines]
    local tag=$1 pr=$2 pc=$3 tb=$4 def=${5:-} b="$OUT/build_$1"
    rm -rf "$b"; mkdir -p "$b"
    vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp \
        +incdir+designs -assert svaext -timescale=1ns/1ps \
        +define+BPG_PR=$pr+define+BPG_PC=$pc$def \
        -o "$b/simv" -Mdir="$b/obj" \
        -y "$SYNOPSYS/dw/sim_ver" +libext+.v+ +incdir+"$SYNOPSYS/dw/sim_ver" \
        "$tb" -top Top > "$OUT/compile_$tag.log" 2>&1 \
        || { echo "compile $tag FAILED: $OUT/compile_$tag.log"; return 1; }
}

# label kind shape BA BW L NIG NJG DIST SEED FLAGS EXPECT  (EXPECT: pass | fail)
CASES=$(cat <<'EOF'
g4x1_int8_uniform_L256_b2x1        ipd 4x1 8 8  256 2 1 uniform    81 JUNK                 pass
g4x1_w4a8_gatejunk_L384_b1x2       ipd 4x1 8 4  384 1 2 uniform    82 RING_GATE_JUNK       pass
g4x1_int8_oldc_unforced_L256_b2x1  ipd 4x1 8 8  256 2 1 uniform    83 OLDC_UNFORCED,JUNK   pass
g4x1_neg_drain_early               ipd 4x1 8 8  256 1 1 uniform    84 NEG_DRAIN_EARLY      fail
g2x2_int8_uniform_L256_b2x1        ipd 2x2 8 8  256 2 1 uniform     1 -                    pass
g2x2_int8_uniform_L384_b1x2_junk   ipd 2x2 8 8  384 1 2 uniform     2 JUNK                 pass
g2x2_w4a8_uniform_L512_b2x1        ipd 2x2 8 4  512 2 1 uniform     3 -                    pass
g2x2_int4_uniform_L256_b1x2        ipd 2x2 4 4  256 1 2 uniform     4 -                    pass
g2x2_int8_allmin_L1024_b1x1        ipd 2x2 8 8 1024 1 1 allmin      0 -                    pass
g2x2_int8_neg1xmin_L512_b2x1       ipd 2x2 8 8  512 2 1 neg1xmin    0 -                    pass
g2x2_int8_globalwait_L256_b2x1     ipd 2x2 8 8  256 2 1 uniform     5 GLOBAL_LAP_WAIT      pass
g2x2_neg_ring_no_row_skew          ipd 2x2 8 8  256 1 1 uniform     6 NEG_RING_NO_ROW_SKEW fail
g2x2_neg_ring_no_col_skew          ipd 2x2 8 8  256 1 1 uniform     7 NEG_RING_NO_COL_SKEW fail
g2x2_neg_global_lap                ipd 2x2 8 8  256 1 1 uniform     8 NEG_GLOBAL_LAP       fail
g2x2_int8_gatejunk_L256_b2x1       ipd 2x2 8 8  256 2 1 uniform     9 RING_GATE_JUNK,JUNK  pass
g2x2_neg_gap_short                 ipd 2x2 8 8  256 1 1 uniform    61 NEG_GAP_SHORT        fail
g2x2_neg_drain_early               ipd 2x2 8 8  256 1 1 uniform    62 NEG_DRAIN_EARLY      fail
g2x2_neg_block_overlap             ipd 2x2 8 8  256 2 1 uniform    63 NEG_BLOCK_OVERLAP    fail
g2x2_neg_oldc_unforced             ipd 2x2 8 8  256 1 1 uniform    85 OLDC_UNFORCED        fail
g2x2_neg_lap0                      ipd 2x2 8 8  256 1 1 uniform    91 LAP_LEN=0            fail
g2x2_neg_lap2                      ipd 2x2 8 8  256 1 1 uniform    92 LAP_LEN=2            fail
g2x2_neg_lap8                      ipd 2x2 8 8  256 1 1 uniform    93 LAP_LEN=8            fail
g2x2_neg_ring_stray                ipd 2x2 8 8  256 1 1 uniform    94 NEG_RING_STRAY       fail
g2x3_int8_uniform_L256_b2x2        ipd 2x3 8 8  256 2 2 uniform    11 -                    pass
g2x3_w4a8_minxmax_L384_b1x2        ipd 2x3 8 4  384 1 2 minxmax     0 -                    pass
g2x3_int4_uniform_L384_b2x1_junk   ipd 2x3 4 4  384 2 1 uniform    12 JUNK                 pass
g2x3_int8_alternating_L256_b1x1    ipd 2x3 8 8  256 1 1 alternating 0 -                    pass
g2x3_int8_globalwait_L256_b1x2     ipd 2x3 8 8  256 1 2 uniform    13 GLOBAL_LAP_WAIT      pass
g2x3_neg_ring_no_row_skew          ipd 2x3 8 8  256 1 1 uniform    14 NEG_RING_NO_ROW_SKEW fail
g2x3_neg_ring_no_col_skew          ipd 2x3 8 8  256 1 1 uniform    15 NEG_RING_NO_COL_SKEW fail
g2x3_neg_global_lap                ipd 2x3 8 8  256 1 1 uniform    16 NEG_GLOBAL_LAP       fail
g2x3_int4_gatejunk_L256_b1x2       ipd 2x3 4 4  256 1 2 uniform    17 RING_GATE_JUNK       pass
g2x3_neg_gate_bypass               ipd 2x3 4 4  256 1 2 uniform    17 RING_GATE_JUNK,NEG_GATE_BYPASS fail
g2x3_neg_drain_early_int4          ipd 2x3 4 4  256 1 1 uniform    64 NEG_DRAIN_EARLY      fail
g2x3_neg_lap2_int4                 ipd 2x3 4 4  256 1 1 uniform    95 LAP_LEN=2            fail
g3x2_int8_uniform_L384_b2x1        ipd 3x2 8 8  384 2 1 uniform    21 -                    pass
g3x2_w4a8_uniform_L256_b2x2        ipd 3x2 8 4  256 2 2 uniform    22 -                    pass
g3x2_int4_minxmax_L256_b1x2        ipd 3x2 4 4  256 1 2 minxmax     0 -                    pass
g3x2_int8_maxxmin_L256_b1x1_junk   ipd 3x2 8 8  256 1 1 maxxmin     0 JUNK                 pass
g3x2_int8_globalwait_L256_b2x1     ipd 3x2 8 8  256 2 1 uniform    23 GLOBAL_LAP_WAIT      pass
g3x2_neg_ring_no_row_skew          ipd 3x2 8 8  256 1 1 uniform    24 NEG_RING_NO_ROW_SKEW fail
g3x2_neg_ring_no_col_skew          ipd 3x2 8 8  256 1 1 uniform    25 NEG_RING_NO_COL_SKEW fail
g3x2_neg_global_lap                ipd 3x2 8 8  256 1 1 uniform    26 NEG_GLOBAL_LAP       fail
g3x2_neg_gap_short_w4a8            ipd 3x2 8 4  256 1 1 uniform    65 NEG_GAP_SHORT        fail
g4x4_int8_uniform_L256_b2x1        ipd 4x4 8 8  256 2 1 uniform    31 -                    pass
g4x4_int8_uniform_L256_b1x2_junk   ipd 4x4 8 8  256 1 2 uniform    32 JUNK                 pass
g4x4_w4a8_uniform_L384_b2x1        ipd 4x4 8 4  384 2 1 uniform    33 -                    pass
g4x4_int4_uniform_L256_b2x1        ipd 4x4 4 4  256 2 1 uniform    34 -                    pass
g4x4_int8_allmin_L512_b1x1         ipd 4x4 8 8  512 1 1 allmin      0 -                    pass
g4x4_int8_uniform_L1024_b1x1       ipd 4x4 8 8 1024 1 1 uniform    38 -                    pass
g4x4_int8_uniform_L1024_b1x2_junk  ipd 4x4 8 8 1024 1 2 uniform    39 JUNK                 pass
g4x4_int8_uniform_L4096_b1x1       ipd 4x4 8 8 4096 1 1 uniform    35 -                    pass
g4x4_int8_uniform_L4096_b2x1       ipd 4x4 8 8 4096 2 1 uniform    40 -                    pass
g4x4_w4a8_uniform_L4096_b1x1       ipd 4x4 8 4 4096 1 1 uniform    36 -                    pass
g4x4_int4_uniform_L4096_b1x1       ipd 4x4 4 4 4096 1 1 uniform    37 -                    pass
g4x4_int8_globalwait_L4096_b1x1    ipd 4x4 8 8 4096 1 1 uniform    35 GLOBAL_LAP_WAIT      pass
g4x4_neg_ring_no_row_skew          ipd 4x4 8 8  256 1 1 uniform    41 NEG_RING_NO_ROW_SKEW fail
g4x4_neg_ring_no_col_skew          ipd 4x4 8 8  256 1 1 uniform    42 NEG_RING_NO_COL_SKEW fail
g4x4_neg_global_lap                ipd 4x4 8 8  256 1 1 uniform    43 NEG_GLOBAL_LAP       fail
g4x4_w4a8_gatejunk_L256_b2x2_junk  ipd 4x4 8 4  256 2 2 uniform    44 RING_GATE_JUNK,JUNK  pass
g4x4_neg_gap_short                 ipd 4x4 8 8  256 1 1 uniform    66 NEG_GAP_SHORT        fail
g4x4_neg_drain_early               ipd 4x4 8 8  256 1 1 uniform    67 NEG_DRAIN_EARLY      fail
g4x4_neg_block_overlap             ipd 4x4 8 8  256 1 2 uniform    68 NEG_BLOCK_OVERLAP    fail
g4x4_neg_lap0                      ipd 4x4 8 8  256 1 1 uniform    96 LAP_LEN=0            fail
g4x4_neg_lap2                      ipd 4x4 8 8  256 1 1 uniform    97 LAP_LEN=2            fail
g4x4_neg_ring_stray                ipd 4x4 8 8  256 1 1 uniform    98 NEG_RING_STRAY       fail
g4x8_int8_uniform_L1024_b1x1       ipd 4x8 8 8 1024 1 1 uniform    58 -                    pass
g4x8_int8_uniform_L4096_b1x1       ipd 4x8 8 8 4096 1 1 uniform    51 -                    pass
g4x8_int8_uniform_L4096_b1x2       ipd 4x8 8 8 4096 1 2 uniform    59 -                    pass
g4x8_int8_globalwait_L4096_b1x1    ipd 4x8 8 8 4096 1 1 uniform    51 GLOBAL_LAP_WAIT      pass
g4x8_w4a8_uniform_L4096_b1x1       ipd 4x8 8 4 4096 1 1 uniform    52 -                    pass
g4x8_int4_uniform_L4096_b1x1       ipd 4x8 4 4 4096 1 1 uniform    53 -                    pass
g4x8_int8_uniform_L256_b1x1_junk   ipd 4x8 8 8  256 1 1 uniform    54 JUNK                 pass
g4x8_int8_uniform_L256_b2x2_junk   ipd 4x8 8 8  256 2 2 uniform    55 JUNK                 pass
g4x8_int4_uniform_L384_b2x1        ipd 4x8 4 4  384 2 1 uniform    56 -                    pass
g4x8_w4a8_minxmax_L256_b1x2        ipd 4x8 8 4  256 1 2 minxmax     0 -                    pass
g4x8_int8_gatejunk_L256_b2x1       ipd 4x8 8 8  256 2 1 uniform    57 RING_GATE_JUNK       pass
g4x8_neg_gate_bypass               ipd 4x8 8 8  256 2 1 uniform    57 RING_GATE_JUNK,NEG_GATE_BYPASS fail
g4x8_neg_gap_short                 ipd 4x8 8 8  256 1 1 uniform    69 NEG_GAP_SHORT        fail
g4x8_neg_drain_early               ipd 4x8 8 8  256 1 1 uniform    70 NEG_DRAIN_EARLY      fail
g4x8_neg_block_overlap             ipd 4x8 8 8  256 2 1 uniform    71 NEG_BLOCK_OVERLAP    fail
g4x8_neg_oldc_unforced             ipd 4x8 8 8  256 1 1 uniform    86 OLDC_UNFORCED        fail
g4x8_neg_lap2                      ipd 4x8 8 8  256 1 1 uniform    99 LAP_LEN=2            fail
g4x8_neg_ring_stray                ipd 4x8 8 8  256 1 1 uniform   100 NEG_RING_STRAY       fail
bpg2x2_with_ipd_schedule           bp  2x2 8 8  256 2 1 uniform     1 LAP_LEN=1            fail
bpg4x4_with_ipd_schedule           bp  4x4 8 8  256 1 1 uniform    31 LAP_LEN=1            fail
xc2x2_int8_uniform_L256_b2x1       xc  2x2 8 8  256 2 1 uniform     1 -                    pass
xc2x2_int8_uniform_L384_b1x2_junk  xc  2x2 8 8  384 1 2 uniform     2 JUNK                 pass
xc2x2_int8_globalwait_L256_b2x1    xc  2x2 8 8  256 2 1 uniform     5 GLOBAL_LAP_WAIT      pass
xc2x2_neg_gap_short                xc  2x2 8 8  256 1 1 uniform    61 NEG_GAP_SHORT        fail
xc2x3_int4_uniform_L384_b2x1_junk  xc  2x3 4 4  384 2 1 uniform    12 JUNK                 pass
xc2x3_int4_gatejunk_L256_b1x2      xc  2x3 4 4  256 1 2 uniform    17 RING_GATE_JUNK       pass
xc4x4_int8_uniform_L4096_b1x1      xc  4x4 8 8 4096 1 1 uniform    35 -                    pass
xc4x4_int8_uniform_L1024_b1x1      xc  4x4 8 8 1024 1 1 uniform    38 -                    pass
xc4x4_w4a8_uniform_L4096_b1x1      xc  4x4 8 4 4096 1 1 uniform    36 -                    pass
xc4x4_w4a8_gatejunk_L256_b2x2_junk xc  4x4 8 4  256 2 2 uniform    42 RING_GATE_JUNK,JUNK  pass
xc4x4_neg_drain_early              xc  4x4 8 8  256 1 1 uniform    67 NEG_DRAIN_EARLY      fail
xc4x8_int8_uniform_L4096_b1x1      xc  4x8 8 8 4096 1 1 uniform    51 -                    pass
xc4x8_int8_uniform_L1024_b1x1      xc  4x8 8 8 1024 1 1 uniform    58 -                    pass
xc4x8_int4_uniform_L4096_b1x1      xc  4x8 4 4 4096 1 1 uniform    53 -                    pass
xc4x8_int8_uniform_L256_b2x2_junk  xc  4x8 8 8  256 2 2 uniform    55 JUNK                 pass
xc4x8_neg_block_overlap            xc  4x8 8 8  256 2 1 uniform    71 NEG_BLOCK_OVERLAP    fail
EOF
)

# run one simulation + check; prints nothing, returns 0 if the outcome matches EXPECT.
sim_check() {   # dir simv checker ba bw L mrows ncols dist seed flags expect -> sets RESULT
    local dir=$1 simv=$2 chk=$3 ba=$4 bw=$5 L=$6 mrows=$7 ncols=$8 dist=$9 seed=${10} flags=${11} expect=${12}
    local plus=() fl x nm
    if [[ "$flags" != - ]]; then
        IFS=, read -ra fl <<< "$flags"
        for x in "${fl[@]}"; do plus+=("+$x"); done
    fi
    rm -rf "$dir"; mkdir -p "$dir"
    python3 sweeps/int_mode/bp/gen_bp_workload.py --ba "$ba" --bw "$bw" --L "$L" \
        --mrows "$mrows" --ncols "$ncols" --dist "$dist" --seed "$seed" --out-dir "$dir" > "$dir/gen.log"
    (cd "$dir" && "$simv" +BA="$ba" +BW="$bw" +L="$L" +MROWS="$mrows" \
        +NCOLS="$ncols" "${plus[@]}" > sim.log 2>&1)
    grep -q '^PASS: BP grid bench' "$dir/sim.log" || { RESULT="FAIL (simulation error, $dir/sim.log)"; return 1; }
    if python3 "$chk" "$dir" --json "$dir/check.json" > "$dir/check.log" 2>&1; then
        [[ $expect == pass ]] && { RESULT="PASS  $(tail -1 "$dir/check.log" | sed 's/^\[PASS\] //')"; return 0; }
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

one() {   # label kind shape ba bw L nig njg dist seed flags expect
    local label=$1 kind=$2 shape=$3 ba=$4 bw=$5 L=$6 nig=$7 njg=$8 dist=$9 seed=${10} flags=${11} expect=${12}
    local pr=${shape%x*} pc=${shape#*x} dir="$OUT/$label" RESULT r1 r2 f8
    local rows_pe=$(( 8 / ba ))
    local mrows=$(( pr * rows_pe * nig )) ncols=$(( 8 * pc * njg ))
    case $kind in
        ipd|bp)
            sim_check "$dir" "$OUT/build_$kind$shape/simv" "$CHK" "$ba" "$bw" "$L" "$mrows" "$ncols" \
                "$dist" "$seed" "$flags" "$expect"
            local rc=$?; echo "$label: $RESULT"; return $rc ;;
        xc)
            [[ $flags == - ]] && f8=LAP_LEN=8 || f8="$flags,LAP_LEN=8"
            sim_check "$dir/orig" "$OUT/build_orig$shape/simv" "$CHK_ORIG" "$ba" "$bw" "$L" "$mrows" "$ncols" \
                "$dist" "$seed" "$flags" "$expect" || { echo "$label: FAIL (original bench: $RESULT)"; return 1; }
            r1=$RESULT
            sim_check "$dir/gen_lap8" "$OUT/build_bp$shape/simv" "$CHK" "$ba" "$bw" "$L" "$mrows" "$ncols" \
                "$dist" "$seed" "$f8" "$expect" || { echo "$label: FAIL (IPD bench +LAP_LEN=8 on BP grid: $RESULT)"; return 1; }
            cmp -s <(tail -n +2 "$dir/orig/bpg_trace.txt") <(tail -n +2 "$dir/gen_lap8/bpg_trace.txt") \
                || { echo "$label: FAIL (trace bodies differ)"; return 1; }
            [[ "$(head -1 "$dir/orig/bpg_trace.txt") 8" == "$(head -1 "$dir/gen_lap8/bpg_trace.txt")" ]] \
                || { echo "$label: FAIL (headers differ beyond the LAP_LEN field)"; return 1; }
            echo "$label: PASS (bench cross-check: original bench and IPD bench +LAP_LEN=8 on the BP grid, $(( $(wc -l < "$dir/orig/bpg_trace.txt") - 1 )) trace lines identical; original bench: ${r1#PASS })"
            return 0 ;;
    esac
}

status=0
pids=()
for s in $SHAPES; do
    compile "ipd$s" "${s%x*}" "${s#*x}" "$TB" & pids+=("$!")
    if grep -qE "^\S+\s+(xc|bp)\s+$s\s" <<< "$CASES"; then
        compile "bp$s" "${s%x*}" "${s#*x}" "$TB" "+define+BPG_DUT_BP" & pids+=("$!")
    fi
    if grep -qE "^\S+\s+xc\s+$s\s" <<< "$CASES"; then
        compile "orig$s" "${s%x*}" "${s#*x}" "$TB_ORIG" & pids+=("$!")
    fi
done
for p in "${pids[@]}"; do wait "$p" || status=1; done
(( status == 0 )) || { echo "run_bp_ipd_grid_checks: COMPILE FAILED"; exit 1; }
for s in $SHAPES; do
    grep -q "signed_segmented_csa_bp_ipd/inner_pe_core_signed_segmented_csa_ipd.sv" "$OUT/compile_ipd$s.log" \
        || { echo "ipd$s did not compile the IPD core"; exit 1; }
done

{
while read -r label kind shape ba bw L nig njg dist seed flags expect; do
    [[ -n "$label" ]] || continue
    [[ " $SHAPES " == *" $shape "* ]] || continue
    one "$label" "$kind" "$shape" "$ba" "$bw" "$L" "$nig" "$njg" "$dist" "$seed" "$flags" "$expect" &
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
done <<< "$CASES"
while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done
echo "run_bp_ipd_grid_checks: $([[ $status == 0 ]] && echo ALL AS EXPECTED || echo UNEXPECTED RESULTS)"
} > "$OUT/summary.log" 2>&1
sort "$OUT/summary.log"
python3 - "$OUT" <<'PY' | tee "$OUT/periods.txt"
import json, sys
from pathlib import Path
rows = []
for p in sorted(Path(sys.argv[1]).glob("g*/check.json")):
    d = json.loads(p.read_text())
    if d["status"] != "PASS":
        continue
    rows.append((d["grid"], d["precision"], d["L"], d["blocks"], d["mode"], d["lap_len"], d["block_len"],
                 d["measured_periods"] or "-", d["formula_per_pe_laps"], d["formula_bp_ring_per_pe_laps"],
                 d["data_edge_utilization"], round(d["bw"] * d["nb"] / d["formula_bp_ring_per_pe_laps"], 4),
                 p.parent.name))
print("\nIPD grid block periods (passing runs; feasibility shown by the bit-exact run, multi-block runs also"
      " measure the drain-start spacing):\n  grid prec L blocks mode lap_len block_len measured"
      " formula(BW*NB+LAP_LEN*(BW-1)+S+8*P_C) bp_ring_formula util_ipd util_bp_ring case")
for r in sorted(rows):
    print("  " + " ".join(str(x) for x in r))
ring = []
for p in sorted(Path(sys.argv[1]).glob("xc*/orig/check.json")):
    d = json.loads(p.read_text())
    if d["status"] != "PASS":
        continue
    ring.append((d["grid"], d["precision"], d["L"], d["blocks"], d["mode"], d["block_len"],
                 d["measured_periods"] or "-", d["formula_per_pe_laps"], d["data_edge_utilization"],
                 p.parent.parent.name))
print("\nBP-ring grid (csa_bp_20261004_lap RTL, original bench, 8-edge laps) block periods from the cross-check runs:\n"
      "  grid prec L blocks mode block_len measured formula(BW*NB+8*(BW-1)+S+8*P_C) util case")
for r in sorted(ring):
    print("  " + " ".join(str(x) for x in r))
PY
grep -q 'ALL AS EXPECTED' "$OUT/summary.log"
