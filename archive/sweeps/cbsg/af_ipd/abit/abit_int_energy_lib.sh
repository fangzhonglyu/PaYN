# shellcheck shell=bash
# Point definitions for sweeps/cbsg/af_ipd/abit/run_abit_int_energy.sh: routed INT energy of the all-bits-in-time
# schedule (abit) on the qualified AF-IPD route, plus current-schedule (cur) controls on the SAME operands.
# Sources sweeps/cbsg/af_ipd/af_ipd_int_energy_lib.sh read-only for the cur points (its bpe_defs, bpe_pass_line,
# bpe_snapshot and BPE_TB, i.e. exactly how the current schedule's INT energy was measured; BPE_LAP_LEN = 1 and
# BPE_LAP_RING_ONLY = 1 are the only values it allows).
#
# Point label: <sched>_<prec>_uniform_L<L>_<window>
#   sched   abit  designs/payn/power/power_payn_array_cbsg_af_ipd_int_abit.sv (this schedule)
#           cur   designs/payn/power/power_payn_array_cbsg_af_ipd_int.sv (the current schedule, unchanged bench)
#   prec    int8 (BA = BW = 8), int6 (6, 6), int4 (4, 4), w4a8 (BA 8, BW 4), w6a8 (BA 8, BW 6)
#   dist    uniform: the existing INT energy distribution (gen_bitplane_workload.py uniform; the abit generator's
#           --dist plain writes the same bytes for the same seed and shape), seeds int8 1, int4 3, w4a8 5 (the
#           existing lib's), int6 9, w6a8 11
#   L       per precision a fixed shape with about 3,072 data cycles (SHAPE below); the cur control of a (prec, L)
#           uses the same MROWS x NCOLS operands (same MACs, same data cycles at 128 / 512 / 256 MAC per data cycle)
#   window  dr = data + lap/ring intervals (drain paused, mode 0: the headline methodology), d = data only (mode 1,
#           peak), all = drain included (mode 2)
# The abit W4A8 L=1024 shape (MROWS 8, NCOLS 96, seed 5) is the existing w4a8_uniform_L1024_dr point's operands.
# shellcheck source=../af_ipd_int_energy_lib.sh
source sweeps/cbsg/af_ipd/af_ipd_int_energy_lib.sh

ABIT_TB=designs/payn/power/power_payn_array_cbsg_af_ipd_int_abit.sv
ABIT_DEFAULT_POINTS="abit_int8_uniform_L384_dr abit_int8_uniform_L384_all abit_int8_uniform_L384_d
abit_int8_uniform_L256_dr abit_int6_uniform_L1024_dr abit_int6_uniform_L1024_all abit_int6_uniform_L4096_dr
abit_int6_uniform_L4096_d abit_int4_uniform_L1024_dr abit_int4_uniform_L1024_all abit_int4_uniform_L4096_dr
abit_int4_uniform_L4096_d abit_w4a8_uniform_L1024_dr
cur_int8_uniform_L384_dr cur_int8_uniform_L384_all cur_int8_uniform_L256_dr cur_int4_uniform_L1024_dr
cur_int4_uniform_L1024_all cur_int4_uniform_L4096_dr"

# abit_point_config LABEL: sets SCHED BA BW L MROWS NCOLS DIST SEED MODE NBLK NB ROWS_PE ACTIVE TB TRACE WINFILE;
# returns 2 (with a message) on a bad label.
abit_point_config() {
    local sched prec dist l win extra shape
    IFS=_ read -r sched prec dist l win extra <<< "$1"
    if [[ -n "$extra" || ! "$l" =~ ^L[1-9][0-9]*$ || "$dist" != uniform ]]; then
        echo "bad point label '$1' (want <abit|cur>_<int8|int6|int4|w4a8|w6a8>_uniform_L<L>_<dr|d|all>)" >&2
        return 2
    fi
    L=${l#L}
    case "$prec" in
        int8) BA=8 BW=8 SEED=1;; int6) BA=6 BW=6 SEED=9;; int4) BA=4 BW=4 SEED=3;;
        w4a8) BA=8 BW=4 SEED=5;; w6a8) BA=8 BW=6 SEED=11;;
        *) echo "bad precision in '$1'" >&2; return 2;;
    esac
    case "$win" in dr) MODE=0;; d) MODE=1;; all) MODE=2;; *) echo "bad window in '$1'" >&2; return 2;; esac
    case "$prec:$L" in        # SHAPE: MROWS NCOLS (about 3,072 data cycles)
        int8:384) shape="16 64";; int8:256) shape="24 64";; int8:128) shape="48 64";;
        int6:1024) shape="24 32";; int6:4096) shape="8 24";;
        int4:1024) shape="24 64";; int4:4096) shape="16 24";;
        w4a8:1024) shape="8 96";; w6a8:1024) shape="8 64";;
        *) echo "no shape for $prec L=$L in '$1'" >&2; return 2;;
    esac
    read -r MROWS NCOLS <<< "$shape"
    NB=$((L / 128)) DIST=uniform SCHED=$sched
    case "$sched" in
        abit)
            if (( L * (1 << (BA + BW - 2)) > (1 << 23) - 1 )); then
                echo "L=$L in '$1' can overflow the 24-bit tile at BA=$BA BW=$BW" >&2; return 2
            fi
            ROWS_PE=8 NBLK=$(( (MROWS / 8) * (NCOLS / 8) ))
            local np=$((BA * BW)) nl=$((BA + BW - 2))
            case "$MODE" in
                0) ACTIVE=$((NBLK * (np * NB + nl)));;
                1) ACTIVE=$((NBLK * np * NB));;
                2) ACTIVE=$((NBLK * (np * NB + nl + 8)));;
            esac
            TB=$ABIT_TB TRACE=abit_trace.txt WINFILE=abit_saif.txt;;
        cur)
            [[ "$BA" == 8 || "$BA" == 4 ]] && [[ "$BW" == 8 || "$BW" == 4 ]] \
                || { echo "the current-schedule bench supports BA, BW in {4, 8} only ('$1')" >&2; return 2; }
            ROWS_PE=$((8 / BA)) NBLK=$(( (MROWS / ROWS_PE) * (NCOLS / 8) ))
            case "$MODE" in
                0) ACTIVE=$((NBLK * (BW * NB + BPE_LAP_LEN * (BW - 1))));;
                1) ACTIVE=$((NBLK * BW * NB));;
                2) ACTIVE=$((NBLK * (BW * NB + BPE_LAP_LEN * (BW - 1) + 8)));;
            esac
            TB=$BPE_TB TRACE=bpt_trace.txt WINFILE=bpe_saif.txt;;
        *) echo "bad schedule in '$1'" >&2; return 2;;
    esac
}

abit_defs() {
    if [[ "$SCHED" == cur ]]; then bpe_defs; return; fi
    printf '+define+BPA_BA=%s+define+BPA_BW=%s+define+BPA_L=%s+define+BPA_MROWS=%s+define+BPA_NCOLS=%s+define+BPA_SAIF_MODE=%s' \
        "$BA" "$BW" "$L" "$MROWS" "$NCOLS" "$MODE"
}

abit_pass_line() {
    if [[ "$SCHED" == cur ]]; then bpe_pass_line; return; fi
    printf 'PASS: ABIT INT SAIF captured; BA=%s BW=%s L=%s blocks=%s mode=%s active=%s drained=%s combined=%s block_len=%s' \
        "$BA" "$BW" "$L" "$NBLK" "$MODE" "$ACTIVE" "$((NBLK * 8))" "$((NBLK * 8))" \
        "$((BA * BW * NB + BA + BW - 2 + 8))"
}

# abit_gen_stim STIM_DIR RUN_DIR...: operands (gen_abit_workload.py --dist plain = gen_bitplane_workload.py's
# operands) into STIM_DIR, copied as bpt_*.hex into each RUN_DIR.
abit_gen_stim() {
    local stim=$1 d
    shift
    mkdir -p "$stim"
    python3 sweeps/cbsg/af_ipd/abit/gen_abit_workload.py --ba "$BA" --bw "$BW" --L "$L" --mrows "$MROWS" \
        --ncols "$NCOLS" --dist plain --plain-dist uniform --seed "$SEED" --row-unit "$ROWS_PE" \
        --out-dir "$stim" > "$stim/gen.log"
    for d in "$@"; do
        mkdir -p "$d"
        cp -p "$stim/bpt_a.hex" "$d/bpt_a.hex"
        cp -p "$stim/bpt_w.hex" "$d/bpt_w.hex"
    done
}

# abit_check RUN_DIR JSON: the schedule's trace + window checker.
abit_check() {
    if [[ "$SCHED" == cur ]]; then
        python3 sweeps/cbsg/af_ipd/check_bp_power_trace.py "$1" --json "$2" --lap-ring-only --lap-len "$BPE_LAP_LEN"
    else
        python3 sweeps/cbsg/af_ipd/abit/check_abit_power_trace.py "$1" --json "$2"
    fi
}
