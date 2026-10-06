#!/bin/bash
# Pre-layout INT energy A/B of the lap-length family (g = tiles per doubling
# mux): the BP ring (g = 8), the sub-ring tops (g = 4, 2) and in-place doubling
# (g = 1), all on the same basis, single PE.
#
#   bash sweeps/int_mode/bp/sr/run_int_energy_prelayout_ab.sh               # every arm, every point
#   ARMS="lap ipd" POINTS="int8_uniform_L1024_dr" bash .../run_int_energy_prelayout_ab.sh
#   LIST=1 ...   print the arm / point plan and exit
#
# Arms (synthesis runs, read only; nothing is written into syn/build):
#   lap  PAYN_SC_CSA_BP/csa_bp_20261004_lap            payn_array_signed_segmented_csa_bp     g = 8
#   sr4  PAYN_SC_CSA_BP_SR4/csa_bp_sr4_20261004_clean  payn_array_signed_segmented_csa_bp_sr  g = 4
#   sr2  PAYN_SC_CSA_BP_SR2/csa_bp_sr2_20261004_clean  payn_array_signed_segmented_csa_bp_sr  g = 2
#   ipd  PAYN_SC_CSA_BP_IPD/csa_bp_ipd_20261004        payn_array_signed_segmented_csa_bp_ipd g = 1
# (run names overridable: LAP_RUN, SR4_RUN, SR2_RUN, IPD_RUN).
#
# Bench: designs/payn/power/power_payn_array_bp_int.sv, points and defines from
# sweeps/int_mode/bp/bp_int_energy_lib.sh with BPE_LAP_RING_ONLY=1 (the
# csa_bp_20261004_lap contract the routed numbers used; on the SR / IPD tops
# shift_in is then high on drain edges only and ring_q alone runs the laps) and
# BPE_LAP_LEN = g (the lap arm runs the bench's default schedule, no lap
# define).  Operands are the routed campaign's (same generator, seeds and
# shapes), identical across arms, so every delta is activity-matched.
# Windows: d / dr as the routed flow (data / data + ring intervals, classed by
# interval count, drain excluded), plus dc / drc (the same windows classed by
# cause: every lap edge's response in the lap class), at L = 1024 (48 / 96
# blocks) and 4096 (one block), INT8 and INT4 uniform; the routed campaign's
# long-L data-only points (INT8 L = 49152, INT4 L = 98304) for calibration;
# and the drain-inclusive window (all) at L = 1024 as a secondary number.
#
# Per (arm, point), under OUT/<arm>/<label>/:
#   1. RTL on a per-arm RTL snapshot (OUT/<arm>/rtl_snapshot, the include
#      closure of the arm's top): the bench's exact PASS line; every drained
#      tile and combiner word bit-exact against numpy and the SAIF window
#      counts exact for g (check_bp_power_trace.py --lap-ring-only --lap-len g).
#   2. GL on the synthesized netlist, max delays from an IDEAL-CLOCK copy of
#      its DC SDF (OUT/<arm>/sdf/, sweeps/int_mode/bp/sr/ideal_clock_sdf.py):
#      DC leaves the gated clock nets unbuffered pre-CTS, so its SDF gives the
#      PREICG_X0P5B clock gates CK->ECK delays of up to 3.36 ns, longer than
#      the 1.25 ns clock pulse; VCS then swallows the gated clocks (the tiles
#      never leave their power-up X).  The copy zeroes only those 480 IOPATH
#      lines (the ideal clock DC's STA assumed); every data-path delay is
#      kept, so the SAIF holds the pre-layout glitch activity.  Same compile
#      and run as `make sim GL=syn` (direct VCS so that the SDF can be the
#      copy) with the routed flow's arguments, +neg_tchk +sdfverbose, timing
#      checks on.  Then: PASS line, SDF annotation and post-reset timing audit
#      (validate_routed_gl.py), the same bit-exact check, GL trace and window
#      record byte-identical to RTL, validate_sc_power_saif.py and
#      bp_saif_int_audit.py on the SAIF.
#   3. PT-PX, pre-layout (sweeps/int_mode/bp/sr/pt_int_energy_prelayout.tcl:
#      the routed power.tcl without parasitics), activity coverage checked
#      (no default / unannotated nets, pinless policy applied).
#   4. row.csv (sweeps/int_mode/bp/bp_int_energy_row.py, unchanged).
# Then OUT/results.csv and sweeps/int_mode/bp/sr/int_energy_prelayout_ab.py
# (pJ/MAC, per-cycle energies, deltas vs lap, calibration against the routed
# lap campaign, comparison with the estimate).
# Never overwrites: a completed point is reused, an unfinished one is kept and
# the run stops unless RETRY_FAILED=1 (which moves it aside).
set -Eeuo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
cd "$REPO"
export BPE_LAP_RING_ONLY=1
# shellcheck source=../bp_int_energy_lib.sh
source sweeps/int_mode/bp/bp_int_energy_lib.sh

OUT=${OUT:-build/power_char/tile_doubling_energy_20261004/int_energy_ab}
[[ "$OUT" == /* ]] || OUT="$REPO/$OUT"
ARMS=${ARMS:-"lap sr4 sr2 ipd"}
DEFAULT_POINTS=""
for _p in int8 int4; do
    for _l in 1024 4096; do
        for _w in d dr dc drc; do DEFAULT_POINTS+=" ${_p}_uniform_L${_l}_${_w}"; done
    done
done
DEFAULT_POINTS+=" int8_uniform_L49152_d int4_uniform_L98304_d int8_uniform_L1024_all int4_uniform_L1024_all"
unset _p _l _w
POINTS=${POINTS:-$DEFAULT_POINTS}
MAX_JOBS=${MAX_JOBS:-8}
RETRY_FAILED=${RETRY_FAILED:-0}
LIST=${LIST:-0}
LAP_RUN=${LAP_RUN:-csa_bp_20261004_lap}
SR4_RUN=${SR4_RUN:-csa_bp_sr4_20261004_clean}
SR2_RUN=${SR2_RUN:-csa_bp_sr2_20261004_clean}
IPD_RUN=${IPD_RUN:-csa_bp_ipd_20261004}
TB=$BPE_TB
PERIOD=2.5
PT_TCL=$REPO/sweeps/int_mode/bp/sr/pt_int_energy_prelayout.tcl
GL_EXTRA=${GL_EXTRA:-}
GL_VALIDATOR_ARGS=${GL_VALIDATOR_ARGS:-}
KIT=/afs/eecs.umich.edu/kits/ARM/TSMC_22ULL/arm_2020q4
VLIB="$KIT/sc7mcpp140z_base_svt_c30/r3p0/verilog/sc7mcpp140z_cln22ul_base_svt_c30.v $KIT/sc7mcpp140z_hpk_svt_c30/r3p0/verilog/sc7mcpp140z_cln22ul_hpk_svt_c30.v"

arm_cfg() {   # arm -> "target run top g dut_defines"
    case $1 in
        lap) echo "PAYN_SC_CSA_BP $LAP_RUN payn_array_signed_segmented_csa_bp 8 -" ;;
        sr4) echo "PAYN_SC_CSA_BP_SR4 $SR4_RUN payn_array_signed_segmented_csa_bp_sr 4 +define+BPE_DUT_SR+define+PAYN_LAP_G=4" ;;
        sr2) echo "PAYN_SC_CSA_BP_SR2 $SR2_RUN payn_array_signed_segmented_csa_bp_sr 2 +define+BPE_DUT_SR+define+PAYN_LAP_G=2" ;;
        ipd) echo "PAYN_SC_CSA_BP_IPD $IPD_RUN payn_array_signed_segmented_csa_bp_ipd 1 +define+BPE_DUT_IPD" ;;
        *) echo "unknown arm $1" >&2; return 2 ;;
    esac
}
arm_src() {   # arm -> the top's source under designs/
    case $1 in
        lap) echo payn/variants/signed_segmented_csa_bp/payn_array_signed_segmented_csa_bp.sv ;;
        sr4|sr2) echo payn/variants/signed_segmented_csa_bp_sr/payn_array_signed_segmented_csa_bp_sr.sv ;;
        ipd) echo payn/variants/signed_segmented_csa_bp_ipd/payn_array_signed_segmented_csa_bp_ipd.sv ;;
    esac
}

[[ "$MAX_JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "MAX_JOBS must be a positive integer" >&2; exit 2; }
for a in $ARMS; do
    read -r tgt run top g dd <<< "$(arm_cfg "$a")" || exit 2
    syn=$REPO/syn/build/TSMC22/$tgt/$run
    for f in "$top.syn.v" "$top.syn.sdf" "$top.syn.sdc"; do
        [[ -s "$syn/$f" ]] || { echo "[$a] missing $syn/$f" >&2; exit 2; }
    done
done
for label in $POINTS; do
    bpe_point_config "$label" > /dev/null || { echo "invalid point $label" >&2; exit 2; }
done

if [[ "$LIST" == 1 ]]; then
    for a in $ARMS; do
        read -r tgt run top g dd <<< "$(arm_cfg "$a")"
        echo "arm $a: TSMC22/$tgt/$run top=$top g=$g dut_defines=$dd"
        for label in $POINTS; do
            BPE_LAP_LEN=$g bpe_point_config "$label"
            printf '  %-26s BA=%s BW=%s L=%s MROWS=%s NCOLS=%s blocks=%s mode=%s active=%s\n    defs=%s\n    expect "%s"\n' \
                "$label" "$BA" "$BW" "$L" "$MROWS" "$NCOLS" "$NBLK" "$MODE" "$ACTIVE" \
                "$(BPE_LAP_LEN=$g bpe_defs)" "$(BPE_LAP_LEN=$g bpe_pass_line)"
        done
    done
    exit 0
fi

source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
export SYNOPSYS=${SYNOPSYS:-/usr/caen/synopsys-synth-2021.06-SP1}
export ZERO_PINLESS_NET_ACTIVITY=1
export USE_DW=1 NTFY_CHNL=
export TSMC22_CELL_TIER=sc7mcpp140z TSMC22_LIB_FLAVORS=svt_c30
export TSMC22_HPK_FLAVORS=svt_c30 TSMC22_HPK=1
export PERIOD
export SNPSLMD_QUEUE=true
unset NETLIST_FILE SDC_FILE SDF_FILE NO_SDF VCS_ARGS

# arm_snapshot ARM SNAP: the include closure of the arm's top + clk_util.sv,
# with a sha256 MANIFEST; on reuse, report drift of the working tree.
arm_snapshot() {
    python3 - "$2" "$(arm_src "$1")" <<'PY'
import hashlib, re, shutil, sys
from pathlib import Path
snap, root = Path(sys.argv[1]), Path('designs')
inc = re.compile(r'^\s*`include\s+"([^"]+)"', re.M)
todo, seen = [sys.argv[2], 'common/clk_util.sv'], []
while todo:
    rel = todo.pop()
    if rel in seen:
        continue
    if not (root / rel).is_file():
        sys.exit(f'include {rel} not found under designs/')
    seen.append(rel)
    todo += inc.findall((root / rel).read_text())
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

# PT activity coverage (the activity half of sweeps/validate_pt_power_coverage.py;
# there are no parasitics to audit pre-layout).
pt_activity_check() {   # reports_dir pt_log json
    python3 - "$@" <<'PY'
import json, re, sys
from pathlib import Path
rep, log, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
rows = re.findall(r'^[ \t]*Nets[ \t]+(?=\d)(.+)$', (rep / 'saif_coverage.rpt').read_text(), re.M)
if len(rows) != 2:
    sys.exit('expected switching and static-probability net coverage rows')
forced = re.findall(r'Forced\s+(\d+)\s+pinless net\(s\) to static-zero activity', log.read_text(errors='replace'))
if len(forced) != 1:
    sys.exit('missing ZERO_PINLESS_NET_ACTIVITY evidence')
pinless = int(forced[0])
res = {}
for kind, row in zip(('switching', 'static_probability'), rows):
    counts = [int(x) for x in re.findall(r'(\d+)\([0-9.]+%\)', row)]
    total = int(re.search(r'\s(\d+)\s*$', row)[1])
    if len(counts) != 10 or sum(counts) != total or total <= 0:
        sys.exit(f'unrecognized {kind} coverage row')
    if counts[6] or counts[9]:
        sys.exit(f'{kind}: {counts[6]} default and {counts[9]} unannotated nets')
    if counts[1] != pinless:
        sys.exit(f'{kind}: static nets {counts[1]} != pinless {pinless}')
    res[kind] = counts
if res['switching'] != res['static_probability']:
    sys.exit('switching and static-probability sources disagree')
out.write_text(json.dumps({'status': 'PASS', 'activity_file_nets': res['switching'][0],
                           'static_pinless_nets': pinless, 'parasitics': 'none (pre-layout)'}, indent=2) + '\n')
print(f"PT activity coverage PASS: {res['switching'][0]} nets from the SAIF, {pinless} pinless static, 0 default, 0 unannotated")
PY
}

# validate_routed_gl.py verdict, with ONE pre-layout allowance: DC writes the
# async-reset check of the DFFRPQ* flops as RECOVERY + HOLD (negedge R), the
# routed (Innovus) SDF as RECREM; the cell models carry $recrem, so VCS finds
# no $hold for R and warns SDFCOM_CFTC.  Accepted only if that is the sole
# rejection reason, every SDFCOM_CFTC is a $hold(posedge CK [&&& ENABLE_D],
# negedge R) on a DFFRPQ* cell and no timing violation follows reset;
# recorded in the JSON.
prelayout_timing_qualify() {   # sim.log raw.json out.json
    python3 - "$@" <<'PYQ'
import json, re, sys
log, raw, out = open(sys.argv[1], errors='replace').read(), json.load(open(sys.argv[2])), sys.argv[3]
rec = dict(raw)
if raw['status'] != 'PASS':
    if raw['rejection_reasons'] != ['unapproved SDF warnings: SDFCOM_CFTC']:
        sys.exit(f"GL timing qualification FAIL: {raw['rejection_reasons']}")
    blocks = re.findall(r"Warning-\[SDFCOM_CFTC\](.*?)(?=\n\s*\n|\Z)", log, re.S)
    norm = [' '.join(b.split()) for b in blocks]
    bad = [b for b in norm if not (re.search(r'module: DFFRPQ\w*_A7PP140ZTS_C30', b) and
                                   re.search(r'Cannot find timing check \$hold\(posedge CK( &&& \(ENABLE_D==1.h1\))?,negedge R,', b))]
    if bad or len(blocks) != raw['sdf_warning_categories'].get('SDFCOM_CFTC') or raw['post_reset_timing_violations']:
        sys.exit(f"SDFCOM_CFTC allowance refused: {len(bad)} other blocks, "
                 f"{raw['post_reset_timing_violations']} post-reset violations")
    rec['status'] = 'PASS'
    rec['validator_status'] = 'FAIL'
    rec['prelayout_allowance'] = {
        'SDFCOM_CFTC': len(blocks),
        'reason': 'DC SDF writes the DFFRPQ* async-reset removal check as HOLD (negedge R) (posedge CK); '
                  'the ARM models check R with $recrem, so VCS cannot annotate it (the routed SDF writes RECREM)'}
json.dump(rec, open(out, 'w'), indent=2)
print(f"pre-layout GL timing qualification PASS (validator {raw['status']}; "
      f"{rec.get('prelayout_allowance', {}).get('SDFCOM_CFTC', 0)} SDFCOM_CFTC allowed; "
      f"{raw['startup_timing_violations']} startup / {raw['post_reset_timing_violations']} post-reset timing reports)")
PYQ
}

run_point() (
    local arm=$1 label=$2 tgt run top g dd syn work rtldir gldir defs pass glargs dutargs
    local BA BW L MROWS NCOLS DIST SEED MODE NBLK NB ROWS_PE ACTIVE
    read -r tgt run top g dd <<< "$(arm_cfg "$arm")"
    export BPE_LAP_LEN=$g
    bpe_point_config "$label"
    syn=$REPO/syn/build/TSMC22/$tgt/$run
    work=$OUT/$arm/$label rtldir=$OUT/$arm/$label/rtl gldir=$OUT/$arm/$label/gl
    defs=$(bpe_defs)
    pass=$(bpe_pass_line)
    dutargs=""
    [[ "$dd" == - ]] || dutargs=" ${dd//+define/ +define}"
    glargs="+define+PAYN_ARRAY_DUT=$top$defs +neg_tchk +sdfverbose${GL_EXTRA:+ $GL_EXTRA}"
    local snap=$OUT/$arm/rtl_snapshot tag="[$arm/$label]"

    if [[ -f "$work/status" && "$(cat "$work/status")" == PASS ]]; then
        grep -qx "netlist=$syn/$top.syn.v" "$work/inputs.txt" \
            || { echo "$tag completed point belongs to another netlist; use another OUT" >&2; exit 1; }
        echo "$tag reuse completed point"; exit 0
    fi
    if [[ -e "$work" ]]; then
        [[ "$RETRY_FAILED" == 1 ]] || { echo "$tag unfinished point preserved; RETRY_FAILED=1 to redo" >&2; exit 1; }
        mv "$work" "$work.failed_$(date +%Y%m%d_%H%M%S)_$BASHPID"
    fi
    mkdir -p "$work/stim" "$rtldir/$TB" "$gldir/$TB" "$work/power"
    trap 'rc=$?; printf "FAILED arm=%s label=%s exit=%s line=%s time=%s\n" "$arm" "$label" "$rc" "$LINENO" "$(date -Is)" >> "$work/failures.log"; exit "$rc"' ERR
    printf 'arm=%s\nlabel=%s\ntarget=TSMC22/%s\nrun=%s\nnetlist=%s\nsdf_source=%s (simulated: ideal-clock copy in OUT/<arm>/sdf)\nsdc=%s\ntop=%s\nlap_len=%s\ndut_defines=%s\nBA=%s BW=%s L=%s MROWS=%s NCOLS=%s blocks=%s NB=%s\ndist=%s seed=%s saif_mode=%s active_intervals=%s\nlap_ring_only=%s\nrtl_defs=%s%s\nglargs=%s\nsdf_corner=max\npt=%s (pre-layout, no parasitics)\nrtl_snapshot=%s\nstarted=%s\n' \
        "$arm" "$label" "$tgt" "$run" "$syn/$top.syn.v" "$syn/$top.syn.sdf" "$syn/$top.syn.sdc" "$top" "$g" "$dd" \
        "$BA" "$BW" "$L" "$MROWS" "$NCOLS" "$NBLK" "$NB" "$DIST" "$SEED" "$MODE" "$ACTIVE" \
        "$BPE_LAP_RING_ONLY" "${defs//+define/ +define}" "$dutargs" "$glargs" "$PT_TCL" "$snap" "$(date -Is)" > "$work/inputs.txt"

    bpe_gen_stim "$work/stim" "$rtldir/$TB" "$gldir/$TB"

    echo "$tag RTL"
    make sim TOP=Top BUILD_DIR="$rtldir" TB="$TB" USE_DW=1 NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" \
        VCS_ARGS="+incdir+$snap ${defs//+define/ +define}$dutargs" > "$rtldir/simulation.log" 2>&1
    grep -Fqx "$pass" "$rtldir/simulation.log"
    python3 sweeps/int_mode/bp/check_bp_power_trace.py "$rtldir/$TB" --json "$rtldir/check.json" \
        --lap-ring-only --lap-len "$g" > "$rtldir/check.log" 2>&1
    grep -q '^\[PASS\]' "$rtldir/check.log"
    rm -rf "$rtldir/$TB.obj" "$rtldir/$TB/simv.daidir" "$rtldir/$TB/simv" "$rtldir/$TB/dut.saif"

    echo "$tag GL (synthesized netlist, ideal-clock DC SDF, max)"
    local sdf=$OUT/$arm/sdf/$top.syn.idealclk.sdf
    [[ -s "$sdf" ]]
    {
        printf 'post-syn GL sim (direct VCS, the compile and run of make sim GL=syn with the ideal-clock SDF):\n'
        printf '  netlist = %s\n  sdf     = %s\n  vlib    = %s\n  period  = %s ns\n  sdf corner = max\n' \
            "$syn/$top.syn.v" "$sdf" "$VLIB" "$PERIOD"
        # shellcheck disable=SC2086
        vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca $glargs +incdir+"$REPO/designs" -assert svaext \
            +maxdelays +define+GL_SIM "+define+SDF_FILE=\"$sdf\"" +define+ASTRAEA_CLK_PERIOD_NS=$PERIOD \
            -timescale=1ns/1ps +define+TETRAMAX -o "$gldir/$TB/simv" -Mdir="$gldir/$TB.obj" \
            $VLIB "$syn/$top.syn.v" "$TB" -top Top
        (cd "$gldir/$TB" && ./simv +sdf="$sdf")
    } > "$gldir/simulation.log" 2>&1
    grep -Fqx "$pass" "$gldir/simulation.log"
    grep -Fq '[INFO] $sdf_annotate(' "$gldir/simulation.log"
    local -a vargs=()
    read -r -a vargs <<< "$GL_VALIDATOR_ARGS"
    python3 sweeps/validate_routed_gl.py "$gldir/simulation.log" --expected-pass "$pass" \
        "${vargs[@]}" --json "$gldir/timing_qualification_raw.json" > "$gldir/timing_validation.log" 2>&1 || true
    prelayout_timing_qualify "$gldir/simulation.log" "$gldir/timing_qualification_raw.json" \
        "$gldir/timing_qualification.json" >> "$gldir/timing_validation.log" 2>&1
    local saif="$gldir/$TB/dut.saif"
    [[ -s "$saif" ]]
    python3 sweeps/int_mode/bp/check_bp_power_trace.py "$gldir/$TB" --json "$gldir/check.json" \
        --lap-ring-only --lap-len "$g" > "$gldir/check.log" 2>&1
    grep -q '^\[PASS\]' "$gldir/check.log"
    cmp -s "$rtldir/$TB/bpt_trace.txt" "$gldir/$TB/bpt_trace.txt"
    cmp -s "$rtldir/$TB/bpe_saif.txt" "$gldir/$TB/bpe_saif.txt"
    python3 sweeps/validate_sc_power_saif.py "$saif" --expected-period-ns "$PERIOD" \
        > "$gldir/saif_validation.log" 2>&1
    python3 sweeps/int_mode/bp/bp_saif_int_audit.py "$saif" --json "$gldir/saif_int_audit.json" \
        > "$gldir/saif_int_audit.log" 2>&1
    rm -rf "$gldir/$TB.obj" "$gldir/$TB/simv.daidir" "$gldir/$TB/simv"

    echo "$tag PT-PX (pre-layout)"
    local ptw="$work/pt"
    mkdir -p "$ptw"
    (cd "$ptw" && TOP="$top" NL="$syn/$top.syn.v" SDC="$syn/$top.syn.sdc" SAIF_FILE="$saif" \
        SAIF_STRIP_PATH=Top/dut pt_shell -file "$PT_TCL" > pt.log 2>&1)
    if grep -nE '^(Error:|ERROR:)' "$ptw/pt.log" > "$ptw/pt_errors.txt"; then false; fi
    grep -q "^INT_PRELAYOUT_POWER_DONE $top\$" "$ptw/pt.log"
    pt_activity_check "$ptw/reports" "$ptw/pt.log" "$ptw/reports/power_coverage.json" > "$work/power_coverage.log" 2>&1
    cp -p "$ptw/pt.log" "$ptw"/reports/*.rpt "$ptw/reports/block_power.csv" "$ptw/reports/power_coverage.json" "$work/power/"
    rm -f "$saif.gz"; gzip -k "$saif"; rm -f "$saif"   # keep the SAIF, compressed

    python3 sweeps/int_mode/bp/bp_int_energy_row.py "$work" "$label" --period-ns "$PERIOD" \
        --route "${run}_prelayout" > "$work/row.log" 2>&1
    printf 'PASS\n' > "$work/status"
    echo "$tag complete: $(tail -n 1 "$work/row.csv" | cut -d, -f1-13,22-23)"
)

mkdir -p "$OUT"
for a in $ARMS; do
    arm_snapshot "$a" "$OUT/$a/rtl_snapshot"
    read -r tgt run top g dd <<< "$(arm_cfg "$a")"
    src_sdf=$REPO/syn/build/TSMC22/$tgt/$run/$top.syn.sdf
    isdf=$OUT/$a/sdf/$top.syn.idealclk.sdf
    if [[ -s "$isdf" ]]; then
        python3 -c 'import hashlib, json, sys; rec = json.load(open(sys.argv[1])); sys.exit(0 if rec["sdf_in_sha256"] == hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest() else 1)' \
            "$OUT/$a/sdf/ideal_clock_sdf.json" "$src_sdf" || { echo "[$a] $isdf was made from another SDF" >&2; exit 2; }
        echo "[$a] ideal-clock SDF reused: $isdf"
    else
        mkdir -p "$OUT/$a/sdf"
        python3 sweeps/int_mode/bp/sr/ideal_clock_sdf.py "$src_sdf" "$isdf" --json "$OUT/$a/sdf/ideal_clock_sdf.json" \
            | sed "s/^/[$a] /"
    fi
done
status=0
for label in $POINTS; do
    for a in $ARMS; do
        run_point "$a" "$label" &
        while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || true; done
    done
done
wait || true
# The outcome is each point's status file (wait -n can miss a job that ends
# before the loop polls).
for label in $POINTS; do
    for a in $ARMS; do
        if [[ "$(cat "$OUT/$a/$label/status" 2>/dev/null)" != PASS ]]; then
            echo "[$a/$label] NOT PASSED (see $OUT/$a/$label/failures.log)"; status=1
        fi
    done
done

python3 - "$OUT" <<'PY'
import csv, sys
from pathlib import Path
out = Path(sys.argv[1])
rows = []
for p in sorted(out.glob('*/*/row.csv')):
    st = p.parent / 'status'
    if st.is_file() and st.read_text().strip() == 'PASS':
        r = next(csv.DictReader(p.open()))
        r = {'arm': p.parent.parent.name, **r}
        rows.append(r)
if rows:
    with (out / 'results.csv').open('w', newline='') as stream:
        w = csv.DictWriter(stream, fieldnames=list(rows[0]))
        w.writeheader(); w.writerows(rows)
    print(f"{len(rows)} qualified points -> {out / 'results.csv'}")
PY
if [[ -s "$OUT/results.csv" ]]; then
    python3 sweeps/int_mode/bp/sr/int_energy_prelayout_ab.py "$OUT" > "$OUT/summary.txt" 2>&1 \
        || { echo "int_energy_prelayout_ab.py failed; see $OUT/summary.txt" >&2; status=1; }
    cat "$OUT/summary.txt"
fi
exit "$status"
