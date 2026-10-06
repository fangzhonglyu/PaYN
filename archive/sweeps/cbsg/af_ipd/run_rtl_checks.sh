#!/bin/bash
# RTL checks for the C-BSG AF + IPD variant (designs/payn/variants/signed_segmented_csa_cbsg_af_ipd):
# SC mode = the AF C-BSG design (kernel bit-exact), INT mode = the BP INT contract with 1-edge
# in-place laps, on one top (payn_array_signed_segmented_csa_cbsg_af_ipd).  The preflight before
# synthesizing TSMC22/PAYN_SC_CSA_CBSG_AF_IPD.  Modelled on sweeps/cbsg/af/run_rtl_checks.sh and
# sweeps/int_mode/bp/ipd/run_bp_ipd_{rtl,grid}_checks.sh (sha256 of those in the variant README).
# K8/M16/N8x8, LOW_W=9, OWIDTH=24.  Everything lands in build/cbsg/af_ipd/.
#
# (copies)  sweeps/cbsg/af_ipd/check_copies.sh: source hashes vs copied_from.sha256, every RTL copy is
#           its source after the AfIpd renames (the peripheral: plus the INT bypass only), python
#           tool copies unchanged.
# (ref)     cbsg_ref.py --check-golden on the 12 shipped cases (build/cbsg/golden, read-only);
#           sweeps/cbsg/af/emit_af_cases.py and sweeps/cbsg/af/review/emit_review_cases.py emit the
#           AF extra (24) and review (7) cases into build/cbsg/af_ipd/golden_{extra,rv}, each gated
#           by kernel == RG == AF and re-derived from its .mem files (the AF campaign's own sets;
#           they are also compared with build/cbsg/af/golden_{extra,rv}, info only).
# (units)   sweeps/cbsg/af_ipd/tb_cbsg_af_ipd_units.sv: the AF unit bench on the copies (kA encoder
#           exhaustive, stream generator), INT silence (b = 0 -> kA = 0 for every L 0..255, zero
#           magnitudes -> silent streams for every cyc / phase, INT select passes the raw planes),
#           and the peripheral copy against the original AF peripheral (SC select equal, INT select
#           = original | raw), and L = 0 gives kA = 0 for every b (the A-side gate point quoted in
#           the peripheral header).
# (sc)      designs/payn/tb/test_payn_array_cbsg_af_ipd.sv +MODE=sc compiled with +define+CAI_LOCKSTEP
#           (an AF top instance on the same SC inputs, compared every edge): the AF functional matrix
#           (every golden / extra / review case alone, all cases chained under the robustness modes,
#           the negative controls with their tags), every run with +INT_JUNK (random raw planes,
#           int_prec, ring_in) plus two tied-off chains; two RNG_LOW_IDLE chains (the AF counter
#           holds between blocks) and NEG_SHORT_LAST=2 with RNG_LOW_IDLE (the cut-block check on the
#           next case's first block; contract count equal to the AF top's).  Every run must also be
#           lockstep-clean.
# (sctrace) SC traces (every drain, per-block tile accumulator, phase and kA) of the bench on the
#           AF-IPD top with +INT_JUNK and on the AF top (+define+CAI_DUT_AF) must be byte-identical.
# (int)     +MODE=int on the AF-IPD top: the IPD single-PE INT matrix (INT8 / W4A8 / INT4, extremes,
#           ReLU, near-limit L, multi-block, JUNK, MODE_AT=3, both shift contracts, negative
#           controls: no lap, double lap, BP-length lap, stray ring, lap on the last MAC, wrong
#           int_prec, int_mode late, live magnitudes) plus the AF-specific cases (counter parked at
#           cycle 0 with zero magnitudes, also with INT a_len_in = 255; nonzero A or W magnitudes in
#           INT mode; SC strobes in INT mode); checker sweeps/cbsg/af_ipd/check_bp_trace.py; block periods vs BW*NB + (BW-1) + 8;
#           lap coverage (pending carry and borrow folded by lap edges).
# (intx)    the original IPD bench on the original IPD top, same workloads: INT traces and
#           schedules byte-identical to the AF-IPD top's.
# (switch)  +MODE=switch: SC golden cases and INT blocks back to back on one DUT, no reset, tightest
#           transitions (and +SW_GAP), INT junk in SC segments, junk INT segments, stalls / gaps,
#           structural phase restart only (NO_SLICE_START), all 43 SC cases interleaved with 43 INT
#           blocks; the review case for the cut-block check (short last SC blocks, rng_en held
#           low through the INT segment, INT a_len_in = 255 or 128: RNG_LOW_IDLE + INT_LEN_DC, also
#           over all 43 cases); negative controls (int_mode early / late, no zero-load, int_mode
#           dropped before the last INT drain, no operand reload after INT, and a last SC block cut
#           short before an INT segment, which only the first SC block_start after it can flag:
#           tag CUT = "cuts a block").
# (grid)    IPD grid wrapper, rename check: designs/payn/tb/test_pe_grid_cbsg_af_ipd.sv on the copied
#           grid wrapper (a rename-only copy of the IPD grid: no AF edge, no INT bypass, mode
#           register, guard or combiner), 2x2 and 4x4, 1-edge per-PE laps: the IPD grid matrix for
#           those shapes (sweeps/cbsg/af_ipd/check_bp_ipd_grid_trace.py), and traces byte-identical
#           to the original IPD grid bench on the original IPD grid.  Evidence for the copied IPD lap
#           wave only, not for the AF + INT integration on a grid (per-row/column AF edges are open).
# (power)   SC: designs/payn/power/power_payn_array_cbsg_af_ipd.sv (tied-off and junk INT inputs),
#           uniform and ladder, 256 blocks: traces byte-identical to the AF power bench on the AF top
#           and bit-exact by sweeps/cbsg/af/check_power_trace.py.  INT:
#           designs/payn/power/power_payn_array_cbsg_af_ipd_int.sv (1-edge laps, shift_in on drains
#           only), INT8 / W4A8 / INT4 L=1024, SAIF modes 0/1/2, checked by
#           sweeps/cbsg/af_ipd/check_bp_power_trace.py --lap-len 1 --lap-ring-only.
#
# Every simv is compiled by this invocation: the parts that share one (int + switch: build_int,
# sc + sctrace: build_sc) reuse it only if it is newer than this run's stamp ($OUT/.run_stamp).
#
#   bash sweeps/cbsg/af_ipd/run_rtl_checks.sh                  # everything
#   PARTS="int switch" bash sweeps/cbsg/af_ipd/run_rtl_checks.sh
# Summary: build/cbsg/af_ipd/rtl_checks_summary.log; per part <part>_summary.log, run dirs <part>/<label>/.
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
export USE_DW=1 NTFY_CHNL= PYTHONDONTWRITEBYTECODE=1
PARTS=${PARTS:-"copies ref units sc sctrace int intx switch grid power"}
MAX_JOBS=${MAX_JOBS:-12}
OUT=build/cbsg/af_ipd
GOLD=build/cbsg/golden
EXTRA=$OUT/golden_extra
RV=$OUT/golden_rv
D=sweeps/cbsg/af_ipd
TB=designs/payn/tb/test_payn_array_cbsg_af_ipd.sv
GEN=$D/gen_bp_workload.py
CHK=$D/check_bp_trace.py
mkdir -p "$OUT"
STAMP="$OUT/.run_stamp"          # simv files newer than this were compiled by this invocation
touch "$STAMP"
fresh() { [[ -x "$1" && "$1" -nt "$STAMP" ]]; }

vcs_compile() {   # out_dir tb top extra_args... ; writes out_dir/simv, out_dir/compile.log
    local b=$1 tb=$2 top=$3; shift 3
    rm -rf "$b"; mkdir -p "$b"
    vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp +incdir+designs \
        -assert svaext -timescale=1ns/1ps "$@" -o "$b/simv" -Mdir="$b/obj" \
        -y "$SYNOPSYS/dw/sim_ver" +libext+.v+ +incdir+"$SYNOPSYS/dw/sim_ver" \
        "$tb" -top "$top" > "$b/compile.log" 2>&1
}
jobs_wait() {     # keep at most MAX_JOBS background jobs; returns 1 if a finished job failed
    local s=0
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || s=1; done
    return "$s"
}
jobs_drain() { local s=0; while (( $(jobs -rp | wc -l) > 0 )); do wait -n || s=1; done; return "$s"; }
plus_of() {       # comma list or - -> one plusarg per line
    local x fl
    [[ "$1" == - ]] && return 0
    IFS=, read -ra fl <<< "$1"
    for x in "${fl[@]}"; do echo "+$x"; done
}

#---------------------------------------------------------------- (copies) --
run_copies() { bash "$D/check_copies.sh"; }

#------------------------------------------------------------------- (ref) --
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
    for x in golden_extra golden_rv; do
        if [[ -d build/cbsg/af/$x ]]; then
            if diff -rq "$OUT/$x" "build/cbsg/af/$x" > /dev/null 2>&1; then
                echo "info: $OUT/$x identical to build/cbsg/af/$x (the AF campaign's set)"
            else
                echo "info: $OUT/$x differs from build/cbsg/af/$x (the AF set was regenerated since?)"
            fi
        fi
    done
}

#----------------------------------------------------------------- (units) --
run_units() {
    local b="$OUT/units"
    rm -rf "$b"; mkdir -p "$b"
    vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -assert svaext +incdir+designs \
        -timescale=1ns/1ps -o "$b/simv" -Mdir="$b/obj" \
        "$D/tb_cbsg_af_ipd_units.sv" -top TbCbsgAfIpdUnits > "$b/compile.log" 2>&1 \
        || { echo "units: compile FAILED (see $b/compile.log)"; return 1; }
    (cd "$b" && ./simv > sim.log 2>&1) || true
    grep '^UNITS PASS' "$b/sim.log" || { echo "units: FAIL (see $b/sim.log)"; return 1; }
}

#-------------------------------------------------------------------- (sc) --
resolve() {   # comma list of case names / @golden / @extra / @rv / @all -> comma list of absolute dirs
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

# label  cases  flags(comma plusargs or -)  expect: pass | fail:TAG+TAG+!TAG  (LOCKSTEP must be absent always)
# The AF functional matrix (sweeps/cbsg/af/run_rtl_checks.sh) with INT_JUNK on every run, plus two
# tied-off chains.
SC_CASES=$(cat <<'EOF'
chain_all                 @all            INT_JUNK                                                   pass
chain_all_tied            @all            -                                                          pass
chain_all_stall_tied_s21  @all            STALL,GAPS,RNG_GAP_LOW,MAC_EXACT,SEED=21                   pass
chain_all_full            @all            FULL_CYCLES,INT_JUNK                                       pass
chain_all_gaps_s1         @all            GAPS,RNG_GAP_LOW,SEED=1,INT_JUNK                           pass
chain_all_gaps_mac_s2     @all            GAPS,RNG_GAP_LOW,MAC_EXACT,SEED=2,INT_JUNK                 pass
chain_all_loose_s3        @all            LOOSE_DRAIN,MAC_EXACT,SEED=3,INT_JUNK                      pass
chain_all_combo_s4        @all            GAPS,RNG_GAP_LOW,MAC_EXACT,LOOSE_DRAIN,FULL_CYCLES,SEED=4,INT_JUNK pass
chain_all_stall_s5        @all            STALL,SEED=5,INT_JUNK                                      pass
chain_all_stall_mac_s6    @all            STALL,GAPS,RNG_GAP_LOW,MAC_EXACT,SEED=6,INT_JUNK           pass
chain_all_rng_end_mac_s7  @all            RNG_LOW_END,GAPS,MAC_EXACT,SEED=7,INT_JUNK                 pass
chain_all_rng_end_tight   @all            RNG_LOW_END,INT_JUNK                                       pass
chain_all_junk_s8         @all            JUNK_BUS,GAPS,RNG_GAP_LOW,SEED=8,INT_JUNK                  pass
chain_all_reset_s9        @all            MID_RESET,SEED=9,INT_JUNK                                  pass
chain_all_no_ss           @all            NO_SLICE_START,INT_JUNK                                    pass
chain_all_ss_only         @all            KILL_DRAIN_RESET,INT_JUNK                                  pass
chain_all_no_ss_combo_s10 @all            NO_SLICE_START,STALL,JUNK_BUS,MID_RESET,GAPS,RNG_GAP_LOW,MAC_EXACT,LOOSE_DRAIN,FULL_CYCLES,SEED=10,INT_JUNK pass
chain_all_ss_only_combo_s11 @all          KILL_DRAIN_RESET,STALL,JUNK_BUS,GAPS,RNG_GAP_LOW,LOOSE_DRAIN,SEED=11,INT_JUNK pass
chain_all_rng_low_idle    @all            RNG_LOW_IDLE,INT_JUNK                                      pass
chain_all_rng_low_idle_combo_s13 @all     RNG_LOW_IDLE,STALL,GAPS,MAC_EXACT,LOOSE_DRAIN,SEED=13,INT_JUNK pass
neg_short_last_idle       @golden         NEG_SHORT_LAST=2,RNG_LOW_IDLE,INT_JUNK                     fail:CHECK+CONTRACT
neg_call_phase_prot       calls_prot      NO_CALL_SS,KILL_DRAIN_RESET,INT_JUNK                       fail:CHECK+CONTRACT
neg_call_phase_av257      calls_av257     NO_CALL_SS,KILL_DRAIN_RESET,INT_JUNK                       fail:CHECK+CONTRACT
neg_call_phase_uL         af_uL_001_032   NO_CALL_SS,KILL_DRAIN_RESET,INT_JUNK                       fail:CHECK+CONTRACT
neg_call_phase_mixed      af_calls_mixed  NO_CALL_SS,KILL_DRAIN_RESET,INT_JUNK                       fail:CHECK+CONTRACT
neg_call_phase_tiny       rv_tiny_calls   NO_CALL_SS,KILL_DRAIN_RESET,INT_JUNK                       fail:CHECK+CONTRACT
neg_call_phase_chain      @golden         NO_CALL_SS,KILL_DRAIN_RESET,INT_JUNK                       fail:CHECK+CONTRACT
neg_no_ss_chain           @golden         NO_SLICE_START,KILL_DRAIN_RESET,INT_JUNK                   fail:CHECK+CONTRACT
neg_slice_phase_96        chunked_96      NO_SLICE_SS,KILL_DRAIN_RESET,INT_JUNK                      fail:CHECK+CONTRACT
neg_slice_phase_100       chunked_100     NO_SLICE_SS,KILL_DRAIN_RESET,INT_JUNK                      fail:CHECK+CONTRACT
neg_slice_phase_perhead   af_perhead      NO_SLICE_SS,KILL_DRAIN_RESET,INT_JUNK                      fail:CHECK+CONTRACT
neg_slice_phase_cd8       rv_cd8          NO_SLICE_SS,KILL_DRAIN_RESET,INT_JUNK                      fail:CHECK+CONTRACT
slice_phase_rung128_noop  chunked_rung    NO_SLICE_SS,KILL_DRAIN_RESET,INT_JUNK                      pass
neg_stall_nomac           plain_u97,calls_prot NEG_STALL_NOMAC,SEED=3,INT_JUNK                       fail:CHECK+CONTRACT
neg_rng_low_end_gaps      @golden         RNG_LOW_END,GAPS,SEED=4,INT_JUNK                           fail:CHECK+CONTRACT
neg_stray_load            @golden         NEG_STRAY_LOAD,SEED=12,INT_JUNK                            fail:CHECK+CONTRACT
neg_junk_ss               @golden         JUNK_SS,SEED=2,INT_JUNK                                    fail:CONTRACT+!CHECK+!BLOCK+!KA+!PHASE
neg_lane_rev_u97          plain_u97       NEG_LANE_REV,INT_JUNK                                      fail:CHECK+KA
neg_lane_rev_u128         plain_u128      NEG_LANE_REV,INT_JUNK                                      fail:CHECK
neg_lane_rev_ladders      af_ladders_0    NEG_LANE_REV,INT_JUNK                                      fail:CHECK+KA
neg_ka_eq_b_ladder        plain_ladder    NEG_KA_EQ_B,INT_JUNK                                       fail:CHECK+KA
neg_ka_eq_b_uL            af_uL_033_064   NEG_KA_EQ_B,INT_JUNK                                       fail:CHECK+KA
neg_ka_eq_b_u128          plain_u128      NEG_KA_EQ_B,INT_JUNK                                       pass
neg_row_len_max_ladder    plain_ladder    NEG_ROW_LEN_MAX,INT_JUNK                                   fail:CHECK+KA
neg_row_len_max_rung      chunked_rung    NEG_ROW_LEN_MAX,INT_JUNK                                   fail:CHECK+KA
neg_len_128_u97           plain_u97       NEG_LEN_128,INT_JUNK                                       fail:CHECK+KA
neg_len_128_uL            af_uL_001_032   NEG_LEN_128,INT_JUNK                                       fail:CHECK+KA
neg_short_u97             plain_u97       NEG_SHORT_BLOCK,INT_JUNK                                   fail:CHECK+CONTRACT
neg_short_uL              af_uL_065_096   NEG_SHORT_BLOCK,INT_JUNK                                   fail:CHECK+CONTRACT
neg_drain_early_rung      chunked_rung    NEG_DRAIN_EARLY,INT_JUNK                                   fail:CHECK+CONTRACT
neg_next_early_rung       chunked_rung    NEG_NEXT_EARLY,INT_JUNK                                    fail:CHECK+CONTRACT
EOF
)

sc_case() {   # simv dir label cases flags expect
    local simv=$1 base=$2 label=$3 cases=$4 flags=$5 expect=$6
    local dir="$base/$label" rc=0 res tags t want list
    local -a plus
    mapfile -t plus < <(plus_of "$flags")
    rm -rf "$dir"; mkdir -p "$dir"
    list=$(resolve "$cases") || { echo "$label: FAIL (cannot resolve cases $cases)"; return 1; }
    (cd "$dir" && "$simv" +MODE=sc "+CASES=$list" "${plus[@]}" > sim.log 2>&1) || rc=$?
    res=$(grep -m1 '^RESULT' "$dir/sim.log" | sed 's/^RESULT //') || true
    tags=""
    for t in CHECK BLOCK KA PHASE CONTRACT LOCKSTEP; do
        grep -q "^\[$t\] [0-9]" "$dir/sim.log" && tags+=" $t"
    done
    grep -q '^RESULT.*lockstep edges [1-9]' "$dir/sim.log" || tags+=" NO_LOCKSTEP"
    if [[ "$expect" == pass ]]; then
        if (( rc == 0 )) && grep -q '^PASS: CBSG AF-IPD bench' "$dir/sim.log" && [[ -z "$tags" ]]; then
            echo "$label: PASS ($res)"; return 0
        fi
        echo "$label: FAIL (rc=$rc tags:${tags:- none}; see $dir/sim.log)"; return 1
    fi
    if ! grep -q '^FAIL: CBSG AF-IPD bench' "$dir/sim.log"; then
        echo "$label: FAIL (negative control not caught; see $dir/sim.log)"; return 1
    fi
    IFS=+ read -ra want <<< "${expect#fail:}+!LOCKSTEP+!NO_LOCKSTEP"
    for t in "${want[@]}"; do
        if [[ "$t" == !* ]]; then
            [[ " $tags " != *" ${t#!} "* ]] || { echo "$label: FAIL (tag ${t#!} present, expected absent; tags:$tags)"; return 1; }
        else
            [[ " $tags " == *" $t "* ]] || { echo "$label: FAIL (tag $t missing; tags:$tags)"; return 1; }
        fi
    done
    echo "$label: PASS (negative control caught, tags:$tags; $(grep -E "^\[(CHECK|CONTRACT|KA)\] [0-9]" "$dir/sim.log" | sed 's/ \[CBSG-AF-CONTRACT\] errors//' | tr '\n' ';' | sed 's/;$//'); $(grep -m1 '^RESULT' "$dir/sim.log" | grep -oE 'lockstep edges [0-9]+ bad [0-9]+'))"
}

run_sc() {
    local b="$OUT/build_sc" status=0 label cases flags expect n
    rm -rf "$OUT/sc"; mkdir -p "$OUT/sc"
    vcs_compile "$b" "$TB" Top +define+CAI_LOCKSTEP || { echo "SC bench (lockstep) compile FAILED ($b/compile.log)"; return 1; }
    {
        for d in "$GOLD"/*/; do n=$(basename "$d"); echo "gold_$n $n INT_JUNK pass"; done
        for d in "$EXTRA"/*/; do n=$(basename "$d"); echo "extra_$n $n INT_JUNK pass"; done
        for d in "$RV"/*/; do n=$(basename "$d"); echo "rv_$n $n INT_JUNK pass"; done
        echo "$SC_CASES"
    } > "$OUT/sc_cases.txt"
    while read -r label cases flags expect; do
        [[ -n "$label" ]] || continue
        sc_case "$REPO/$b/simv" "$OUT/sc" "$label" "$cases" "$flags" "$expect" &
        jobs_wait || status=1
    done < "$OUT/sc_cases.txt"
    jobs_drain || status=1
    echo "SC functional matrix (lockstep vs the AF top): $(grep -c . "$OUT/sc_cases.txt") runs, status $([[ $status == 0 ]] && echo PASS || echo FAIL)"
    return "$status"
}

#--------------------------------------------------------------- (sctrace) --
TR_CASES=$(cat <<'EOF'
tr_chain_all                @all          -
tr_chain_all_no_ss_combo    @all          NO_SLICE_START,STALL,JUNK_BUS,MID_RESET,GAPS,RNG_GAP_LOW,MAC_EXACT,LOOSE_DRAIN,FULL_CYCLES,SEED=10
tr_chain_all_ss_only_combo  @all          KILL_DRAIN_RESET,STALL,JUNK_BUS,GAPS,RNG_GAP_LOW,LOOSE_DRAIN,SEED=11
tr_chain_all_rng_end_mac    @all          RNG_LOW_END,GAPS,MAC_EXACT,SEED=7
tr_neg_call_phase_chain     @golden       NO_CALL_SS,KILL_DRAIN_RESET
tr_neg_ka_eq_b_uL           af_uL_033_064 NEG_KA_EQ_B
tr_neg_stray_load           @golden       NEG_STRAY_LOAD,SEED=12
EOF
)
tr_case() {   # label cases flags
    local label=$1 cases=$2 flags=$3 dir="$OUT/sctrace/$1" list va vb
    local -a plus
    mapfile -t plus < <(plus_of "$flags")
    rm -rf "$dir"; mkdir -p "$dir/afipd" "$dir/af"
    list=$(resolve "$cases") || { echo "$label: FAIL (cases)"; return 1; }
    (cd "$dir/afipd" && "$REPO/$OUT/build_sc/simv" +MODE=sc "+CASES=$list" "${plus[@]}" +INT_JUNK +SC_TRACE=sc_trace.txt > sim.log 2>&1)
    (cd "$dir/af" && "$REPO/$OUT/build_af/simv" +MODE=sc "+CASES=$list" "${plus[@]}" +SC_TRACE=sc_trace.txt > sim.log 2>&1)
    va=$(grep -m1 -E '^(PASS|FAIL): CBSG AF-IPD bench' "$dir/afipd/sim.log" | cut -c1-4)
    vb=$(grep -m1 -E '^(PASS|FAIL): CBSG AF-IPD bench' "$dir/af/sim.log" | cut -c1-4)
    [[ -n "$va" && "$va" == "$vb" ]] || { echo "$label: FAIL (verdicts differ: AF-IPD '$va', AF '$vb')"; return 1; }
    [[ "$(grep -m1 '^RESULT' "$dir/afipd/sim.log" | sed 's/ | lockstep.*//')" == "$(grep -m1 '^RESULT' "$dir/af/sim.log")" ]] \
        || { echo "$label: FAIL (RESULT lines differ)"; return 1; }
    cmp -s "$dir/afipd/sc_trace.txt" "$dir/af/sc_trace.txt" \
        || { echo "$label: FAIL (SC traces differ)"; return 1; }
    echo "$label: PASS (SC trace byte-identical, AF-IPD top with INT junk vs AF top: $(wc -l < "$dir/af/sc_trace.txt") lines, $(stat -c %s "$dir/af/sc_trace.txt") B, verdict $va both; $(grep -m1 '^INT_JUNK' "$dir/afipd/sim.log"))"
}
run_sctrace() {
    local status=0 label cases flags
    rm -rf "$OUT/sctrace"; mkdir -p "$OUT/sctrace"
    fresh "$OUT/build_sc/simv" || vcs_compile "$OUT/build_sc" "$TB" Top +define+CAI_LOCKSTEP \
        || { echo "SC bench (lockstep) compile FAILED"; return 1; }
    vcs_compile "$OUT/build_af" "$TB" Top +define+CAI_DUT_AF || { echo "bench on the AF top: compile FAILED"; return 1; }
    grep -q "signed_segmented_csa_cbsg_af/payn_array_signed_segmented_csa_cbsg_af.sv" "$OUT/build_af/compile.log" \
        || { echo "AF-top build did not read the AF top"; return 1; }
    while read -r label cases flags; do
        [[ -n "$label" ]] || continue
        tr_case "$label" "$cases" "$flags" &
        jobs_wait || status=1
    done <<< "$TR_CASES"
    jobs_drain || status=1
    echo "SC trace identity (AF-IPD top + INT junk vs AF top): $(grep -c . <<< "$TR_CASES") runs, status $([[ $status == 0 ]] && echo PASS || echo FAIL)"
    return "$status"
}

#------------------------------------------------------------------- (int) --
# label BA BW L MROWS NCOLS DIST SEED FLAGS EXPECT   (FLAGS: comma-separated plusargs)
# EXPECT: pass | fail:CHECK | fail:TIMING | fail:CONTRACT ([BP-CONTRACT]) |
#         fail:AFCONTRACT (bit-exact, but [CBSG-AF-CONTRACT] count > 0)
# The IPD matrix (sweeps/int_mode/bp/ipd/run_bp_ipd_rtl_checks.sh) plus the AF-specific cases at the end.
INT_CASES=$(cat <<'EOF'
int8_uniform_L128_m1n8           8 8     128 1  8 uniform     1 -                pass
int8_uniform_L384_m2n16          8 8     384 2 16 uniform     2 -                pass
int8_uniform_L1024_m2n16         8 8    1024 2 16 uniform     3 -                pass
int8_uniform_L4096_m1n8          8 8    4096 1  8 uniform     4 -                pass
int8_relu_L1024_m1n8             8 8    1024 1  8 relu        5 -                pass
int8_allmin_L1024_m1n8           8 8    1024 1  8 allmin      0 -                pass
int8_allmax_L1024_m1n8           8 8    1024 1  8 allmax      0 -                pass
int8_minxmax_L1024_m1n16         8 8    1024 1 16 minxmax     0 -                pass
int8_maxxmin_L256_m2n8           8 8     256 2  8 maxxmin     0 -                pass
int8_alternating_L1024_m2n8      8 8    1024 2  8 alternating 0 -                pass
int8_uniform_L256_m2n16_junk     8 8     256 2 16 uniform     6 JUNK             pass
int8_uniform_L256_m2n8_modeat3   8 8     256 2  8 uniform     7 MODE_AT=3        pass
int8_allmin_L65408_m1n8          8 8   65408 1  8 allmin      0 -                pass
int8_neg1xmin_L65408_m1n8        8 8   65408 1  8 neg1xmin    0 -                pass
w4a8_uniform_L128_m1n8           8 4     128 1  8 uniform    11 -                pass
w4a8_uniform_L1024_m2n16         8 4    1024 2 16 uniform    12 -                pass
w4a8_allmin_L1024_m1n8           8 4    1024 1  8 allmin      0 -                pass
w4a8_allmax_L1024_m1n8           8 4    1024 1  8 allmax      0 -                pass
w4a8_minxmax_L1024_m1n8          8 4    1024 1  8 minxmax     0 -                pass
w4a8_alternating_L512_m1n16      8 4     512 1 16 alternating 0 -                pass
w4a8_uniform_L256_m3n8_junk      8 4     256 3  8 uniform    13 JUNK             pass
w4a8_neg1xmin_L1048448_m1n8      8 4 1048448 1  8 neg1xmin    0 -                pass
int4_uniform_L128_m2n8           4 4     128 2  8 uniform    21 -                pass
int4_uniform_L1024_m4n16         4 4    1024 4 16 uniform    22 -                pass
int4_allmin_L1024_m2n8           4 4    1024 2  8 allmin      0 -                pass
int4_allmax_L1024_m2n8           4 4    1024 2  8 allmax      0 -                pass
int4_minxmax_L1024_m2n8          4 4    1024 2  8 minxmax     0 -                pass
int4_alternating_L384_m4n8       4 4     384 4  8 alternating 0 -                pass
int4_uniform_L256_m2n16_junk     4 4     256 2 16 uniform    23 JUNK             pass
int4_allmin_L1048448_m2n8        4 4 1048448 2  8 allmin      0 -                pass
int8_uniform_L256_m1n8_lapring   8 8     256 1  8 uniform    33 LAP_RING_ONLY    pass
int8_uniform_L1024_m2n16_lapring 8 8    1024 2 16 uniform     3 LAP_RING_ONLY    pass
int8_uniform_L4096_m1n8_lapring  8 8    4096 1  8 uniform     4 LAP_RING_ONLY    pass
int8_alternating_L1024_m2n8_lapring 8 8 1024 2  8 alternating 0 LAP_RING_ONLY    pass
int8_uniform_L256_m2n16_junk_lapring 8 8 256 2 16 uniform     6 JUNK,LAP_RING_ONLY pass
int8_uniform_L256_m2n8_modeat3_lapring 8 8 256 2 8 uniform    7 MODE_AT=3,LAP_RING_ONLY pass
int8_neg1xmin_L65408_m1n8_lapring 8 8  65408 1  8 neg1xmin    0 LAP_RING_ONLY    pass
w4a8_uniform_L1024_m2n16_lapring 8 4    1024 2 16 uniform    12 LAP_RING_ONLY    pass
w4a8_uniform_L256_m3n8_junk_lapring 8 4  256 3  8 uniform    13 JUNK,LAP_RING_ONLY pass
int4_uniform_L1024_m4n16_lapring 4 4    1024 4 16 uniform    22 LAP_RING_ONLY    pass
int4_uniform_L256_m2n16_junk_lapring 4 4 256 2 16 uniform    23 JUNK,LAP_RING_ONLY pass
int4_allmin_L1048448_m2n8_lapring 4 4 1048448 2 8 allmin      0 LAP_RING_ONLY    pass
neg_int8_lap0_L256_m1n8          8 8     256 1  8 uniform    41 LAP_LEN=0        fail:CHECK
neg_int8_lap0_L256_m1n8_lapring  8 8     256 1  8 uniform    41 LAP_LEN=0,LAP_RING_ONLY fail:CHECK
neg_int8_noring_L256_m1n8        8 8     256 1  8 uniform    31 NEG_NO_RING      fail:TIMING
neg_int8_noring_L256_m1n8_lapring 8 8    256 1  8 uniform    38 NEG_NO_RING,LAP_RING_ONLY fail:CHECK
neg_int8_lap2_L256_m1n8          8 8     256 1  8 uniform    42 LAP_LEN=2        fail:CHECK
neg_int8_lap2_L256_m1n8_lapring  8 8     256 1  8 uniform    42 LAP_LEN=2,LAP_RING_ONLY fail:CHECK
neg_w4a8_lap2_L256_m1n8_lapring  8 4     256 1  8 uniform    43 LAP_LEN=2,LAP_RING_ONLY fail:CHECK
neg_int4_lap2_L256_m2n8_lapring  4 4     256 2  8 uniform    44 LAP_LEN=2,LAP_RING_ONLY fail:CHECK
neg_int8_lap8_L256_m1n8_lapring  8 8     256 1  8 uniform    45 LAP_LEN=8,LAP_RING_ONLY fail:CHECK
neg_int8_ringstray_L256_m1n8     8 8     256 1  8 uniform    36 NEG_RING_STRAY   fail:CHECK
neg_int8_ringstray_L256_m1n8_lapring 8 8 256 1  8 uniform    37 NEG_RING_STRAY,LAP_RING_ONLY fail:CHECK
neg_int8_ringstraymid_L1024_m1n8_lapring 8 8 1024 1 8 uniform 46 NEG_RING_STRAY_MID,LAP_RING_ONLY fail:CHECK
neg_int4_ringstraymid_L1024_m2n8_lapring 4 4 1024 2 8 uniform 47 NEG_RING_STRAY_MID,LAP_RING_ONLY fail:CHECK
neg_int8_nobubble_L256_m1n8_lapring 8 8  256 1  8 uniform    48 NEG_NO_BUBBLE,LAP_RING_ONLY fail:CHECK
neg_int8_nobubble_L1024_m2n8     8 8    1024 2  8 uniform    49 NEG_NO_BUBBLE    fail:CHECK
neg_w4a8_nobubble_L256_m1n8_lapring 8 4  256 1  8 uniform    50 NEG_NO_BUBBLE,LAP_RING_ONLY fail:CHECK
neg_int4_prec_L256_m2n8          4 4     256 2  8 uniform    32 NEG_PREC         fail:CHECK
neg_int8_mag_L256_m1n8           8 8     256 1  8 uniform    34 NEG_MAG          fail:CONTRACT
neg_int8_modeat4_L256_m1n8       8 8     256 1  8 uniform    35 MODE_AT=4        fail:CHECK
int8_park_cyc0_L256_m2n8         8 8     256 2  8 uniform    61 PARK_CYC0,MODE_AT=3 pass
int8_park_cyc0_L1024_m1n8_lapring 8 8   1024 1  8 uniform    62 PARK_CYC0,MODE_AT=2,LAP_RING_ONLY pass
int4_park_cyc0_L256_m2n8_junk    4 4     256 2  8 uniform    63 PARK_CYC0,MODE_AT=3,JUNK pass
w4a8_uniform_L512_m2n8_junk_modeat2 8 4  512 2  8 uniform    64 JUNK,MODE_AT=2,LAP_RING_ONLY pass
neg_int8_mag_a_park_L256_m1n8    8 8     256 1  8 uniform    65 PARK_CYC0,MODE_AT=3,NEG_MAG_A fail:CONTRACT
neg_int4_mag_a_park_L256_m2n8_lapring 4 4 256 2 8 uniform    66 PARK_CYC0,MODE_AT=2,NEG_MAG_A,LAP_RING_ONLY fail:CONTRACT
neg_int8_mag_w_L256_m1n8         8 8     256 1  8 uniform    67 NEG_MAG_W        fail:CONTRACT
neg_w4a8_mag_w_L256_m1n8_lapring 8 4     256 1  8 uniform    68 NEG_MAG_W,LAP_RING_ONLY fail:CONTRACT
neg_int8_scstrobe_L256_m2n8_junk 8 8     256 2  8 uniform    69 JUNK,JUNK_SCSTROBE fail:AFCONTRACT
neg_int4_scstrobe_L256_m2n8      4 4     256 2  8 uniform    70 JUNK_SCSTROBE    fail:AFCONTRACT
int8_park_cyc0_L256_m1n8_lendc255 8 8    256 1  8 uniform    71 PARK_CYC0,MODE_AT=2,INT_LEN_DC=255 pass
EOF
)

int_case() {   # simv base label BA BW L MROWS NCOLS DIST SEED FLAGS EXPECT
    local simv=$1 base=$2 label=$3 ba=$4 bw=$5 L=$6 mrows=$7 ncols=$8 dist=$9 seed=${10} flags=${11} expect=${12}
    local dir="$base/$label" rc=0 bench_pass=0 tag afc
    local -a plus
    mapfile -t plus < <(plus_of "$flags")
    rm -rf "$dir"; mkdir -p "$dir"
    python3 "$GEN" --ba "$ba" --bw "$bw" --L "$L" --mrows "$mrows" --ncols "$ncols" --dist "$dist" \
        --seed "$seed" --out-dir "$dir" > "$dir/gen.log"
    (cd "$dir" && "$simv" +MODE=int +BA="$ba" +BW="$bw" +L="$L" +MROWS="$mrows" +NCOLS="$ncols" "${plus[@]}" \
        > sim.log 2>&1) || rc=$?
    if (( rc == 0 )) && grep -q '^PASS: BP INT bench' "$dir/sim.log"; then bench_pass=1; fi
    case "$expect" in
        fail:TIMING|fail:CONTRACT)
            tag=TIMING-FAIL
            [[ "$expect" == fail:CONTRACT ]] && tag=BP-CONTRACT
            if (( bench_pass == 0 )) && grep -q "\[$tag\]" "$dir/sim.log"; then
                echo "$label: PASS (negative control caught by [$tag]:$(grep -m1 "\[$tag\]" "$dir/sim.log" | sed 's/^.*\]//' | cut -c1-80))"
                return 0
            fi
            echo "$label: FAIL (expected [$tag], see $dir/sim.log)"; return 1 ;;
    esac
    (( bench_pass )) || { echo "$label: FAIL (simulation error, see $dir/sim.log)"; return 1; }
    afc=$(grep -m1 '^PASS: BP INT bench' "$dir/sim.log" | grep -oE 'af_contract=[0-9]+' | cut -d= -f2)
    if python3 "$CHK" "$dir" --json "$dir/check.json" > "$dir/check.log" 2>&1; then
        if [[ "$expect" == fail:AFCONTRACT ]]; then
            (( afc > 0 )) && { echo "$label: PASS (bit-exact as required, and [CBSG-AF-CONTRACT] caught the SC strobes in INT mode: $afc errors)"; return 0; }
            echo "$label: FAIL (SC strobes in INT mode not flagged)"; return 1
        fi
        [[ "$expect" == pass ]] || { echo "$label: FAIL (negative control was not caught)"; return 1; }
        (( afc == 0 )) || { echo "$label: FAIL ([CBSG-AF-CONTRACT] $afc errors in a legal INT run)"; return 1; }
        echo "$label: PASS $(tail -n 1 "$dir/check.log" | sed 's/^\[PASS\] //')"
    else
        grep -q '^\[FAIL\]' "$dir/check.log" || { echo "$label: FAIL (checker error, see $dir/check.log)"; return 1; }
        [[ "$expect" == fail:CHECK ]] || { echo "$label: FAIL $(tail -n 1 "$dir/check.log")"; return 1; }
        echo "$label: PASS (negative control caught by the checker: $(tail -n 1 "$dir/check.log" | sed 's/^\[FAIL\] //'))"
    fi
    if (( L > 100000 )); then rm -f "$dir/bpt_a.hex" "$dir/bpt_w.hex"; fi
}

period_table() {   # dir
    python3 - "$1" <<'PY'
import json, re, sys
from pathlib import Path
rows = []
for d in sorted(Path(sys.argv[1]).iterdir()):
    s, c = d / "bpt_sched.txt", d / "check.json"
    if not (s.is_file() and c.is_file()):
        continue
    if json.loads(c.read_text())["status"] != "PASS":
        continue
    lines = s.read_text().split("\n")
    kv = dict(re.findall(r"(\w+)=(-?\d+)", lines[0]))
    starts = [int(l.split()[2]) for l in lines[1:] if l.startswith("DRAIN_START")]
    spacing = sorted({b - a for a, b in zip(starts, starts[1:])})
    nb, bw, lap = int(kv["nb"]), int(kv["bw"]), int(kv["lap_len"])
    ok = (lap == 1 and int(kv["blk_len"]) == int(kv["formula"]) == bw * nb + (bw - 1) + 8
          and (not spacing or spacing == [int(kv["blk_len"])]))
    rows.append((d.name, lap, kv["blk_len"], kv["formula"], spacing or "-", f"{bw*nb/int(kv['blk_len']):.1%}",
                 "OK" if ok else "MISMATCH"))
print("single-PE block periods (passing cases): case lap_len block_len formula(BW*NB+(BW-1)+8) "
      "measured_drain_spacing data_utilization")
bad = 0
for r in rows:
    print("  " + " ".join(str(x) for x in r))
    bad += r[-1] != "OK"
print(f"period rows: {len(rows)}, mismatches: {bad}")
sys.exit(1 if bad or not rows else 0)
PY
}

run_case_list() {   # simv dir cases
    local simv=$1 dir=$2 cases=$3 status=0
    while read -r label ba bw L mrows ncols dist seed flags expect; do
        [[ -n "$label" ]] || continue
        int_case "$simv" "$dir" "$label" "$ba" "$bw" "$L" "$mrows" "$ncols" "$dist" "$seed" "$flags" "$expect" &
        jobs_wait || status=1
    done <<< "$cases"
    jobs_drain || status=1
    return "$status"
}

build_int() {
    fresh "$OUT/build_int/simv" && return 0
    vcs_compile "$OUT/build_int" "$TB" Top || { echo "INT bench compile FAILED ($OUT/build_int/compile.log)"; return 1; }
    grep -q "signed_segmented_csa_cbsg_af_ipd/inner_pe_core_signed_segmented_csa_cbsg_af_ipd.sv" "$OUT/build_int/compile.log" \
        || { echo "INT build did not read the AF-IPD PE core"; return 1; }
}

run_int() {
    local status=0
    rm -rf "$OUT/int"; mkdir -p "$OUT/int"
    build_int || return 1
    run_case_list "$REPO/$OUT/build_int/simv" "$OUT/int" "$INT_CASES" || status=1
    echo "INT matrix: $(grep -c . <<< "$INT_CASES") cases, status $([[ $status == 0 ]] && echo PASS || echo FAIL)"
    python3 - "$OUT/int" <<'PY' || status=1
import json, re, sys
from pathlib import Path
tot = dict(cases=0, lap_edges=0, tile_laps=0, with_pending_carry=0, with_pending_borrow=0)
silent = 0
for d in sorted(Path(sys.argv[1]).iterdir()):
    c = d / "check.json"
    if not c.is_file() or json.loads(c.read_text())["status"] != "PASS":
        continue
    log = (d / "sim.log").read_text()
    m = re.search(r"LAP_COVERAGE (.*)", log)
    if not m:
        continue
    tot["cases"] += 1
    for k, v in re.findall(r"(\w+)=(\d+)", m[1]):
        tot[k] += int(v)
    s = re.search(r"INT_SILENT_MAC_SAMPLES (\d+)", log)
    silent += int(s[1]) if s else 0
print("  lap coverage (bit-exact cases): " + ", ".join(f"{k} {v}" for k, v in tot.items()))
print(f"  INT MACs consumed with the AF streams silent ([BP-CONTRACT] watched every one): {silent}")
sys.exit(0 if tot["with_pending_carry"] > 0 and tot["with_pending_borrow"] > 0 else 1)
PY
    period_table "$OUT/int" || status=1
    return "$status"
}

#------------------------------------------------------------------ (intx) --
# Original IPD bench (designs/payn/tb/test_payn_array_bp_ipd.sv, default compile = the IPD top) on
# the int part's workloads: traces and schedules must be byte-identical.
INTX_LABELS="int8_uniform_L384_m2n16 int8_uniform_L4096_m1n8 int8_alternating_L1024_m2n8 int8_uniform_L256_m2n16_junk
int8_uniform_L256_m2n8_modeat3 int8_neg1xmin_L65408_m1n8_lapring w4a8_uniform_L1024_m2n16 w4a8_uniform_L256_m3n8_junk_lapring
int4_uniform_L1024_m4n16_lapring int4_uniform_L256_m2n16_junk int8_relu_L1024_m1n8 neg_int4_prec_L256_m2n8
neg_int8_ringstray_L256_m1n8_lapring neg_int8_lap2_L256_m1n8 neg_int8_nobubble_L1024_m2n8"
intx_case() {   # label
    local label=$1 line flags dir="$OUT/intx/$1" src="$OUT/int/$1"
    local -a plus
    line=$(grep -E "^$label " <<< "$INT_CASES") || { echo "$label: FAIL (not in the INT matrix)"; return 1; }
    read -r _ ba bw L mrows ncols _ _ flags _ <<< "$line"
    mapfile -t plus < <(plus_of "$flags")
    [[ -f "$src/bpt_trace.txt" && -f "$src/bpt_a.hex" ]] || { echo "$label: FAIL (run the int part first)"; return 1; }
    rm -rf "$dir"; mkdir -p "$dir"
    cp "$src/bpt_a.hex" "$src/bpt_w.hex" "$dir/"
    (cd "$dir" && "$REPO/$OUT/build_ipd_orig/simv" +BA="$ba" +BW="$bw" +L="$L" +MROWS="$mrows" +NCOLS="$ncols" "${plus[@]}" \
        > sim.log 2>&1)
    grep -q '^PASS: BP INT bench' "$dir/sim.log" || { echo "$label: FAIL (original bench run, see $dir/sim.log)"; return 1; }
    cmp -s "$dir/bpt_trace.txt" "$src/bpt_trace.txt" || { echo "$label: FAIL (INT traces differ)"; return 1; }
    cmp -s "$dir/bpt_sched.txt" "$src/bpt_sched.txt" || { echo "$label: FAIL (schedules differ)"; return 1; }
    echo "$label: PASS (trace and schedule byte-identical to the IPD top under the original IPD bench, $(wc -l < "$dir/bpt_trace.txt") trace lines)"
}
run_intx() {
    local status=0 l
    rm -rf "$OUT/intx"; mkdir -p "$OUT/intx"
    vcs_compile "$OUT/build_ipd_orig" designs/payn/tb/test_payn_array_bp_ipd.sv Top \
        || { echo "original IPD bench compile FAILED"; return 1; }
    grep -q "signed_segmented_csa_bp_ipd/payn_array_signed_segmented_csa_bp_ipd.sv" "$OUT/build_ipd_orig/compile.log" \
        || { echo "original IPD bench did not read the IPD top"; return 1; }
    for l in $INTX_LABELS; do
        intx_case "$l" &
        jobs_wait || status=1
    done
    jobs_drain || status=1
    echo "INT cross-check vs the IPD top: $(wc -w <<< "$INTX_LABELS") cases, status $([[ $status == 0 ]] && echo PASS || echo FAIL)"
    return "$status"
}

#---------------------------------------------------------------- (switch) --
# label | flags | expect | items.  SC item = case name; INT item = i:BA:BW:L:MROWS:NCOLS:MODE_AT:JUNK:LRO:DIST:SEED.
# EXPECT: pass | fail:TIMING | fail:BPCONTRACT | fail:TAG+TAG (CHECK CONTRACT ... from the SC result lines)
SW_CASES=$(cat <<'EOF'
sw_basic | - | pass | plain_u128 i:8:8:256:1:8:0:0:1:uniform:5 calls_prot i:4:4:256:2:8:0:0:0:uniform:6 plain_u97 i:8:4:384:1:16:3:0:1:uniform:7 chunked_rung
sw_int_junk | INT_JUNK,SEED=3 | pass | chunked_96 i:8:8:384:2:8:0:1:1:uniform:11 perhead_64 i:4:4:256:2:16:1:1:0:uniform:12 i:8:8:256:1:8:2:1:1:alternating:0 plain_ladder i:8:4:256:1:8:0:1:0:uniform:13 calls_av257
sw_stall_gaps | INT_JUNK,STALL,GAPS,RNG_GAP_LOW,MAC_EXACT,LOOSE_DRAIN,SEED=4 | pass | rv_tiny_calls i:8:8:512:1:8:0:0:1:uniform:21 af_calls_mixed i:4:4:384:2:8:3:1:1:uniform:22 rv_cd8 i:8:8:256:2:8:0:1:0:minxmax:0 chunked_tail5
sw_no_ss | INT_JUNK,NO_SLICE_START | pass | calls_prot i:8:8:256:1:8:0:0:1:uniform:31 chunked_100 i:8:4:256:1:8:0:1:1:uniform:32 rv_cd16 i:4:4:256:2:8:0:0:1:uniform:33 perhead_128
sw_ss_only | INT_JUNK,KILL_DRAIN_RESET | pass | calls_av257 i:8:8:256:1:8:0:0:1:uniform:34 chunked_rung i:4:4:128:2:8:0:1:1:uniform:35 plain_extreme
sw_gap3 | INT_JUNK,SW_GAP=3 | pass | plain_u128 i:8:8:256:1:8:3:1:1:uniform:41 plain_u97 i:4:4:256:2:8:0:0:0:allmin:0 plain_extreme
sw_int_first | INT_JUNK | pass | i:8:8:256:1:8:0:0:1:uniform:51 plain_u128 i:8:8:1024:1:8:0:1:1:allmin:0 i:4:4:256:2:8:0:0:1:allmax:0 rv_c1_chain
all_interleaved | INT_JUNK,SEED=5 | pass | @ALL
sw_len_dc_hold | INT_JUNK,RNG_LOW_IDLE,INT_LEN_DC=255 | pass | rv_c1_chain i:8:8:256:1:8:0:0:1:uniform:71 af_perhead i:4:4:256:2:8:0:0:0:uniform:72 af_uL_001_032 i:8:4:256:1:8:2:0:1:uniform:73 perhead_64 i:8:8:128:1:8:0:0:1:uniform:74 plain_u97 i:4:4:128:2:8:1:0:1:uniform:75 calls_prot
sw_len_dc128_gap1 | RNG_LOW_IDLE,INT_LEN_DC=128,SW_GAP=1 | pass | rv_c1_chain i:8:8:256:1:8:0:0:1:uniform:76 af_uL_001_032 i:8:8:256:1:8:3:0:0:uniform:77 af_perhead
all_interleaved_len_dc | INT_JUNK,RNG_LOW_IDLE,INT_LEN_DC=255,SEED=6 | pass | @ALL
neg_sw_early_int | NEG_SW_EARLY_INT | fail:TIMING | plain_u128 i:8:8:256:1:8:0:0:1:uniform:61 plain_u97
neg_sw_late_drop | NEG_SW_LATE_DROP | fail:CHECK+CONTRACT | plain_u128 i:8:8:256:1:8:0:0:1:uniform:62 plain_u97
neg_sw_no_zero_load | NEG_SW_NO_ZERO_LOAD | fail:BPCONTRACT | plain_u128 i:8:8:256:1:8:0:0:1:uniform:63 plain_u97
neg_sw_int_drop_early | NEG_SW_INT_DROP_EARLY | fail:TIMING | plain_u128 i:8:8:256:1:8:0:0:1:uniform:64 plain_u97
neg_sw_no_reload | NEG_SW_NO_RELOAD | fail:CHECK+CONTRACT | plain_u128 i:8:8:256:1:8:0:0:1:uniform:65 plain_u97
neg_sw_cut_across_int | NEG_SHORT_LAST=2,RNG_LOW_IDLE | fail:CHECK+CONTRACT+CUT | plain_u128 i:8:8:256:1:8:0:0:1:uniform:78 plain_u97
EOF
)
sw_case() {   # label flags expect items...
    local label=$1 flags=$2 expect=$3 items=$4 dir="$OUT/switch/$1" seq=() it n=0 bad=0 f rc=0 tags t
    local -a plus parts
    mapfile -t plus < <(plus_of "$flags")
    rm -rf "$dir"; mkdir -p "$dir"
    for it in $items; do
        if [[ $it == i:* ]]; then
            IFS=: read -ra parts <<< "$it"
            mkdir -p "$dir/i$n"
            python3 "$GEN" --ba "${parts[1]}" --bw "${parts[2]}" --L "${parts[3]}" --mrows "${parts[4]}" \
                --ncols "${parts[5]}" --dist "${parts[9]}" --seed "${parts[10]}" --out-dir "$dir/i$n" > "$dir/i$n/gen.log"
            echo "${parts[1]} ${parts[2]} ${parts[3]} ${parts[4]} ${parts[5]} ${parts[6]} ${parts[7]} ${parts[8]}" > "$dir/i$n/bpt_cfg.txt"
            seq+=("int:$REPO/$dir/i$n")
            n=$((n + 1))
        else
            seq+=("sc:$(resolve "$it")") || { echo "$label: FAIL (case $it)"; return 1; }
        fi
    done
    (cd "$dir" && "$REPO/$OUT/build_int/simv" +MODE=switch "+SWITCH=$(IFS=,; echo "${seq[*]}")" "${plus[@]}" > sim.log 2>&1) || rc=$?
    case "$expect" in
        pass)
            grep -q '^PASS: CBSG AF-IPD switch bench' "$dir/sim.log" || { echo "$label: FAIL (bench, see $dir/sim.log)"; return 1; }
            for ((f = 0; f < n; f++)); do
                python3 "$CHK" "$dir/i$f" --json "$dir/i$f/check.json" > "$dir/i$f/check.log" 2>&1 || bad=$((bad + 1))
            done
            (( bad == 0 )) || { echo "$label: FAIL ($bad of $n INT segments not bit-exact)"; return 1; }
            echo "$label: PASS ($(grep -m1 '^SWITCH_RESULT' "$dir/sim.log" | sed 's/^SWITCH_RESULT //'); SC: $(grep -m1 '^RESULT' "$dir/sim.log" | grep -oE 'blocks=[0-9]+ drains=[0-9]+'), $(grep -m1 '^RESULT' "$dir/sim.log" | grep -oE 'drain values [0-9]+ bad 0'), contract 0; INT: $n segments bit-exact, $(python3 -c 'import sys,json; print(sum(json.load(open(f))["macs"] for f in sys.argv[1:]), "MACs")' "$dir"/i*/check.json))" ;;
        fail:TIMING|fail:BPCONTRACT)
            t=TIMING-FAIL; [[ $expect == fail:BPCONTRACT ]] && t=BP-CONTRACT
            grep -q "\[$t\]" "$dir/sim.log" && ! grep -q '^PASS:' "$dir/sim.log" \
                && { echo "$label: PASS (negative control caught by [$t]:$(grep -m1 "\[$t\]" "$dir/sim.log" | sed 's/^.*\]//' | cut -c1-90))"; return 0; }
            echo "$label: FAIL (expected [$t], see $dir/sim.log)"; return 1 ;;
        fail:*)
            grep -q '^FAIL: CBSG AF-IPD switch bench' "$dir/sim.log" || { echo "$label: FAIL (negative control not caught, see $dir/sim.log)"; return 1; }
            tags=""
            for t in CHECK BLOCK KA PHASE CONTRACT INTCOUNT; do grep -q "^\[$t\] " "$dir/sim.log" && tags+=" $t"; done
            grep -q 'cuts a block' "$dir/sim.log" && tags+=" CUT"
            IFS=+ read -ra parts <<< "${expect#fail:}"
            for t in "${parts[@]}"; do
                [[ " $tags " == *" $t "* ]] || { echo "$label: FAIL (tag $t missing; tags:$tags)"; return 1; }
            done
            echo "$label: PASS (negative control caught, tags:$tags; $(grep -E '^\[(CHECK|CONTRACT)\] [0-9]' "$dir/sim.log" | sed 's/ \[CBSG-AF-CONTRACT\] errors//' | tr '\n' ';' | sed 's/;$//'))" ;;
    esac
}
run_switch() {
    local status=0 label flags expect items all="" k=0 c cfgs
    rm -rf "$OUT/switch"; mkdir -p "$OUT/switch"
    build_int || return 1
    # @ALL: every golden / extra / review case, each followed by an INT block (rotating precision,
    # MODE_AT, junk and shift contract).
    cfgs=("8:8:256:1:8:0:0:1" "8:4:384:1:8:1:1:0" "4:4:256:2:8:2:0:1" "8:8:128:1:16:3:1:1" "4:4:384:2:8:0:1:0" "8:4:128:1:8:0:0:0")
    for c in "$GOLD"/*/ "$EXTRA"/*/ "$RV"/*/; do
        all+="$(basename "$c") i:${cfgs[$((k % 6))]}:uniform:$((100 + k)) "
        k=$((k + 1))
    done
    while IFS='|' read -r label flags expect items; do
        label=$(echo $label); flags=$(echo $flags); expect=$(echo $expect); items=$(echo $items)
        [[ -n "$label" ]] || continue
        [[ "$items" == @ALL ]] && items=$all
        sw_case "$label" "$flags" "$expect" "$items" &
        jobs_wait || status=1
    done <<< "$SW_CASES"
    jobs_drain || status=1
    echo "SC <-> INT switching: $(grep -c . <<< "$SW_CASES") runs, status $([[ $status == 0 ]] && echo PASS || echo FAIL)"
    return "$status"
}

#------------------------------------------------------------------ (grid) --
GTB=designs/payn/tb/test_pe_grid_cbsg_af_ipd.sv
GTB_ORIG=designs/payn/tb/test_pe_grid_bp_ipd.sv
GCHK=$D/check_bp_ipd_grid_trace.py
# label kind shape BA BW L NIG NJG DIST SEED FLAGS EXPECT  (kind: g = this grid; xc = this grid vs the
# original bench on the original IPD grid, traces byte-identical).  The 2x2 / 4x4 rows of
# sweeps/int_mode/bp/ipd/run_bp_ipd_grid_checks.sh.
GRID_CASES=$(cat <<'EOF'
g2x2_int8_uniform_L256_b2x1        g  2x2 8 8  256 2 1 uniform     1 -                    pass
g2x2_int8_uniform_L384_b1x2_junk   g  2x2 8 8  384 1 2 uniform     2 JUNK                 pass
g2x2_w4a8_uniform_L512_b2x1        g  2x2 8 4  512 2 1 uniform     3 -                    pass
g2x2_int4_uniform_L256_b1x2        g  2x2 4 4  256 1 2 uniform     4 -                    pass
g2x2_int8_allmin_L1024_b1x1        g  2x2 8 8 1024 1 1 allmin      0 -                    pass
g2x2_int8_neg1xmin_L512_b2x1       g  2x2 8 8  512 2 1 neg1xmin    0 -                    pass
g2x2_int8_globalwait_L256_b2x1     g  2x2 8 8  256 2 1 uniform     5 GLOBAL_LAP_WAIT      pass
g2x2_neg_ring_no_row_skew          g  2x2 8 8  256 1 1 uniform     6 NEG_RING_NO_ROW_SKEW fail
g2x2_neg_ring_no_col_skew          g  2x2 8 8  256 1 1 uniform     7 NEG_RING_NO_COL_SKEW fail
g2x2_neg_global_lap                g  2x2 8 8  256 1 1 uniform     8 NEG_GLOBAL_LAP       fail
g2x2_int8_gatejunk_L256_b2x1       g  2x2 8 8  256 2 1 uniform     9 RING_GATE_JUNK,JUNK  pass
g2x2_neg_gap_short                 g  2x2 8 8  256 1 1 uniform    61 NEG_GAP_SHORT        fail
g2x2_neg_drain_early               g  2x2 8 8  256 1 1 uniform    62 NEG_DRAIN_EARLY      fail
g2x2_neg_block_overlap             g  2x2 8 8  256 2 1 uniform    63 NEG_BLOCK_OVERLAP    fail
g2x2_neg_oldc_unforced             g  2x2 8 8  256 1 1 uniform    85 OLDC_UNFORCED        fail
g2x2_neg_lap0                      g  2x2 8 8  256 1 1 uniform    91 LAP_LEN=0            fail
g2x2_neg_lap2                      g  2x2 8 8  256 1 1 uniform    92 LAP_LEN=2            fail
g2x2_neg_lap8                      g  2x2 8 8  256 1 1 uniform    93 LAP_LEN=8            fail
g2x2_neg_ring_stray                g  2x2 8 8  256 1 1 uniform    94 NEG_RING_STRAY       fail
g4x4_int8_uniform_L256_b2x1        g  4x4 8 8  256 2 1 uniform    31 -                    pass
g4x4_int8_uniform_L256_b1x2_junk   g  4x4 8 8  256 1 2 uniform    32 JUNK                 pass
g4x4_w4a8_uniform_L384_b2x1        g  4x4 8 4  384 2 1 uniform    33 -                    pass
g4x4_int4_uniform_L256_b2x1        g  4x4 4 4  256 2 1 uniform    34 -                    pass
g4x4_int8_allmin_L512_b1x1         g  4x4 8 8  512 1 1 allmin      0 -                    pass
g4x4_int8_uniform_L1024_b1x1       g  4x4 8 8 1024 1 1 uniform    38 -                    pass
g4x4_int8_uniform_L1024_b1x2_junk  g  4x4 8 8 1024 1 2 uniform    39 JUNK                 pass
g4x4_int8_uniform_L4096_b1x1       g  4x4 8 8 4096 1 1 uniform    35 -                    pass
g4x4_int8_uniform_L4096_b2x1       g  4x4 8 8 4096 2 1 uniform    40 -                    pass
g4x4_w4a8_uniform_L4096_b1x1       g  4x4 8 4 4096 1 1 uniform    36 -                    pass
g4x4_int4_uniform_L4096_b1x1       g  4x4 4 4 4096 1 1 uniform    37 -                    pass
g4x4_int8_globalwait_L4096_b1x1    g  4x4 8 8 4096 1 1 uniform    35 GLOBAL_LAP_WAIT      pass
g4x4_neg_ring_no_row_skew          g  4x4 8 8  256 1 1 uniform    41 NEG_RING_NO_ROW_SKEW fail
g4x4_neg_ring_no_col_skew          g  4x4 8 8  256 1 1 uniform    42 NEG_RING_NO_COL_SKEW fail
g4x4_neg_global_lap                g  4x4 8 8  256 1 1 uniform    43 NEG_GLOBAL_LAP       fail
g4x4_w4a8_gatejunk_L256_b2x2_junk  g  4x4 8 4  256 2 2 uniform    44 RING_GATE_JUNK,JUNK  pass
g4x4_neg_gap_short                 g  4x4 8 8  256 1 1 uniform    66 NEG_GAP_SHORT        fail
g4x4_neg_drain_early               g  4x4 8 8  256 1 1 uniform    67 NEG_DRAIN_EARLY      fail
g4x4_neg_block_overlap             g  4x4 8 8  256 1 2 uniform    68 NEG_BLOCK_OVERLAP    fail
g4x4_neg_lap0                      g  4x4 8 8  256 1 1 uniform    96 LAP_LEN=0            fail
g4x4_neg_lap2                      g  4x4 8 8  256 1 1 uniform    97 LAP_LEN=2            fail
g4x4_neg_ring_stray                g  4x4 8 8  256 1 1 uniform    98 NEG_RING_STRAY       fail
xc2x2_int8_uniform_L256_b2x1       xc 2x2 8 8  256 2 1 uniform     1 -                    pass
xc2x2_int8_uniform_L384_b1x2_junk  xc 2x2 8 8  384 1 2 uniform     2 JUNK                 pass
xc2x2_int8_gatejunk_L256_b2x1      xc 2x2 8 8  256 2 1 uniform     9 RING_GATE_JUNK,JUNK  pass
xc2x2_int8_globalwait_L256_b2x1    xc 2x2 8 8  256 2 1 uniform     5 GLOBAL_LAP_WAIT      pass
xc2x2_neg_gap_short                xc 2x2 8 8  256 1 1 uniform    61 NEG_GAP_SHORT        fail
xc4x4_int8_uniform_L4096_b1x1      xc 4x4 8 8 4096 1 1 uniform    35 -                    pass
xc4x4_w4a8_uniform_L4096_b1x1      xc 4x4 8 4 4096 1 1 uniform    36 -                    pass
xc4x4_int4_uniform_L256_b2x1       xc 4x4 4 4  256 2 1 uniform    34 -                    pass
xc4x4_int8_uniform_L1024_b1x2_junk xc 4x4 8 8 1024 1 2 uniform    39 JUNK                 pass
xc4x4_neg_ring_stray               xc 4x4 8 8  256 1 1 uniform    98 NEG_RING_STRAY       fail
EOF
)
grid_sim() {   # dir simv ba bw L mrows ncols dist seed flags expect -> RESULT
    local dir=$1 simv=$2 ba=$3 bw=$4 L=$5 mrows=$6 ncols=$7 dist=$8 seed=$9 flags=${10} expect=${11} nm
    local -a plus
    mapfile -t plus < <(plus_of "$flags")
    rm -rf "$dir"; mkdir -p "$dir"
    python3 "$GEN" --ba "$ba" --bw "$bw" --L "$L" --mrows "$mrows" --ncols "$ncols" --dist "$dist" \
        --seed "$seed" --out-dir "$dir" > "$dir/gen.log"
    (cd "$dir" && "$simv" +BA="$ba" +BW="$bw" +L="$L" +MROWS="$mrows" +NCOLS="$ncols" "${plus[@]}" > sim.log 2>&1)
    grep -q '^PASS: BP grid bench' "$dir/sim.log" || { RESULT="FAIL (simulation error, $dir/sim.log)"; return 1; }
    if python3 "$GCHK" "$dir" --json "$dir/check.json" > "$dir/check.log" 2>&1; then
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
grid_one() {   # label kind shape ba bw L nig njg dist seed flags expect
    local label=$1 kind=$2 shape=$3 ba=$4 bw=$5 L=$6 nig=$7 njg=$8 dist=$9 seed=${10} flags=${11} expect=${12}
    local pr=${shape%x*} pc=${shape#*x} dir="$OUT/grid/$label" RESULT r1
    local mrows=$(( pr * (8 / ba) * nig )) ncols=$(( 8 * pc * njg ))
    if [[ $kind == g ]]; then
        grid_sim "$dir" "$REPO/$OUT/grid/build_g$shape/simv" "$ba" "$bw" "$L" "$mrows" "$ncols" "$dist" "$seed" "$flags" "$expect"
        local rc=$?; echo "$label: $RESULT"; return $rc
    fi
    grid_sim "$dir/afipd" "$REPO/$OUT/grid/build_g$shape/simv" "$ba" "$bw" "$L" "$mrows" "$ncols" "$dist" "$seed" "$flags" "$expect" \
        || { echo "$label: FAIL (copied grid: $RESULT)"; return 1; }
    r1=$RESULT
    grid_sim "$dir/orig" "$REPO/$OUT/grid/build_orig$shape/simv" "$ba" "$bw" "$L" "$mrows" "$ncols" "$dist" "$seed" "$flags" "$expect" \
        || { echo "$label: FAIL (original IPD grid: $RESULT)"; return 1; }
    cmp -s "$dir/afipd/bpg_trace.txt" "$dir/orig/bpg_trace.txt" || { echo "$label: FAIL (traces differ)"; return 1; }
    echo "$label: PASS (copied grid trace byte-identical to the original IPD grid's, $(wc -l < "$dir/orig/bpg_trace.txt") lines; ${r1#PASS })"
}
run_grid() {
    local status=0 s pids=()
    rm -rf "$OUT/grid"; mkdir -p "$OUT/grid"
    for s in 2x2 4x4; do
        vcs_compile "$OUT/grid/build_g$s" "$GTB" Top "+define+BPG_PR=${s%x*}+define+BPG_PC=${s#*x}" & pids+=("$!")
        vcs_compile "$OUT/grid/build_orig$s" "$GTB_ORIG" Top "+define+BPG_PR=${s%x*}+define+BPG_PC=${s#*x}" & pids+=("$!")
    done
    for p in "${pids[@]}"; do wait "$p" || status=1; done
    (( status == 0 )) || { echo "grid compile FAILED ($OUT/grid/build_*/compile.log)"; return 1; }
    for s in 2x2 4x4; do
        grep -q "signed_segmented_csa_cbsg_af_ipd/inner_pe_core_signed_segmented_csa_cbsg_af_ipd.sv" "$OUT/grid/build_g$s/compile.log" \
            || { echo "grid build $s did not read the AF-IPD PE core"; return 1; }
    done
    while read -r label kind shape ba bw L nig njg dist seed flags expect; do
        [[ -n "$label" ]] || continue
        grid_one "$label" "$kind" "$shape" "$ba" "$bw" "$L" "$nig" "$njg" "$dist" "$seed" "$flags" "$expect" &
        jobs_wait || status=1
    done <<< "$GRID_CASES"
    jobs_drain || status=1
    python3 - "$OUT/grid" <<'PY'
import json, sys
from pathlib import Path
rows = []
for p in sorted(Path(sys.argv[1]).glob("g*/check.json")):
    d = json.loads(p.read_text())
    if d["status"] != "PASS":
        continue
    rows.append((d["grid"], d["precision"], d["L"], d["blocks"], d["mode"], d["lap_len"], d["block_len"],
                 d["measured_periods"] or "-", d["formula_per_pe_laps"], d["data_edge_utilization"], p.parent.name))
print("grid block periods (passing runs): grid prec L blocks mode lap_len block_len measured "
      "formula(BW*NB+LAP_LEN*(BW-1)+S+8*P_C) util case")
for r in sorted(rows):
    print("  " + " ".join(str(x) for x in r))
PY
    echo "IPD grid wrapper, rename check (rename-only copy of the IPD grid; no AF edge, bypass, mode register, guard or combiner, so not AF-IPD grid evidence), 2x2 and 4x4: $(grep -c . <<< "$GRID_CASES") cases, status $([[ $status == 0 ]] && echo PASS || echo FAIL)"
    return "$status"
}

#----------------------------------------------------------------- (power) --
PTB=designs/payn/power/power_payn_array_cbsg_af_ipd.sv
PTB_AF=designs/payn/power/power_payn_array_cbsg_af.sv
ITB=designs/payn/power/power_payn_array_cbsg_af_ipd_int.sv
pwr_sc_run() {   # tag tb defines
    local tag=$1 tb=$2 def=$3 b="$OUT/power/$1"
    vcs_compile "$b" "$tb" Top $def || { echo "$tag: compile FAILED"; return 1; }
    (cd "$b" && ./simv > sim.log 2>&1)
    grep -q '^PASS: streaming C-BSG AF' "$b/sim.log" || { echo "$tag: FAIL (see $b/sim.log)"; return 1; }
}
# label BA BW L MROWS NCOLS SAIF_MODE extra-plusargs(- or comma list) checker-args
PWR_INT=$(cat <<'EOF'
int8_L1024_dr     8 8 1024 1 8 0 -                --lap-ring-only
int8_L1024_d      8 8 1024 1 8 1 -                --lap-ring-only
int8_L1024_all    8 8 1024 1 8 2 -                --lap-ring-only
w4a8_L1024_dr     8 4 1024 1 8 0 -                --lap-ring-only
int4_L1024_dr     4 4 1024 2 8 0 -                --lap-ring-only
int4_L1024_all    4 4 1024 2 8 2 -                --lap-ring-only
int8_L2048_m2n16_dr 8 8 2048 2 16 0 -             --lap-ring-only
int8_L1024_dr_shiftlaps 8 8 1024 1 8 0 LAP_RING_ONLY=0 -
int8_L1024_dr_modeat_m1 8 8 1024 1 8 0 MODE_AT=-1 --lap-ring-only
EOF
)
pwr_int_case() {   # label ba bw L mrows ncols mode extra chkargs
    local label=$1 ba=$2 bw=$3 L=$4 mrows=$5 ncols=$6 mode=$7 extra=$8 chk=$9 dir="$OUT/power/int/$1"
    local -a plus cargs=()
    mapfile -t plus < <(plus_of "$extra")
    [[ "$chk" == - ]] || cargs=("$chk")
    rm -rf "$dir"; mkdir -p "$dir"
    python3 "$GEN" --ba "$ba" --bw "$bw" --L "$L" --mrows "$mrows" --ncols "$ncols" --dist uniform --seed 1 \
        --out-dir "$dir" > "$dir/gen.log"
    (cd "$dir" && "$REPO/$OUT/power/build_int/simv" +BA="$ba" +BW="$bw" +L="$L" +MROWS="$mrows" +NCOLS="$ncols" \
        +SAIF_MODE="$mode" "${plus[@]}" > sim.log 2>&1)
    grep -q '^PASS: BP INT SAIF captured' "$dir/sim.log" || { echo "$label: FAIL (bench, see $dir/sim.log)"; return 1; }
    python3 $D/check_bp_power_trace.py "$dir" --json "$dir/check.json" --lap-len 1 "${cargs[@]}" > "$dir/check.log" 2>&1 \
        || { echo "$label: FAIL $(tail -1 "$dir/check.log")"; return 1; }
    echo "$label: PASS $(tail -1 "$dir/check.log" | sed 's/^\[PASS\] //'); SAIF $(stat -c %s "$dir/dut.saif") B"
}
run_power() {
    local status=0 wl def pids=() label ba bw L mrows ncols mode extra chk
    rm -rf "$OUT/power"; mkdir -p "$OUT/power/int"
    for wl in uniform ladder; do
        def=""; [[ $wl == ladder ]] && def="+define+CBSG_PWR_LADDER"
        pwr_sc_run "af_$wl" "$PTB_AF" "$def" > "$OUT/power/af_$wl.out" 2>&1 & pids+=("$!")
        pwr_sc_run "afipd_$wl" "$PTB" "$def" > "$OUT/power/afipd_$wl.out" 2>&1 & pids+=("$!")
        pwr_sc_run "afipd_junk_$wl" "$PTB" "$def+define+CAI_PWR_INT_JUNK" > "$OUT/power/afipd_junk_$wl.out" 2>&1 & pids+=("$!")
    done
    vcs_compile "$OUT/power/build_int" "$ITB" Top & pids+=("$!")
    for p in "${pids[@]}"; do wait "$p" || status=1; done
    cat "$OUT"/power/*.out 2>/dev/null
    for wl in uniform ladder; do
        local t_af="$OUT/power/af_$wl/array_streaming_cbsg_af_rtl.txt"
        if cmp -s "$t_af" "$OUT/power/afipd_$wl/array_streaming_cbsg_af_rtl.txt" \
           && cmp -s "$t_af" "$OUT/power/afipd_junk_$wl/array_streaming_cbsg_af_rtl.txt" \
           && python3 sweeps/cbsg/af/check_power_trace.py "$OUT/power/afipd_junk_$wl/array_streaming_cbsg_af_rtl.txt" \
                  --json "$OUT/power/afipd_junk_$wl/check.json" > "$OUT/power/afipd_junk_${wl}_check.log" 2>&1; then
            echo "sc_power_$wl: PASS (trace byte-identical to the AF top's, INT inputs tied off and junk; $(sed 's/^\[PASS\] //' "$OUT/power/afipd_junk_${wl}_check.log"); SAIF $(stat -c %s "$OUT/power/afipd_$wl/dut.saif") B tied-off)"
        else
            echo "sc_power_$wl: FAIL (traces differ from the AF top's or check failed)"; status=1
        fi
    done
    [[ -x "$OUT/power/build_int/simv" ]] || { echo "INT energy bench compile FAILED"; return 1; }
    while read -r label ba bw L mrows ncols mode extra chk; do
        [[ -n "$label" ]] || continue
        pwr_int_case "$label" "$ba" "$bw" "$L" "$mrows" "$ncols" "$mode" "$extra" "$chk" &
        jobs_wait || status=1
    done <<< "$PWR_INT"
    jobs_drain || status=1
    echo "power benches: status $([[ $status == 0 ]] && echo PASS || echo FAIL)"
    return "$status"
}

#------------------------------------------------------------------ driver --
status=0
order=(copies ref units sc sctrace int intx switch grid power)
# ref first (sc / sctrace / switch need its cases); int before intx; the rest in parallel groups.
for p in copies ref units; do
    [[ " $PARTS " == *" $p "* ]] || continue
    "run_$p" > "$OUT/${p}_summary.log" 2>&1 || status=1
done
pids=()
for p in sc int grid power; do
    [[ " $PARTS " == *" $p "* ]] || continue
    { "run_$p" > "$OUT/${p}_summary.log" 2>&1; } & pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid" || status=1; done
pids=()
for p in sctrace intx switch; do
    [[ " $PARTS " == *" $p "* ]] || continue
    { "run_$p" > "$OUT/${p}_summary.log" 2>&1; } & pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid" || status=1; done
{
    echo "C-BSG AF + IPD RTL checks, $(date '+%F %T'), RTL designs/payn/variants/signed_segmented_csa_cbsg_af_ipd"
    for p in "${order[@]}"; do
        [[ " $PARTS " == *" $p "* ]] || continue
        echo "== $p"
        case $p in
            sc)
                sort "$OUT/sc_summary.log"
                awk '/: PASS \(cases=/ {
                         n++; for (i = 1; i <= NF; i++) {
                             if ($i ~ /^blocks=/) { split($i, a, "="); b += a[2] }
                             if ($i == "drain" && $(i+1) == "values") d += $(i+2)
                             if ($i == "block" && $(i+1) == "values") k += $(i+2)
                             if ($i == "kA" && $(i+1) == "values") e += $(i+2)
                             if ($i == "lockstep" && $(i+1) == "edges") l += $(i+2) } }
                     /negative control caught/ { neg++ }
                     END { printf "SC totals: %d passing runs, %d blocks, %d drained accumulators, %d per-block accumulators, %d kA values bit-exact; %d lockstep edges (positive runs) identical to the AF top; %d negative controls caught\n", n, b, d, k, e, l, neg }' \
                    "$OUT/sc_summary.log" ;;
            int)
                grep -v '^  \|^single-PE block\|^period rows' "$OUT/int_summary.log" | sort
                grep '^single-PE block\|^  \|^period rows' "$OUT/int_summary.log" || true ;;
            grid|switch|intx|sctrace|power)
                grep -v '^  \|^grid block' "$OUT/${p}_summary.log" | sort
                grep '^grid block\|^  ' "$OUT/${p}_summary.log" || true ;;
            *) cat "$OUT/${p}_summary.log" ;;
        esac
    done
    echo "C-BSG AF + IPD RTL checks: $([[ $status == 0 ]] && echo PASS || echo FAIL)"
} | tee "$OUT/rtl_checks_summary.log"
exit "$status"
