#!/bin/bash
# Adversarial review of the C-BSG AF RTL (not part of run_rtl_checks.sh).  Compiles the review copy of the
# functional bench (sweeps/cbsg/af/review/test_cbsg_af_review.sv) into build/cbsg/af/review/build and runs
# the matrix below.  Needs build/cbsg/golden, build/cbsg/af/golden_extra (run_rtl_checks.sh ref part),
# build/cbsg/af/review/golden_rv (emit_review_cases.py) and build/cbsg/af/review/golden_seed7
# (emit_af_cases.py --seed 7).  Summary: build/cbsg/af/review/review_summary.log
# NOTE (after the review fixes): this matrix describes the pre-fix RTL.  Its modes (+STALL, +NEG_STALL_NOMAC,
# +NEG_RNG_LOW_END as RNG_LOW_END, +JUNK_BUS, +JUNK_SS, +MID_RESET) and the golden_rv cases are now part of
# sweeps/cbsg/af/run_rtl_checks.sh and designs/payn/tb/test_payn_array_cbsg_af.sv.  With the structural phase
# restart, NEG_NO_CALL_PHASE / NEG_NO_SLICE_PHASE no longer fail on their own (they need KILL_DRAIN_RESET in the
# main bench), and the rng_low_end rows no longer raise contract errors.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
cd "$REPO"
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
OUT=build/cbsg/af/review
B=$OUT/build
MAX_JOBS=${MAX_JOBS:-8}
mkdir -p "$B"
if [[ "${SKIP_COMPILE:-0}" != 1 ]]; then
    vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp +incdir+designs -assert svaext \
        -timescale=1ns/1ps -o "$B/simv" -Mdir="$B/obj" \
        -y "$SYNOPSYS/dw/sim_ver" +libext+.v+ +incdir+"$SYNOPSYS/dw/sim_ver" \
        sweeps/cbsg/af/review/test_cbsg_af_review.sv -top Top > "$OUT/compile.log" 2>&1 \
        || { echo "compile FAILED (see $OUT/compile.log)"; exit 1; }
fi
SIMV=$REPO/$B/simv

list() {   # dirs (globs) -> comma list
    local out=() d
    for g in "$@"; do for d in $g; do [[ -d $d ]] && out+=("$REPO/${d%/}"); done; done
    (IFS=,; echo "${out[*]}")
}
ALL="build/cbsg/golden/*/ build/cbsg/af/golden_extra/*/ $OUT/golden_rv/*/ $OUT/golden_seed7/*/"

run() {   # label expect(pass|fail:TAGS) cases plusargs...
    local label=$1 expect=$2 cases=$3; shift 3
    local d=$OUT/runs/$label tags="" t
    rm -rf "$d"; mkdir -p "$d"
    (cd "$d" && "$SIMV" "+CASES=$cases" "$@" > sim.log 2>&1) || true
    for t in CHECK BLOCK KA PHASE CONTRACT; do grep -q "^\[$t\] [0-9]" "$d/sim.log" && tags+=" $t"; done
    local res; res=$(grep -m1 '^RESULT' "$d/sim.log" | sed 's/^RESULT //' || true)
    local st; st=$(grep -m1 '^REVIEW' "$d/sim.log" || true)
    if [[ $expect == pass ]]; then
        if grep -q '^PASS: CBSG AF bench' "$d/sim.log" && [[ -z $tags ]]; then echo "$label: PASS ($st; $res)";
        else echo "$label: FAIL (expected pass; tags:${tags:- none}; $(grep -m3 -E '^\[(CHECK|BLOCK|KA|PHASE|CONTRACT|BENCH)\]|Error' "$d/sim.log" | tr '\n' ';'))"; fi
        return
    fi
    if ! grep -q '^FAIL: CBSG AF bench' "$d/sim.log"; then echo "$label: FAIL (negative control not caught; $st; $res)"; return; fi
    local ok=1 w
    IFS=+ read -ra want <<< "${expect#fail:}"
    for w in "${want[@]}"; do
        if [[ $w == !* ]]; then [[ " $tags " != *" ${w#!} "* ]] || ok=0; else [[ " $tags " == *" $w "* ]] || ok=0; fi
    done
    echo "$label: $([[ $ok == 1 ]] && echo PASS || echo FAIL) (negative control, tags:$tags; $st; $(grep -E '^\[(CHECK|CONTRACT|KA|BLOCK)\] [0-9]' "$d/sim.log" | tr '\n' ';'))"
}

RV_ALL=$(list "$OUT/golden_rv/*/")
S7_ALL=$(list "$OUT/golden_seed7/*/")
EVERY=$(list $ALL)
{
    run rv_chain            pass "$RV_ALL"
    run seed7_chain         pass "$S7_ALL"
    for d in "$OUT"/golden_rv/*/; do n=$(basename "$d"); run "rv_$n" pass "$REPO/${d%/}"; done
    run every_chain_stall   pass "$EVERY" +STALL +SEED=5
    run every_chain_stall_mac pass "$EVERY" +STALL +MAC_EXACT +GAPS +RNG_GAP_LOW +SEED=6
    run every_chain_junk    pass "$EVERY" +JUNK_BUS +GAPS +RNG_GAP_LOW +SEED=7
    run every_chain_reset   pass "$EVERY" +MID_RESET +SEED=8
    run every_chain_combo   pass "$EVERY" +STALL +JUNK_BUS +MID_RESET +GAPS +RNG_GAP_LOW +LOOSE_DRAIN +FULL_CYCLES +SEED=9
    run rv_full_cycles      pass "$RV_ALL" +FULL_CYCLES +LOOSE_DRAIN +SEED=10
    run neg_stall_nomac     fail:CHECK "$(list build/cbsg/golden/plain_u97/ build/cbsg/golden/calls_prot/)" +NEG_STALL_NOMAC +SEED=3
    run neg_rng_low_end_gaps fail:CHECK "$(list build/cbsg/golden/*/)" +NEG_RNG_LOW_END +GAPS +SEED=4
    run neg_rng_low_end_tight fail:CONTRACT+!CHECK+!BLOCK "$(list build/cbsg/golden/plain_u128/)" +NEG_RNG_LOW_END
    run rng_low_end_macexact fail:CONTRACT+!CHECK+!BLOCK "$(list build/cbsg/golden/*/)" +NEG_RNG_LOW_END +GAPS +MAC_EXACT +SEED=4
    run junk_ss             fail:CONTRACT+!CHECK+!BLOCK+!KA+!PHASE "$(list build/cbsg/golden/*/)" +JUNK_SS +SEED=2
    run neg_call_phase_rv_tiny fail:CHECK+CONTRACT "$(list $OUT/golden_rv/rv_tiny_calls/)" +NEG_NO_CALL_PHASE
    run neg_slice_phase_rv_cd8 fail:CHECK+CONTRACT "$(list $OUT/golden_rv/rv_cd8/)" +NEG_NO_SLICE_PHASE
    run neg_short_rv_c1     fail:CHECK "$(list $OUT/golden_rv/rv_plain_randL/)" +NEG_SHORT_BLOCK
} > "$OUT/review_summary.log" 2>&1
cat "$OUT/review_summary.log"
