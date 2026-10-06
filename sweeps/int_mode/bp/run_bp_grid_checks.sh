#!/bin/bash
# BP INT mode on a PE grid with the per-PE lap enable (RTL).
#
# Grid: designs/payn/variants/signed_segmented_csa_bp/inner_pe_grid_signed_segmented_csa_bp.sv
# Bench: designs/payn/tb/test_pe_grid_bp.sv (systolic skew applied by the
# bench, ring_in per PE row with that row's A skew, global shift_in only for
# the final drain).  Checker: sweeps/int_mode/bp/check_bp_grid_trace.py
# (every drained tile and every combined output bit-exact vs numpy int64,
# drain edges, every PE's lap runs recorded from the RTL ring_q, and the
# scheduled block period vs
#   BW*NB + 8*(BW-1) + (P_R+P_C-2) + 8*P_C;
# multi-block runs also measure the drain-start spacing).
#
# Matrix: shapes 4x1, 2x2, 2x3, 3x2, 4x4, 4x8; INT8, W4A8, INT4; multi-block
# back-to-back (blocks along both the activation-row and the output-column
# groups, 4x8 included); extremes; JUNK; RING_GATE_JUNK (int_mode high only
# while some row injects, junk ring_in otherwise: the west-edge gate, and a
# wave in flight finishing after int_mode falls); L=4096 for the utilization
# table.  Positive control: the global-lap schedule (GLOBAL_LAP_WAIT: every
# PE's ring_in FORCED to one broadcast signal, shift_in on the lap edges,
# each lap waits S edges; the grid's own ring wave cannot make simultaneous
# laps for P_C > 1).  Negative controls that must fail with tile mismatches:
#   NEG_RING_NO_ROW_SKEW  ring wave not skewed per PE row
#   NEG_RING_NO_COL_SKEW  ring wave not skewed per PE column (broadcast)
#   NEG_GLOBAL_LAP        laps issued globally without waiting for the skew
#   NEG_GAP_SHORT         tightness, lap term: GAP = 7 (lap on the last MAC)
#   NEG_DRAIN_EARLY       tightness, skew term: drain at S-1
#   NEG_BLOCK_OVERLAP     tightness, drain term: next block one edge early
#   NEG_GATE_BYPASS       RING_GATE_JUNK with the west int_mode gate bypassed
#                         (forced): the junk starts stray laps
#   OLDC_UNFORCED         the old single-PE contract on the grid with nothing
#                         forced (one global ring signal on every row, shift_in
#                         on the lap edges): passes on 4x1 (P_C = 1), must fail
#                         for P_C > 1
# and an as-built cross-check: the same grid built from the csa_bp_20261003b
# RTL snapshot must FAIL per-PE laps (ring_q alone did not shift) and PASS the
# global-lap schedule.
#
# The independent adversarial grid harness (reset/abort, int_mode drops with
# a wave in flight, SC ring junk, one-edge faults, 1xN / Nx1 shapes) is
# sweeps/int_mode/bp/verify_grid/run_vg.sh.
#
#   bash sweeps/int_mode/bp/run_bp_grid_checks.sh
#   SHAPES="2x2" bash sweeps/int_mode/bp/run_bp_grid_checks.sh   # subset
#   OUT=<dir, absolute or relative to the repo>
# Logs: build/rtl_preflight/csa_bp_grid/{summary.log,compile_<shape>.log,<case>/}
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$REPO"
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
OUT=$(realpath -m "${OUT:-build/rtl_preflight/csa_bp_grid}")
MAX_JOBS=${MAX_JOBS:-8}
SHAPES=${SHAPES:-"4x1 2x2 2x3 3x2 4x4 4x8"}
TB=designs/payn/tb/test_pe_grid_bp.sv
SNAP=$(realpath -m "${ASBUILT_SNAPSHOT:-build/power_char/int_mode_energy_20261003/bp/csa_bp_20261003b_distguide_spp_pins/rtl_snapshot}")
mkdir -p "$OUT"

compile() {   # tag P_R P_C [extra incdir first]
    local tag=$1 pr=$2 pc=$3 inc=${4:-} b="$OUT/build_$1"
    rm -rf "$b"; mkdir -p "$b"
    vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp \
        ${inc:+"+incdir+$inc"} +incdir+designs -assert svaext -timescale=1ns/1ps \
        +define+BPG_PR=$pr+define+BPG_PC=$pc \
        -o "$b/simv" -Mdir="$b/obj" \
        -y "$SYNOPSYS/dw/sim_ver" +libext+.v+ +incdir+"$SYNOPSYS/dw/sim_ver" \
        "$TB" -top Top > "$OUT/compile_$tag.log" 2>&1 \
        || { echo "compile $tag FAILED: $OUT/compile_$tag.log"; return 1; }
}

# label shape BA BW L NIG NJG DIST SEED FLAGS EXPECT  (EXPECT: pass | fail)
CASES=$(cat <<'EOF'
g4x1_int8_uniform_L256_b2x1        4x1 8 8  256 2 1 uniform    81 JUNK                 pass
g4x1_w4a8_gatejunk_L384_b1x2       4x1 8 4  384 1 2 uniform    82 RING_GATE_JUNK       pass
g4x1_int8_oldc_unforced_L256_b2x1  4x1 8 8  256 2 1 uniform    83 OLDC_UNFORCED,JUNK   pass
g4x1_neg_drain_early               4x1 8 8  256 1 1 uniform    84 NEG_DRAIN_EARLY      fail
g2x2_int8_uniform_L256_b2x1        2x2 8 8  256 2 1 uniform     1 -                    pass
g2x2_int8_uniform_L384_b1x2_junk   2x2 8 8  384 1 2 uniform     2 JUNK                 pass
g2x2_w4a8_uniform_L512_b2x1        2x2 8 4  512 2 1 uniform     3 -                    pass
g2x2_int4_uniform_L256_b1x2        2x2 4 4  256 1 2 uniform     4 -                    pass
g2x2_int8_allmin_L1024_b1x1        2x2 8 8 1024 1 1 allmin      0 -                    pass
g2x2_int8_neg1xmin_L512_b2x1       2x2 8 8  512 2 1 neg1xmin    0 -                    pass
g2x2_int8_globalwait_L256_b2x1     2x2 8 8  256 2 1 uniform     5 GLOBAL_LAP_WAIT      pass
g2x2_neg_ring_no_row_skew          2x2 8 8  256 1 1 uniform     6 NEG_RING_NO_ROW_SKEW fail
g2x2_neg_ring_no_col_skew          2x2 8 8  256 1 1 uniform     7 NEG_RING_NO_COL_SKEW fail
g2x2_neg_global_lap                2x2 8 8  256 1 1 uniform     8 NEG_GLOBAL_LAP       fail
g2x2_int8_gatejunk_L256_b2x1       2x2 8 8  256 2 1 uniform     9 RING_GATE_JUNK,JUNK  pass
g2x2_neg_gap_short                 2x2 8 8  256 1 1 uniform    61 NEG_GAP_SHORT        fail
g2x2_neg_drain_early               2x2 8 8  256 1 1 uniform    62 NEG_DRAIN_EARLY      fail
g2x2_neg_block_overlap             2x2 8 8  256 2 1 uniform    63 NEG_BLOCK_OVERLAP    fail
g2x2_neg_oldc_unforced             2x2 8 8  256 1 1 uniform    85 OLDC_UNFORCED        fail
g2x3_int8_uniform_L256_b2x2        2x3 8 8  256 2 2 uniform    11 -                    pass
g2x3_w4a8_minxmax_L384_b1x2        2x3 8 4  384 1 2 minxmax     0 -                    pass
g2x3_int4_uniform_L384_b2x1_junk   2x3 4 4  384 2 1 uniform    12 JUNK                 pass
g2x3_int8_alternating_L256_b1x1    2x3 8 8  256 1 1 alternating 0 -                    pass
g2x3_int8_globalwait_L256_b1x2     2x3 8 8  256 1 2 uniform    13 GLOBAL_LAP_WAIT      pass
g2x3_neg_ring_no_row_skew          2x3 8 8  256 1 1 uniform    14 NEG_RING_NO_ROW_SKEW fail
g2x3_neg_ring_no_col_skew          2x3 8 8  256 1 1 uniform    15 NEG_RING_NO_COL_SKEW fail
g2x3_neg_global_lap                2x3 8 8  256 1 1 uniform    16 NEG_GLOBAL_LAP       fail
g2x3_int4_gatejunk_L256_b1x2       2x3 4 4  256 1 2 uniform    17 RING_GATE_JUNK       pass
g2x3_neg_gate_bypass               2x3 4 4  256 1 2 uniform    17 RING_GATE_JUNK,NEG_GATE_BYPASS fail
g2x3_neg_drain_early_int4          2x3 4 4  256 1 1 uniform    64 NEG_DRAIN_EARLY      fail
g3x2_int8_uniform_L384_b2x1        3x2 8 8  384 2 1 uniform    21 -                    pass
g3x2_w4a8_uniform_L256_b2x2        3x2 8 4  256 2 2 uniform    22 -                    pass
g3x2_int4_minxmax_L256_b1x2        3x2 4 4  256 1 2 minxmax     0 -                    pass
g3x2_int8_maxxmin_L256_b1x1_junk   3x2 8 8  256 1 1 maxxmin     0 JUNK                 pass
g3x2_int8_globalwait_L256_b2x1     3x2 8 8  256 2 1 uniform    23 GLOBAL_LAP_WAIT      pass
g3x2_neg_ring_no_row_skew          3x2 8 8  256 1 1 uniform    24 NEG_RING_NO_ROW_SKEW fail
g3x2_neg_ring_no_col_skew          3x2 8 8  256 1 1 uniform    25 NEG_RING_NO_COL_SKEW fail
g3x2_neg_global_lap                3x2 8 8  256 1 1 uniform    26 NEG_GLOBAL_LAP       fail
g3x2_neg_gap_short_w4a8            3x2 8 4  256 1 1 uniform    65 NEG_GAP_SHORT        fail
g4x4_int8_uniform_L256_b2x1        4x4 8 8  256 2 1 uniform    31 -                    pass
g4x4_int8_uniform_L256_b1x2_junk   4x4 8 8  256 1 2 uniform    32 JUNK                 pass
g4x4_w4a8_uniform_L384_b2x1        4x4 8 4  384 2 1 uniform    33 -                    pass
g4x4_int4_uniform_L256_b2x1        4x4 4 4  256 2 1 uniform    34 -                    pass
g4x4_int8_allmin_L512_b1x1         4x4 8 8  512 1 1 allmin      0 -                    pass
g4x4_int8_uniform_L4096_b1x1       4x4 8 8 4096 1 1 uniform    35 -                    pass
g4x4_w4a8_uniform_L4096_b1x1       4x4 8 4 4096 1 1 uniform    36 -                    pass
g4x4_int4_uniform_L4096_b1x1       4x4 4 4 4096 1 1 uniform    37 -                    pass
g4x4_int8_globalwait_L4096_b1x1    4x4 8 8 4096 1 1 uniform    35 GLOBAL_LAP_WAIT      pass
g4x4_w4a8_globalwait_L4096_b1x1    4x4 8 4 4096 1 1 uniform    36 GLOBAL_LAP_WAIT      pass
g4x4_int4_globalwait_L4096_b1x1    4x4 4 4 4096 1 1 uniform    37 GLOBAL_LAP_WAIT      pass
g4x4_int8_globalwait_L256_b1x2     4x4 8 8  256 1 2 uniform    38 GLOBAL_LAP_WAIT      pass
g4x4_neg_ring_no_row_skew          4x4 8 8  256 1 1 uniform    39 NEG_RING_NO_ROW_SKEW fail
g4x4_neg_ring_no_col_skew          4x4 8 8  256 1 1 uniform    40 NEG_RING_NO_COL_SKEW fail
g4x4_neg_global_lap                4x4 8 8  256 1 1 uniform    41 NEG_GLOBAL_LAP       fail
g4x4_w4a8_gatejunk_L256_b2x2_junk  4x4 8 4  256 2 2 uniform    42 RING_GATE_JUNK,JUNK  pass
g4x4_neg_gap_short                 4x4 8 8  256 1 1 uniform    66 NEG_GAP_SHORT        fail
g4x4_neg_drain_early               4x4 8 8  256 1 1 uniform    67 NEG_DRAIN_EARLY      fail
g4x4_neg_block_overlap             4x4 8 8  256 1 2 uniform    68 NEG_BLOCK_OVERLAP    fail
g4x8_int8_uniform_L4096_b1x1       4x8 8 8 4096 1 1 uniform    51 -                    pass
g4x8_int8_globalwait_L4096_b1x1    4x8 8 8 4096 1 1 uniform    51 GLOBAL_LAP_WAIT      pass
g4x8_w4a8_uniform_L4096_b1x1       4x8 8 4 4096 1 1 uniform    52 -                    pass
g4x8_w4a8_globalwait_L4096_b1x1    4x8 8 4 4096 1 1 uniform    52 GLOBAL_LAP_WAIT      pass
g4x8_int4_uniform_L4096_b1x1       4x8 4 4 4096 1 1 uniform    53 -                    pass
g4x8_int4_globalwait_L4096_b1x1    4x8 4 4 4096 1 1 uniform    53 GLOBAL_LAP_WAIT      pass
g4x8_int8_uniform_L256_b1x1_junk   4x8 8 8  256 1 1 uniform    54 JUNK                 pass
g4x8_int8_uniform_L256_b2x2_junk   4x8 8 8  256 2 2 uniform    55 JUNK                 pass
g4x8_int4_uniform_L384_b2x1        4x8 4 4  384 2 1 uniform    56 -                    pass
g4x8_w4a8_minxmax_L256_b1x2        4x8 8 4  256 1 2 minxmax     0 -                    pass
g4x8_int8_gatejunk_L256_b2x1       4x8 8 8  256 2 1 uniform    57 RING_GATE_JUNK       pass
g4x8_neg_gate_bypass               4x8 8 8  256 2 1 uniform    57 RING_GATE_JUNK,NEG_GATE_BYPASS fail
g4x8_neg_gap_short                 4x8 8 8  256 1 1 uniform    69 NEG_GAP_SHORT        fail
g4x8_neg_drain_early               4x8 8 8  256 1 1 uniform    70 NEG_DRAIN_EARLY      fail
g4x8_neg_block_overlap             4x8 8 8  256 2 1 uniform    71 NEG_BLOCK_OVERLAP    fail
g4x8_neg_oldc_unforced             4x8 8 8  256 1 1 uniform    86 OLDC_UNFORCED        fail
asbuilt2x2_per_pe_laps             2x2 8 8  256 2 1 uniform     1 -                    fail
asbuilt2x2_globalwait              2x2 8 8  256 2 1 uniform     5 GLOBAL_LAP_WAIT      pass
EOF
)

one() {   # label shape ba bw L nig njg dist seed flags expect
    local label=$1 shape=$2 ba=$3 bw=$4 L=$5 nig=$6 njg=$7 dist=$8 seed=$9 flags=${10} expect=${11}
    local pr=${shape%x*} pc=${shape#*x} dir="$OUT/$label" plus=() fl x tag=$shape
    [[ $label == asbuilt* ]] && tag=asbuilt$shape
    local rows_pe=$(( 8 / ba ))
    local mrows=$(( pr * rows_pe * nig )) ncols=$(( 8 * pc * njg ))
    if [[ "$flags" != - ]]; then
        IFS=, read -ra fl <<< "$flags"
        for x in "${fl[@]}"; do plus+=("+$x"); done
    fi
    rm -rf "$dir"; mkdir -p "$dir"
    python3 sweeps/int_mode/bp/gen_bp_workload.py --ba "$ba" --bw "$bw" --L "$L" \
        --mrows "$mrows" --ncols "$ncols" --dist "$dist" --seed "$seed" --out-dir "$dir" > "$dir/gen.log"
    (cd "$dir" && "$OUT/build_$tag/simv" +BA="$ba" +BW="$bw" +L="$L" +MROWS="$mrows" \
        +NCOLS="$ncols" "${plus[@]}" > sim.log 2>&1)
    grep -q '^PASS: BP grid bench' "$dir/sim.log" || { echo "$label: FAIL (simulation error, $dir/sim.log)"; return 1; }
    if python3 sweeps/int_mode/bp/check_bp_grid_trace.py "$dir" --json "$dir/check.json" > "$dir/check.log" 2>&1; then
        [[ $expect == pass ]] && { echo "$label: PASS  $(tail -1 "$dir/check.log" | sed 's/^\[PASS\] //')"; return 0; }
        echo "$label: FAIL (negative control NOT caught)  $(tail -1 "$dir/check.log")"; return 1
    fi
    grep -q '^\[FAIL\]' "$dir/check.log" || { echo "$label: FAIL (checker error, $dir/check.log)"; return 1; }
    if [[ $expect == fail ]]; then
        local nm
        nm=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['n_mismatch'])" "$dir/check.json")
        (( nm > 0 )) || { echo "$label: FAIL (failed without tile mismatches)  $(tail -1 "$dir/check.log")"; return 1; }
        echo "$label: PASS (expected failure caught: $nm tile/output mismatches)"; return 0
    fi
    echo "$label: FAIL  $(tail -1 "$dir/check.log")"; return 1
}

status=0
pids=()
for s in $SHAPES; do compile "$s" "${s%x*}" "${s#*x}" & pids+=("$!"); done
if [[ " $SHAPES " == *" 2x2 "* && -d "$SNAP" ]]; then
    compile asbuilt2x2 2 2 "$SNAP" & pids+=("$!")
fi
for p in "${pids[@]}"; do wait "$p" || status=1; done
(( status == 0 )) || { echo "run_bp_grid_checks: COMPILE FAILED"; exit 1; }

{
while read -r label shape ba bw L nig njg dist seed flags expect; do
    [[ -n "$label" ]] || continue
    [[ " $SHAPES " == *" $shape "* ]] || continue
    if [[ $label == asbuilt* && ! -x "$OUT/build_asbuilt$shape/simv" ]]; then continue; fi
    one "$label" "$shape" "$ba" "$bw" "$L" "$nig" "$njg" "$dist" "$seed" "$flags" "$expect" &
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
done <<< "$CASES"
while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done
echo "run_bp_grid_checks: $([[ $status == 0 ]] && echo ALL AS EXPECTED || echo UNEXPECTED RESULTS)"
} > "$OUT/summary.log" 2>&1
sort "$OUT/summary.log"
python3 - "$OUT" <<'PY'
import json, sys
from pathlib import Path
rows = []
for p in sorted(Path(sys.argv[1]).glob("*/check.json")):
    d = json.loads(p.read_text())
    if d["status"] != "PASS":
        continue
    rows.append((d["grid"], d["precision"], d["L"], d["mode"], d["block_len"], d["measured_periods"] or "-",
                 d["formula_per_pe_laps"],
                 d["formula_global_laps"], d["per_pass_global_bubbles"], d["data_edge_utilization"], p.parent.name))
print("\nscheduled block periods (passing runs; feasibility shown by the bit-exact run, multi-block runs also"
      " measure the drain-start spacing): grid prec L mode block_len measured per_pe_formula global_formula"
      " bubbles/pass util case")
for r in rows:
    print("  " + " ".join(str(x) for x in r))
PY
grep -q 'ALL AS EXPECTED' "$OUT/summary.log"
