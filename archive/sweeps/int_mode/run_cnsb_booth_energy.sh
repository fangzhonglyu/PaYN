#!/bin/bash
# INT-mode energy of the comparator-native spatial Booth mapping (CNSB,
# sweeps/int_mode/model_red_team_novel.py) on the UNCHANGED routed CSA layout.
#   bash sweeps/int_mode/run_cnsb_booth_energy.sh
#   POINTS="int8:uniform:gated:0" bash sweeps/int_mode/run_cnsb_booth_energy.sh
#   RETRY_FAILED=1 bash sweeps/int_mode/run_cnsb_booth_energy.sh
#
# Point = prec:dist:sign:sigma_frac (sigma = sigma_frac * 2^(bits-1); unused
# for uniform).  Every point:
#   1. cnsb_booth_energy.py gen  -> per-slice port image (codes + digit signs)
#   2. RTL sim of the CSA array with designs/payn/power/power_payn_array_int_booth.sv,
#      drained tiles checked bit-exact (tile T_pq, combine == numpy, stimulus
#      emulation)
#   3. full-library max-SDF GL on the accepted route through the same bench,
#      +neg_tchk +sdfverbose, validate_routed_gl.py (10 ps IOPATH clamp
#      approval, as for every CSA point), the same bit-exact check on the GL
#      drain, validate_sc_power_saif.py on the SAIF
#   4. PT-PX (make power_apr) through a lightweight view directory
#      apr/build/TSMC22/PAYN_SC_CSA/intE_booth_<label> (symlinked outputs and
#      SDC, its own activity/ and reports/), then validate_pt_power_coverage.py
# The SAIF window is INT_SLICES (3072) accumulating clocks with the peripheral
# and PE pipes carrying real data on every edge; the drain is outside it.
# No synthesis, no APR, no existing file is modified.
set -Eeuo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$REPO"
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
POINTS=${POINTS:-"int8:uniform:gated:0 int8:dnn:gated:0.5 int8:dnn:gated:0.25
                  w4a8:uniform:gated:0 w4a8:dnn:gated:0.5 w4a8:dnn:gated:0.25
                  int4:uniform:gated:0 int4:dnn:gated:0.5 int4:dnn:gated:0.25
                  int8:dnn:raw:0.25"}
SLICES=${SLICES:-3072}
SEED=${SEED:-20261003}
MAX_JOBS=${MAX_JOBS:-4}
TAG=${TAG:-intE_booth}
OUT=${OUT:-build/power_char/int_mode_energy_20261003/cnsb_booth}
RETRY_FAILED=${RETRY_FAILED:-0}
[[ "$OUT" == /* ]] || OUT="$REPO/$OUT"

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
TB=designs/payn/power/power_payn_array_int_booth.sv
GEN=sweeps/int_mode/cnsb_booth_energy.py
VCS_CMD='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
TARGET=TSMC22/PAYN_SC_CSA RUN=csa_20261002_distguide_spp_fixed
TOP=payn_array_signed_segmented_csa
RTL_SRC=designs/payn/variants/signed_segmented_csa/payn_array_signed_segmented_csa.sv
DIMS="+define+SC_K=8+define+SC_M=16+define+SC_NH=8+define+SC_NW=8+define+SC_OWIDTH=24+define+INT_SLICES=$SLICES"
# The csa route's single clamped -2 ps IOPATH (u_peripheral/U13281) was
# accepted at qualification with a 10 ps bound; the same bound applies here.
VALIDATOR_ARGS="--approve-negative-iopath-clamp-ps 10"
PASS_LINE="PASS: INT Booth SAIF captured; $SLICES slices, drain dumped -> cnsb_booth_energy.py check"

label_of() {
    local prec=$1 dist=$2 sign=$3 sf=$4 l
    if [[ "$dist" == uniform ]]; then l="${prec}_uniform"
    else l="${prec}_gauss$(python3 -c "print(round(2/$sf))")"; fi   # sigma = range/N
    [[ "$sign" == gated ]] || l="${l}_${sign}sign"
    echo "$l"
}

run_point() (
    local prec dist sign sf
    IFS=: read -r prec dist sign sf <<< "$1"
    local label; label=$(label_of "$prec" "$dist" "$sign" "$sf")
    local work="$OUT/$label" view_run="${TAG}_$label"
    local view="$REPO/apr/build/$TARGET/$view_run" route="$REPO/apr/build/$TARGET/$RUN"
    if [[ -f "$work/status" && "$(cat "$work/status")" == PASS ]]; then
        echo "[$label] reuse completed point"; exit 0
    fi
    if [[ -e "$work" ]]; then
        [[ "$RETRY_FAILED" == 1 ]] || { echo "[$label] unfinished point preserved; RETRY_FAILED=1 to redo" >&2; exit 1; }
        mv "$work" "$work.failed_$(date +%Y%m%d_%H%M%S)_$BASHPID"
    fi
    mkdir -p "$work"
    exec 9>"$work/worker.lock"; flock -n 9
    trap 'rc=$?; printf "FAILED label=%s exit=%s time=%s\n" "$label" "$rc" "$(date -Is)" >> "$work/failures.log"; exit "$rc"' ERR
    local glargs="+define+PAYN_ARRAY_DUT=$TOP$DIMS +neg_tchk +sdfverbose"
    local rtlargs="-debug_access+pp +define+PAYN_ARRAY_EXTERNAL_RTL+define+PAYN_ARRAY_DUT=$TOP+define+PAYN_SEG_LOW_W=9$DIMS"
    printf 'label=%s\nprec=%s dist=%s sign=%s sigma_frac=%s seed=%s slices=%s\ntarget=%s\nroute=%s\nview=%s\nrtlargs=%s\nglargs=%s\nvalidator_args=%s\nrtl_source_git=%s\n' \
        "$label" "$prec" "$dist" "$sign" "$sf" "$SEED" "$SLICES" "$TARGET" "$route" "$view" \
        "$rtlargs" "$glargs" "$VALIDATOR_ARGS" \
        "$(git rev-parse --short HEAD) dirty:$(git status --porcelain designs/payn/variants/signed_segmented_csa designs/payn/pe_peripheral.sv designs/payn/sobol.sv | tr '\n' ' ')" \
        > "$work/inputs.txt"

    python3 "$GEN" gen --prec "$prec" --dist "$dist" --sign "$sign" --sigma-frac "$sf" \
        --slices "$SLICES" --seed "$SEED" --out "$work/stim" > "$work/stim.log" 2>&1

    echo "[$label] RTL started"
    mkdir -p "$work/rtl/$TB"
    cp "$work/stim/int_stim.mem" "$work/stim/int_preset.mem" "$work/rtl/$TB/"
    make sim TOP=Top TB="$TB" USE_DW=1 BUILD_DIR="$work/rtl" GL= TARGET= RTL_PREFLIGHT_CMD= \
        SIM_SRCS="$RTL_SRC" VCS_ARGS="$rtlargs" "VCS=$VCS_CMD" NTFY_CHNL= \
        ASTRAEA_FLOW="$ASTRAEA_FLOW" > "$work/rtl/simulation.log" 2>&1
    grep -Fq "$PASS_LINE" "$work/rtl/simulation.log"
    python3 "$GEN" check --stim "$work/stim" --trace "$work/rtl/$TB/int_booth_trace.txt" \
        --json "$work/rtl/check.json" > "$work/rtl/check.log" 2>&1

    echo "[$label] RTL bit-exact; GL started"
    mkdir -p "$work/gl/$TB"
    cp "$work/stim/int_stim.mem" "$work/stim/int_preset.mem" "$work/gl/$TB/"
    make sim GL=apr TARGET="$TARGET" RUN="$RUN" TB="$TB" BUILD_DIR="$work/gl" \
        SDF_CORNER=max NO_SDF= RTL_PREFLIGHT_CMD=true VCS_ARGS="$glargs" "VCS=$VCS_CMD" \
        NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" > "$work/gl/simulation.log" 2>&1
    grep -Fq "$PASS_LINE" "$work/gl/simulation.log"
    # shellcheck disable=SC2086
    python3 sweeps/validate_routed_gl.py "$work/gl/simulation.log" --expected-pass "$PASS_LINE" \
        $VALIDATOR_ARGS --json "$work/gl/timing_qualification.json" > "$work/gl/timing_validation.log" 2>&1
    python3 "$GEN" check --stim "$work/stim" --trace "$work/gl/$TB/int_booth_trace.txt" \
        --json "$work/gl/check.json" > "$work/gl/check.log" 2>&1
    local saif="$work/gl/$TB/dut.saif"
    [[ -s "$saif" ]]
    python3 sweeps/validate_sc_power_saif.py "$saif" --expected-period-ns "$PERIOD" \
        > "$work/gl/saif_validation.log" 2>&1
    echo "[$label] GL bit-exact and qualified; PT-PX started"

    mkdir -p "$view/activity" "$view/reports"
    [[ -e "$view/outputs" ]] || ln -s "../$RUN/outputs" "$view/outputs"
    [[ -e "$view/$TOP.syn.sdc" ]] || ln -s "../$RUN/$TOP.syn.sdc" "$view/$TOP.syn.sdc"
    POWER_SAIF_VALIDATOR="$REPO/sweeps/validate_sc_power_saif.py" \
        make power_apr TARGET="$TARGET" RUN="$view_run" SAIF="$saif" SAIF_STRIP_PATH=Top/dut \
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
meta = json.loads((work / 'stim' / 'stim_meta.json').read_text())
p = work / 'power'
report = (p / 'power.rpt').read_text()
def total(name):
    m = re.search(name + r'\s*=\s*([0-9.eE+-]+)', report)
    assert m, name
    return float(m[1]) * 1e3
cells = {}
for line in (p / 'cell_power.rpt').read_text().splitlines():
    m = re.match(r'(u_pe|u_peripheral|u_a_rng|u_w_rng)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s.*\bh\s*$', line)
    if m and m[1] not in cells:
        cells[m[1]] = float(m[5]) * 1e3
assert set(cells) == {'u_pe', 'u_peripheral', 'u_a_rng', 'u_w_rng'}, cells
timing = json.loads((work / 'gl' / 'timing_qualification.json').read_text())
rtl = json.loads((work / 'rtl' / 'check.json').read_text())
gl = json.loads((work / 'gl' / 'check.json').read_text())
cov = json.loads((p / 'power_coverage.json').read_text())
assert timing['status'] == 'PASS' and rtl['status'] == 'PASS' and gl['status'] == 'PASS'
assert cov['status'] == 'PASS'
mpc = meta['mac_per_cycle_per_pe']
power = total('Total Power')
sobol = cells['u_a_rng'] + cells['u_w_rng']
row = dict(label=label, prec=meta['prec'], dist=meta['dist'], sign=meta['sign'],
           sigma_frac=meta['sigma_frac'], slices=meta['slices'],
           reduction_len=meta['reduction_len_accumulated'], mac_per_cycle_per_pe=mpc,
           power_mW=power, internal_mW=total('Cell Internal Power'),
           switching_mW=total('Net Switching Power'), leakage_mW=total('Cell Leakage Power'),
           u_pe_mW=cells['u_pe'], u_peripheral_mW=cells['u_peripheral'], sobol_mW=sobol,
           other_mW=power - cells['u_pe'] - cells['u_peripheral'] - sobol,
           pJ_MAC=power * period / mpc, array_pJ_MAC=cells['u_pe'] * period / mpc,
           peripheral_pJ_MAC=cells['u_peripheral'] * period / mpc,
           rtl_check=rtl['status'], gl_check=gl['status'],
           gl_tiles_checked=gl['tiles_checked'], gl_gemm_outputs_checked=gl['gemm_outputs_checked'],
           sdf_warnings=json.dumps(timing['sdf_warning_categories'], sort_keys=True),
           approved_iopath_clamps=len(timing['approved_negative_iopath_clamps']),
           post_reset_timing_violations=timing['post_reset_timing_violations'],
           a_digit_zero_frac=meta['stats']['a_digit_zero_frac'],
           w_digit_zero_frac=meta['stats']['w_digit_zero_frac'],
           mean_lane_count=meta['stats']['mean_lane_count'],
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
status=0
for pt in $POINTS; do
    run_point "$pt" &
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
done
while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done

python3 - "$OUT" <<'PY'
import csv, sys
from pathlib import Path
out = Path(sys.argv[1])
rows = [next(csv.DictReader(p.open())) for p in sorted(out.glob('*/row.csv'))]
order = {'int8': 0, 'w4a8': 1, 'int4': 2}
rows.sort(key=lambda r: (order[r['prec']], r['sign'] != 'gated', r['dist'] != 'uniform',
                         -float(r['sigma_frac'] or 9)))
if rows:
    with (out / 'results.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader(); writer.writerows(rows)
    print(f"{len(rows)} qualified points -> {out / 'results.csv'}")
PY
exit "$status"
