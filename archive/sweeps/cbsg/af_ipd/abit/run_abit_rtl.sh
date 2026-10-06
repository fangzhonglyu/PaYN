#!/bin/bash
# RTL verification of the ALL-BITS-IN-TIME INT schedule on the C-BSG AF + IPD design (doc/cbsg_handoff.md section 5,
# item 6.1), with no RTL change: the variant designs/payn/variants/signed_segmented_csa_cbsg_af_ipd is read only.
#
# Parts (PARTS="build single grid regress", default all):
#   build    compiles designs/payn/tb/test_payn_array_cbsg_af_ipd.sv (the AF-IPD functional bench; its opt-in
#            +MODE=abit is this schedule) and designs/payn/tb/test_pe_grid_cbsg_af_ipd_abit.sv (abit copy of the IPD
#            grid bench, on the copied grid wrapper) for 2x2 and 4x4.
#   single   +MODE=abit single-PE matrix (SINGLE_CASES): INT8 (L 128..384), INT6 and INT4 (L 128..4096), mixed
#            W4A8 / W6A8 / W8A4, extremes, junk, late int_mode, parked AF counter; negative controls that must be
#            CAUGHT (wrong drains vs the GEMM while the RTL equals the replay of the logged schedule): missing lap,
#            extra lap, wrong pass sign, wrong level order, and the tightness controls (no bubble before a lap,
#            drain one edge early, next block one edge early); contract controls ([BP-CONTRACT] on live W streams,
#            [CBSG-AF-CONTRACT] on SC strobes).  Checker sweeps/cbsg/af_ipd/abit/check_abit_trace.py.
#   grid     the abit grid bench on 2x2 and 4x4 (GRID_CASES): bit-exact drains, per-PE lap runs on the r+c wave,
#            block period with skew and the 8*P_C drain; negative controls (no row / column skew of the lap wave,
#            drain early, block overlap, no bubble, missing lap, extra lap, sign, order).  Checker
#            sweeps/cbsg/af_ipd/abit/check_abit_grid_trace.py.
#   regress  the existing runner's INT and switch parts (PARTS="int switch" bash sweeps/cbsg/af_ipd/run_rtl_checks.sh)
#            on the extended bench, and every INT / switch trace, schedule and check JSON compared byte for byte with
#            the hashes taken before the bench was extended (build/cbsg/af_ipd/abit/baseline/).  The existing
#            runner rewrites build/cbsg/af_ipd/rtl_checks_summary.log with only those parts; this part keeps that
#            rerun summary as baseline/rtl_checks_summary_int_switch_rerun.log and restores the full summary.
# Summary: build/cbsg/af_ipd/abit/abit_rtl_summary.log; per part <part>_summary.log; run dirs <part>/<label>/.
#   bash sweeps/cbsg/af_ipd/abit/run_abit_rtl.sh
#   PARTS="single" bash sweeps/cbsg/af_ipd/abit/run_abit_rtl.sh
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
builtin cd "$REPO"
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export USE_DW=1 NTFY_CHNL= PYTHONDONTWRITEBYTECODE=1
PARTS=${PARTS:-"build single grid regress"}
MAX_JOBS=${MAX_JOBS:-12}
OUT=build/cbsg/af_ipd/abit
A=sweeps/cbsg/af_ipd/abit
TB=designs/payn/tb/test_payn_array_cbsg_af_ipd.sv
GTB=designs/payn/tb/test_pe_grid_cbsg_af_ipd_abit.sv
GEN=$A/gen_abit_workload.py
CHK=$A/check_abit_trace.py
GCHK=$A/check_abit_grid_trace.py
mkdir -p "$OUT"

vcs_compile() {   # out_dir tb top extra_args... (the existing runner's flags)
    local b=$1 tb=$2 top=$3; shift 3
    rm -rf "$b"; mkdir -p "$b"
    vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp +incdir+designs \
        -assert svaext -timescale=1ns/1ps "$@" -o "$b/simv" -Mdir="$b/obj" \
        -y "$SYNOPSYS/dw/sim_ver" +libext+.v+ +incdir+"$SYNOPSYS/dw/sim_ver" \
        "$tb" -top "$top" > "$b/compile.log" 2>&1
}
jobs_wait() { local s=0; while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || s=1; done; return "$s"; }
jobs_drain() { local s=0; while (( $(jobs -rp | wc -l) > 0 )); do wait -n || s=1; done; return "$s"; }
plus_of() { local x fl; [[ "$1" == - ]] && return 0; IFS=, read -ra fl <<< "$1"; for x in "${fl[@]}"; do echo "+$x"; done; }

#------------------------------------------------------------------ (build) --
run_build() {
    local s status=0
    vcs_compile "$OUT/build_func" "$TB" Top & local p1=$!
    for s in 2x2 4x4; do vcs_compile "$OUT/build_grid_$s" "$GTB" Top "+define+BPG_PR=${s%x*}+define+BPG_PC=${s#*x}" & done
    wait "$p1" || status=1
    jobs_drain || status=1
    for b in build_func build_grid_2x2 build_grid_4x4; do
        if [[ -x "$OUT/$b/simv" ]] && grep -q 'signed_segmented_csa_cbsg_af_ipd/inner_pe_core_signed_segmented_csa_cbsg_af_ipd.sv' "$OUT/$b/compile.log"; then
            echo "$b: compiled (reads the AF-IPD PE core)"
        else
            echo "$b: compile FAILED ($OUT/$b/compile.log)"; status=1
        fi
    done
    sha256sum "$TB" "$GTB" designs/payn/variants/signed_segmented_csa_cbsg_af_ipd/*.sv > "$OUT/build_sources_sha256.txt"
    return "$status"
}

#----------------------------------------------------------------- (single) --
# label BA BW L MROWS NCOLS DIST SEED FLAGS EXPECT
# EXPECT: pass | caught (data wrong, RTL = replay of the logged schedule) | fail:CONTRACT ([BP-CONTRACT] stops the
# run) | fail:AFCONTRACT (bit-exact, [CBSG-AF-CONTRACT] count > 0)
SINGLE_CASES=$(cat <<'EOF'
int8_uniform_L128_m8n8            8 8  128  8  8 uniform      1 -                       pass
int8_uniform_L256_m16n16          8 8  256 16 16 uniform      2 -                       pass
int8_uniform_L384_m16n16          8 8  384 16 16 uniform      3 -                       pass
int8_uniform_L384_m24n16_junk     8 8  384 24 16 uniform      4 JUNK                    pass
int8_uniform_L256_m16n8_junk      8 8  256 16  8 uniform     14 JUNK                    pass
int8_allmin_L384_m8n8             8 8  384  8  8 allmin       0 -                       pass
int8_allmax_L384_m8n8             8 8  384  8  8 allmax       0 -                       pass
int8_minxmax_L384_m8n8            8 8  384  8  8 minxmax      0 -                       pass
int8_maxxmin_L256_m8n16           8 8  256  8 16 maxxmin      0 -                       pass
int8_neg1xmin_L384_m8n8           8 8  384  8  8 neg1xmin     0 -                       pass
int8_alternating_L384_m8n16       8 8  384  8 16 alternating  0 -                       pass
int8_relu_L384_m8n8               8 8  384  8  8 relu         5 -                       pass
int8_gauss_L256_m8n8              8 8  256  8  8 gauss        6 -                       pass
int8_plain_L384_m16n64            8 8  384 16 64 plain        1 -                       pass
int8_uniform_L256_m8n8_modeat3    8 8  256  8  8 uniform      7 MODE_AT=3               pass
int8_uniform_L256_m8n16_park      8 8  256  8 16 uniform      8 PARK_CYC0,MODE_AT=2     pass
int8_uniform_L384_m8n8_park_junk  8 8  384  8  8 uniform      9 PARK_CYC0,MODE_AT=3,JUNK pass
int8_uniform_L1024_m8n8_rangedata 8 8 1024  8  8 uniform     10 ABIT_RANGE_DATA         pass
int8_uniform_L4096_m8n8_rangedata 8 8 4096  8  8 uniform     11 ABIT_RANGE_DATA         pass
int6_uniform_L128_m8n8            6 6  128  8  8 uniform     21 -                       pass
int6_uniform_L1024_m16n16         6 6 1024 16 16 uniform     22 -                       pass
int6_uniform_L4096_m8n8           6 6 4096  8  8 uniform     23 -                       pass
int6_allmin_L4096_m8n8            6 6 4096  8  8 allmin       0 -                       pass
int6_minxmax_L4096_m8n8           6 6 4096  8  8 minxmax      0 -                       pass
int6_allmax_L1024_m8n8            6 6 1024  8  8 allmax       0 -                       pass
int6_alternating_L1024_m8n8       6 6 1024  8  8 alternating  0 -                       pass
int6_uniform_L1024_m16n8_junk     6 6 1024 16  8 uniform     24 JUNK                    pass
int6_plain_L1024_m24n32           6 6 1024 24 32 plain        9 -                       pass
int4_uniform_L128_m8n8            4 4  128  8  8 uniform     31 -                       pass
int4_uniform_L1024_m16n16         4 4 1024 16 16 uniform     32 -                       pass
int4_uniform_L4096_m8n8           4 4 4096  8  8 uniform     33 -                       pass
int4_allmin_L4096_m8n8            4 4 4096  8  8 allmin       0 -                       pass
int4_allmax_L1024_m8n8            4 4 1024  8  8 allmax       0 -                       pass
int4_minxmax_L4096_m8n8           4 4 4096  8  8 minxmax      0 -                       pass
int4_alternating_L1024_m8n8       4 4 1024  8  8 alternating  0 -                       pass
int4_uniform_L1024_m8n16_junk     4 4 1024  8 16 uniform     34 JUNK                    pass
int4_allmin_L16384_m8n8           4 4 16384 8  8 allmin       0 -                       pass
w4a8_uniform_L1024_m16n16         8 4 1024 16 16 uniform     41 -                       pass
w4a8_allmin_L1024_m8n8            8 4 1024  8  8 allmin       0 -                       pass
w4a8_uniform_L512_m8n8_junk       8 4  512  8  8 uniform     42 JUNK                    pass
w6a8_uniform_L1024_m8n16          8 6 1024  8 16 uniform     43 -                       pass
w6a8_minxmax_L1024_m8n8           8 6 1024  8  8 minxmax      0 -                       pass
w8a4_uniform_L1024_m8n8           4 8 1024  8  8 uniform     44 -                       pass
neg_int8_nolap_first_L128         8 8  128  8  8 uniform     51 NEG_ABIT_NO_LAP=1       caught
neg_int8_nolap_mid_L128           8 8  128  8  8 uniform     52 NEG_ABIT_NO_LAP=7       caught
neg_int8_nolap_last_L256          8 8  256  8  8 uniform     53 NEG_ABIT_NO_LAP=14      caught
neg_int6_nolap_L1024              6 6 1024  8  8 uniform     54 NEG_ABIT_NO_LAP=5       caught
neg_int4_nolap_L1024              4 4 1024  8  8 uniform     55 NEG_ABIT_NO_LAP=3       caught
neg_w6a8_nolap_L1024              8 6 1024  8  8 uniform     56 NEG_ABIT_NO_LAP=6       caught
neg_int8_extralap_L128            8 8  128  8  8 uniform     57 NEG_ABIT_EXTRA_LAP=7    caught
neg_int6_extralap_L1024           6 6 1024  8  8 uniform     58 NEG_ABIT_EXTRA_LAP=5    caught
neg_int4_extralap_L1024           4 4 1024  8  8 uniform     59 NEG_ABIT_EXTRA_LAP=3    caught
neg_w4a8_extralap_L512            8 4  512  8  8 uniform     60 NEG_ABIT_EXTRA_LAP=4    caught
neg_int8_sign_a0_L128             8 8  128  8  8 uniform     61 NEG_ABIT_SIGN=1         caught
neg_int8_sign_flip_L256           8 8  256  8  8 uniform     62 NEG_ABIT_SIGN=2         caught
neg_int6_sign_a0_L1024            6 6 1024  8  8 uniform     63 NEG_ABIT_SIGN=1         caught
neg_int4_sign_flip_L1024          4 4 1024  8  8 uniform     64 NEG_ABIT_SIGN=2         caught
neg_w6a8_sign_a0_L1024            8 6 1024  8  8 uniform     65 NEG_ABIT_SIGN=1         caught
neg_int8_order_lsb_L128           8 8  128  8  8 uniform     66 NEG_ABIT_ORDER=1        caught
neg_int8_order_swap_L256          8 8  256  8  8 uniform     67 NEG_ABIT_ORDER=2        caught
neg_int6_order_lsb_L1024          6 6 1024  8  8 uniform     68 NEG_ABIT_ORDER=1        caught
neg_int4_order_swap_L1024         4 4 1024  8  8 uniform     69 NEG_ABIT_ORDER=2        caught
neg_int8_nobubble_L256            8 8  256  8 16 uniform     70 NEG_ABIT_NO_BUBBLE      caught
neg_int4_nobubble_L1024           4 4 1024  8  8 uniform     71 NEG_ABIT_NO_BUBBLE      caught
neg_int8_drainearly_L256          8 8  256  8  8 uniform     72 NEG_ABIT_DRAIN_EARLY    caught
neg_int6_drainearly_L1024         6 6 1024  8  8 uniform     73 NEG_ABIT_DRAIN_EARLY    caught
neg_int8_overlap_L256_m8n16       8 8  256  8 16 uniform     74 NEG_ABIT_OVERLAP        caught
neg_int4_overlap_L1024_m8n16      4 4 1024  8 16 uniform     75 NEG_ABIT_OVERLAP        caught
neg_int8_mag_w_L128               8 8  128  8  8 uniform     76 NEG_MAG_W               fail:CONTRACT
neg_int6_scstrobe_L1024           6 6 1024  8  8 uniform     77 JUNK_SCSTROBE           fail:AFCONTRACT
EOF
)

single_case() {   # label ba bw L mrows ncols dist seed flags expect
    local label=$1 ba=$2 bw=$3 L=$4 mrows=$5 ncols=$6 dist=$7 seed=$8 flags=$9 expect=${10}
    local dir="$OUT/single/$label" rc=0 bench_pass=0 afc
    local -a plus
    mapfile -t plus < <(plus_of "$flags")
    rm -rf "$dir"; mkdir -p "$dir"
    python3 "$GEN" --ba "$ba" --bw "$bw" --L "$L" --mrows "$mrows" --ncols "$ncols" --dist "$dist" \
        --seed "$seed" --out-dir "$dir" > "$dir/gen.log" || { echo "$label: FAIL (generator)"; return 1; }
    (builtin cd "$dir" && "$REPO/$OUT/build_func/simv" +MODE=abit +BA="$ba" +BW="$bw" +L="$L" +MROWS="$mrows" \
        +NCOLS="$ncols" +SEED="$seed" "${plus[@]}" > sim.log 2>&1) || rc=$?
    if (( rc == 0 )) && grep -q '^PASS: ABIT INT bench' "$dir/sim.log"; then bench_pass=1; fi
    if [[ "$expect" == fail:CONTRACT ]]; then
        if (( bench_pass == 0 )) && grep -q '\[BP-CONTRACT\]' "$dir/sim.log"; then
            echo "$label: PASS (contract control caught by [BP-CONTRACT])"; return 0
        fi
        echo "$label: FAIL (expected [BP-CONTRACT], see $dir/sim.log)"; return 1
    fi
    (( bench_pass )) || { echo "$label: FAIL (simulation error, see $dir/sim.log)"; return 1; }
    afc=$(grep -m1 '^PASS: ABIT INT bench' "$dir/sim.log" | grep -oE 'af_contract=[0-9]+' | cut -d= -f2)
    case "$expect" in
        caught)
            if python3 "$CHK" "$dir" --json "$dir/check.json" --expect-fail > "$dir/check.log" 2>&1; then
                (( afc == 0 )) || { echo "$label: FAIL ([CBSG-AF-CONTRACT] $afc in a negative schedule control)"; return 1; }
                echo "$label: PASS (negative control $(tail -n 1 "$dir/check.log"))"
            else
                echo "$label: FAIL (negative control not caught: $(tail -n 1 "$dir/check.log"))"; return 1
            fi ;;
        pass|fail:AFCONTRACT)
            if ! python3 "$CHK" "$dir" --json "$dir/check.json" > "$dir/check.log" 2>&1; then
                echo "$label: FAIL $(tail -n 1 "$dir/check.log")"; return 1
            fi
            if [[ "$expect" == fail:AFCONTRACT ]]; then
                (( afc > 0 )) && { echo "$label: PASS (bit-exact, and [CBSG-AF-CONTRACT] caught the SC strobes in INT mode: $afc errors)"; return 0; }
                echo "$label: FAIL (SC strobes in INT mode not flagged)"; return 1
            fi
            (( afc == 0 )) || { echo "$label: FAIL ([CBSG-AF-CONTRACT] $afc errors in a legal run)"; return 1; }
            echo "$label: PASS $(tail -n 1 "$dir/check.log" | sed 's/^\[PASS\] //')" ;;
        *) echo "$label: FAIL (unknown expectation $expect)"; return 1 ;;
    esac
}

run_single() {
    local status=0
    rm -rf "$OUT/single"; mkdir -p "$OUT/single"
    [[ -x "$OUT/build_func/simv" ]] || { echo "no $OUT/build_func/simv (PARTS=build)"; return 1; }
    while read -r label ba bw L mrows ncols dist seed flags expect; do
        [[ -n "$label" ]] || continue
        single_case "$label" "$ba" "$bw" "$L" "$mrows" "$ncols" "$dist" "$seed" "$flags" "$expect" &
        jobs_wait || status=1
    done <<< "$SINGLE_CASES"
    jobs_drain || status=1
    echo "single-PE abit matrix: $(grep -c . <<< "$SINGLE_CASES") cases, status $([[ $status == 0 ]] && echo PASS || echo FAIL)"
    python3 - "$OUT/single" <<'PY' || status=1
import json, re, sys
from pathlib import Path
rows, cov, silent, bad = [], dict(lap_edges=0, tile_laps=0, with_pending_carry=0, with_pending_borrow=0), 0, 0
for d in sorted(Path(sys.argv[1]).iterdir()):
    c = d / "check.json"
    if not c.is_file():
        continue
    j = json.loads(c.read_text())
    log = (d / "sim.log").read_text()
    if j["status"] == "PASS":
        m = re.search(r"LAP_COVERAGE (.*)", log)
        for k, v in re.findall(r"(\w+)=(\d+)", m[1] if m else ""):
            cov[k] += int(v)
        s = re.search(r"INT_SILENT_MAC_SAMPLES (\d+)", log)
        silent += int(s[1]) if s else 0
        ok = j["period_ok"] and j["measured_periods"] == [j["formula"]]
        bad += not ok
        rows.append((d.name, j["precision"], j["L"], j["blocks"], j["formula"], j["measured_periods"],
                     f"{j['data_utilization']:.1%}", "OK" if ok else "MISMATCH"))
print("single-PE block periods (passing cases): case precision L blocks formula(BA*BW*NB+(BA+BW-2)+8) "
      "measured data_utilization")
for r in rows:
    print("  " + " ".join(str(x) for x in r))
print(f"period rows: {len(rows)}, mismatches: {bad}")
print("  lap coverage (bit-exact cases): " + ", ".join(f"{k} {v}" for k, v in cov.items()))
print(f"  INT MACs consumed with the AF streams silent ([BP-CONTRACT] watched every one): {silent}")
sys.exit(0 if rows and not bad and cov["with_pending_carry"] > 0 and cov["with_pending_borrow"] > 0 else 1)
PY
    return "$status"
}

#------------------------------------------------------------------- (grid) --
# label shape BA BW L MROWS NCOLS DIST SEED FLAGS EXPECT (pass | caught)
GRID_CASES=$(cat <<'EOF'
g2_int8_uniform_L384_m16n16          2x2 8 8  384 16 16 uniform      1 -                    pass
g2_int8_uniform_L256_m32n32_junk     2x2 8 8  256 32 32 uniform      2 JUNK                 pass
g2_int8_allmin_L384_m16n16           2x2 8 8  384 16 16 allmin       0 -                    pass
g2_int6_uniform_L1024_m16n32         2x2 6 6 1024 16 32 uniform      3 -                    pass
g2_int6_uniform_L4096_m16n16         2x2 6 6 4096 16 16 uniform      4 -                    pass
g2_int4_uniform_L1024_m32n16         2x2 4 4 1024 32 16 uniform      5 -                    pass
g2_int4_uniform_L4096_m16n16_junk    2x2 4 4 4096 16 16 uniform      6 JUNK                 pass
g2_w4a8_uniform_L1024_m16n16         2x2 8 4 1024 16 16 uniform      7 -                    pass
g2_w6a8_minxmax_L1024_m16n16         2x2 8 6 1024 16 16 minxmax      0 -                    pass
g4_int8_uniform_L384_m32n32          4x4 8 8  384 32 32 uniform     11 -                    pass
g4_int8_uniform_L256_m64n32_junk     4x4 8 8  256 64 32 uniform     12 JUNK                 pass
g4_int8_allmin_L384_m32n32           4x4 8 8  384 32 32 allmin       0 -                    pass
g4_int8_uniform_L128_m32n32          4x4 8 8  128 32 32 uniform     13 -                    pass
g4_int8_uniform_L1024_m32n32_rangedata 4x4 8 8 1024 32 32 uniform   14 ABIT_RANGE_DATA      pass
g4_int8_uniform_L4096_m32n32_rangedata 4x4 8 8 4096 32 32 uniform   15 ABIT_RANGE_DATA      pass
g4_int6_uniform_L1024_m32n64_junk    4x4 6 6 1024 32 64 uniform     16 JUNK                 pass
g4_int6_uniform_L4096_m32n32         4x4 6 6 4096 32 32 uniform     17 -                    pass
g4_int6_allmin_L4096_m32n32          4x4 6 6 4096 32 32 allmin       0 -                    pass
g4_int4_uniform_L1024_m32n32         4x4 4 4 1024 32 32 uniform     18 -                    pass
g4_int4_uniform_L4096_m32n32         4x4 4 4 4096 32 32 uniform     19 -                    pass
g4_w4a8_uniform_L1024_m32n32         4x4 8 4 1024 32 32 uniform     20 -                    pass
gneg2_int8_rowskew_L128              2x2 8 8  128 16 16 uniform     31 NEG_RING_NO_ROW_SKEW caught
gneg2_int8_colskew_L128              2x2 8 8  128 16 16 uniform     32 NEG_RING_NO_COL_SKEW caught
gneg4_int8_rowskew_L256              4x4 8 8  256 32 32 uniform     33 NEG_RING_NO_ROW_SKEW caught
gneg4_int6_colskew_L1024             4x4 6 6 1024 32 32 uniform     34 NEG_RING_NO_COL_SKEW caught
gneg2_int8_drainearly_L128           2x2 8 8  128 16 16 uniform     35 NEG_DRAIN_EARLY      caught
gneg4_int4_drainearly_L1024          4x4 4 4 1024 32 32 uniform     36 NEG_DRAIN_EARLY      caught
gneg2_int8_overlap_L128              2x2 8 8  128 16 32 uniform     37 NEG_BLOCK_OVERLAP    caught
gneg4_int4_overlap_L1024             4x4 4 4 1024 32 64 uniform     38 NEG_BLOCK_OVERLAP    caught
gneg2_int8_nobubble_L128             2x2 8 8  128 16 16 uniform     39 NEG_ABIT_NO_BUBBLE   caught
gneg4_int6_nobubble_L1024            4x4 6 6 1024 32 32 uniform     40 NEG_ABIT_NO_BUBBLE   caught
gneg2_int8_nolap_L128                2x2 8 8  128 16 16 uniform     41 NEG_ABIT_NO_LAP=7    caught
gneg4_int8_extralap_L256             4x4 8 8  256 32 32 uniform     42 NEG_ABIT_EXTRA_LAP=7 caught
gneg2_int6_sign_L1024                2x2 6 6 1024 16 16 uniform     43 NEG_ABIT_SIGN=1      caught
gneg4_int4_order_L1024               4x4 4 4 1024 32 32 uniform     44 NEG_ABIT_ORDER=1     caught
EOF
)

grid_case() {   # label shape ba bw L mrows ncols dist seed flags expect
    local label=$1 shape=$2 ba=$3 bw=$4 L=$5 mrows=$6 ncols=$7 dist=$8 seed=$9 flags=${10} expect=${11}
    local dir="$OUT/grid/$label" rc=0
    local -a plus
    mapfile -t plus < <(plus_of "$flags")
    rm -rf "$dir"; mkdir -p "$dir"
    python3 "$GEN" --ba "$ba" --bw "$bw" --L "$L" --mrows "$mrows" --ncols "$ncols" --dist "$dist" \
        --seed "$seed" --out-dir "$dir" > "$dir/gen.log" || { echo "$label: FAIL (generator)"; return 1; }
    (builtin cd "$dir" && "$REPO/$OUT/build_grid_$shape/simv" +BA="$ba" +BW="$bw" +L="$L" +MROWS="$mrows" \
        +NCOLS="$ncols" "${plus[@]}" > sim.log 2>&1) || rc=$?
    (( rc == 0 )) && grep -q '^PASS: ABIT grid bench' "$dir/sim.log" || { echo "$label: FAIL (simulation error, $dir/sim.log)"; return 1; }
    if [[ "$expect" == caught ]]; then
        if python3 "$GCHK" "$dir" --json "$dir/check.json" --expect-fail > "$dir/check.log" 2>&1; then
            echo "$label: PASS (negative control $(tail -n 1 "$dir/check.log"))"
        else
            echo "$label: FAIL (negative control not caught: $(tail -n 1 "$dir/check.log"))"; return 1
        fi
    elif python3 "$GCHK" "$dir" --json "$dir/check.json" > "$dir/check.log" 2>&1; then
        echo "$label: PASS $(tail -n 1 "$dir/check.log" | sed 's/^\[PASS\] //')"
    else
        echo "$label: FAIL $(tail -n 1 "$dir/check.log")"; return 1
    fi
}

run_grid() {
    local status=0
    rm -rf "$OUT/grid"; mkdir -p "$OUT/grid"
    for s in 2x2 4x4; do [[ -x "$OUT/build_grid_$s/simv" ]] || { echo "no $OUT/build_grid_$s/simv (PARTS=build)"; return 1; }; done
    while read -r label shape ba bw L mrows ncols dist seed flags expect; do
        [[ -n "$label" ]] || continue
        grid_case "$label" "$shape" "$ba" "$bw" "$L" "$mrows" "$ncols" "$dist" "$seed" "$flags" "$expect" &
        jobs_wait || status=1
    done <<< "$GRID_CASES"
    jobs_drain || status=1
    echo "abit grid matrix (2x2, 4x4): $(grep -c . <<< "$GRID_CASES") cases, status $([[ $status == 0 ]] && echo PASS || echo FAIL)"
    python3 - "$OUT/grid" <<'PY' || status=1
import json, sys
from pathlib import Path
rows, bad = [], 0
for d in sorted(Path(sys.argv[1]).iterdir()):
    c = d / "check.json"
    if not c.is_file():
        continue
    j = json.loads(c.read_text())
    if j["status"] != "PASS":
        continue
    ok = j["period_ok"] and j["measured_periods"] == [j["formula"]]
    bad += not ok
    rows.append((d.name, j["grid"], j["precision"], j["L"], j["blocks"], j["formula"], j["measured_periods"],
                 f"{j['data_utilization']:.1%}", "OK" if ok else "MISMATCH"))
print("grid block periods (passing runs): case grid precision L blocks "
      "formula(BA*BW*NB+(BA+BW-2)+(P_R+P_C-2)+8*P_C) measured data_utilization")
for r in rows:
    print("  " + " ".join(str(x) for x in r))
print(f"grid period rows: {len(rows)}, mismatches: {bad}")
sys.exit(0 if rows and not bad else 1)
PY
    return "$status"
}

#---------------------------------------------------------------- (regress) --
run_regress() {
    local status=0 p BASE="$OUT/baseline" full="build/cbsg/af_ipd/rtl_checks_summary.log"
    [[ -s "$BASE/int_hashes_before.txt" && -s "$BASE/switch_hashes_before.txt" ]] \
        || { echo "no baseline hashes in $BASE"; return 1; }
    [[ -s "$BASE/rtl_checks_summary_full_before.log" ]] || cp -p "$full" "$BASE/rtl_checks_summary_full_before.log"
    PARTS="int switch" bash sweeps/cbsg/af_ipd/run_rtl_checks.sh > "$OUT/regress_run_rtl_checks.out" 2>&1 || status=1
    cp -p "$full" "$BASE/rtl_checks_summary_int_switch_rerun.log"
    cp -p "$BASE/rtl_checks_summary_full_before.log" "$full"      # restore the full-run summary
    echo "existing runner, PARTS=\"int switch\" on the extended bench: $(tail -n 1 "$BASE/rtl_checks_summary_int_switch_rerun.log")"
    for p in int switch; do
        (builtin cd "build/cbsg/af_ipd/$p" && find . -type f \( -name bpt_trace.txt -o -name bpt_sched.txt -o -name check.json \) -print0 \
            | sort -z | xargs -0 sha256sum) > "$BASE/${p}_hashes_after.txt"
        if cmp -s "$BASE/${p}_hashes_before.txt" "$BASE/${p}_hashes_after.txt"; then
            echo "$p: $(wc -l < "$BASE/${p}_hashes_after.txt") trace / schedule / check files byte-identical to the run before the bench was extended"
        else
            echo "$p: FAIL (files differ from the baseline: diff $BASE/${p}_hashes_before.txt $BASE/${p}_hashes_after.txt)"; status=1
        fi
        cp -p "build/cbsg/af_ipd/${p}_summary.log" "$BASE/${p}_summary_after.log"
        if diff -q <(sort "$BASE/${p}_summary_before.log") <(sort "$BASE/${p}_summary_after.log") > /dev/null; then
            echo "$p summary: identical lines to the earlier run ($(wc -l < "$BASE/${p}_summary_after.log") lines)"
        else
            echo "$p summary: differs from the earlier run (diff $BASE/${p}_summary_before.log $BASE/${p}_summary_after.log)"
        fi
    done
    return "$status"
}

#----------------------------------------------------------------- driver --
status=0
for p in build single grid regress; do
    [[ " $PARTS " == *" $p "* ]] || continue
    if [[ "$p" == single ]] && [[ " $PARTS " == *" grid "* ]]; then
        { run_single > "$OUT/single_summary.log" 2>&1; } & sp=$!
        continue
    fi
    "run_$p" > "$OUT/${p}_summary.log" 2>&1 || status=1
    if [[ "$p" == grid && -n "${sp:-}" ]]; then wait "$sp" || status=1; sp=; fi
done
[[ -z "${sp:-}" ]] || { wait "$sp" || status=1; }
# The summary covers every part that has a summary log (this run's parts and earlier runs' others).
for p in build single grid regress; do
    [[ -s "$OUT/${p}_summary.log" ]] || continue
    if grep -Eq ': FAIL|status FAIL|compile FAILED' "$OUT/${p}_summary.log"; then status=1; fi
done
{
    echo "All-bits-in-time INT schedule on AF-IPD, RTL checks, $(date '+%F %T'); RTL designs/payn/variants/signed_segmented_csa_cbsg_af_ipd (unchanged)"
    for p in build single grid regress; do
        [[ -s "$OUT/${p}_summary.log" ]] || continue
        echo "== $p ($(date -r "$OUT/${p}_summary.log" '+%F %T'))"
        case $p in
            single|grid) grep -v '^  \|block periods\|period rows' "$OUT/${p}_summary.log" | sort
                         grep '^  \|block periods\|period rows' "$OUT/${p}_summary.log" || true ;;
            *) cat "$OUT/${p}_summary.log" ;;
        esac
    done
    echo "All-bits-in-time RTL checks: $([[ $status == 0 ]] && echo PASS || echo FAIL)"
} | tee "$OUT/abit_rtl_summary.log"
exit "$status"
