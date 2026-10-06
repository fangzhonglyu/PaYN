#!/bin/bash
# Fix stage of the BP lap-schedule study: extra RTL runs of the BP-hybrid
# schedule H(TA,TW) on the UNCHANGED csa_bp_20261004_lap grid RTL, beyond the
# adversarial review's matrix (run_bp_hybrid_checks.sh, which is not changed):
#   * the 24-bit range edge of INT8 H(4,8): L = 4352 (largest multiple of 128
#     <= 4,369) with the worst-case operands (|tile| = 1920 * 4352 = 8,355,840);
#   * W4A8 H(8,4) and INT4 H(4,4) (the round-1 'HB' corner) on 4x8, multi-block;
#   * INT8 H(2,8), H(4,4) at L = 8192 and H(2,4) (TW < BW: weight-bit groups
#     across tile columns plus activation bits in time; the model's best INT8
#     point at L = 65,536), incl. its range case;
#   * a 3x2 grid (P_R > P_C, not in the review) and 1-PE W4A8 / INT4;
#   * negative controls on the new shapes.
# Bench designs/payn/tb/test_pe_grid_bp_hybrid.sv and checker
# sweeps/int_mode/bp/hybrid/check_bp_hybrid_trace.py, both used unchanged.
#
#   bash sweeps/int_mode/bp/hybrid/run_bp_hybrid_fix_checks.sh      [OUT=...] [MAX_JOBS=<n>]
# Logs: build/rtl_preflight/bp_hybrid_fix/{summary.log,hyb/<case>/,compile_*.log}
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
OUT=$(realpath -m "${OUT:-build/rtl_preflight/bp_hybrid_fix}")
MAX_JOBS=${MAX_JOBS:-12}
TB_H=designs/payn/tb/test_pe_grid_bp_hybrid.sv
GEN=sweeps/int_mode/bp/space/gen_bp_space_workload.py
CHECK_H=sweeps/int_mode/bp/hybrid/check_bp_hybrid_trace.py
mkdir -p "$OUT/hyb"

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
f4x4_int8_ta4tw8_neg1xmin_L4352_m16n32_range    4x4 8 8 4 8 4352 16  32 neg1xmin     0 -                 pass
f4x4_int8_ta4tw8_maxxmin_L4352_m16n32_junk      4x4 8 8 4 8 4352 16  32 maxxmin      0 JUNK              pass
f4x4_int8_ta4tw8_gauss_L2048_m32n64             4x4 8 8 4 8 2048 32  64 gauss      611 -                 pass
f4x8_w4a8_ta8tw4_uniform_L4096_m32n128          4x8 8 4 8 4 4096 32 128 uniform    612 -                 pass
f4x8_int4_ta4tw4_uniform_L4096_m32n128          4x8 4 4 4 4 4096 32 128 uniform    613 -                 pass
f4x8_int8_ta2tw8_uniform_L4096_m8n128           4x8 8 8 2 8 4096  8 128 uniform    614 -                 pass
f4x4_int8_ta4tw4_uniform_L8192_m16n32           4x4 8 8 4 4 8192 16  32 uniform    615 -                 pass
f4x4_int8_ta2tw8_relu_L8192_m8n64_junk          4x4 8 8 2 8 8192  8  64 relu       616 JUNK              pass
f4x4_int8_ta2tw4_uniform_L4096_m8n32            4x4 8 8 2 4 4096  8  32 uniform    617 -                 pass
f4x4_int8_ta2tw4_neg1xmin_L8192_m8n16           4x4 8 8 2 4 8192  8  16 neg1xmin     0 -                 pass
f3x2_int8_ta4tw8_uniform_L1024_m24n32           3x2 8 8 4 8 1024 24  32 uniform    618 -                 pass
f3x2_int8_ta8tw8_uniform_L384_m48n16_junk       3x2 8 8 8 8  384 48  16 uniform    619 JUNK              pass
f3x2_w4a8_ta8tw4_alternating_L2048_m24n32       3x2 8 4 8 4 2048 24  32 alternating  0 -                 pass
f1x1_int4_ta4tw4_uniform_L1024_m16n16           1x1 4 4 4 4 1024 16  16 uniform    620 -                 pass
f1x1_w4a8_ta8tw4_relu_L1024_m8n16_junk          1x1 8 4 8 4 1024  8  16 relu       621 JUNK              pass
f1x1_int8_ta4tw8_allmin_L4352_m4n8              1x1 8 8 4 8 4352  4   8 allmin       0 -                 pass
f4x8_neg_gapshort_w4a8_ta8tw4                   4x8 8 4 8 4  256 32  64 uniform    691 NEG_GAP_SHORT     fail
f4x8_neg_overlap_int4_ta4tw4                    4x8 4 4 4 4  256 32 128 uniform    692 NEG_BLOCK_OVERLAP fail
f3x2_neg_asignheld_int8_ta4tw8                  3x2 8 8 4 8  256 12  16 uniform    693 NEG_ASIGN_HELD    fail
f3x2_neg_drainearly_int8_ta4tw8                 3x2 8 8 4 8  256 12  16 uniform    694 NEG_DRAIN_EARLY   fail
f4x4_neg_gapshort_int8_ta2tw4                   4x4 8 8 2 4  256  8  16 uniform    695 NEG_GAP_SHORT     fail
EOF
)

one() {   # label shape ba bw ta tw L mrows ncols dist seed flags expect
    local label=$1 shape=$2 ba=$3 bw=$4 ta=$5 tw=$6 L=$7 mrows=$8 ncols=$9 dist=${10} seed=${11} flags=${12} expect=${13}
    local simv="$OUT/build_h$shape/simv" plus=(+TA="$ta" +TW="$tw") fl f dir="$OUT/hyb/$label"
    if [[ "$flags" != - ]]; then IFS=, read -ra fl <<< "$flags"; for f in "${fl[@]}"; do plus+=("+$f"); done; fi
    rm -rf "$dir"; mkdir -p "$dir"
    python3 "$GEN" --ba "$ba" --bw "$bw" --L "$L" --mrows "$mrows" --ncols "$ncols" \
        --dist "$dist" --seed "$seed" --out-dir "$dir" > "$dir/gen.log" || { echo "$label: FAIL (generator)"; return 1; }
    (cd "$dir" && "$simv" +BA="$ba" +BW="$bw" +L="$L" +MROWS="$mrows" +NCOLS="$ncols" "${plus[@]}" > sim.log 2>&1)
    grep -q '^PASS: BP' "$dir/sim.log" || { echo "$label: FAIL (simulation error, $dir/sim.log)"; return 1; }
    local rc=0
    python3 "$CHECK_H" "$dir" --json "$dir/check.json" > "$dir/check.log" 2>&1 || rc=$?
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

status=0
pids=()
for s in 1x1 3x2 4x4 4x8; do
    vcs_build "h$s" "$TB_H" "+define+BPG_PR=${s%x*}+define+BPG_PC=${s#*x}" & pids+=("$!")
done
for p in "${pids[@]}"; do wait "$p" || status=1; done
(( status == 0 )) || { echo "run_bp_hybrid_fix_checks: COMPILE FAILED"; exit 1; }

{
while read -r label shape ba bw ta tw L mrows ncols dist seed flags expect; do
    [[ -n "$label" ]] || continue
    one "$label" "$shape" "$ba" "$bw" "$ta" "$tw" "$L" "$mrows" "$ncols" "$dist" "$seed" "$flags" "$expect" &
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
done <<< "$HCASES"
while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done
echo "run_bp_hybrid_fix_checks: $([[ $status == 0 ]] && echo ALL AS EXPECTED || echo UNEXPECTED RESULTS)"
} > "$OUT/summary.log" 2>&1
grep -v -i zoxide "$OUT/summary.log" | grep -v '^$' | sort
grep -q 'ALL AS EXPECTED' "$OUT/summary.log" && ! grep -q ': FAIL' "$OUT/summary.log"
