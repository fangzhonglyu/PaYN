# shellcheck shell=bash
# Shared point definitions for the BP INT energy bench
# (designs/payn/power/power_payn_array_bp_int.sv), sourced by
# sweeps/int_mode/bp/run_bp_int_energy.sh (routed netlist) and
# sweeps/int_mode/bp/run_bp_int_energy_preflight.sh (RTL / post-synthesis GL),
# so both run exactly the same configurations.
#
# Point label: <prec>_<dist>_L<L>_<window>, as in sweeps/int_mode/run_bitplane_energy.sh:
#   prec   int8 (BA = BW = 8), int4 (BA = BW = 4, int_prec = 1), w4a8 (BA = 8, BW = 4)
#   dist   uniform (full signed range), gauss (round N(0, 2^(B-1)/4): sigma 32 for
#          8-bit, 2 for 4-bit operands), relu (post-ReLU activations, Gaussian
#          weights) -- sweeps/int_mode/gen_bitplane_workload.py, same seeds as the
#          emulation campaign, so the operands are identical point for point
#   L      1024: multi-block, 3,072 data cycles (INT8 48 blocks, INT4 / W4A8 96);
#          any other multiple of 128: ONE block (long L = the peak: INT8 49,152,
#          INT4 / W4A8 98,304 also give 3,072 data cycles)
#   window dr = data + ring (drain paused, BPE_SAIF_MODE 0), d = data only (peak,
#          mode 1), all = drain included (mode 2)
# The operands of a (prec, dist, L) triple are identical across window modes.
#
# Lap contract: BPE_LAP_RING_ONLY=1 in the environment runs every point with
# shift_in on drain edges only (laps on the per-PE ring_q alone, the
# csa_bp_20261004_lap contract); 0 (default) keeps shift_in on lap edges too,
# which is what every earlier campaign ran and is still legal on one PE.
# The default's defines and PASS line are unchanged.
BPE_LAP_RING_ONLY=${BPE_LAP_RING_ONLY:-0}
[[ "$BPE_LAP_RING_ONLY" == 0 || "$BPE_LAP_RING_ONLY" == 1 ]] \
    || { echo "BPE_LAP_RING_ONLY must be 0 or 1 (got '$BPE_LAP_RING_ONLY')" >&2; return 2 2>/dev/null || exit 2; }
#
# Opt-in (sweeps/int_mode/bp/sr/run_int_energy_prelayout_ab.sh); the defaults
# leave every define, PASS line and window count unchanged:
#   BPE_LAP_LEN=g (1, 2, 4; default 8 = the BP ring): g-edge laps for the
#     sub-ring / in-place-doubling tops.  A block is BW*NB + g*(BW-1) + 8 edges,
#     the ring window g*(BW-1) intervals per block; g != 8 adds
#     +define+BPE_LAP_LEN=g and " lap_len=g" to the PASS line.
#   window dc (BPE_SAIF_MODE 3) / drc (mode 4): the d / dr windows classed by
#     the edge that causes each interval (the bench header), same counts.
BPE_LAP_LEN=${BPE_LAP_LEN:-8}
[[ "$BPE_LAP_LEN" == 1 || "$BPE_LAP_LEN" == 2 || "$BPE_LAP_LEN" == 4 || "$BPE_LAP_LEN" == 8 ]] \
    || { echo "BPE_LAP_LEN must be 1, 2, 4 or 8 (got '$BPE_LAP_LEN')" >&2; return 2 2>/dev/null || exit 2; }

BPE_TB=designs/payn/power/power_payn_array_bp_int.sv

BPE_DEFAULT_POINTS=""
for _prec in int8 int4 w4a8; do
    case $_prec in int8) _long=49152;; *) _long=98304;; esac
    for _dist in uniform gauss relu; do
        BPE_DEFAULT_POINTS+=" ${_prec}_${_dist}_L${_long}_d ${_prec}_${_dist}_L${_long}_dr"
        BPE_DEFAULT_POINTS+=" ${_prec}_${_dist}_L1024_d ${_prec}_${_dist}_L1024_dr ${_prec}_${_dist}_L1024_all"
    done
done
unset _prec _long _dist

# bpe_point_config LABEL: sets BA BW L MROWS NCOLS DIST SEED MODE NBLK NB ROWS_PE
# ACTIVE (SAIF intervals in the window); returns 2 (with a message) on a bad label.
bpe_point_config() {
    local prec dist l win extra
    IFS=_ read -r prec dist l win extra <<< "$1"
    if [[ -n "$extra" || ! "$l" =~ ^L[1-9][0-9]*$ ]]; then
        echo "bad point label '$1' (want <int8|int4|w4a8>_<uniform|gauss|relu>_L<L>_<d|dr|all>)" >&2
        return 2
    fi
    l=${l#L}
    case "$prec" in
        int8) BA=8 BW=8;; int4) BA=4 BW=4;; w4a8) BA=8 BW=4;;
        *) echo "bad precision in '$1'" >&2; return 2;;
    esac
    case "$dist" in uniform) SEED=1;; gauss) SEED=2;; relu) SEED=7;;
        *) echo "bad distribution in '$1'" >&2; return 2;;
    esac
    case "$prec" in int4) SEED=$((SEED + 2));; w4a8) SEED=$((SEED + 4));; esac
    case "$win" in dr) MODE=0;; d) MODE=1;; all) MODE=2;; dc) MODE=3;; drc) MODE=4;;
        *) echo "bad window in '$1'" >&2; return 2;;
    esac
    if (( l % 128 != 0 )); then
        echo "L=$l in '$1' is not a multiple of 128" >&2; return 2
    fi
    # |tile| <= 2^(BW-1) * L must fit the 24-bit tiles (INT8 L <= 65,535).
    if (( (1 << (BW - 1)) * l >= (1 << 23) )); then
        echo "L=$l in '$1' can overflow the 24-bit tiles at BW=$BW" >&2; return 2
    fi
    L=$l
    ROWS_PE=$((8 / BA)) NB=$((l / 128))
    if (( l == 1024 )); then
        local nblk=$((3072 / (BW * NB))) njg
        case "$prec" in int8) njg=8;; int4) njg=16;; w4a8) njg=12;; esac
        NCOLS=$((8 * njg)) MROWS=$((ROWS_PE * nblk / njg))
    else
        MROWS=$ROWS_PE NCOLS=8
    fi
    DIST=$dist
    NBLK=$(( (MROWS / ROWS_PE) * (NCOLS / 8) ))
    case "$MODE" in
        0|4) ACTIVE=$((NBLK * (BW * NB + BPE_LAP_LEN * (BW - 1))));;
        1|3) ACTIVE=$((NBLK * BW * NB));;
        2) ACTIVE=$((NBLK * (BW * NB + BPE_LAP_LEN * (BW - 1) + 8)));;
    esac
}

# Compile-time defines for the current point (no spaces: one VCS_ARGS word).
bpe_defs() {
    printf '+define+BPE_BA=%s+define+BPE_BW=%s+define+BPE_L=%s+define+BPE_MROWS=%s+define+BPE_NCOLS=%s+define+BPE_SAIF_MODE=%s' \
        "$BA" "$BW" "$L" "$MROWS" "$NCOLS" "$MODE"
    [[ "$BPE_LAP_RING_ONLY" == 0 ]] || printf '+define+BPE_LAP_RING_ONLY=1'
    [[ "$BPE_LAP_LEN" == 8 ]] || printf '+define+BPE_LAP_LEN=%s' "$BPE_LAP_LEN"
}

# The bench's exact PASS line for the current point.
bpe_pass_line() {
    printf 'PASS: BP INT SAIF captured; BA=%s BW=%s L=%s blocks=%s mode=%s active=%s drained=%s combined=%s' \
        "$BA" "$BW" "$L" "$NBLK" "$MODE" "$ACTIVE" "$((NBLK * 8))" "$((NBLK * 8))"
    [[ "$BPE_LAP_RING_ONLY" == 0 ]] || printf ' lap_ring_only=1'
    [[ "$BPE_LAP_LEN" == 8 ]] || printf ' lap_len=%s' "$BPE_LAP_LEN"
}

# bpe_gen_stim STIM_DIR RUN_DIR...: operands for the current point into STIM_DIR
# (intb_*.hex + intb_meta.json + gen.log), copied as bpt_*.hex into each RUN_DIR.
bpe_gen_stim() {
    local stim=$1 d
    shift
    mkdir -p "$stim"
    python3 sweeps/int_mode/gen_bitplane_workload.py --ba "$BA" --bw "$BW" --L "$L" \
        --mrows "$MROWS" --ncols "$NCOLS" --dist "$DIST" --seed "$SEED" --out-dir "$stim" \
        > "$stim/gen.log"
    for d in "$@"; do
        mkdir -p "$d"
        cp -p "$stim/intb_a.hex" "$d/bpt_a.hex"
        cp -p "$stim/intb_w.hex" "$d/bpt_w.hex"
    done
}

# bpe_snapshot SNAP: copy the include closure of the BP top and the bench
# (resolved against designs/) to SNAP with a sha256 MANIFEST; on reuse, report
# whether the working tree still matches.  RTL runs then put +incdir+SNAP
# ahead of designs/, pinning the RTL for the whole campaign.
bpe_snapshot() {
    python3 - "$1" <<'PY'
import hashlib, re, shutil, sys
from pathlib import Path
snap, root = Path(sys.argv[1]), Path('designs')
seeds = ['payn/variants/signed_segmented_csa_bp/payn_array_signed_segmented_csa_bp.sv',
         'common/clk_util.sv']
inc = re.compile(r'^\s*`include\s+"([^"]+)"', re.M)
todo, seen = list(seeds), []
while todo:
    rel = todo.pop()
    if rel in seen:
        continue
    src = root / rel
    if not src.is_file():
        sys.exit(f'include {rel} not found under designs/')
    seen.append(rel)
    todo += inc.findall(src.read_text())
digest = {rel: hashlib.sha256((root / rel).read_bytes()).hexdigest() for rel in sorted(seen)}
manifest = snap / 'MANIFEST'
if manifest.exists():
    old = dict(line.split()[::-1] for line in manifest.read_text().splitlines() if line.strip())
    drift = sorted(r for r in set(old) | set(digest) if old.get(r) != digest.get(r))
    print(f'RTL snapshot {snap}: reused ({len(old)} files)' +
          (f'; NOTE working tree differs in {drift}' if drift else '; working tree identical'))
    sys.exit(0)
for rel in seen:
    (snap / rel).parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / rel, snap / rel)
manifest.write_text(''.join(f'{h}  {r}\n' for r, h in digest.items()))
print(f'RTL snapshot {snap}: {len(seen)} files')
PY
}
