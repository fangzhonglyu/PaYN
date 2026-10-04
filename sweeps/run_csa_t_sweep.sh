#!/bin/bash
# Energy versus stochastic length T on the routed K8/M16/N8 LOW_W=9 layouts.
#   bash sweeps/run_csa_t_sweep.sh                      # csa, techmap, control
#   ARMS="csa" T_LIST="16 32" bash sweeps/run_csa_t_sweep.sh
#   RETRY_FAILED=1 bash sweeps/run_csa_t_sweep.sh       # redo failed points
#   ARMS="control_k8m8n8 csa_k8m8n8" T_LIST=128 bash sweeps/run_csa_t_sweep.sh
#       other shapes: control_kKmMnN is the clean KMN-sweep route,
#       csa_kKmMnN the carry-save shape route from CAMPAIGN=csa_20261003
#
# No synthesis or APR. Each point reuses the accepted routed checkpoint through
# a lightweight APR view directory (symlinked outputs and SDC, its own
# activity/ and reports/), so the accepted reports and activity stay untouched.
# Each point gets the same qualification as the routed campaign's final stage
# (sweeps/run_popcount_apr.sh): full-library max-SDF GL with +neg_tchk and
# +sdfverbose, routed-timing audit, bit-exact streaming cosim, SAIF
# validation, PT-PX with extracted parasitics and coverage validation.
#
# Every point runs ~3,072 productive clocks: SC_BATCHES = TOTAL_CYCLES/(T/M),
# rounded to the nearest batch where T/M does not divide it (T=80: 614 x 5 =
# 3,070; T=112: 439 x 7 = 3,073). PT-PX power is the average over the point's
# own SAIF window. Magnitudes and signs reload every T/M clocks.
# The layouts were workload-optimized with T=128 activity and are not
# re-optimized per T.
set -Eeuo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
ARMS=${ARMS:-"csa techmap control"}
T_LIST=${T_LIST:-"16 32 48 64 80 96 112 128"}
TOTAL_CYCLES=${TOTAL_CYCLES:-3072}
MAX_JOBS=${MAX_JOBS:-4}
TAG=${TAG:-tsweep_20261003}
OUT=${OUT:-build/power_char/csa_t_sweep_20261003}
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
TB=designs/payn/power/power_payn_array.sv
VCS_CMD='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'

# arm -> target, accepted route, top, routed-GL validator approvals. The csa
# route's single clamped -2 ps IOPATH (u_peripheral/U13281) was accepted at
# qualification with a 10 ps bound; the same bound applies at every T.
arm_config() {
    K=8 M=16 NH=8 NW=8
    if [[ "$1" =~ ^(control|csa)_k([0-9]+)m([0-9]+)n([0-9]+)$ ]]; then
        K=${BASH_REMATCH[2]} M=${BASH_REMATCH[3]} NH=${BASH_REMATCH[4]} NW=${BASH_REMATCH[4]}
    fi
    case "$1" in
        csa_k*) target=TSMC22/PAYN_SC_CSA; run=csa_20261003_$1_distguide_spp_fixed
             top=payn_array_signed_segmented_csa
             validator_args=${CSA_SHAPE_VALIDATOR_ARGS:-};;
        control_k*) target=TSMC22/PAYN_SC_SIGNED_SEGMENTED_CLEAN; run=k${K}m${M}n${NH}_lw9_id125_distguide_spp_fixed
             top=payn_array_signed_segmented_clean; validator_args="";;
        csa) target=TSMC22/PAYN_SC_CSA; run=csa_20261002_distguide_spp_fixed
             top=payn_array_signed_segmented_csa
             validator_args="--approve-negative-iopath-clamp-ps 10";;
        techmap) target=TSMC22/PAYN_SC_POPCOUNT_TECHMAP; run=pc16_20260930_techmap_distguide_spp_fixed
             top=payn_array_signed_segmented_popcount; validator_args="";;
        inferred) target=TSMC22/PAYN_SC_POPCOUNT_INFERRED; run=pc16_20260930_inferred_distguide_spp_fixed
             top=payn_array_signed_segmented_popcount; validator_args="";;
        control) target=TSMC22/PAYN_SC_SIGNED_SEGMENTED_CLEAN; run=k8m16n8_lw9_id125_distguide_spp_fixed
             top=payn_array_signed_segmented_clean; validator_args="";;
        *) echo "Unknown arm: $1" >&2; return 2;;
    esac
}

run_point() (
    local arm=$1 t=$2 target run top validator_args K M NH NW
    arm_config "$arm"
    local mac_cycles=$((t / M))
    local batches=$(( (TOTAL_CYCLES + mac_cycles / 2) / mac_cycles ))
    local work="$OUT/$arm/T$t" simdir="$OUT/$arm/T$t/gl"
    # Shape arms share a target directory with the base arms, so their view
    # names carry the arm; the base arms keep their original view names.
    local view_run="${TAG}_T$t"
    [[ "$arm" != *_k* ]] || view_run="${TAG}_${arm}_T$t"
    local route="$REPO/apr/build/$target/$run"
    local view="$REPO/apr/build/$target/$view_run"
    local glargs="+define+PAYN_ARRAY_DUT=$top+define+SC_K=$K+define+SC_M=$M+define+SC_NH=$NH+define+SC_NW=$NW+define+SC_OWIDTH=24+define+SC_T=$t+define+SC_BATCHES=$batches +neg_tchk +sdfverbose"
    local pass="PASS: streaming SC SAIF captured; $batches batches x $mac_cycles cycles"

    ((t > 0 && t % M == 0)) || { echo "[$arm T$t] T must be a positive multiple of $M" >&2; exit 2; }
    if [[ -f "$work/status" && "$(cat "$work/status")" == PASS ]]; then
        echo "[$arm T$t] reuse completed point"; exit 0
    fi
    if [[ -e "$work" ]]; then
        [[ "$RETRY_FAILED" == 1 ]] || { echo "[$arm T$t] unfinished point preserved; RETRY_FAILED=1 to redo" >&2; exit 1; }
        mv "$work" "$work.failed_$(date +%Y%m%d_%H%M%S)_$BASHPID"
    fi
    mkdir -p "$simdir"
    exec 9>"$work/worker.lock"; flock -n 9
    trap 'rc=$?; printf "FAILED arm=%s T=%s exit=%s time=%s\n" "$arm" "$t" "$rc" "$(date -Is)" >> "$work/failures.log"; exit "$rc"' ERR
    printf 'arm=%s\ntarget=%s\nroute=%s\nview=%s\nT=%s mac_cycles=%s batches=%s productive_cycles=%s\nglargs=%s\nvalidator_args=%s\n' \
        "$arm" "$target" "$route" "$view" "$t" "$mac_cycles" "$batches" "$((batches * mac_cycles))" \
        "$glargs" "$validator_args" > "$work/inputs.txt"
    echo "[$arm T$t] GL started ($batches x $mac_cycles)"

    make sim GL=apr TARGET="$target" RUN="$run" TB="$TB" BUILD_DIR="$simdir" \
        SDF_CORNER=max NO_SDF= RTL_PREFLIGHT_CMD=true VCS_ARGS="$glargs" "VCS=$VCS_CMD" \
        NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" > "$simdir/simulation.log" 2>&1
    grep -Fq "$pass" "$simdir/simulation.log"
    # shellcheck disable=SC2086
    python3 sweeps/validate_routed_gl.py "$simdir/simulation.log" --expected-pass "$pass" \
        $validator_args --json "$simdir/timing_qualification.json" > "$simdir/timing_validation.log" 2>&1
    local trace="$simdir/$TB/array_streaming_rtl.txt" saif="$simdir/$TB/dut.saif"
    [[ -s "$trace" && -s "$saif" ]]
    [[ "$(head -n 1 "$trace")" == "STREAMCFG $K $M $NH $NW 8 24 $t $batches 0" ]]
    python3 designs/payn/cosim/cosim_streaming.py "$trace" > "$simdir/cosim.log" 2>&1
    grep -q '\[PASS\]' "$simdir/cosim.log"
    python3 sweeps/validate_sc_power_saif.py "$saif" --expected-period-ns "$PERIOD" \
        > "$simdir/saif_validation.log" 2>&1
    echo "[$arm T$t] GL passed; PT-PX started"

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

    python3 - "$work" "$arm" "$t" "$mac_cycles" "$batches" "$K" "$M" "$NH" "$NW" "$PERIOD" <<'PY'
import csv, json, re, sys
from pathlib import Path
work, arm, t, mac_cycles, batches, k, m, nh, nw, period = sys.argv[1:]
t, mac_cycles, batches = int(t), int(mac_cycles), int(batches)
p = Path(work) / 'power'
report = (p / 'power.rpt').read_text()
def total(name):
    match = re.search(name + r'\s*=\s*([0-9.eE+-]+)', report)
    assert match, name
    return float(match[1]) * 1e3
hier = {}
for line in (p / 'power_hier.rpt').read_text().splitlines():
    match = re.match(r'\s+(u_pe|u_peripheral|u_a_rng|u_w_rng)\s+\(\S+\)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)', line)
    if match and match[1] not in hier:
        hier[match[1]] = float(match[5]) * 1e3
assert set(hier) == {'u_pe', 'u_peripheral', 'u_a_rng', 'u_w_rng'}, hier
timing = json.loads((Path(work) / 'gl' / 'timing_qualification.json').read_text())
assert timing['status'] == 'PASS'
mac_per_cycle = int(k) * int(m) * int(nh) * int(nw) / t
power = total('Total Power')
row = dict(arm=arm, T=t, mac_cycles=mac_cycles, batches=batches,
           productive_cycles=batches * mac_cycles, mac_per_cycle=mac_per_cycle,
           power_mW=power, internal_mW=total('Cell Internal Power'),
           switching_mW=total('Net Switching Power'), leakage_mW=total('Cell Leakage Power'),
           u_pe_mW=hier['u_pe'], u_peripheral_mW=hier['u_peripheral'],
           sobol_mW=hier['u_a_rng'] + hier['u_w_rng'],
           pJ_MAC=power * float(period) / mac_per_cycle,
           array_pJ_MAC=hier['u_pe'] * float(period) / mac_per_cycle,
           sdf_warnings=json.dumps(timing['sdf_warning_categories'], sort_keys=True),
           approved_iopath_clamps=len(timing['approved_negative_iopath_clamps']),
           post_reset_timing_violations=timing['post_reset_timing_violations'],
           status='PASS')
with (Path(work) / 'row.csv').open('w', newline='') as stream:
    writer = csv.DictWriter(stream, fieldnames=list(row))
    writer.writeheader(); writer.writerow(row)
print(json.dumps(row))
PY
    printf 'PASS\n' > "$work/status"
    echo "[$arm T$t] complete: $(tail -n 1 "$work/row.csv")"
)

mkdir -p "$OUT"
status=0
for arm in $ARMS; do
    arm_config "$arm"
    for t in $T_LIST; do
        run_point "$arm" "$t" &
        while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
    done
done
while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done

python3 - "$OUT" <<'PY'
import csv, sys
from pathlib import Path
out = Path(sys.argv[1])
rows = [next(csv.DictReader(p.open())) for p in sorted(out.glob('*/T*/row.csv'))]
rows.sort(key=lambda r: (r['arm'], int(r['T'])))
if rows:
    with (out / 'results.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader(); writer.writerows(rows)
    print(f"{len(rows)} qualified points -> {out / 'results.csv'}")
PY
exit "$status"
