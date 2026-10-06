#!/bin/bash
# The independent adversarial PE-grid harness of sweeps/int_mode/bp/verify_grid/
# (run_vg.sh, unchanged: reset / abort mid-lap and mid-pass, one-edge ring-wave
# and schedule faults, SC ring junk, INT->SC->INT, back-to-back mixed
# precisions), ported to any lap length and run on the grids of
#   bp   InnerPESignedSegmentedCsaBpGrid      lap 8  (BP ring, csa_bp_20261004_lap)
#   ipd  InnerPESignedSegmentedCsaBpIpdGrid   lap 1  (in-place doubling)
#   sr2  InnerPESignedSegmentedCsaBpSrGrid    lap 2  (sub-ring, PAYN_LAP_G=2)
#   sr4  InnerPESignedSegmentedCsaBpSrGrid    lap 4  (sub-ring, PAYN_LAP_G=4)
#
#   gen_vg_stim_lap.py   copy of verify_grid/gen_vg_stim.py with --lap-len (default 8)
#   tb_vg_player_lap.sv  copy of verify_grid/tb_vg_player.sv with the DUT grid chosen by define
#   check_vg.py          verify_grid/check_vg.py, unchanged (reads the period formula from meta.json)
#
# Port check: for the bp configuration the ported generator at --lap-len 8 must
# write byte-identical stim.txt / expect.npz / plusargs.txt / meta.json to the
# original generator (same seed), so the bp rows are the original harness.
# Expectations per scenario are the original run_vg.sh's (cases_for, copied).
#
#   bash sweeps/int_mode/bp/sr/verify_grid/run_vg_lap.sh
#   DUTS="sr2" SHAPES="2x3" bash sweeps/int_mode/bp/sr/verify_grid/run_vg_lap.sh
# Logs: build/rtl_preflight/bp_sr/verify_grid/{summary.log,<dut>_<shape>_<scenario>/}
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)
cd "$REPO"
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
OUT=$(realpath -m "${OUT:-build/rtl_preflight/bp_sr/verify_grid}")
MAX_JOBS=${MAX_JOBS:-16}
SHAPES=${SHAPES:-"1x1 1x4 1x8 4x1 8x1 2x3 4x4 4x8"}
DUTS=${DUTS:-"bp ipd sr2 sr4"}
VG=sweeps/int_mode/bp/verify_grid
VL=sweeps/int_mode/bp/sr/verify_grid
mkdir -p "$OUT"

low_w() { [[ $1 == 4x4 ]] && echo 7 || echo 9; }
lap_of() { case $1 in bp) echo 8;; ipd) echo 1;; sr2) echo 2;; sr4) echo 4;; esac; }
def_of() { case $1 in bp) echo "";; ipd) echo "+define+VG_DUT_IPD";; sr2) echo "+define+VG_DUT_SR+define+PAYN_LAP_G=2";;
                      sr4) echo "+define+VG_DUT_SR+define+PAYN_LAP_G=4";; esac; }

compile() {   # dut shape
    local d=$1 s=$2 pr=${2%x*} pc=${2#*x} b="$OUT/build_$1_$2"
    rm -rf "$b"; mkdir -p "$b"
    vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp \
        +incdir+designs -assert svaext -timescale=1ns/1ps \
        +define+VG_PR=$pr+define+VG_PC=$pc+define+VG_LOW_W=$(low_w "$s")$(def_of "$d") \
        -o "$b/simv" -Mdir="$b/obj" \
        -y "$SYNOPSYS/dw/sim_ver" +libext+.v+ +incdir+"$SYNOPSYS/dw/sim_ver" \
        "$VL/tb_vg_player_lap.sv" -top tb_vg_player > "$OUT/compile_$1_$2.log" 2>&1 \
        || { echo "compile $1 $2 FAILED: $OUT/compile_$1_$2.log"; return 1; }
}

cases_for() {   # shape -> "scenario expect" lines (copied from verify_grid/run_vg.sh)
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

one() {   # dut shape scenario expect seed
    local dut=$1 s=$2 sc=$3 expect=$4 seed=$5 pr=${2%x*} pc=${2#*x} lap
    lap=$(lap_of "$dut")
    local d="$OUT/${dut}_${s}_${sc}"
    rm -rf "$d"; mkdir -p "$d"
    python3 "$VL/gen_vg_stim_lap.py" --pr "$pr" --pc "$pc" --scenario "$sc" --seed "$seed" --lap-len "$lap" \
        --out-dir "$d" > "$d/gen.log" 2>&1 || { echo "$dut $s $sc: FAIL (generator error, $d/gen.log)"; return 1; }
    if [[ $dut == bp ]]; then   # port check: identical to the original generator
        mkdir -p "$d/orig_gen"
        python3 "$VG/gen_vg_stim.py" --pr "$pr" --pc "$pc" --scenario "$sc" --seed "$seed" --out-dir "$d/orig_gen" \
            > "$d/orig_gen/gen.log" 2>&1
        local f
        for f in stim.txt expect.npz plusargs.txt meta.json gen.log; do
            cmp -s "$d/$f" "$d/orig_gen/$f" || { echo "$dut $s $sc: FAIL (ported generator differs from the original: $f)"; return 1; }
        done
        rm -rf "$d/orig_gen"
    fi
    (cd "$d" && "$OUT/build_${dut}_$s/simv" +STIM=stim.txt +TRACE=trace.txt $(cat plusargs.txt) > sim.log 2>&1)
    grep -q '^VG_DONE' "$d/sim.log" || { echo "$dut $s $sc: FAIL (simulation error, $d/sim.log)"; return 1; }
    rm -f "$d/stim.txt"
    if python3 "$VG/check_vg.py" "$d" --json "$d/check.json" > "$d/check.log" 2>&1; then
        [[ $expect == pass ]] && { echo "$dut $s $sc: PASS  $(tail -1 "$d/check.log")"; return 0; }
        echo "$dut $s $sc: UNEXPECTED PASS (negative not caught)  $(tail -1 "$d/check.log")"; return 1
    fi
    grep -q '^\[FAIL\]' "$d/check.log" || { echo "$dut $s $sc: FAIL (checker error, $d/check.log)"; return 1; }
    if [[ $expect == fail ]]; then
        local nm
        nm=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['n_tile_mismatch'])" "$d/check.json")
        (( nm > 0 )) || { echo "$dut $s $sc: FAIL (failed without tile mismatches)  $(tail -1 "$d/check.log")"; return 1; }
        echo "$dut $s $sc: PASS (expected failure caught)  $(tail -1 "$d/check.log")"; return 0
    fi
    echo "$dut $s $sc: FAIL  $(tail -1 "$d/check.log")"; return 1
}

status=0
pids=()
for dut in $DUTS; do for s in $SHAPES; do compile "$dut" "$s" & pids+=("$!"); done; done
for p in "${pids[@]}"; do wait "$p" || status=1; done
(( status == 0 )) || { echo "run_vg_lap: COMPILE FAILED"; exit 1; }

{
for dut in $DUTS; do
    seed=100           # same seed sequence as run_vg.sh, for every DUT
    for s in $SHAPES; do
        while read -r sc expect; do
            seed=$(( seed + 1 ))
            one "$dut" "$s" "$sc" "$expect" "$seed" &
            while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
        done < <(cases_for "$s")
    done
done
while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done
echo "run_vg_lap: $([[ $status == 0 ]] && echo ALL AS EXPECTED || echo UNEXPECTED RESULTS)"
} > "$OUT/summary.log" 2>&1
sort "$OUT/summary.log"
grep -q 'ALL AS EXPECTED' "$OUT/summary.log"
