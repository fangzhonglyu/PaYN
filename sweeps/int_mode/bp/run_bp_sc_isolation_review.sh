#!/bin/bash
# Independent SC-mode isolation review of the bit-plane INT top
# (payn_array_signed_segmented_csa_bp) against the accepted carry-save top,
# K8/M16/N8, LOW_W=9, T=128.  Does not reuse the implementer's build dirs.
#
#  hooks   The PAYN_INT_PORTS hooks are the only change to the two SC benches:
#          strip(`ifdef PAYN_INT_PORTS) of the working-tree bench == HEAD, and
#          the HEAD bench vs the working-tree bench (no define) give
#          byte-identical traces (and SAIF bodies) on the accepted CSA top.
#  bench   BP top + PAYN_INT_PORTS through the unchanged SC benches: array
#          cosim (3 seeds) and 384-batch streaming cosim PASS, traces
#          byte-identical to the CSA top; same with PAYN_INT_RAW_JUNK.
#  lock    Lockstep bench (designs/payn/tb/test_payn_array_bp_sc_lockstep.sv):
#          CSA and BP tops side by side, every clock 4-state compare of
#          acc_out_east, all tile state, peripheral outputs, rails; BP-only
#          registers must stay at reset.  Matrix of junk / X / reset / mode
#          switch runs; +JUNK_RING must pass (ring_in gated by int_mode in the
#          post-review RTL).
#
#   bash sweeps/int_mode/bp/run_bp_sc_isolation_review.sh
#   PARTS="lock" bash sweeps/int_mode/bp/run_bp_sc_isolation_review.sh
# Logs: build/rtl_preflight/csa_bp_review/*.log
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
export USE_DW=1 NTFY_CHNL=
PARTS=${PARTS:-"hooks bench lock"}
OUT=build/rtl_preflight/csa_bp_review
mkdir -p "$OUT"
VCS_PP='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
BP_SRC=designs/payn/variants/signed_segmented_csa_bp/payn_array_signed_segmented_csa_bp.sv
CSA_SRC=designs/payn/variants/signed_segmented_csa/payn_array_signed_segmented_csa.sv
SHAPE_DEF="+define+PAYN_ARRAY_EXTERNAL_RTL+define+PAYN_SEG_LOW_W=9+define+SC_K=8+define+SC_M=16+define+SC_NH=8+define+SC_NW=8+define+SC_OWIDTH=24+define+SC_T=128"
ARRAY_TB=designs/payn/tb/test_payn_array.sv
STREAM_TB=designs/payn/power/power_payn_array.sv
HEAD_DIR=$OUT/head_benches        # HEAD copies of the two benches (relative TB paths)

# sim name tb src defines -> trace path on stdout-free success
sim() {
    local name=$1 tb=$2 src=$3 def=$4
    make sim TOP=Top TB="$tb" BUILD_DIR="$OUT/$name" GL= TARGET= RTL_PREFLIGHT_CMD= \
        SIM_SRCS="$src" VCS_ARGS="$def" "VCS=$VCS_PP" > "$OUT/$name.log" 2>&1 \
        || { echo "$name: FAIL (make sim, see $OUT/$name.log)"; return 1; }
}
array_case() {   # name tb src defines
    sim "$@" || return 1
    python3 designs/payn/cosim/cosim_array.py "$OUT/$1/$2/array_rtl.txt" >> "$OUT/$1.log" 2>&1 \
        || { echo "$1: FAIL (cosim_array.py)"; return 1; }
    grep -q '\[PASS\]' "$OUT/$1.log" || { echo "$1: FAIL (no PASS)"; return 1; }
    echo "$1: array cosim PASS"
}
stream_case() {  # name tb src defines
    sim "$1" "$2" "$3" "$4+define+SC_BATCHES=384" || return 1
    python3 designs/payn/cosim/cosim_streaming.py "$OUT/$1/$2/array_streaming_rtl.txt" >> "$OUT/$1.log" 2>&1 \
        || { echo "$1: FAIL (cosim_streaming.py)"; return 1; }
    grep -q '\[PASS\]' "$OUT/$1.log" || { echo "$1: FAIL (no PASS)"; return 1; }
    echo "$1: streaming cosim PASS (384 batches)"
}
same() {         # label fileA fileB
    if cmp -s "$2" "$3"; then echo "$1: identical"; else echo "$1: DIFFER ($2 vs $3)"; return 1; fi
}
saif_body() { grep -v -E '^\s*\((DATE|VENDOR|PROGRAM_NAME|VERSION|DIVIDER|TIMESCALE|DESIGN)\b' "$1"; }

#---------------------------------------------------------------- hooks --
run_hooks() {
    local status=0 f
    mkdir -p "$HEAD_DIR"
    for f in "$ARRAY_TB" "$STREAM_TB"; do
        git show "HEAD:$f" > "$HEAD_DIR/$(basename "$f")"
        if python3 sweeps/int_mode/bp/strip_ifdef_block.py PAYN_INT_PORTS "$f" | cmp -s - "$HEAD_DIR/$(basename "$f")"; then
            echo "hooks: $f minus the PAYN_INT_PORTS block == HEAD"
        else
            echo "hooks: $f minus the PAYN_INT_PORTS block DIFFERS from HEAD"; status=1
        fi
    done
    local pids=()
    array_case hook_head_array "$HEAD_DIR/test_payn_array.sv" "$CSA_SRC" "$SHAPE_DEF+define+PAYN_ARRAY_DUT=payn_array_signed_segmented_csa" & pids+=("$!")
    array_case hook_cur_array "$ARRAY_TB" "$CSA_SRC" "$SHAPE_DEF+define+PAYN_ARRAY_DUT=payn_array_signed_segmented_csa" & pids+=("$!")
    stream_case hook_head_stream "$HEAD_DIR/power_payn_array.sv" "$CSA_SRC" "$SHAPE_DEF+define+PAYN_ARRAY_DUT=payn_array_signed_segmented_csa" & pids+=("$!")
    stream_case hook_cur_stream "$STREAM_TB" "$CSA_SRC" "$SHAPE_DEF+define+PAYN_ARRAY_DUT=payn_array_signed_segmented_csa" & pids+=("$!")
    for p in "${pids[@]}"; do wait "$p" || status=1; done
    (( status == 0 )) || return 1
    same "hooks: array trace HEAD bench vs current bench (CSA top, no define)" \
        "$OUT/hook_head_array/$HEAD_DIR/test_payn_array.sv/array_rtl.txt" \
        "$OUT/hook_cur_array/$ARRAY_TB/array_rtl.txt" || status=1
    same "hooks: stream trace HEAD bench vs current bench (CSA top, no define)" \
        "$OUT/hook_head_stream/$HEAD_DIR/power_payn_array.sv/array_streaming_rtl.txt" \
        "$OUT/hook_cur_stream/$STREAM_TB/array_streaming_rtl.txt" || status=1
    if cmp -s <(saif_body "$OUT/hook_head_stream/$HEAD_DIR/power_payn_array.sv/dut.saif") \
              <(saif_body "$OUT/hook_cur_stream/$STREAM_TB/dut.saif"); then
        echo "hooks: SAIF body HEAD bench vs current bench: identical"
    else
        echo "hooks: SAIF body HEAD bench vs current bench: DIFFER"; status=1
    fi
    return "$status"
}

#---------------------------------------------------------------- bench --
run_bench() {
    local status=0 pids=() s
    local bpdef="$SHAPE_DEF+define+PAYN_ARRAY_DUT=payn_array_signed_segmented_csa_bp+define+PAYN_INT_PORTS"
    local csadef="$SHAPE_DEF+define+PAYN_ARRAY_DUT=payn_array_signed_segmented_csa"
    # Seeds: the bench default (32'hDEADBEEF) and two more, passed in decimal
    # because a quote in VCS_ARGS would break the make recipe's shell line.
    for s in default 1 195948557; do
        local sd=""
        [[ "$s" == default ]] || sd="+define+SC_SEED=$s"
        array_case "bench_bp_array_$s" "$ARRAY_TB" "$BP_SRC" "$bpdef$sd" & pids+=("$!")
        array_case "bench_bpjunk_array_$s" "$ARRAY_TB" "$BP_SRC" "$bpdef+define+PAYN_INT_RAW_JUNK$sd" & pids+=("$!")
        array_case "bench_csa_array_$s" "$ARRAY_TB" "$CSA_SRC" "$csadef$sd" & pids+=("$!")
    done
    stream_case bench_bp_stream "$STREAM_TB" "$BP_SRC" "$bpdef" & pids+=("$!")
    stream_case bench_bpjunk_stream "$STREAM_TB" "$BP_SRC" "$bpdef+define+PAYN_INT_RAW_JUNK" & pids+=("$!")
    stream_case bench_csa_stream "$STREAM_TB" "$CSA_SRC" "$csadef" & pids+=("$!")
    for p in "${pids[@]}"; do wait "$p" || status=1; done
    (( status == 0 )) || return 1
    for s in default 1 195948557; do
        same "bench: array trace BP (tied) vs CSA, seed $s" \
            "$OUT/bench_bp_array_$s/$ARRAY_TB/array_rtl.txt" "$OUT/bench_csa_array_$s/$ARRAY_TB/array_rtl.txt" || status=1
        same "bench: array trace BP (raw junk) vs CSA, seed $s" \
            "$OUT/bench_bpjunk_array_$s/$ARRAY_TB/array_rtl.txt" "$OUT/bench_csa_array_$s/$ARRAY_TB/array_rtl.txt" || status=1
    done
    same "bench: stream trace BP (tied) vs CSA" \
        "$OUT/bench_bp_stream/$STREAM_TB/array_streaming_rtl.txt" "$OUT/bench_csa_stream/$STREAM_TB/array_streaming_rtl.txt" || status=1
    same "bench: stream trace BP (raw junk) vs CSA" \
        "$OUT/bench_bpjunk_stream/$STREAM_TB/array_streaming_rtl.txt" "$OUT/bench_csa_stream/$STREAM_TB/array_streaming_rtl.txt" || status=1
    return "$status"
}

#----------------------------------------------------------------- lock --
LOCK_TB=designs/payn/tb/test_payn_array_bp_sc_lockstep.sv
# label expect plusargs...
LOCK_CASES=$(cat <<'EOF'
lock_plain            pass +SEED=1
lock_junk_raw_prec    pass +SEED=2 +JUNK_RAW +JUNK_PREC
lock_x_raw            pass +SEED=3 +X_RAW
lock_xinit_junk       pass +SEED=4 +XINIT +JUNK_RAW +JUNK_PREC
lock_xinit_x_raw      pass +SEED=5 +XINIT +X_RAW
lock_modeswitch_junk  pass +SEED=6 +MODESWITCH +JUNK_RAW +JUNK_PREC
lock_modeswitch_xinit pass +SEED=7 +MODESWITCH +XINIT +X_RAW
lock_junk_ring        pass +SEED=8 +JUNK_RING
lock_junk_ring_raw    pass +SEED=10 +JUNK_RING +JUNK_RAW +JUNK_PREC
lock_modeswitch_ring  pass +SEED=11 +MODESWITCH +JUNK_RING +JUNK_RAW
lock_neg_mode_pulse   fail +SEED=9 +JUNK_RAW +NEG_MODE_PULSE
EOF
)
run_lock() {
    local status=0 build="$OUT/lock_build"
    make sim TOP=Top TB="$LOCK_TB" BUILD_DIR="$build" GL= TARGET= RTL_PREFLIGHT_CMD= \
        SIM_SRCS="$CSA_SRC $BP_SRC" VCS_ARGS="+define+PAYN_SEG_LOW_W=9" "VCS=$VCS_PP" \
        > "$OUT/lock_compile.log" 2>&1 || { echo "lock: compile/default run FAIL ($OUT/lock_compile.log)"; return 1; }
    grep -q '^PASS: BP SC lockstep' "$OUT/lock_compile.log" || { echo "lock: default run FAIL"; return 1; }
    local simv="$REPO/$build/$LOCK_TB/simv" pids=()
    while read -r label expect args; do
        [[ -n "$label" ]] || continue
        (
            mkdir -p "$OUT/$label"
            # shellcheck disable=SC2086
            (cd "$OUT/$label" && "$simv" $args > sim.log 2>&1) && rc=0 || rc=$?
            stats=$(grep '^\[STATS\]' "$OUT/$label/sim.log" | sed 's/^\[STATS\] //')
            if grep -q '^PASS: BP SC lockstep' "$OUT/$label/sim.log"; then
                [[ "$expect" == pass ]] && { echo "$label: PASS ($stats)"; exit 0; }
                echo "$label: UNEXPECTED PASS ($stats)"; exit 1
            fi
            first=$(grep -m1 'LOCKSTEP-FAIL' "$OUT/$label/sim.log" || true)
            [[ "$expect" == fail ]] && { echo "$label: FAILS AS EXPECTED ($stats; first: $first)"; exit 0; }
            echo "$label: FAIL rc=$rc ($stats; first: $first)"; exit 1
        ) & pids+=("$!")
    done <<< "$LOCK_CASES"
    for p in "${pids[@]}"; do wait "$p" || status=1; done
    return "$status"
}

status=0
for part in $PARTS; do
    "run_$part" > "$OUT/$part.summary" 2>&1 || status=1
    echo "== $part"; cat "$OUT/$part.summary"
done
echo "csa_bp SC isolation review: $([[ $status == 0 ]] && echo PASS || echo FAIL)"
exit "$status"
