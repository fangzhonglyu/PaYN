#!/bin/bash
# RTL checks for the C-BSG A-first variant (designs/payn/variants/signed_segmented_csa_cbsg_af),
# the preflight before synthesizing TSMC22/PAYN_SC_CSA_CBSG_AF.  K8/M16/N8x8, LOW_W=9, OWIDTH=24.
#
# (ref)   reference side: cbsg_ref.py --check-golden re-derives the 12 shipped golden cases
#         (build/cbsg/golden) from their .mem files; sweeps/cbsg/af/emit_af_cases.py emits the extra
#         cases (build/cbsg/af/golden_extra: every L 1..128, all trace ladders plain and as chunk_d-128
#         rung tables, chunk_d 128/96/100 with tails, per-head, back-to-back mixed and odd-block calls,
#         D=2048, extremes), each gated by kernel == RG == AF and re-derived from its .mem files;
#         sweeps/cbsg/af/review/emit_review_cases.py emits the review cases (build/cbsg/af/golden_rv:
#         chunk_d 8 / 16 / unaligned, one-cycle blocks, 60 tiny back-to-back calls, random per-row L),
#         same gate.
# (units) sweeps/cbsg/af/tb_cbsg_af_units.sv: the kA encoder exhaustively (1,056,768 cases) and
#         the W stream generator against brute-force definitions.
# (func)  designs/payn/tb/test_payn_array_cbsg_af.sv on one compile:
#           every golden and extra case alone (tightest legal schedule);
#           all cases chained in one run without reset, plain and under the robustness modes
#           (all 8 cycles, random gaps with rng_en toggling, exact mac_en, loose drains, legal stalls,
#           rng_en low on the last advance edge, junk buses, DUT reset between cases), and with the
#           phase restart driven by the drains alone (no slice_start) or by slice_start alone;
#           negative controls that must FAIL with the listed tags and without the !tags:
#             CHECK drain mismatch, BLOCK per-block accumulator, KA encoder, PHASE phase register,
#             CONTRACT the top's [CBSG-AF-CONTRACT] simulation checks.
# (power) designs/payn/power/power_payn_array_cbsg_af.sv, uniform L=128 and the ladder workload,
#         256 blocks each, drain checked bit-exactly by sweeps/cbsg/af/check_power_trace.py.
#
#   bash sweeps/cbsg/af/run_rtl_checks.sh                # everything
#   PARTS="func" bash sweeps/cbsg/af/run_rtl_checks.sh   # subset: ref units func power
# Logs: build/cbsg/af/rtl_checks_summary.log (summary), build/cbsg/af/{ref,units,func,power}*.log,
# per-case dirs build/cbsg/af/func/<label>/.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$REPO"
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export USE_DW=1 NTFY_CHNL= PYTHONDONTWRITEBYTECODE=1
PARTS=${PARTS:-"ref units func power"}
MAX_JOBS=${MAX_JOBS:-8}
OUT=build/cbsg/af
GOLD=build/cbsg/golden
EXTRA=$OUT/golden_extra
RV=$OUT/golden_rv
VCS_PP='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
mkdir -p "$OUT"

#----------------------------------------------------------------- (ref) --
run_ref() {
    local n
    python3 sweeps/cbsg/cbsg_ref.py --check-golden "$GOLD" > "$OUT/ref_check_golden.log" 2>&1 \
        || { echo "check-golden FAILED (see $OUT/ref_check_golden.log)"; return 1; }
    n=$(grep -c '^\[PASS\]' "$OUT/ref_check_golden.log" || true)
    if grep -q '^\[FAIL\]' "$OUT/ref_check_golden.log" || (( n != 12 )); then
        echo "check-golden: $n PASS of 12 (see $OUT/ref_check_golden.log)"; return 1
    fi
    echo "shipped golden cases re-derived from .mem: $n PASS"
    rm -rf "$EXTRA"
    python3 sweeps/cbsg/af/emit_af_cases.py --out "$EXTRA" > "$OUT/golden_extra_emit.log" 2>&1 \
        || { echo "extra-case emit FAILED (see $OUT/golden_extra_emit.log)"; return 1; }
    n=$(grep -c '^\[PASS\]' "$OUT/golden_extra_emit.log" || true)
    if grep -q '^\[FAIL\]' "$OUT/golden_extra_emit.log" || (( n == 0 )); then
        echo "extra cases: $n PASS (see $OUT/golden_extra_emit.log)"; return 1
    fi
    echo "extra cases emitted (kernel == RG == AF) and re-derived from .mem: $n PASS," \
         "$(awk '{for(i=1;i<=NF;i++) if($(i+1)=="blocks,") b+=$i} END{print b}' "$OUT/golden_extra_emit.log") blocks"
    rm -rf "$RV"
    python3 sweeps/cbsg/af/review/emit_review_cases.py --out "$RV" > "$OUT/golden_rv_emit.log" 2>&1 \
        || { echo "review-case emit FAILED (see $OUT/golden_rv_emit.log)"; return 1; }
    n=$(grep -c '^\[PASS\]' "$OUT/golden_rv_emit.log" || true)
    if grep -q '^\[FAIL\]' "$OUT/golden_rv_emit.log" || (( n == 0 )); then
        echo "review cases: $n PASS (see $OUT/golden_rv_emit.log)"; return 1
    fi
    echo "review cases emitted (kernel == RG == AF) and re-derived from .mem: $n PASS," \
         "$(awk '{for(i=1;i<=NF;i++) if($(i+1)=="blocks,") b+=$i} END{print b}' "$OUT/golden_rv_emit.log") blocks"
}

#--------------------------------------------------------------- (units) --
run_units() {
    local b="$OUT/units"
    rm -rf "$b"; mkdir -p "$b"
    vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -assert svaext +incdir+designs \
        -timescale=1ns/1ps -o "$b/simv" -Mdir="$b/obj" \
        sweeps/cbsg/af/tb_cbsg_af_units.sv -top TbCbsgAfUnits > "$b/compile.log" 2>&1 \
        || { echo "units: compile FAILED (see $b/compile.log)"; return 1; }
    (cd "$b" && ./simv > sim.log 2>&1) || true
    grep '^UNITS PASS' "$b/sim.log" || { echo "units: FAIL (see $b/sim.log)"; return 1; }
}

#---------------------------------------------------------------- (func) --
TB=designs/payn/tb/test_payn_array_cbsg_af.sv
FUNC_DIR=$OUT/func

resolve() {   # comma list of case names / @golden / @extra / @all -> comma list of absolute dirs
    local out=() x d
    IFS=, read -ra xs <<< "$1"
    for x in "${xs[@]}"; do
        case "$x" in
            @golden) for d in "$GOLD"/*/; do out+=("$REPO/${d%/}"); done ;;
            @extra)  for d in "$EXTRA"/*/; do out+=("$REPO/${d%/}"); done ;;
            @rv)     for d in "$RV"/*/; do out+=("$REPO/${d%/}"); done ;;
            @all)    for d in "$GOLD"/*/ "$EXTRA"/*/ "$RV"/*/; do out+=("$REPO/${d%/}"); done ;;
            *) if [[ -d "$GOLD/$x" ]]; then out+=("$REPO/$GOLD/$x");
               elif [[ -d "$EXTRA/$x" ]]; then out+=("$REPO/$EXTRA/$x");
               elif [[ -d "$RV/$x" ]]; then out+=("$REPO/$RV/$x");
               else echo "unknown case $x" >&2; return 1; fi ;;
        esac
    done
    (IFS=,; echo "${out[*]}")
}

# label  cases  flags(comma plusargs or -)  expect: pass | fail:TAG+TAG+!TAG
# Phase controls: the DUT restarts the phase on its own after every drain (and reset) and on
# slice_start.  NO_*_SS withhold slice_start; KILL_DRAIN_RESET forces the drain-derived restart off,
# which models an edge that depends on slice_start alone.
# slice_phase_rung128_noop: chunk_d 128 chunks are 16 blocks, so the phase wraps to 0 by itself at every chunk
# start; withholding the restart there is a no-op (the reference's known blind spot), and the monitor, which
# checks the phase each slice actually loads, rightly stays silent.
NEG_CASES=$(cat <<'EOF'
chain_all                 @all            -                                                 pass
chain_all_full            @all            FULL_CYCLES                                       pass
chain_all_gaps_s1         @all            GAPS,RNG_GAP_LOW,SEED=1                           pass
chain_all_gaps_mac_s2     @all            GAPS,RNG_GAP_LOW,MAC_EXACT,SEED=2                 pass
chain_all_loose_s3        @all            LOOSE_DRAIN,MAC_EXACT,SEED=3                      pass
chain_all_combo_s4        @all            GAPS,RNG_GAP_LOW,MAC_EXACT,LOOSE_DRAIN,FULL_CYCLES,SEED=4 pass
chain_all_stall_s5        @all            STALL,SEED=5                                      pass
chain_all_stall_mac_s6    @all            STALL,GAPS,RNG_GAP_LOW,MAC_EXACT,SEED=6           pass
chain_all_rng_end_mac_s7  @all            RNG_LOW_END,GAPS,MAC_EXACT,SEED=7                 pass
chain_all_rng_end_tight   @all            RNG_LOW_END                                       pass
chain_all_junk_s8         @all            JUNK_BUS,GAPS,RNG_GAP_LOW,SEED=8                  pass
chain_all_reset_s9        @all            MID_RESET,SEED=9                                  pass
chain_all_no_ss           @all            NO_SLICE_START                                    pass
chain_all_ss_only         @all            KILL_DRAIN_RESET                                  pass
chain_all_no_ss_combo_s10 @all            NO_SLICE_START,STALL,JUNK_BUS,MID_RESET,GAPS,RNG_GAP_LOW,MAC_EXACT,LOOSE_DRAIN,FULL_CYCLES,SEED=10 pass
chain_all_ss_only_combo_s11 @all          KILL_DRAIN_RESET,STALL,JUNK_BUS,GAPS,RNG_GAP_LOW,LOOSE_DRAIN,SEED=11 pass
neg_call_phase_prot       calls_prot      NO_CALL_SS,KILL_DRAIN_RESET                       fail:CHECK+CONTRACT
neg_call_phase_av257      calls_av257     NO_CALL_SS,KILL_DRAIN_RESET                       fail:CHECK+CONTRACT
neg_call_phase_uL         af_uL_001_032   NO_CALL_SS,KILL_DRAIN_RESET                       fail:CHECK+CONTRACT
neg_call_phase_mixed      af_calls_mixed  NO_CALL_SS,KILL_DRAIN_RESET                       fail:CHECK+CONTRACT
neg_call_phase_tiny       rv_tiny_calls   NO_CALL_SS,KILL_DRAIN_RESET                       fail:CHECK+CONTRACT
neg_call_phase_chain      @golden         NO_CALL_SS,KILL_DRAIN_RESET                       fail:CHECK+CONTRACT
neg_no_ss_chain           @golden         NO_SLICE_START,KILL_DRAIN_RESET                   fail:CHECK+CONTRACT
neg_slice_phase_96        chunked_96      NO_SLICE_SS,KILL_DRAIN_RESET                      fail:CHECK+CONTRACT
neg_slice_phase_100       chunked_100     NO_SLICE_SS,KILL_DRAIN_RESET                      fail:CHECK+CONTRACT
neg_slice_phase_perhead   af_perhead      NO_SLICE_SS,KILL_DRAIN_RESET                      fail:CHECK+CONTRACT
neg_slice_phase_cd8       rv_cd8          NO_SLICE_SS,KILL_DRAIN_RESET                      fail:CHECK+CONTRACT
slice_phase_rung128_noop  chunked_rung    NO_SLICE_SS,KILL_DRAIN_RESET                      pass
neg_stall_nomac           plain_u97,calls_prot NEG_STALL_NOMAC,SEED=3                       fail:CHECK+CONTRACT
neg_rng_low_end_gaps      @golden         RNG_LOW_END,GAPS,SEED=4                           fail:CHECK+CONTRACT
neg_stray_load            @golden         NEG_STRAY_LOAD,SEED=12                            fail:CHECK+CONTRACT
neg_junk_ss               @golden         JUNK_SS,SEED=2                                    fail:CONTRACT+!CHECK+!BLOCK+!KA+!PHASE
neg_lane_rev_u97          plain_u97       NEG_LANE_REV                                      fail:CHECK+KA
neg_lane_rev_u128         plain_u128      NEG_LANE_REV                                      fail:CHECK
neg_lane_rev_ladders      af_ladders_0    NEG_LANE_REV                                      fail:CHECK+KA
neg_ka_eq_b_ladder        plain_ladder    NEG_KA_EQ_B                                       fail:CHECK+KA
neg_ka_eq_b_uL            af_uL_033_064   NEG_KA_EQ_B                                       fail:CHECK+KA
neg_ka_eq_b_u128          plain_u128      NEG_KA_EQ_B                                       pass
neg_row_len_max_ladder    plain_ladder    NEG_ROW_LEN_MAX                                   fail:CHECK+KA
neg_row_len_max_rung      chunked_rung    NEG_ROW_LEN_MAX                                   fail:CHECK+KA
neg_len_128_u97           plain_u97       NEG_LEN_128                                       fail:CHECK+KA
neg_len_128_uL            af_uL_001_032   NEG_LEN_128                                       fail:CHECK+KA
neg_short_u97             plain_u97       NEG_SHORT_BLOCK                                   fail:CHECK+CONTRACT
neg_short_uL              af_uL_065_096   NEG_SHORT_BLOCK                                   fail:CHECK+CONTRACT
neg_drain_early_rung      chunked_rung    NEG_DRAIN_EARLY                                   fail:CHECK+CONTRACT
neg_next_early_rung       chunked_rung    NEG_NEXT_EARLY                                    fail:CHECK+CONTRACT
EOF
)

func_case() {   # simv label cases flags expect
    local simv=$1 label=$2 cases=$3 flags=$4 expect=$5
    local dir="$FUNC_DIR/$label" plus=() fl x rc=0 res tags t want list
    if [[ "$flags" != - ]]; then
        IFS=, read -ra fl <<< "$flags"
        for x in "${fl[@]}"; do plus+=("+$x"); done
    fi
    rm -rf "$dir"; mkdir -p "$dir"
    list=$(resolve "$cases") || { echo "$label: FAIL (cannot resolve cases $cases)"; return 1; }
    (cd "$dir" && "$simv" "+CASES=$list" "${plus[@]}" > sim.log 2>&1) || rc=$?
    res=$(grep -m1 '^RESULT' "$dir/sim.log" | sed 's/^RESULT //') || true
    tags=""
    for t in CHECK BLOCK KA PHASE CONTRACT; do
        grep -q "^\[$t\] [0-9]" "$dir/sim.log" && tags+=" $t"
    done
    if [[ "$expect" == pass ]]; then
        if (( rc == 0 )) && grep -q '^PASS: CBSG AF bench' "$dir/sim.log" && [[ -z "$tags" ]]; then
            echo "$label: PASS ($res)"; return 0
        fi
        echo "$label: FAIL (rc=$rc tags:${tags:- none}; see $dir/sim.log)"; return 1
    fi
    # Negative control: the bench must FAIL, with every listed tag and none of the !tags.
    if ! grep -q '^FAIL: CBSG AF bench' "$dir/sim.log"; then
        echo "$label: FAIL (negative control not caught; see $dir/sim.log)"; return 1
    fi
    IFS=+ read -ra want <<< "${expect#fail:}"
    for t in "${want[@]}"; do
        if [[ "$t" == !* ]]; then
            [[ " $tags " != *" ${t#!} "* ]] || { echo "$label: FAIL (tag ${t#!} present, expected absent; tags:$tags)"; return 1; }
        else
            [[ " $tags " == *" $t "* ]] || { echo "$label: FAIL (tag $t missing; tags:$tags)"; return 1; }
        fi
    done
    echo "$label: PASS (negative control caught, tags:$tags; $(grep -E "^\[(CHECK|CONTRACT|KA)\] [0-9]" "$dir/sim.log" | sed 's/ \[CBSG-AF-CONTRACT\] errors//' | tr '\n' ';' | sed 's/;$//'); $(grep -m1 '^RESULT' "$dir/sim.log" | grep -oE 'stalls [0-9]+ stray loads [0-9]+'))"
}

run_func() {
    local build="$OUT/func_build" simv status=0 label cases flags expect n
    rm -rf "$FUNC_DIR"; mkdir -p "$FUNC_DIR" "$build/$TB"
    # The compile run (make sim) plays plain_u128 from cbsg_cases.txt in its run directory.
    echo "$REPO/$GOLD/plain_u128" > "$build/$TB/cbsg_cases.txt"
    make sim TOP=Top TB="$TB" BUILD_DIR="$REPO/$build" GL= TARGET= RTL_PREFLIGHT_CMD= \
        "VCS=$VCS_PP" > "$OUT/func_compile.log" 2>&1 || true
    grep -q '^PASS: CBSG AF bench' "$OUT/func_compile.log" \
        || { echo "functional bench: compile run FAILED (see $OUT/func_compile.log)"; return 1; }
    simv="$REPO/$build/$TB/simv"
    {
        for d in "$GOLD"/*/; do n=$(basename "$d"); echo "gold_$n $n - pass"; done
        for d in "$EXTRA"/*/; do n=$(basename "$d"); echo "extra_$n $n - pass"; done
        for d in "$RV"/*/; do n=$(basename "$d"); echo "rv_$n $n - pass"; done
        echo "$NEG_CASES"
    } > "$OUT/func_cases.txt"
    while read -r label cases flags expect; do
        [[ -n "$label" ]] || continue
        func_case "$simv" "$label" "$cases" "$flags" "$expect" &
        while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
    done < "$OUT/func_cases.txt"
    while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done
    echo "functional matrix: $(grep -c . "$OUT/func_cases.txt") runs, status $([[ $status == 0 ]] && echo PASS || echo FAIL)"
    return "$status"
}

#--------------------------------------------------------------- (power) --
PTB=designs/payn/power/power_payn_array_cbsg_af.sv
run_power() {
    local wl defs b status=0
    for wl in uniform ladder; do
        b="$REPO/$OUT/power_$wl"
        defs=""
        [[ $wl == ladder ]] && defs="+define+CBSG_PWR_LADDER"
        rm -rf "$b"
        if make sim TOP=Top TB="$PTB" BUILD_DIR="$b" GL= TARGET= RTL_PREFLIGHT_CMD= \
                "VCS=$VCS_PP" VCS_ARGS="$defs" > "$OUT/power_$wl.log" 2>&1 \
            && grep -q '^PASS: streaming C-BSG AF' "$OUT/power_$wl.log" \
            && [[ $(stat -c %s "$b/$PTB/dut.saif") -gt 1000000 ]] \
            && python3 sweeps/cbsg/af/check_power_trace.py "$b/$PTB/array_streaming_cbsg_af_rtl.txt" \
                   --json "$b/check.json" > "$OUT/power_${wl}_check.log" 2>&1; then
            echo "power_$wl: PASS $(sed 's/^\[PASS\] //' "$OUT/power_${wl}_check.log"); SAIF $(stat -c %s "$b/$PTB/dut.saif") B"
        else
            echo "power_$wl: FAIL (see $OUT/power_$wl.log, $OUT/power_${wl}_check.log)"; status=1
        fi
    done
    return "$status"
}

status=0
pids=()
for p in ref units; do
    if [[ " $PARTS " == *" $p "* ]]; then
        "run_$p" > "$OUT/${p}_summary.log" 2>&1 || status=1
    fi
done
# func needs the extra cases (ref); power and units are independent of them.
[[ " $PARTS " == *" func "* ]] && { run_func > "$OUT/func_summary.log" 2>&1 & pids+=("$!"); }
[[ " $PARTS " == *" power "* ]] && { run_power > "$OUT/power_summary.log" 2>&1 & pids+=("$!"); }
for pid in "${pids[@]}"; do wait "$pid" || status=1; done
{
    echo "C-BSG AF RTL checks, $(date '+%F %T'), RTL designs/payn/variants/signed_segmented_csa_cbsg_af"
    for p in ref units func power; do
        [[ " $PARTS " == *" $p "* ]] || continue
        echo "== $p"
        if [[ $p == func ]]; then
            sort "$OUT/func_summary.log"
            awk '/: PASS \(cases=/ {
                     n++; for (i = 1; i <= NF; i++) {
                         if ($i ~ /^blocks=/) { split($i, a, "="); b += a[2] }
                         if ($i == "drain" && $(i+1) == "values") d += $(i+2)
                         if ($i == "block" && $(i+1) == "values") k += $(i+2)
                         if ($i == "kA" && $(i+1) == "values") e += $(i+2) } }
                 /negative control caught/ { neg++ }
                 END { printf "functional totals: %d passing runs, %d blocks, %d drained accumulators, %d per-block accumulators, %d kA values compared bit-exactly; %d negative controls caught\n", n, b, d, k, e, neg }' \
                "$OUT/func_summary.log"
        else
            cat "$OUT/${p}_summary.log"
        fi
    done
    echo "C-BSG AF RTL checks: $([[ $status == 0 ]] && echo PASS || echo FAIL)"
} | tee "$OUT/rtl_checks_summary.log"
exit "$status"
