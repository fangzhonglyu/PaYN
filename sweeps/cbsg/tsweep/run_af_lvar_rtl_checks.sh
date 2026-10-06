#!/bin/bash
# RTL proof of the AF ladder-variant power bench (designs/payn/power/power_payn_array_cbsg_af_lvar.sv) and its checker
# (sweeps/cbsg/tsweep/check_af_power_trace_lvar.py), on the AF RTL (payn_array_signed_segmented_csa_cbsg_af, K8 M16 N8,
# 384 blocks -- the GL runs' workload size), before any GL run.  The RTL's [CBSG-AF-CONTRACT] monitor is live in every
# run (the bench stops on any contract error).
#
#   ladder      no new define: the bench must be power_payn_array_cbsg_af_vart.sv -- its trace must equal the AF
#               ladder GL traces (headline and sweep) byte for byte; checker PASS plain and with --ref-trace
#   hold8       CBSG_PWR_HOLD_C=8: checker --hold 8 --ref-trace PASS (same operands, same L, and the same drain as
#               the unheld ladder: the held cycles add zero); window 384 x 8 = 3,072
#   rowmax      CBSG_PWR_ROWMAX: checker --rowmax --ref-trace PASS (same operands, every row at its chunk's longest
#               L, block cycles as the ladder's); window 2,816
#   hold7       CBSG_PWR_HOLD_C=7 on the ladder must stop the bench (a chunk with a 128 row needs 8 cycles)
#   negative controls (each must FAIL the checker):
#     hold8_nohold      the hold8 trace checked without --hold (its cycles are not ceil(max L / 16))
#     hold8_c7          one hold8 block relabelled 7 cycles and the next 9 (window kept)
#     hold8_drain       one hold8 drain value +1
#     rowmax_ladderL    the rowmax trace with its ALEN lines replaced by the ladder's per-row L (schedule unchanged,
#                       so only the drained values can tell the two apart), checked as a plain ladder trace
#     rowmax_drain      one rowmax drain value +1
#
#   bash sweeps/cbsg/tsweep/run_af_lvar_rtl_checks.sh
# Outputs: build/power_char/cbsg_20261005/tsweep/af/ladder_variants/rtl_checks/ (summary.txt).
set -Eeuo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$REPO"
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export SYNOPSYS=${SYNOPSYS:-/usr/caen/synopsys-synth-2021.06-SP1}
export USE_DW=1 NTFY_CHNL= SNPSLMD_QUEUE=true PYTHONDONTWRITEBYTECODE=1
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
OUT=$REPO/build/power_char/cbsg_20261005/tsweep/af/ladder_variants/rtl_checks
TRN=array_streaming_cbsg_af_rtl.txt
AF_TRACE=$REPO/build/power_char/cbsg_20261005/af/pinned_fix/postfill/measure/gl_ladder/designs/payn/power/power_payn_array_cbsg_af.sv/$TRN
SW_TRACE=$REPO/build/power_char/cbsg_20261005/tsweep/af/ladder/gl/designs/payn/power/power_payn_array_cbsg_af_vart.sv/$TRN
TB=designs/payn/power/power_payn_array_cbsg_af_lvar.sv
CHK=sweeps/cbsg/tsweep/check_af_power_trace_lvar.py
DEF="+define+SC_BATCHES=384+define+CBSG_PWR_LADDER"
# As sweeps/cbsg/af/run_rtl_checks.sh (power part): -debug_access+pp for $set_gate_level_monitoring("rtl_on", "sv").
VCS_PP='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
mkdir -p "$OUT"
trap 'echo "FAILED at line $LINENO: $BASH_COMMAND" | tee -a "$OUT/summary.txt" >&2' ERR
: > "$OUT/summary.txt"
note() { echo "$*" | tee -a "$OUT/summary.txt"; }
[[ -s "$AF_TRACE" && -s "$SW_TRACE" ]]

rtl_sim() {   # name defines -> 0 if the bench passed
    local name=$1 defs=$2 b="$OUT/$1"
    rm -rf "$b"; mkdir -p "$b"
    make -C "$REPO" sim TOP=Top TB="$TB" BUILD_DIR="$b" GL= TARGET= RTL_PREFLIGHT_CMD= USE_DW=1 VCS_ARGS="$defs" \
        "VCS=$VCS_PP" NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" > "$b/simulation.log" 2>&1 || true
    grep -q '^PASS: streaming C-BSG AF SAIF captured' "$b/simulation.log" && \
        ! grep -qE 'Error-\[|\$fatal|TIMEOUT|X-FAIL|CBSG-AF-CONTRACT\] [1-9]' "$b/simulation.log"
}
pass_line() { grep -m1 '^PASS: streaming C-BSG AF' "$OUT/$1/simulation.log"; }
check() {     # name log-tag checker-args... -> 0 on [PASS]
    local name=$1 tag=$2; shift 2
    python3 "$CHK" "$@" --json "$OUT/$name/check_$tag.json" > "$OUT/$name/check_$tag.log" 2>&1
}
window_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["window_edges"])' "$1"; }

# ---- ladder: no new define == the vart bench ----
rtl_sim ladder "$DEF"
LT="$OUT/ladder/$TB/$TRN"
cmp -s "$LT" "$AF_TRACE" && cmp -s "$LT" "$SW_TRACE"
check ladder plain "$LT"
check ladder ref "$LT" --ref-trace "$AF_TRACE"
note "ladder: $(pass_line ladder | sed 's/ drain dumped.*//'); RTL trace == the AF ladder GL traces byte for byte (headline + sweep); $(head -n1 "$OUT/ladder/check_ref.log")"

# ---- hold8 ----
rtl_sim hold8 "$DEF+define+CBSG_PWR_HOLD_C=8"
HT="$OUT/hold8/$TB/$TRN"
check hold8 ref "$HT" --hold 8 --ref-trace "$AF_TRACE"
[[ "$(window_of "$OUT/hold8/check_ref.json")" == 3072 ]]
cmp -s <(grep '^DRAIN' "$HT") <(grep '^DRAIN' "$AF_TRACE")
note "hold8: $(pass_line hold8 | sed 's/ drain dumped.*//'); $(head -n1 "$OUT/hold8/check_ref.log"); drain identical to the unheld ladder's"

# ---- rowmax ----
rtl_sim rowmax "$DEF+define+CBSG_PWR_ROWMAX"
RT="$OUT/rowmax/$TB/$TRN"
check rowmax ref "$RT" --rowmax --ref-trace "$AF_TRACE"
[[ "$(window_of "$OUT/rowmax/check_ref.json")" == 2816 ]]
note "rowmax: $(pass_line rowmax | sed 's/ drain dumped.*//'); $(head -n1 "$OUT/rowmax/check_ref.log")"

# ---- hold7 must stop ----
if rtl_sim hold7 "$DEF+define+CBSG_PWR_HOLD_C=7"; then
    note "hold7 PASSED -- the bench does not reject a hold shorter than ceil(max L / 16)"; false
fi
grep -q 'CBSG_PWR_HOLD_C=7 is shorter than block' "$OUT/hold7/simulation.log"
note "hold7: stopped as required ($(grep -m1 -o 'CBSG_PWR_HOLD_C=7 is shorter than block [0-9]*.*' "$OUT/hold7/simulation.log"))"

# ---- negative controls ----
mut() {   # src dst mode [ref]
    python3 - "$@" <<'PY'
import sys
src, dst, mode = sys.argv[1:4]
L = open(src).read().splitlines()
if mode == 'c7':                 # block 40 -> 7 cycles, block 41 -> 9 (window unchanged)
    for i, l in enumerate(L):
        f = l.split()
        if f[:2] == ['BLOCK', '40']: f[2] = str(int(f[2]) - 1); L[i] = ' '.join(f)
        if f[:2] == ['BLOCK', '41']: f[2] = str(int(f[2]) + 1); L[i] = ' '.join(f)
elif mode == 'drain':
    i = next(i for i, l in enumerate(L) if l.startswith('DRAIN')); f = L[i].split(); f[1] = str(int(f[1]) + 1); L[i] = ' '.join(f)
elif mode == 'ladderL':          # the reference's per-row L in every ALEN line
    ref = [l for l in open(sys.argv[4]).read().splitlines() if l.startswith('ALEN')]
    k = 0
    for i, l in enumerate(L):
        if l.startswith('ALEN'): L[i] = ref[k]; k += 1
    assert k == len(ref)
open(dst, 'w').write('\n'.join(L) + '\n')
PY
}
neg() {   # name trace checker-args...
    local name=$1 tr=$2; shift 2
    mkdir -p "$OUT/neg"
    if python3 "$CHK" "$tr" "$@" > "$OUT/neg/$name.log" 2>&1; then
        note "NEGATIVE CONTROL $name PASSED the checker -- checker is not discriminating"; return 1
    fi
    note "neg_$name: FAIL as required ($(head -n2 "$OUT/neg/$name.log" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-160))"
}
mkdir -p "$OUT/neg"
neg hold8_nohold "$HT"
mut "$HT" "$OUT/neg/hold8_c7.txt" c7;            neg hold8_c7 "$OUT/neg/hold8_c7.txt" --hold 8
mut "$HT" "$OUT/neg/hold8_drain.txt" drain;      neg hold8_drain "$OUT/neg/hold8_drain.txt" --hold 8
mut "$RT" "$OUT/neg/rowmax_ladderL.txt" ladderL "$AF_TRACE"; neg rowmax_ladderL "$OUT/neg/rowmax_ladderL.txt"
mut "$RT" "$OUT/neg/rowmax_drain.txt" drain;     neg rowmax_drain "$OUT/neg/rowmax_drain.txt" --rowmax
note "ALL RTL CHECKS PASS"
