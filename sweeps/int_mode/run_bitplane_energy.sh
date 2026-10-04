#!/bin/bash
# Bit-plane INT energy on the routed CSA single-PE array (comparator bypass
# and per-PE drain ring emulated in the bench; no hardware change).
#   bash sweeps/int_mode/run_bitplane_energy.sh                 # all points
#   POINTS="int8_uniform_L1024_dr" bash sweeps/int_mode/run_bitplane_energy.sh
#   RETRY_FAILED=1 bash sweeps/int_mode/run_bitplane_energy.sh  # redo failed
#
# Bench: designs/payn/power/power_payn_array_int_bitplane.sv (see its header
# for the mapping, schedule and SAIF window modes).  Each point reuses the
# accepted routed checkpoint csa_20261002_distguide_spp_fixed through its own
# lightweight APR view directory apr/build/TSMC22/PAYN_SC_CSA/intE_bitplane_<label>
# (symlinked outputs/ and SDC, own activity/ and reports/), exactly like
# sweeps/run_csa_t_sweep.sh, and gets the same qualification:
#   1. RTL preflight (committed CSA RTL snapshot, LOW_W=9, DesignWare heap):
#      drained tiles bit-exact against check_bitplane_drain.py's numpy reference
#   2. full-library max-SDF GL with +neg_tchk +sdfverbose, routed-timing audit
#      (validate_routed_gl.py, the route's one documented -2 ps IOPATH clamp
#      approved at 10 ps), drained tiles bit-exact again, X-free accumulators
#   3. SAIF validation (validate_sc_power_saif.py), PT-PX with extracted
#      parasitics (make power_apr on the view dir), coverage validation
# Point label: <prec>_<dist>_L<L>_<window>, window = dr (data+ring, drain
# paused), d (data only), all (drain included); dist = uniform (full signed
# range), gauss (signed, sigma = range/4) or relu (post-ReLU activations,
# Gaussian weights) -- see gen_bitplane_workload.py.
set -Eeuo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$REPO"
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
MAX_JOBS=${MAX_JOBS:-4}
TAG=${TAG:-intE_bitplane}
OUT=${OUT:-build/power_char/int_mode_energy_20261003/bitplane}
RETRY_FAILED=${RETRY_FAILED:-0}
[[ "$OUT" == /* ]] || OUT="$REPO/$OUT"
SNAP="$OUT/rtl_snapshot_81881b0"

source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export SYNOPSYS=${SYNOPSYS:-/usr/caen/synopsys-synth-2021.06-SP1}
export ZERO_PINLESS_NET_ACTIVITY=1
export USE_DW=1 NTFY_CHNL=
export TSMC22_CELL_TIER=sc7mcpp140z TSMC22_LIB_FLAVORS=svt_c30
export TSMC22_HPK_FLAVORS=svt_c30 TSMC22_HPK=1
export PERIOD=2.5
unset NETLIST_FILE SDC_FILE SDF_FILE NO_SDF VCS_ARGS
TB=designs/payn/power/power_payn_array_int_bitplane.sv
VCS_CMD='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
target=TSMC22/PAYN_SC_CSA
run=csa_20261002_distguide_spp_fixed
top=payn_array_signed_segmented_csa
validator_args="--approve-negative-iopath-clamp-ps 10"

# label -> "BA BW L MROWS NCOLS DIST SEED MODE".  Long-L points put ~3,072
# data cycles in ONE block (ring laps 1.8% / 0.8% of cycles): the peak.  L=1024
# points run 48 (INT8) or 96 (INT4) blocks, also 3,072 data cycles.  The
# operands of a (precision, dist, L) triple are identical across window modes.
point_config() {
    local prec dist l win
    IFS=_ read -r prec dist l win <<< "$1"
    l=${l#L}
    case "$prec" in
        int8) BA=8 BW=8;; int4) BA=4 BW=4;; w4a8) BA=8 BW=4;;
        *) echo "bad precision in $1" >&2; return 2;;
    esac
    case "$dist" in uniform) SEED=1;; gauss) SEED=2;; relu) SEED=7;; *) echo "bad dist in $1" >&2; return 2;; esac
    case "$prec" in int4) SEED=$((SEED + 2));; w4a8) SEED=$((SEED + 4));; esac
    L=$l
    local rows_pe=$((8 / BA)) nb=$((l / 128))
    if (( l == 1024 )); then
        # 3,072 data cycles: blocks = 3072 / (BW * nb)
        local nblk=$((3072 / (BW * nb))) njg
        case "$prec" in int8) njg=8;; int4) njg=16;; w4a8) njg=12;; esac
        NCOLS=$((8 * njg)); MROWS=$((rows_pe * nblk / njg))
    else
        MROWS=$rows_pe NCOLS=8
    fi
    case "$win" in dr) MODE=0;; d) MODE=1;; all) MODE=2;; *) echo "bad window in $1" >&2; return 2;; esac
    DIST=$dist
    NBLK=$(( (MROWS / rows_pe) * (NCOLS / 8) ))
    NB=$nb
    case "$MODE" in
        0) ACTIVE=$((NBLK * (BW * nb + 8 * (BW - 1))));;
        1) ACTIVE=$((NBLK * BW * nb));;
        2) ACTIVE=$((NBLK * BW * (nb + 8)));;
    esac
}

DEFAULT_POINTS=""
for prec in int8 int4; do
    case $prec in int8) long=49152;; int4) long=98304;; esac
    for dist in uniform gauss relu; do
        DEFAULT_POINTS+=" ${prec}_${dist}_L${long}_d ${prec}_${dist}_L${long}_dr"
        DEFAULT_POINTS+=" ${prec}_${dist}_L1024_d ${prec}_${dist}_L1024_dr ${prec}_${dist}_L1024_all"
    done
done
POINTS=${POINTS:-$DEFAULT_POINTS}

run_point() (
    local label=$1 BA BW L MROWS NCOLS DIST SEED MODE NBLK NB ACTIVE
    point_config "$label"
    local work="$OUT/$label" simdir="$OUT/$label/gl" rtldir="$OUT/$label/rtl"
    local view_run="${TAG}_${label}" route="$REPO/apr/build/$target/$run"
    local view="$REPO/apr/build/$target/${TAG}_${label}"
    local defs="+define+INTB_BA=$BA+define+INTB_BW=$BW+define+INTB_L=$L+define+INTB_MROWS=$MROWS+define+INTB_NCOLS=$NCOLS+define+INTB_SAIF_MODE=$MODE"
    local glargs="+define+PAYN_ARRAY_DUT=$top$defs +neg_tchk +sdfverbose"
    local pass="PASS: INT bit-plane SAIF captured; BA=$BA BW=$BW L=$L blocks=$NBLK mode=$MODE active=$ACTIVE"

    if [[ -f "$work/status" && "$(cat "$work/status")" == PASS ]]; then
        echo "[$label] reuse completed point"; exit 0
    fi
    if [[ -e "$work" ]]; then
        [[ "$RETRY_FAILED" == 1 ]] || { echo "[$label] unfinished point preserved; RETRY_FAILED=1 to redo" >&2; exit 1; }
        mv "$work" "$work.failed_$(date +%Y%m%d_%H%M%S)_$BASHPID"
    fi
    mkdir -p "$work/stim" "$simdir/$TB" "$rtldir/$TB"
    exec 9>"$work/worker.lock"; flock -n 9
    trap 'rc=$?; printf "FAILED label=%s exit=%s time=%s\n" "$label" "$rc" "$(date -Is)" >> "$work/failures.log"; exit "$rc"' ERR
    printf 'label=%s\ntarget=%s\nroute=%s\nview=%s\nBA=%s BW=%s L=%s MROWS=%s NCOLS=%s blocks=%s NB=%s\ndist=%s seed=%s saif_mode=%s active_intervals=%s\nglargs=%s\nvalidator_args=%s\nrtl_snapshot=%s (git %s)\n' \
        "$label" "$target" "$route" "$view" "$BA" "$BW" "$L" "$MROWS" "$NCOLS" "$NBLK" "$NB" \
        "$DIST" "$SEED" "$MODE" "$ACTIVE" "$glargs" "$validator_args" "$SNAP" "$(cat "$SNAP/GIT_HEAD")" > "$work/inputs.txt"

    python3 sweeps/int_mode/gen_bitplane_workload.py --ba "$BA" --bw "$BW" --L "$L" \
        --mrows "$MROWS" --ncols "$NCOLS" --dist "$DIST" --seed "$SEED" --out-dir "$work/stim" \
        > "$work/stim/gen.log"
    cp -p "$work/stim"/intb_*.hex "$rtldir/$TB/"
    cp -p "$work/stim"/intb_*.hex "$simdir/$TB/"

    echo "[$label] RTL preflight"
    make sim TOP=Top BUILD_DIR="$rtldir" TB="$TB" USE_DW=1 NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" \
        VCS_ARGS="+incdir+$SNAP ${defs//+define/ +define}" > "$rtldir/simulation.log" 2>&1
    grep -Fq "$pass" "$rtldir/simulation.log"
    python3 sweeps/int_mode/check_bitplane_drain.py "$rtldir/$TB" --json "$rtldir/check.json" \
        > "$rtldir/check.log" 2>&1
    grep -q '^\[PASS\]' "$rtldir/check.log"
    rm -rf "$rtldir/$TB.obj" "$rtldir/$TB/simv.daidir" "$rtldir/$TB/simv" "$rtldir/$TB/dut.saif"

    echo "[$label] GL started"
    make sim GL=apr TARGET="$target" RUN="$run" TB="$TB" BUILD_DIR="$simdir" \
        SDF_CORNER=max NO_SDF= RTL_PREFLIGHT_CMD=true VCS_ARGS="$glargs" "VCS=$VCS_CMD" \
        NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" > "$simdir/simulation.log" 2>&1
    grep -Fq "$pass" "$simdir/simulation.log"
    # shellcheck disable=SC2086
    python3 sweeps/validate_routed_gl.py "$simdir/simulation.log" --expected-pass "$pass" \
        $validator_args --json "$simdir/timing_qualification.json" > "$simdir/timing_validation.log" 2>&1
    local saif="$simdir/$TB/dut.saif"
    [[ -s "$saif" ]]
    python3 sweeps/int_mode/check_bitplane_drain.py "$simdir/$TB" --json "$simdir/check.json" \
        > "$simdir/check.log" 2>&1
    grep -q '^\[PASS\]' "$simdir/check.log"
    cmp -s <(grep '^DRAIN' "$rtldir/$TB/intb_trace.txt") <(grep '^DRAIN' "$simdir/$TB/intb_trace.txt")
    python3 sweeps/validate_sc_power_saif.py "$saif" --expected-period-ns "$PERIOD" \
        > "$simdir/saif_validation.log" 2>&1
    rm -rf "$simdir/$TB.obj"
    echo "[$label] GL passed; PT-PX started"

    mkdir -p "$view/activity" "$view/reports"
    [[ -e "$view/outputs" ]] || ln -s "../$run/outputs" "$view/outputs"
    [[ -e "$view/$top.syn.sdc" ]] || ln -s "../$run/$top.syn.sdc" "$view/$top.syn.sdc"
    POWER_SAIF_VALIDATOR="$REPO/sweeps/validate_sc_power_saif.py" \
        make power_apr TARGET="$target" RUN="$view_run" SAIF="$saif" SAIF_STRIP_PATH=Top/dut \
        NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" > "$work/power_make.log" 2>&1
    grep -q 'Report : Averaged Power' "$view/reports/power.rpt"
    python3 sweeps/validate_pt_power_coverage.py "$view/reports" \
        --power-log "$view/power_apr.log" --json "$view/reports/power_coverage.json" \
        > "$work/power_coverage.log" 2>&1
    mkdir -p "$work/power"
    cp -p "$view/power_apr.log" "$view"/reports/*.rpt "$view/reports/power_coverage.json" "$work/power/"

    python3 - "$work" "$label" "$PERIOD" <<'PY'
import csv, json, re, sys
from pathlib import Path
work, label, period = Path(sys.argv[1]), sys.argv[2], float(sys.argv[3])
chk = json.loads((work / 'gl' / 'check.json').read_text())
timing = json.loads((work / 'gl' / 'timing_qualification.json').read_text())
assert chk['status'] == 'PASS' and timing['status'] == 'PASS'
report = (work / 'power' / 'power.rpt').read_text()
def total(name):
    m = re.search(name + r'\s*=\s*([0-9.eE+-]+)', report)
    assert m, name
    return float(m[1]) * 1e3
hier = {}
for line in (work / 'power' / 'power_hier.rpt').read_text().splitlines():
    m = re.match(r'\s+(u_pe|u_peripheral|u_a_rng|u_w_rng)\s+\(\S+\)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)', line)
    if m and m[1] not in hier:
        hier[m[1]] = float(m[5]) * 1e3
assert set(hier) == {'u_pe', 'u_peripheral', 'u_a_rng', 'u_w_rng'}, hier
ba, bw = chk['ba'], chk['bw']
win = chk['saif_window']
mac_per_data_cycle = 64 * 128 / (ba * bw)          # 128 INT8, 512 INT4, 256 W4A8
macs = win['data'] * mac_per_data_cycle
mac_per_cycle = macs / win['active']
power = total('Total Power')
prec = {(8, 8): 'INT8', (4, 4): 'INT4', (8, 4): 'W4A8', (4, 8): 'W8A4'}[(ba, bw)]
row = dict(label=label, precision=prec, dist=label.split('_')[1], L=chk['L'], blocks=chk['blocks'],
           saif_mode=chk['saif_mode'], active_cycles=win['active'], data_cycles=win['data'],
           ring_cycles=win['ring'], drain_cycles=win['drain'],
           mac_per_data_cycle=mac_per_data_cycle, mac_per_cycle=mac_per_cycle,
           power_mW=power, internal_mW=total('Cell Internal Power'),
           switching_mW=total('Net Switching Power'), leakage_mW=total('Cell Leakage Power'),
           u_pe_mW=hier['u_pe'], u_peripheral_mW=hier['u_peripheral'],
           sobol_mW=hier['u_a_rng'] + hier['u_w_rng'],
           pJ_MAC=power * period / mac_per_cycle,
           array_pJ_MAC=hier['u_pe'] * period / mac_per_cycle,
           max_abs_tile=chk['max_abs_tile'], tiles_checked=chk['tiles_checked'],
           outputs_checked=chk['outputs_checked'],
           sdf_warnings=json.dumps(timing['sdf_warning_categories'], sort_keys=True),
           approved_iopath_clamps=len(timing['approved_negative_iopath_clamps']),
           post_reset_timing_violations=timing['post_reset_timing_violations'],
           status='PASS')
with (work / 'row.csv').open('w', newline='') as stream:
    writer = csv.DictWriter(stream, fieldnames=list(row))
    writer.writeheader(); writer.writerow(row)
print(json.dumps(row))
PY
    printf 'PASS\n' > "$work/status"
    echo "[$label] complete: $(tail -n 1 "$work/row.csv")"
)

mkdir -p "$OUT"
[[ -f "$SNAP/GIT_HEAD" ]] || { echo "missing RTL snapshot $SNAP" >&2; exit 2; }
status=0
for label in $POINTS; do
    point_config "$label" || exit 2
    run_point "$label" &
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
done
while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done

python3 - "$OUT" <<'PY'
import csv, sys
from pathlib import Path
out = Path(sys.argv[1])
rows = [next(csv.DictReader(p.open())) for p in sorted(out.glob('*/row.csv'))]
rows.sort(key=lambda r: (r['precision'], r['dist'], int(r['L']), int(r['saif_mode'])))
if rows:
    with (out / 'results.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader(); writer.writerows(rows)
    print(f"{len(rows)} qualified points -> {out / 'results.csv'}")
PY
exit "$status"
