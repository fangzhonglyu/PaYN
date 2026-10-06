#!/bin/bash
# Fix stage of the BP lap-schedule study: the BP-hybrid schedule H(TA,TW) on the
# UNCHANGED single-PE BP top (payn_array_signed_segmented_csa_bp,
# csa_bp_20261004_lap RTL), with the proposed hybrid east-edge combine
# (designs/payn/variants/signed_segmented_csa_bp_hyb/bp_hybrid_combiner.sv) as
# a sidecar on acc_out_east.  The review ran H only on the grid wrapper, which
# has no peripheral and no combiner.
#   bench    designs/payn/tb/test_payn_array_bp_hybrid.sv
#   checker  sweeps/int_mode/bp/hybrid/check_bp_hybrid_top_trace.py
#   xref     TA=1, TW=BW (the T1 mapping) must give D / C records byte-identical
#            to the proof's single-PE T2 bench at S=1 (test_payn_array_bp_space.sv,
#            compiled fresh here, not changed) on the same operands.
#
#   bash sweeps/int_mode/bp/hybrid/run_bp_hybrid_top_checks.sh     [OUT=...] [MAX_JOBS=<n>]
# Logs: build/rtl_preflight/bp_hybrid_top/{summary.log,hyb/<case>/,xref/<case>/,compile_*.log}
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
OUT=$(realpath -m "${OUT:-build/rtl_preflight/bp_hybrid_top}")
MAX_JOBS=${MAX_JOBS:-12}
TB=designs/payn/tb/test_payn_array_bp_hybrid.sv
TB_S=designs/payn/tb/test_payn_array_bp_space.sv
GEN=sweeps/int_mode/bp/space/gen_bp_space_workload.py
CHECK=sweeps/int_mode/bp/hybrid/check_bp_hybrid_top_trace.py
mkdir -p "$OUT/hyb" "$OUT/xref"
DEFS=""   # the benches pass every top parameter explicitly (as run_bp_space_checks.sh p1)

vcs_build() {   # tag tb
    local tag=$1 tb=$2 b="$OUT/build_$1"
    rm -rf "$b"; mkdir -p "$b"
    vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp \
        +incdir+designs -assert svaext -timescale=1ns/1ps $DEFS \
        -o "$b/simv" -Mdir="$b/obj" \
        -y "$SYNOPSYS/dw/sim_ver" +libext+.v+ +incdir+"$SYNOPSYS/dw/sim_ver" \
        "$tb" -top Top > "$OUT/compile_$tag.log" 2>&1 \
        || { echo "compile $tag FAILED: $OUT/compile_$tag.log"; return 1; }
}

# label BA BW TA TW L MROWS NCOLS DIST SEED FLAGS EXPECT
CASES=$(cat <<'EOF'
t_int8_ta4tw8_uniform_L4096_m8n16          8 8 4 8 4096  8 16 uniform     711 -                 pass
t_int8_ta4tw8_relu_L1024_m8n8_junk         8 8 4 8 1024  8  8 relu        712 JUNK              pass
t_int8_ta4tw8_neg1xmin_L4352_m4n8_range    8 8 4 8 4352  4  8 neg1xmin      0 -                 pass
t_int8_ta4tw8_maxxmin_L4352_m4n8_junk      8 8 4 8 4352  4  8 maxxmin       0 JUNK              pass
t_int8_ta1tw8_uniform_L1024_m2n16_T1       8 8 1 8 1024  2 16 uniform     713 -                 pass
t_int8_ta1tw1_uniform_L1024_m1n2_T2S8      8 8 1 1 1024  1  2 uniform     714 -                 pass
t_int8_ta8tw8_uniform_L384_m16n16_junk     8 8 8 8  384 16 16 uniform     715 JUNK              pass
t_int8_ta4tw4_uniform_L1024_m8n8           8 8 4 4 1024  8  8 uniform     716 -                 pass
t_int8_ta2tw8_gauss_L2048_m4n16            8 8 2 8 2048  4 16 gauss       717 -                 pass
t_int8_ta2tw4_alternating_L2048_m4n8       8 8 2 4 2048  4  8 alternating   0 -                 pass
t_w4a8_ta8tw4_uniform_L1024_m16n16         8 4 8 4 1024 16 16 uniform     718 -                 pass
t_w4a8_ta8tw4_minxmax_L4096_m8n8_junk      8 4 8 4 4096  8  8 minxmax       0 JUNK              pass
t_int4_ta4tw4_uniform_L4096_m8n16          4 4 4 4 4096  8 16 uniform     719 -                 pass
t_int4_ta4tw4_allmin_L1024_m8n8            4 4 4 4 1024  8  8 allmin        0 -                 pass
t_int4_ta2tw4_gauss_L2048_m8n16_junk       4 4 2 4 2048  8 16 gauss       720 JUNK              pass
t_int4_ta1tw4_uniform_L1024_m4n16_T1       4 4 1 4 1024  4 16 uniform     721 -                 pass
t_neg_asignheld_int8_ta4tw8                8 8 4 8  256  4  8 uniform     791 NEG_ASIGN_HELD    fail
t_neg_gapshort_int8_ta4tw8                 8 8 4 8  256  4  8 uniform     792 NEG_GAP_SHORT     fail
t_neg_drainearly_int4_ta4tw4               4 4 4 4  256  8  8 uniform     793 NEG_DRAIN_EARLY   fail
t_neg_overlap_w4a8_ta8tw4                  8 4 8 4  256  8 16 uniform     794 NEG_BLOCK_OVERLAP fail
EOF
)

one() {   # label ba bw ta tw L mrows ncols dist seed flags expect
    local label=$1 ba=$2 bw=$3 ta=$4 tw=$5 L=$6 mrows=$7 ncols=$8 dist=$9 seed=${10} flags=${11} expect=${12}
    local plus=(+TA="$ta" +TW="$tw") fl f dir="$OUT/hyb/$label"
    if [[ "$flags" != - ]]; then IFS=, read -ra fl <<< "$flags"; for f in "${fl[@]}"; do plus+=("+$f"); done; fi
    rm -rf "$dir"; mkdir -p "$dir"
    python3 "$GEN" --ba "$ba" --bw "$bw" --L "$L" --mrows "$mrows" --ncols "$ncols" \
        --dist "$dist" --seed "$seed" --out-dir "$dir" > "$dir/gen.log" || { echo "$label: FAIL (generator)"; return 1; }
    (cd "$dir" && "$OUT/build_top/simv" +BA="$ba" +BW="$bw" +L="$L" +MROWS="$mrows" +NCOLS="$ncols" "${plus[@]}" > sim.log 2>&1)
    grep -q '^PASS: BP hybrid top' "$dir/sim.log" || { echo "$label: FAIL (simulation error, $dir/sim.log)"; return 1; }
    local rc=0
    python3 "$CHECK" "$dir" --json "$dir/check.json" > "$dir/check.log" 2>&1 || rc=$?
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
        echo "$label: PASS (expected failure caught: $nm mismatch records; $(tail -1 "$dir/check.log" | sed 's/^\[FAIL\] [^:]*: //'))"
        return 0
    fi
    echo "$label: FAIL  $(tail -1 "$dir/check.log")"; return 1
}

xref() {   # label BA BW L MROWS NCOLS DIST SEED   (TA=1, TW=BW vs space bench S=1)
    local label=$1 ba=$2 bw=$3 L=$4 mrows=$5 ncols=$6 dist=$7 seed=$8 d="$OUT/xref/$1"
    rm -rf "$d"; mkdir -p "$d/hyb" "$d/space"
    python3 "$GEN" --ba "$ba" --bw "$bw" --L "$L" --mrows "$mrows" --ncols "$ncols" --dist "$dist" \
        --seed "$seed" --out-dir "$d/space" > "$d/space/gen.log"
    cp "$d/space/bpt_a.hex" "$d/space/bpt_w.hex" "$d/hyb/"
    (cd "$d/space" && "$OUT/build_space/simv" +BA="$ba" +BW="$bw" +S=1 +L="$L" +MROWS="$mrows" +NCOLS="$ncols" > sim.log 2>&1)
    (cd "$d/hyb" && "$OUT/build_top/simv" +BA="$ba" +BW="$bw" +TA=1 +TW="$bw" +L="$L" +MROWS="$mrows" +NCOLS="$ncols" > sim.log 2>&1)
    grep -q '^PASS: BP space' "$d/space/sim.log" && grep -q '^PASS: BP hybrid top' "$d/hyb/sim.log" \
        || { echo "$label: FAIL (simulation error)"; return 1; }
    python3 "$CHECK" "$d/hyb" --json "$d/hyb/check.json" > "$d/hyb/check.log" 2>&1 \
        || { echo "$label: FAIL (hybrid T1-mode run does not check)"; return 1; }
    local n
    n=$(grep -c '^[DCE] ' "$d/space/bps_trace.txt")
    if cmp -s <(grep '^[DCE] ' "$d/hyb/bph_trace.txt" | sort) <(grep '^[DCE] ' "$d/space/bps_trace.txt" | sort); then
        echo "$label: PASS (hybrid top bench TA=1 TW=$bw: $n D/C/E records byte-identical to test_payn_array_bp_space.sv S=1)"
    else
        echo "$label: FAIL (records differ from test_payn_array_bp_space.sv S=1)"; return 1
    fi
}

status=0
vcs_build top "$TB" & p1=$!
vcs_build space "$TB_S" & p2=$!
wait $p1 || status=1
wait $p2 || status=1
(( status == 0 )) || { echo "run_bp_hybrid_top_checks: COMPILE FAILED"; exit 1; }

{
while read -r label ba bw ta tw L mrows ncols dist seed flags expect; do
    [[ -n "$label" ]] || continue
    one "$label" "$ba" "$bw" "$ta" "$tw" "$L" "$mrows" "$ncols" "$dist" "$seed" "$flags" "$expect" &
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
done <<< "$CASES"
xref xref_t1_int8_L1024 8 8 1024 1 16 uniform 731 &
xref xref_t1_int4_L1024 4 4 1024 2 16 uniform 732 &
xref xref_t1_w4a8_L512 8 4 512 2 8 relu 733 &
while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done
echo "run_bp_hybrid_top_checks: $([[ $status == 0 ]] && echo ALL AS EXPECTED || echo UNEXPECTED RESULTS)"
} > "$OUT/summary.log" 2>&1
grep -v -i zoxide "$OUT/summary.log" | grep -v '^$' | sort
grep -q 'ALL AS EXPECTED' "$OUT/summary.log" && ! grep -q ': FAIL' "$OUT/summary.log"
