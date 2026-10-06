#!/bin/bash
# Independent adversarial PE-grid harness for BP INT mode with the per-PE lap
# enable (InnerPESignedSegmentedCsaBpGrid, RTL).  Shares no bench, generator or
# checker code with designs/payn/tb/test_pe_grid_bp.sv /
# sweeps/int_mode/bp/run_bp_grid_checks.sh.
#
#   gen_vg_stim.py   first-principles schedule + numpy reference, per edge
#   tb_vg_player.sv  dumb vector player; records ring_q of every PE every edge
#                    and the drained columns; optional bench-side ring forces
#   check_vg.py      bit-exact tiles, combined outputs vs A@W, per-PE ring_q
#                    pattern, X, block period vs the README formula
#
# Shapes: 1x1, 1x4, 1x8, 4x1, 8x1, 2x3, 4x4 (LOW_W=7: most carries/borrows
# at lap edges), 4x8.  Positive scenarios must PASS; negative controls (f_*:
# one-edge ring-wave / schedule errors, ungated ring in SC) must FAIL with
# tile mismatches; the reset_pass_n1 characterization is expected to FAIL on
# grids with min(P_R,P_C) >= 2 (operand pipes are not reset).
#
#   bash sweeps/int_mode/bp/verify_grid/run_vg.sh
#   SHAPES="2x3" bash sweeps/int_mode/bp/verify_grid/run_vg.sh
# Logs: build/rtl_preflight/csa_bp_verify_grid/{summary.log,<shape>_<scenario>/}
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
OUT=$(realpath -m "${OUT:-build/rtl_preflight/csa_bp_verify_grid}")   # absolute or repo-relative
MAX_JOBS=${MAX_JOBS:-8}
SHAPES=${SHAPES:-"1x1 1x4 1x8 4x1 8x1 2x3 4x4 4x8"}
VG=sweeps/int_mode/bp/verify_grid
mkdir -p "$OUT"

low_w() { [[ $1 == 4x4 ]] && echo 7 || echo 9; }

compile() {   # shape
    local s=$1 pr=${1%x*} pc=${1#*x} b="$OUT/build_$1"
    rm -rf "$b"; mkdir -p "$b"
    vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp \
        +incdir+designs -assert svaext -timescale=1ns/1ps \
        +define+VG_PR=$pr+define+VG_PC=$pc+define+VG_LOW_W=$(low_w "$s") \
        -o "$b/simv" -Mdir="$b/obj" \
        -y "$SYNOPSYS/dw/sim_ver" +libext+.v+ +incdir+"$SYNOPSYS/dw/sim_ver" \
        "$VG/tb_vg_player.sv" -top tb_vg_player > "$OUT/compile_$s.log" 2>&1 \
        || { echo "compile $s FAILED: $OUT/compile_$s.log"; return 1; }
}

cases_for() {   # shape -> "scenario expect" lines
    local s=$1 pr=${1%x*} pc=${1#*x}
    local mn=$(( pr < pc ? pr : pc )) S=$(( pr + pc - 2 ))
    local sc
    for sc in b2b_int8 mixed_prec nb1 w4a8_int4 extremes junk_planes oldc_idemp sc_ring_junk int_sc_int \
              "reset_lap_n${mn}_f0" "reset_pass_n${mn}_f0" ; do
        echo "$sc pass"
    done
    if (( mn >= 2 )); then
        echo "reset_pass_n1_f$(( mn - 1 )) pass"
        echo "reset_pass_n1_f0 fail"
        (( mn >= 3 )) && echo "reset_pass_n$(( mn - 1 ))_f0 fail"
    fi
    (( pc == 1 )) && echo "oldc_global pass"
    [[ $s == 1x4 || $s == 4x1 ]] && echo "long_int8 pass"
    [[ $s == 4x4 || $s == 4x8 ]] && echo "util4096 pass"
    for sc in f_row_late f_row_early f_lap_short f_lap_long f_link_late f_link_late_last f_stray \
              f_drain_early f_next_early f_junk_planes_late f_sc_nogate; do
        echo "$sc fail"
    done
    (( pc >= 2 )) && echo "f_link_early fail"
    (( pr >= 2 )) && echo "f_row_noskew fail"
    if (( S >= 1 )); then echo "f_shift_extra fail"; else echo "f_shift_extra pass"; fi
}

one() {   # shape scenario expect seed
    local s=$1 sc=$2 expect=$3 seed=$4 pr=${1%x*} pc=${1#*x}
    local d="$OUT/${s}_${sc}"
    rm -rf "$d"; mkdir -p "$d"
    python3 "$VG/gen_vg_stim.py" --pr "$pr" --pc "$pc" --scenario "$sc" --seed "$seed" --out-dir "$d" > "$d/gen.log" 2>&1 \
        || { echo "$s $sc: FAIL (generator error, $d/gen.log)"; return 1; }
    (cd "$d" && "$OUT/build_$s/simv" +STIM=stim.txt +TRACE=trace.txt $(cat plusargs.txt) > sim.log 2>&1)
    grep -q '^VG_DONE' "$d/sim.log" || { echo "$s $sc: FAIL (simulation error, $d/sim.log)"; return 1; }
    rm -f "$d/stim.txt"
    if python3 "$VG/check_vg.py" "$d" --json "$d/check.json" > "$d/check.log" 2>&1; then
        [[ $expect == pass ]] && { echo "$s $sc: PASS  $(tail -1 "$d/check.log")"; return 0; }
        echo "$s $sc: UNEXPECTED PASS (negative not caught)  $(tail -1 "$d/check.log")"; return 1
    fi
    grep -q '^\[FAIL\]' "$d/check.log" || { echo "$s $sc: FAIL (checker error, $d/check.log)"; return 1; }
    if [[ $expect == fail ]]; then
        local nm
        nm=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['n_tile_mismatch'])" "$d/check.json")
        (( nm > 0 )) || { echo "$s $sc: FAIL (failed without tile mismatches)  $(tail -1 "$d/check.log")"; return 1; }
        echo "$s $sc: PASS (expected failure caught)  $(tail -1 "$d/check.log")"; return 0
    fi
    echo "$s $sc: FAIL  $(tail -1 "$d/check.log")"; return 1
}

status=0
pids=()
for s in $SHAPES; do compile "$s" & pids+=("$!"); done
for p in "${pids[@]}"; do wait "$p" || status=1; done
(( status == 0 )) || { echo "run_vg: COMPILE FAILED"; exit 1; }

{
seed=100
for s in $SHAPES; do
    while read -r sc expect; do
        seed=$(( seed + 1 ))
        one "$s" "$sc" "$expect" "$seed" &
        while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
    done < <(cases_for "$s")
done
while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done
echo "run_vg: $([[ $status == 0 ]] && echo ALL AS EXPECTED || echo UNEXPECTED RESULTS)"
} > "$OUT/summary.log" 2>&1
sort "$OUT/summary.log"
grep -q 'ALL AS EXPECTED' "$OUT/summary.log" || exit 1

# As-built cross-check (optional, ASBUILT=1): the same player on the
# csa_bp_20261003b RTL snapshot (ring_q only steered the west mux).  Per-PE-lap
# blocks must FAIL there; old-contract runs (global laps + shift_in on an Nx1
# grid, shift_in on every lap edge of a 1x1) and SC ring junk must PASS.
[[ ${ASBUILT:-0} == 1 ]] || exit 0
SNAP=$(realpath -m "${ASBUILT_SNAPSHOT:-build/power_char/int_mode_energy_20261003/bp/csa_bp_20261003b_distguide_spp_pins/rtl_snapshot}")
AOUT=$OUT/asbuilt
mkdir -p "$AOUT"
ok=1
for s in 1x1 2x3 4x1; do
    b="$AOUT/build_$s"; mkdir -p "$b"
    vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp \
        +incdir+"$SNAP" +incdir+designs -assert svaext -timescale=1ns/1ps \
        +define+VG_PR=${s%x*}+define+VG_PC=${s#*x}+define+VG_LOW_W=9 \
        -o "$b/simv" -Mdir="$b/obj" -y "$SYNOPSYS/dw/sim_ver" +libext+.v+ +incdir+"$SYNOPSYS/dw/sim_ver" \
        "$VG/tb_vg_player.sv" -top tb_vg_player > "$AOUT/compile_$s.log" 2>&1 || { echo "asbuilt compile $s FAILED"; exit 1; }
done
while read -r s sc expect; do
    d="$AOUT/${s}_${sc}"; mkdir -p "$d"
    python3 "$VG/gen_vg_stim.py" --pr "${s%x*}" --pc "${s#*x}" --scenario "$sc" --seed 5 --out-dir "$d" > "$d/gen.log"
    (cd "$d" && "$AOUT/build_$s/simv" +STIM=stim.txt +TRACE=trace.txt > sim.log 2>&1; rm -f stim.txt)
    if python3 "$VG/check_vg.py" "$d" --json "$d/check.json" > "$d/check.log" 2>&1; then got=pass; else got=fail; fi
    [[ $got == "$expect" ]] && echo "asbuilt $s $sc: as expected ($got)  $(tail -1 "$d/check.log")" \
        || { echo "asbuilt $s $sc: UNEXPECTED ($got)  $(tail -1 "$d/check.log")"; ok=0; }
done <<'EOF2'
1x1 b2b_int8 fail
1x1 oldc_idemp pass
1x1 sc_ring_junk pass
2x3 b2b_int8 fail
2x3 mixed_prec fail
2x3 sc_ring_junk pass
4x1 b2b_int8 fail
EOF2
(( ok )) && echo "run_vg asbuilt: ALL AS EXPECTED" || { echo "run_vg asbuilt: UNEXPECTED RESULTS"; exit 1; }
