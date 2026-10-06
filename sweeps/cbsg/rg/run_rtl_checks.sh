#!/bin/bash
# RTL checks for the C-BSG RG variant (designs/payn/variants/signed_segmented_csa_cbsg_rg).
#
# (a) Goldens.  cbsg_ref.py --check-golden re-derives the 12 shared cases in build/cbsg/golden (read only),
#     and sweeps/cbsg/rg/gen_cases.py writes and re-checks the long multi-call cases in
#     build/cbsg/rg/golden_extra (every L 1..128 plain / chunked 128, 96, 100 / per-head, all trace ladders,
#     heterogeneous back-to-back calls, extreme magnitudes, a 2048-column slice).
# (b) Golden playback on designs/payn/tb/test_payn_array_cbsg_rg.sv.  Every drain is compared bit-exactly
#     with acc_exp.mem; the bench also peeks every tile after every block (acc_blk.mem) and the DUT phase
#     register after every block start (phase.mem).  Every run's three mismatch counts must equal what
#     sweeps/cbsg/rg/predict_faults.py predicts from the .mem files for that run's sequencer policy, DUT
#     fault, cycle policy, phase-reset build and peek mode:
#       pass   all three counts 0 (all cases; FULL_CYCLES; STALL; JUNK; IDX_W = 7 and 9 builds; the
#              slice_start-only build DRAIN_PHASE_RESET = 0; drain-only NO_PEEK and GL_SIM-shaped builds)
#       fail   negative control: drain mismatches > 0, exactly as predicted (sequencer, on the
#              DRAIN_PHASE_RESET = 0 build: phase not reset at call starts / at slice starts / ever; one
#              cycle short; DUT mutations FAULT=1..6 on the CBSG_RG_FAULT_HOOKS builds: lane mask bits,
#              W index = t, no length gate, phase never reset, W index not cleared per block, mask phase
#              one cycle early)
#       blind  a negative control the case cannot see: 0 drain mismatches, as predicted.  This includes the
#              three phase-reset sequencer mistakes on the default build, where the drain that ends every
#              slice arms the phase reset (phase and block counts must be 0 too)
#     Also checked at compile time: a FAULT != 0 build without CBSG_RG_FAULT_HOOKS stops at time 0.
# (d) Fault-hook guard in the synthesis view (part "elab"): DC GTECH elaboration (no target library, no AFS)
#     of the top with FAULT = 0, 1, 2, 4, 6 and no hooks define must write the same netlist as FAULT = 0
#     (FAULT is ignored); with +define CBSG_RG_FAULT_HOOKS, FAULT = 2 and 4 must change it (positive control).
# (c) Streaming power bench designs/payn/power/power_payn_array_cbsg_rg.sv, 384 back-to-back blocks: uniform
#     L = 128 (headline), ladder_rowmix (rung-table worst case, per-row L mixed inside a tile) and
#     ladder_rowgrouped (one L per chunk shared by the tile's rows); sweeps/cbsg/rg/check_power_trace.py
#     recomputes the drain with cbsg_ref (kernel and RG model) bit-exactly.
#
#   bash sweeps/cbsg/rg/run_rtl_checks.sh                # everything
#   PARTS="golden tb" bash sweeps/cbsg/rg/run_rtl_checks.sh   # subsets: golden, tb, power, elab
# Outputs: build/cbsg/rg/ (summary rtl_checks_summary.log; runs/<label>/; power/<workload>/; build/<name>/).
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
export SNPSLMD_QUEUE=true   # queue for Synopsys licenses (also covers the simv that make sim runs)
PARTS=${PARTS:-"golden tb power elab"}
# Parallel simv runs.  Every compile waits for a VCS license (-licwait) and every simv too
# (+vcs+lic+wait), so contention with other sessions slows the suite instead of failing runs.
MAX_JOBS=${MAX_JOBS:-32}
LICWAIT_MIN=${LICWAIT_MIN:-60}
OUT=build/cbsg/rg
GOLD=build/cbsg/golden
XG=$OUT/golden_extra
TB=designs/payn/tb/test_payn_array_cbsg_rg.sv
PWR=designs/payn/power/power_payn_array_cbsg_rg.sv
VCS_RTL="vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -licwait $LICWAIT_MIN \$(VCS_ARGS) +incdir+\$(DESIGNS_DIR) -assert svaext"
VCS_PP="vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -licwait $LICWAIT_MIN -debug_access+pp \$(VCS_ARGS) +incdir+\$(DESIGNS_DIR) -assert svaext"
SUMMARY=$OUT/rtl_checks_summary.log
mkdir -p "$OUT"

#------------------------------------------------------------- (a) goldens --
run_golden() {
    local status=0 pids=() c
    python3 sweeps/cbsg/cbsg_ref.py --check-golden "$GOLD" > "$OUT/golden_check.log" 2>&1 || status=1
    mkdir -p "$OUT/gen_logs"
    for c in allL_plain ladders_plain allL_chunk128 allL_chunk96 allL_chunk100 allL_perhead calls_mix extreme_mix range_2048; do
        python3 sweeps/cbsg/rg/gen_cases.py --out "$XG" --case "$c" > "$OUT/gen_logs/$c.log" 2>&1 & pids+=("$!")
    done
    for p in "${pids[@]}"; do wait "$p" || status=1; done
    cat "$OUT/golden_check.log"
    cat "$OUT"/gen_logs/*.log | sed "s#$REPO/##"
    echo "goldens: shared $(grep -c '^\[PASS\]' "$OUT/golden_check.log")/12 re-derived PASS, extra $(grep -c 'check_golden PASS' "$OUT"/gen_logs/*.log | awk -F: '{s+=$2} END {print s}')/9 written and re-derived PASS"
    return "$status"
}

#------------------------------------------------------- (b) golden playback --
# label build case_dir plusargs expect policy fault cycles
MATRIX=$(cat <<EOF
g_plain_u128              base $GOLD/plain_u128      -                pass  slice  none           exact
g_plain_u97               base $GOLD/plain_u97       -                pass  slice  none           exact
g_plain_ladder            base $GOLD/plain_ladder    -                pass  slice  none           exact
g_plain_extreme           base $GOLD/plain_extreme   -                pass  slice  none           exact
g_chunked_rung            base $GOLD/chunked_rung    -                pass  slice  none           exact
g_chunked_tail5           base $GOLD/chunked_tail5   -                pass  slice  none           exact
g_chunked_96              base $GOLD/chunked_96      -                pass  slice  none           exact
g_chunked_100             base $GOLD/chunked_100     -                pass  slice  none           exact
g_perhead_64              base $GOLD/perhead_64      -                pass  slice  none           exact
g_perhead_128             base $GOLD/perhead_128     -                pass  slice  none           exact
g_calls_prot              base $GOLD/calls_prot      -                pass  slice  none           exact
g_calls_av257             base $GOLD/calls_av257     -                pass  slice  none           exact
x_allL_plain              base $XG/allL_plain        -                pass  slice  none           exact
x_ladders_plain           base $XG/ladders_plain     -                pass  slice  none           exact
x_allL_chunk128           base $XG/allL_chunk128     -                pass  slice  none           exact
x_allL_chunk96            base $XG/allL_chunk96      -                pass  slice  none           exact
x_allL_chunk100           base $XG/allL_chunk100     -                pass  slice  none           exact
x_allL_perhead            base $XG/allL_perhead      -                pass  slice  none           exact
x_calls_mix               base $XG/calls_mix         -                pass  slice  none           exact
x_extreme_mix             base $XG/extreme_mix       -                pass  slice  none           exact
x_range_2048              base $XG/range_2048        -                pass  slice  none           exact
full_plain_ladder         base $GOLD/plain_ladder    FULL_CYCLES      pass  slice  none           full
full_chunked_100          base $GOLD/chunked_100     FULL_CYCLES      pass  slice  none           full
full_calls_av257          base $GOLD/calls_av257     FULL_CYCLES      pass  slice  none           full
full_calls_mix            base $XG/calls_mix         FULL_CYCLES      pass  slice  none           full
full_allL_plain           base $XG/allL_plain        FULL_CYCLES      pass  slice  none           full
stall_calls_prot          base $GOLD/calls_prot      STALL=25,SEED=3  pass  slice  none           exact
stall_chunked_96          base $GOLD/chunked_96      STALL=25,SEED=4  pass  slice  none           exact
stall_calls_mix           base $XG/calls_mix         STALL=30,SEED=5  pass  slice  none           exact
stall_allL_chunk100       base $XG/allL_chunk100     STALL=15,SEED=6  pass  slice  none           exact
stall_plain_extreme       base $GOLD/plain_extreme   STALL=50,SEED=7  pass  slice  none           exact
junk_calls_mix            base $XG/calls_mix         JUNK,SEED=8      pass  slice  none           exact
junk_chunked_rung         base $GOLD/chunked_rung    JUNK,SEED=9      pass  slice  none           exact
junk_allL_perhead         base $XG/allL_perhead      JUNK,SEED=10     pass  slice  none           exact
junk_plain_ladder         base $GOLD/plain_ladder    JUNK,SEED=11     pass  slice  none           exact
stalljunk_calls_av257     base $GOLD/calls_av257     STALL=20,JUNK,SEED=12 pass slice none        exact
stalljunk_ladders_plain   base $XG/ladders_plain     STALL=20,JUNK,SEED=13 pass slice none        exact
idx7_plain_u128           idx7 $GOLD/plain_u128      -                pass  slice  none           exact
idx7_calls_prot           idx7 $GOLD/calls_prot      -                pass  slice  none           exact
idx7_calls_mix            idx7 $XG/calls_mix         -                pass  slice  none           exact
idx7_allL_plain           idx7 $XG/allL_plain        -                pass  slice  none           exact
idx7_extreme_mix          idx7 $XG/extreme_mix       -                pass  slice  none           exact
idx7_range_2048           idx7 $XG/range_2048        -                pass  slice  none           exact
idx9_calls_mix            idx9 $XG/calls_mix         -                pass  slice  none           exact
idx9_allL_plain           idx9 $XG/allL_plain        -                pass  slice  none           exact
idx9_extreme_mix          idx9 $XG/extreme_mix       -                pass  slice  none           exact
neg_nocall_calls_prot     nodr $GOLD/calls_prot      NEG_NO_CALL_RESET  fail  nocall none         exact
neg_nocall_calls_av257    nodr $GOLD/calls_av257     NEG_NO_CALL_RESET  fail  nocall none         exact
neg_nocall_calls_mix      nodr $XG/calls_mix         NEG_NO_CALL_RESET  fail  nocall none         exact
neg_nocall_allL_plain     nodr $XG/allL_plain        NEG_NO_CALL_RESET  fail  nocall none         exact
neg_nocall_ladders_plain  nodr $XG/ladders_plain     NEG_NO_CALL_RESET  fail  nocall none         exact
blind_nocall_chunked_96   nodr $GOLD/chunked_96      NEG_NO_CALL_RESET  blind nocall none         exact
neg_noslice_chunked_96    nodr $GOLD/chunked_96      NEG_NO_SLICE_RESET fail  call   none         exact
neg_noslice_chunked_100   nodr $GOLD/chunked_100     NEG_NO_SLICE_RESET fail  call   none         exact
neg_noslice_allL_chunk96  nodr $XG/allL_chunk96      NEG_NO_SLICE_RESET fail  call   none         exact
neg_noslice_allL_perhead  nodr $XG/allL_perhead      NEG_NO_SLICE_RESET fail  call   none         exact
blind_noslice_calls_prot  nodr $GOLD/calls_prot      NEG_NO_SLICE_RESET blind call   none         exact
neg_free_calls_prot       nodr $GOLD/calls_prot      NEG_FREE_PHASE     fail  free   none         exact
neg_free_calls_av257      nodr $GOLD/calls_av257     NEG_FREE_PHASE     fail  free   none         exact
neg_free_chunked_100      nodr $GOLD/chunked_100     NEG_FREE_PHASE     fail  free   none         exact
neg_free_calls_mix        nodr $XG/calls_mix         NEG_FREE_PHASE     fail  free   none         exact
blind_free_chunked_rung   nodr $GOLD/chunked_rung    NEG_FREE_PHASE     blind free   none         exact
drblind_nocall_calls_prot base $GOLD/calls_prot      NEG_NO_CALL_RESET  blind nocall none         exact
drblind_nocall_calls_av257 base $GOLD/calls_av257    NEG_NO_CALL_RESET  blind nocall none         exact
drblind_nocall_calls_mix  base $XG/calls_mix         NEG_NO_CALL_RESET  blind nocall none         exact
drblind_nocall_allL_plain base $XG/allL_plain        NEG_NO_CALL_RESET  blind nocall none         exact
drblind_nocall_ladders_plain base $XG/ladders_plain  NEG_NO_CALL_RESET  blind nocall none         exact
drblind_noslice_chunked_100 base $GOLD/chunked_100   NEG_NO_SLICE_RESET blind call   none         exact
drblind_noslice_allL_chunk96 base $XG/allL_chunk96   NEG_NO_SLICE_RESET blind call   none         exact
drblind_noslice_allL_perhead base $XG/allL_perhead   NEG_NO_SLICE_RESET blind call   none         exact
drblind_free_calls_prot   base $GOLD/calls_prot      NEG_FREE_PHASE     blind free   none         exact
drblind_free_calls_mix    base $XG/calls_mix         NEG_FREE_PHASE     blind free   none         exact
drblind_free_allL_chunk100 base $XG/allL_chunk100    NEG_FREE_PHASE     blind free   none         exact
drblind_free_sj_calls_mix base $XG/calls_mix         NEG_FREE_PHASE,STALL=20,JUNK,SEED=14 blind free none exact
neg_short_plain_u97       base $GOLD/plain_u97       NEG_SHORT_BLOCK    fail  slice  none         short
neg_short_plain_ladder    base $GOLD/plain_ladder    NEG_SHORT_BLOCK    fail  slice  none         short
neg_short_calls_mix       base $XG/calls_mix         NEG_SHORT_BLOCK    fail  slice  none         short
f1_lane_plain_u128        f1   $GOLD/plain_u128      -                fail  slice  lane_mask      exact
f1_lane_calls_mix         f1   $XG/calls_mix         -                fail  slice  lane_mask      exact
f2_widx_plain_u97         f2   $GOLD/plain_u97       -                fail  slice  w_idx_t        exact
f2_widx_calls_mix         f2   $XG/calls_mix         -                fail  slice  w_idx_t        exact
f3_nogate_plain_ladder    f3   $GOLD/plain_ladder    -                fail  slice  no_len_gate    exact
f3_nogate_plain_u97       f3   $GOLD/plain_u97       -                fail  slice  no_len_gate    exact
f3_nogate_calls_mix       f3   $XG/calls_mix         -                fail  slice  no_len_gate    exact
blind_f3_nogate_plain_u128 f3  $GOLD/plain_u128      -                blind slice  no_len_gate    exact
f4_phasefree_plain_u128   f4   $GOLD/plain_u128      -                fail  slice  phase_free     exact
f4_phasefree_calls_av257  f4   $GOLD/calls_av257     -                fail  slice  phase_free     exact
f4_phasefree_calls_mix    f4   $XG/calls_mix         -                fail  slice  phase_free     exact
f5_jnorestart_plain_u128  f5   $GOLD/plain_u128      -                fail  slice  j_no_restart   exact
f5_jnorestart_calls_mix   f5   $XG/calls_mix         -                fail  slice  j_no_restart   exact
f6_phaseearly_plain_u128  f6   $GOLD/plain_u128      -                fail  slice  pe_phase_early exact
f6_phaseearly_calls_mix   f6   $XG/calls_mix         -                fail  slice  pe_phase_early exact
f6_phaseearly_allL_plain  f6   $XG/allL_plain        -                fail  slice  pe_phase_early exact
nopeek_calls_mix          base $XG/calls_mix         NO_PEEK          pass  slice  none           exact
nopeek_short_plain_u97    base $GOLD/plain_u97       NO_PEEK,NEG_SHORT_BLOCK fail slice none      short
glshape_calls_mix         glshape $XG/calls_mix      -                pass  slice  none           exact
glshape_allL_chunk100     glshape $XG/allL_chunk100  STALL=15,JUNK,SEED=15 pass slice none        exact
glshape_short_calls_mix   glshape $XG/calls_mix      NEG_SHORT_BLOCK  fail  slice  none           short
nodr_calls_mix            nodr $XG/calls_mix         -                pass  slice  none           exact
nodr_allL_chunk96         nodr $XG/allL_chunk96      -                pass  slice  none           exact
nodr_sj_calls_av257       nodr $GOLD/calls_av257     STALL=20,JUNK,SEED=16 pass slice none        exact
EOF
)

# name -> VCS_ARGS for the bench builds
#   base     default RTL (DRAIN_PHASE_RESET = 1, no fault hooks)
#   idx7/9   W index counter width
#   nodr     DRAIN_PHASE_RESET = 0: slice_start is the only phase reset (the sequencer controls fail here)
#   glshape  the bench as a GL build compiles it (+define+GL_SIM: no parameter overrides, no hierarchical
#            reads, drain-only), with the RTL top passed as a source file in place of a netlist
#   f1..f6   fault hooks compiled in (+define+CBSG_RG_FAULT_HOOKS) and FAULT = n
#   nohook   FAULT = 1 without hooks in simulation: must stop at time 0 (compile check only, no runs)
RG_TOP_SV="$REPO/designs/payn/variants/signed_segmented_csa_cbsg_rg/payn_array_signed_segmented_csa_cbsg_rg.sv"
build_defs() {
    case "$1" in
        base) echo "" ;;
        idx7) echo "+define+CBSG_RG_IDX_W=7" ;;
        idx9) echo "+define+CBSG_RG_IDX_W=9" ;;
        nodr) echo "+define+CBSG_RG_DRAIN_RESET=0" ;;
        glshape) echo "+define+GL_SIM $RG_TOP_SV" ;;
        f[1-6]) echo "+define+CBSG_RG_FAULT_HOOKS+CBSG_RG_FAULT=${1#f}" ;;
        nohook) echo "+define+CBSG_RG_FAULT=1" ;;
    esac
}
build_idxw() { case "$1" in idx7) echo 7 ;; idx9) echo 9 ;; *) echo 8 ;; esac; }
build_drain_reset() { case "$1" in nodr) echo 0 ;; *) echo 1 ;; esac; }
BUILDS="base idx7 idx9 nodr glshape f1 f2 f3 f4 f5 f6 nohook"

compile_tb() {   # name
    local b="$OUT/build/$1" defs
    defs=$(build_defs "$1")
    rm -rf "$b"; mkdir -p "$b"
    make sim TOP=Top TB="$TB" BUILD_DIR="$REPO/$b" GL= TARGET= RTL_PREFLIGHT_CMD= \
        "VCS=$VCS_RTL" VCS_ARGS="$defs" > "$b/compile.log" 2>&1
    if [[ "$1" == nohook ]]; then
        grep -q 'needs +define+CBSG_RG_FAULT_HOOKS' "$b/compile.log" && ! grep -q 'CBSGRG compile-only run' "$b/compile.log" \
            || { echo "compile $1: FAIL (FAULT=1 without hooks did not stop at time 0; $b/compile.log)"; return 1; }
        echo "compile $1: OK (FAULT=1 without CBSG_RG_FAULT_HOOKS stops at time 0)"
        return 0
    fi
    grep -q 'CBSGRG compile-only run' "$b/compile.log" || { echo "compile $1: FAIL ($b/compile.log)"; return 1; }
    echo "compile $1: OK (${defs/$REPO\//})"
}

kv() { grep -o "$1=[0-9]*" <<< "$2" | head -1 | cut -d= -f2; }

run_case() {   # label build case_dir plusargs expect policy fault cycles
    local label=$1 build=$2 cdir=$3 plus=$4 expect=$5 pol=$6 fault=$7 cyc=$8
    local dir="$OUT/runs/$label" args=() res pred ok=1 f x
    rm -rf "$dir"; mkdir -p "$dir"
    if [[ "$plus" != - ]]; then IFS=, read -ra f <<< "$plus"; for x in "${f[@]}"; do args+=("+$x"); done; fi
    local peek=()
    [[ "$build" == glshape || ",$plus," == *",NO_PEEK,"* ]] && peek=(--no-peek)
    (cd "$dir" && "$REPO/$OUT/build/$build/$TB/simv" +vcs+lic+wait +CASE="$REPO/$cdir" "${args[@]}" > sim.log 2>&1)
    python3 sweeps/cbsg/rg/predict_faults.py "$cdir" --policy "$pol" --fault "$fault" --cycles "$cyc" \
        --idx-w "$(build_idxw "$build")" --drain-reset "$(build_drain_reset "$build")" "${peek[@]}" \
        > "$dir/predict.log" 2>&1
    res=$(grep '^CBSGRG_RESULT' "$dir/sim.log")
    pred=$(grep '^PREDICT' "$dir/predict.log")
    if [[ -z "$res" || -z "$pred" ]]; then
        echo "$label: FAIL (no result line; see $dir)"; return 1
    fi
    for x in drain_bad drain_total blk_bad blk_total phase_bad phase_total; do
        [[ "$(kv "$x" "$res")" == "$(kv "$x" "$pred")" ]] || ok=0
    done
    local db bb pb
    db=$(kv drain_bad "$res"); bb=$(kv blk_bad "$res"); pb=$(kv phase_bad "$res")
    case "$expect" in
        pass)  (( db == 0 && bb == 0 && pb == 0 )) || ok=0 ;;
        fail)  (( db > 0 )) || ok=0 ;;
        blind) (( db == 0 )) || ok=0 ;;
    esac
    local tag="PASS"; (( ok )) || tag="FAIL"
    echo "$label: $tag [$expect] build=$build ${plus} drains $db/$(kv drain_total "$res") bad, blocks $bb/$(kv blk_total "$res"), phase $pb/$(kv phase_total "$res") (predicted $(kv drain_bad "$pred")/$(kv blk_bad "$pred")/$(kv phase_bad "$pred")); $(kv edges "$res") edges"
    (( ok ))
}

run_tb() {
    local status=0 pids=() n=0 label build cdir plus expect pol fault cyc
    for b in $BUILDS; do compile_tb "$b" & pids+=("$!"); done
    for p in "${pids[@]}"; do wait "$p" || status=1; done
    (( status == 0 )) || { echo "bench compile FAILED"; return 1; }
    while read -r label build cdir plus expect pol fault cyc; do
        [[ -n "$label" ]] || continue
        run_case "$label" "$build" "$cdir" "$plus" "$expect" "$pol" "$fault" "$cyc" >> "$OUT/tb_runs.log" &
        n=$((n + 1))
        while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
    done <<< "$MATRIX"
    while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done
    return "$status"
}

#--------------------------------------------------------------- (c) power --
power_run() {   # name defines
    local b="$OUT/power/$1" t
    rm -rf "$b"; mkdir -p "$b"
    make sim TOP=Top TB="$PWR" BUILD_DIR="$REPO/$b" GL= TARGET= RTL_PREFLIGHT_CMD= \
        "VCS=$VCS_PP" VCS_ARGS="$2" > "$b/sim.log" 2>&1
    grep -q '^PASS: CBSG-RG streaming SAIF captured' "$b/sim.log" || { echo "power $1: FAIL (bench, $b/sim.log)"; return 1; }
    t="$b/$PWR/cbsg_rg_streaming_rtl.txt"
    if python3 sweeps/cbsg/rg/check_power_trace.py "$t" --json "$b/check.json" > "$b/check.log" 2>&1; then
        echo "power $1: PASS $(grep -o 'SAIF captured.*' "$b/sim.log" | sed 's/ -> check_power_trace.py//'); $(tail -n 1 "$b/check.log")"
    else
        echo "power $1: FAIL $(tail -n 1 "$b/check.log")"; return 1
    fi
}
run_power() {
    local status=0 pids=()
    power_run uniform_L128 "+define+SC_BATCHES=384" & pids+=("$!")
    power_run ladder_rowmix "+define+SC_BATCHES=384+define+CBSG_WL_LADDER" & pids+=("$!")
    power_run ladder_rowgrouped "+define+SC_BATCHES=384+define+CBSG_WL_LADDER_GROUPED" & pids+=("$!")
    for p in "${pids[@]}"; do wait "$p" || status=1; done
    return "$status"
}

#------------------------------------------------- (d) fault-hook guard (DC) --
elab_one() {   # fault hooks
    local d="$OUT/dc_fault_guard/f$1_h$2"
    rm -rf "$d"; mkdir -p "$d"
    (cd "$d" && RG_REPO="$REPO" RG_FAULT=$1 RG_HOOKS=$2 dc_shell -f "$REPO/sweeps/cbsg/rg/dc_fault_guard.tcl" > elab.log 2>&1)
    grep -q '^ELABORATE_RESULT 1' "$d/elab.log" && [[ -s "$d/elab.v" ]]
}
elab_norm() { grep -v '^// Date' "$1" | sed -E 's/payn_array_signed_segmented_csa_cbsg_rg[A-Za-z0-9_]*/RGTOP/g'; }
run_elab() {
    local status=0 pids=() c ref="$OUT/dc_fault_guard/f0_h0/elab.v" d regs same
    for c in "0 0" "1 0" "2 0" "4 0" "6 0" "2 1" "4 1"; do elab_one $c & pids+=("$!"); done
    for p in "${pids[@]}"; do wait "$p" || status=1; done
    (( status == 0 )) || { echo "dc elaboration FAILED (see $OUT/dc_fault_guard/*/elab.log)"; return 1; }
    for c in f1_h0 f2_h0 f4_h0 f6_h0 f2_h1 f4_h1; do
        d="$OUT/dc_fault_guard/$c"
        regs=$(grep -o '^REG_COUNT [0-9][0-9]*' "$d/elab.log" | cut -d' ' -f2)
        if diff -q <(elab_norm "$ref") <(elab_norm "$d/elab.v") > /dev/null; then same=1; else same=0; fi
        if [[ "$c" == *_h0 ]]; then
            (( same )) && echo "elab $c: PASS (no hooks: netlist identical to FAULT=0; $regs registers)" \
                       || { echo "elab $c: FAIL (no hooks but netlist differs from FAULT=0)"; status=1; }
        else
            (( same )) && { echo "elab $c: FAIL (hooks compiled in but netlist equals FAULT=0)"; status=1; } \
                       || echo "elab $c: PASS (hooks compiled in: netlist differs, $regs registers)"
        fi
    done
    echo "elab f0_h0: reference, $(grep -o '^REG_COUNT [0-9][0-9]*' "$OUT/dc_fault_guard/f0_h0/elab.log" | cut -d' ' -f2) registers"
    return "$status"
}

#----------------------------------------------------------------- driver --
status=0
: > "$SUMMARY"
echo "C-BSG RG RTL checks $(date -Iseconds) (git $(git rev-parse --short HEAD), working tree has uncommitted changes)" >> "$SUMMARY"
if [[ " $PARTS " == *" golden "* ]]; then
    echo "== (a) goldens" >> "$SUMMARY"
    run_golden >> "$SUMMARY" 2>&1 || status=1
fi
if [[ " $PARTS " == *" tb "* ]]; then
    : > "$OUT/tb_runs.log"
    echo "== (b) golden playback ($TB)" >> "$SUMMARY"
    run_tb > "$OUT/tb_compile.log" 2>&1 || status=1
    cat "$OUT/tb_compile.log" >> "$SUMMARY"
    sort "$OUT/tb_runs.log" >> "$SUMMARY"
    n_all=$(grep -c . "$OUT/tb_runs.log"); n_pass=$(grep -c ': PASS \[' "$OUT/tb_runs.log")
    for e in pass fail blind; do
        printf '  %-5s %3d runs, %3d PASS\n' "$e" "$(grep -c "\[$e\]" "$OUT/tb_runs.log")" \
            "$(grep ': PASS \[' "$OUT/tb_runs.log" | grep -c "\[$e\]")" >> "$SUMMARY"
    done
    python3 - "$OUT/tb_runs.log" >> "$SUMMARY" <<'PY'
import re, sys
acc = blk = ph = dr = 0
for ln in open(sys.argv[1]):
    if ": PASS [pass]" not in ln:
        continue
    m = re.search(r"drains 0/(\d+) bad, blocks 0/(\d+), phase 0/(\d+)", ln)
    acc += int(m.group(1)); blk += int(m.group(2)); ph += int(m.group(3))
print(f"  bit-exact in the [pass] runs: {acc} drained accumulators ({acc // 64} drains), "
      f"{blk} per-block tile values ({blk // 64} block checks), {ph} phase checks")
PY
    echo "golden playback: $n_pass/$n_all runs PASS" >> "$SUMMARY"
    (( n_pass == n_all )) || status=1
fi
if [[ " $PARTS " == *" power "* ]]; then
    echo "== (c) streaming power bench ($PWR)" >> "$SUMMARY"
    run_power >> "$SUMMARY" 2>&1 || status=1
fi
if [[ " $PARTS " == *" elab "* ]]; then
    echo "== (d) fault-hook guard, DC GTECH elaboration" >> "$SUMMARY"
    run_elab >> "$SUMMARY" 2>&1 || status=1
fi
echo "C-BSG RG RTL checks: $([[ $status == 0 ]] && echo PASS || echo FAIL)" >> "$SUMMARY"
cat "$SUMMARY"
exit "$status"
