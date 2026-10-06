#!/bin/bash
# Proof that the opt-in extensions made for the lap-length INT energy A/B
# (sweeps/int_mode/bp/sr/run_int_energy_prelayout_ab.sh) leave every default
# unchanged.  Compares the edited files against byte copies taken before the
# edit (PRE, default build/power_char/tile_doubling_energy_20261004/int_energy_ab/pre_edit_copies):
#   lib      bp_int_energy_lib.sh: BPE_DEFAULT_POINTS, and bpe_point_config /
#            bpe_defs / bpe_pass_line for the 45 default points plus extra
#            labels and bad labels (stdout, stderr, exit code), with
#            BPE_LAP_RING_ONLY = 0 and 1
#   checker  check_bp_power_trace.py: stdout, exit code and JSON on COPIES of
#            the routed lap campaign's RTL and GL run directories (both run on
#            the copies; nothing is written into the campaign)
#   bench    power_payn_array_bp_int.sv: RTL runs of the old and the new bench
#            with the default defines on 8 points (all three window modes, both
#            lap contracts, INT8 / W4A8 / INT4, multi-block and single-block):
#            PASS line, bpt_trace.txt, bpe_saif.txt and dut.saif (minus its
#            DATE / VERSION header lines) byte-identical; the 4 points the
#            routed lap campaign ran also equal that campaign's RTL traces
# Output: OUT (default build/power_char/tile_doubling_energy_20261004/int_energy_ab/defaults_regression)
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
cd "$REPO"
PRE=${PRE:-build/power_char/tile_doubling_energy_20261004/int_energy_ab/pre_edit_copies}
OUT=${OUT:-build/power_char/tile_doubling_energy_20261004/int_energy_ab/defaults_regression}
CAMP=build/power_char/int_mode_energy_20261004_lap/bp/csa_bp_20261004_lap_distguide_spp_pins
PARTS=${PARTS:-"lib checker bench"}
MAX_JOBS=${MAX_JOBS:-8}
TB=designs/payn/power/power_payn_array_bp_int.sv
mkdir -p "$OUT"
status=0

#------------------------------------------------------------------ lib --
run_lib() {
    local lib out rc=0
    for lib in "$PRE/bp_int_energy_lib.sh" sweeps/int_mode/bp/bp_int_energy_lib.sh; do
        out=$OUT/lib_$( [[ "$lib" == "$PRE"/* ]] && echo old || echo new ).txt
        for lro in 0 1; do
            BPE_LAP_RING_ONLY=$lro bash -c '
                source "$1"
                errf=$2
                echo "DEFAULT_POINTS:$BPE_DEFAULT_POINTS"
                for label in $BPE_DEFAULT_POINTS int8_uniform_L4096_d int8_uniform_L4096_dr int4_uniform_L4096_all \
                             w4a8_gauss_L2048_dr int8_relu_L65408_d int2_uniform_L1024_d int8_uniform_L1024_x \
                             int8_uniform_L1000_d int8_uniform_L65536_d int8_uniform_1024_d $3; do
                    rc=0; bpe_point_config "$label" 2> "$errf" || rc=$?
                    if [[ $rc != 0 ]]; then echo "$label rc=$rc $(cat "$errf")"; continue; fi
                    echo "$label $BA $BW $L $MROWS $NCOLS $DIST $SEED $MODE $NBLK $NB $ROWS_PE $ACTIVE"
                    echo "  $(bpe_defs)"
                    echo "  $(bpe_pass_line)"
                done' _ "$lib" "$OUT/lib_err.tmp" "${EXTRA_LABELS:-}"
        done > "$out" 2>&1
    done
    rm -f "$OUT/lib_err.tmp"
    if cmp -s "$OUT/lib_old.txt" "$OUT/lib_new.txt"; then
        echo "lib: PASS (BPE_DEFAULT_POINTS, configs, defines, PASS lines and errors byte-identical: $(grep -c '^  PASS' "$OUT/lib_old.txt") valid and $(grep -c ' rc=' "$OUT/lib_old.txt") invalid labels over both lap contracts)"
    else
        diff "$OUT/lib_old.txt" "$OUT/lib_new.txt" > "$OUT/lib_diff.txt" || true
        echo "lib: FAIL (see $OUT/lib_diff.txt)"; rc=1
    fi
    # The opt-in tokens: rejected by the old library, accepted by the new.
    for lib in "$PRE/bp_int_energy_lib.sh" sweeps/int_mode/bp/bp_int_energy_lib.sh; do
        for label in int8_uniform_L1024_dc int8_uniform_L1024_drc; do
            bash -c 'source "$1"; if bpe_point_config "$2" 2>&1; then echo "$2 -> MODE=$MODE ACTIVE=$ACTIVE"; fi' _ "$lib" "$label" \
                | sed "s|^|  opt-in token ($( [[ "$lib" == "$PRE"/* ]] && echo old || echo new ) lib): |"
        done
    done
    return $rc
}

#-------------------------------------------------------------- checker --
run_checker() {
    local rc=0 p kind d flag n=0
    rm -rf "$OUT/checker"; mkdir -p "$OUT/checker/old_script"
    # The old checker next to the (unchanged) inner checker it runs.
    cp -p "$PRE/check_bp_power_trace.py" sweeps/int_mode/bp/check_bp_trace.py "$OUT/checker/old_script/"
    for p in $(ls "$CAMP" | grep -E '^(int|w4)'); do
        for kind in rtl gl; do
            src="$CAMP/$p/$kind/$TB"
            [[ -f "$src/bpt_trace.txt" ]] || continue
            for ver in old new; do
                d="$OUT/checker/$p/$kind/$ver"
                mkdir -p "$d"
                cp -p "$src"/bpt_trace.txt "$src"/bpt_a.hex "$src"/bpt_w.hex "$src"/bpe_saif.txt "$d/"
                script=sweeps/int_mode/bp/check_bp_power_trace.py
                [[ $ver == new ]] || script=$OUT/checker/old_script/check_bp_power_trace.py
                for flag in "" "--lap-ring-only"; do
                    tag=${flag:+lro}; tag=${tag:-def}
                    r=0
                    python3 "$script" "$d" --json "$d/check_$tag.json" $flag > "$d/check_$tag.log" 2>&1 || r=$?
                    echo "$r" > "$d/check_$tag.rc"
                done
            done
            for tag in def lro; do
                for f in "check_$tag.json" "check_$tag.log" "check_$tag.rc" bpt_check_inner.json; do
                    cmp -s "$OUT/checker/$p/$kind/old/$f" "$OUT/checker/$p/$kind/new/$f" \
                        || { echo "checker: FAIL $p/$kind $f differs"; rc=1; }
                done
            done
            n=$((n + 1))
        done
    done
    local npass nfail
    npass=$(cat "$OUT"/checker/*/*/new/check_lro.rc | grep -c '^0$' || true)
    nfail=$(cat "$OUT"/checker/*/*/new/check_def.rc | grep -vc '^0$' || true)
    [[ $rc == 0 ]] && echo "checker: PASS ($n run dirs x 2 contracts: stdout, exit code and JSON identical; $npass/$n pass with --lap-ring-only, $nfail/$n correctly fail without it)"
    return $rc
}

#---------------------------------------------------------------- bench --
BENCH_POINTS="int8_uniform_L1024_dr:1 int8_uniform_L49152_d:1 int4_uniform_L1024_all:1 w4a8_uniform_L1024_dr:1
int8_gauss_L1024_d:0 w4a8_relu_L98304_d:0 int4_gauss_L1024_all:0 int8_uniform_L4096_dr:0"
bench_point() (
    set -euo pipefail
    local label=${1%:*} lro=${1#*:} ver=$2 tb dir defs pass
    export BPE_LAP_RING_ONLY=$lro
    source sweeps/int_mode/bp/bp_int_energy_lib.sh
    bpe_point_config "$label"
    defs=$(bpe_defs); pass=$(bpe_pass_line)
    tb=$TB; [[ $ver == new ]] || tb=$PRE/power_payn_array_bp_int.sv
    dir=$OUT/bench/$label/$ver
    rm -rf "$dir"; mkdir -p "$dir/$tb"
    bpe_gen_stim "$dir/stim" "$dir/$tb"
    make sim TOP=Top BUILD_DIR="$dir" TB="$tb" USE_DW=1 NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" \
        VCS_ARGS="${defs//+define/ +define}" > "$dir/simulation.log" 2>&1
    # The whole PASS line, trailing blanks included (with lap_ring_only=0 the
    # bench's empty %s pads the line; both benches must print it identically);
    # it must start with the library's expected line.
    grep '^PASS: BP INT SAIF captured' "$dir/simulation.log" > "$dir/pass_line.txt" || { echo "no PASS line"; exit 1; }
    [[ $(wc -l < "$dir/pass_line.txt") == 1 && "$(sed 's/ *$//' "$dir/pass_line.txt")" == "$pass" ]] \
        || { echo "PASS line differs from the expected '$pass'"; exit 1; }
    local run=$dir/$tb
    cp -p "$run/bpt_trace.txt" "$run/bpe_saif.txt" "$dir/"
    grep -vE '^\s*\((DATE|VERSION|VENDOR|PROGRAM_NAME|DIVIDER)\b' "$run/dut.saif" > "$dir/dut.saif.body"
    rm -rf "$dir/$tb.obj" "$run/simv" "$run/simv.daidir" "$run/dut.saif"
)
run_bench() {
    source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
    module load synopsys-lib-compiler/2022.03-SP3
    module load synopsys-synth/2021.06-SP1
    module load primetime/2021.06-SP1
    module load vcs/2020.12-SP2-1
    module load innovus/21.14.000
    module load genus/21.14.000
    export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
    export SYNOPSYS=${SYNOPSYS:-/usr/caen/synopsys-synth-2021.06-SP1}
    export USE_DW=1 NTFY_CHNL= SNPSLMD_QUEUE=true
    unset NETLIST_FILE SDC_FILE SDF_FILE NO_SDF VCS_ARGS
    local rc=0 pt ver label f
    for pt in $BENCH_POINTS; do
        for ver in old new; do
            bench_point "$pt" "$ver" > "$OUT/bench_${pt%:*}_$ver.log" 2>&1 &
            while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || rc=1; done
        done
    done
    while (( $(jobs -rp | wc -l) > 0 )); do wait -n || rc=1; done
    [[ $rc == 0 ]] || echo "bench: a simulation failed (see $OUT/bench_*.log)"
    for pt in $BENCH_POINTS; do
        label=${pt%:*}
        for f in pass_line.txt bpt_trace.txt bpe_saif.txt dut.saif.body; do
            if cmp -s "$OUT/bench/$label/old/$f" "$OUT/bench/$label/new/$f"; then :; else
                echo "bench: FAIL $label $f differs between the old and the new bench"; rc=1
            fi
        done
        if [[ -f "$CAMP/$label/rtl/$TB/bpt_trace.txt" ]]; then
            for f in bpt_trace.txt bpe_saif.txt; do
                cmp -s "$OUT/bench/$label/new/$f" "$CAMP/$label/rtl/$TB/$f" \
                    || { echo "bench: FAIL $label $f differs from the routed lap campaign's RTL run"; rc=1; }
            done
            echo "  $label (lap_ring_only=${pt#*:}): old == new bench; == routed lap campaign RTL ($(cat "$OUT/bench/$label/new/pass_line.txt"))"
        else
            echo "  $label (lap_ring_only=${pt#*:}): old == new bench ($(cat "$OUT/bench/$label/new/pass_line.txt" | sed 's/ *$/<trailing blanks>/'))"
        fi
    done
    [[ $rc == 0 ]] && echo "bench: PASS ($(wc -w <<< "$BENCH_POINTS") points: PASS line, bpt_trace.txt, bpe_saif.txt and the SAIF body byte-identical)"
    return $rc
}

for part in $PARTS; do
    case $part in
        lib) run_lib > "$OUT/lib.log" 2>&1 || status=1; cat "$OUT/lib.log";;
        checker) run_checker > "$OUT/checker.log" 2>&1 || status=1; cat "$OUT/checker.log";;
        bench) run_bench > "$OUT/bench.log" 2>&1 || status=1; cat "$OUT/bench.log";;
        *) echo "unknown part $part" >&2; exit 2;;
    esac
done
echo "defaults regression ($PARTS): $([[ $status == 0 ]] && echo PASS || echo FAIL)"
exit $status
