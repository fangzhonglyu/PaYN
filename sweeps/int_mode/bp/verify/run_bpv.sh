#!/bin/bash
# Independent adversarial INT-mode RTL verification of the BP CSA top
# (payn_array_signed_segmented_csa_bp).  Own bench (tb_bp_vec.sv), own
# generator/reference (bpv_gen.py), own checker (bpv_check.py); nothing is
# shared with designs/payn/tb/test_payn_array_bp.sv or sweeps/int_mode/bp/*.py.
#
#   bash sweeps/int_mode/bp/verify/run_bpv.sh                 # all scenarios
#   SCEN="neg_ring_late1 reset_mid_lap" bash .../run_bpv.sh   # a subset
# Logs: build/rtl_preflight/csa_bp_verify/{compile.log,summary.log,<scenario>/}
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
V=sweeps/int_mode/bp/verify
OUT=$(realpath -m "${OUT:-build/rtl_preflight/csa_bp_verify}")   # absolute or repo-relative
LOW_W=${LOW_W:-9}
MAX_JOBS=${MAX_JOBS:-8}
mkdir -p "$OUT"
BUILD="$OUT/build_loww$LOW_W"
if [[ -z "${NO_COMPILE:-}" ]]; then
    rm -rf "$BUILD"; mkdir -p "$BUILD"
    vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp \
        +incdir+designs -assert svaext -timescale=1ns/1ps +define+BPV_LOW_W=$LOW_W \
        -o "$BUILD/simv" -Mdir="$BUILD/obj" \
        -y "$SYNOPSYS/dw/sim_ver" +libext+.v+ +incdir+"$SYNOPSYS/dw/sim_ver" \
        "$V/tb_bp_vec.sv" -top TbBpVec > "$OUT/compile_loww$LOW_W.log" 2>&1 \
        || { echo "compile FAILED: $OUT/compile_loww$LOW_W.log"; exit 1; }
fi
SIMV="$BUILD/simv"
# Combiner unit test (arbitrary 24-bit tiles, random capture/int_prec/reset).
if [[ -z "${NO_UNIT:-}" ]]; then
    UB="$OUT/build_combiner_unit"; rm -rf "$UB"; mkdir -p "$UB"
    vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp \
        +incdir+designs -assert svaext -timescale=1ns/1ps \
        -o "$UB/simv" -Mdir="$UB/obj" "$V/tb_bp_combiner_unit.sv" -top TbBpCombinerUnit \
        > "$OUT/compile_combiner_unit.log" 2>&1 || { echo "combiner unit compile FAILED"; exit 1; }
    (cd "$UB" && ./simv +ntb_random_seed=7 > "$OUT/combiner_unit.log" 2>&1)
    grep -h '^\[PASS\]\|^\[FAIL\]\|^\[ERR\]' "$OUT/combiner_unit.log" | head -12
    grep -q '^\[PASS\]' "$OUT/combiner_unit.log" || UNIT_FAIL=1
fi
SCEN=${SCEN:-$(python3 $V/bpv_gen.py --list | awk '{print $1}' | tr '\n' ' ')}
[[ -n "${SCEN// /}" ]] || { echo "no scenarios (generator broken?)"; exit 1; }

one() {
    local sc=$1 dir="$OUT/$sc" expect
    expect=$(python3 $V/bpv_gen.py --list | awk -v s="$sc" '$1==s{print $2}')
    rm -rf "$dir"; mkdir -p "$dir"
    python3 $V/bpv_gen.py --scenario "$sc" --out-dir "$dir" > "$dir/gen.log" 2>&1 \
        || { echo "$sc: FAIL (generator error)"; return 1; }
    (cd "$dir" && "$SIMV" > sim.log 2>&1)
    if ! grep -q BPV_DONE "$dir/sim.log"; then
        # Post-review: the top's [BP-CONTRACT] simulation check may stop a run.
        if [[ $expect == fail ]] && grep -q '\[BP-CONTRACT\]' "$dir/sim.log"; then
            echo "$sc: PASS (expected failure caught by [BP-CONTRACT])"; return 0
        fi
        echo "$sc: FAIL (simulation error, $dir/sim.log)"; return 1
    fi
    if python3 $V/bpv_check.py "$dir" --json "$dir/check.json" > "$dir/check.log" 2>&1; then
        [[ $expect == pass ]] && { echo "$sc: PASS  $(tail -1 "$dir/check.log")"; return 0; }
        echo "$sc: FAIL (injected error NOT detected)  $(tail -1 "$dir/check.log")"; return 1
    else
        grep -q '^\[FAIL\]' "$dir/check.log" || { echo "$sc: FAIL (checker crashed, $dir/check.log)"; return 1; }
        [[ $expect == fail ]] && { echo "$sc: PASS (expected failure caught)  $(tail -1 "$dir/check.log")"; return 0; }
        echo "$sc: FAIL  $(tail -1 "$dir/check.log")"; return 1
    fi
}
status=0
for sc in $SCEN; do
    one "$sc" &
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
done
while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done
# INT->SC A/B: the SC drain after an INT stream must (per transparency) not depend
# on the raw planes of the last INT edge.  The review reproduced a carry-over
# here; with the post-review MAC guard the two drains must be identical.
if [[ " $SCEN " == *" int_to_sc_A "* && " $SCEN " == *" int_to_sc_B "* ]]; then
    if python3 $V/bpv_ab_sc_tail.py "$OUT/int_to_sc_A" "$OUT/int_to_sc_B" > "$OUT/int_to_sc_ab.log" 2>&1; then
        echo "int_to_sc_AB: PASS (no INT->SC carry-over)  $(tail -1 "$OUT/int_to_sc_ab.log")"
    else
        echo "int_to_sc_AB: FAIL (INT->SC carry-over)  $(tail -1 "$OUT/int_to_sc_ab.log")"; status=1
    fi
fi
[[ -n "${UNIT_FAIL:-}" ]] && status=1
echo "run_bpv LOW_W=$LOW_W: $([[ $status == 0 ]] && echo ALL AS EXPECTED || echo UNEXPECTED RESULTS)"
exit $status
