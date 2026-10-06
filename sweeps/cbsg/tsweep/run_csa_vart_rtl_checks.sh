#!/bin/bash
# RTL proof of the variable-length CSA power bench (designs/payn/power/power_payn_array_csa_vart.sv) and its
# checker (sweeps/cbsg/tsweep/cosim_streaming_vart.py), on the accepted CSA RTL
# (payn_array_signed_segmented_csa, K8 M16 N8, LOW_W=9 -- the PAYN_SC_CSA synthesis defines), before any GL run.
#
#   orig_T128     the original bench power_payn_array.sv, T=128, 384 batches (the headline workload), checked by
#                 both cosim_streaming.py and cosim_streaming_vart.py (the copy agrees with the original checker)
#   repro_T128    the vart bench replaying orig_T128's operands with c_b = 8 (stimulus from orig_T128's trace):
#                 its trace must equal orig_T128's (same operands, same drain) apart from the header/BATCH/WINDOW
#                 lines -- i.e. loads and drain are the original bench's
#   ladder        the vart bench with the AF ladder run's exact operands and per-block cycles (stimulus from the
#                 AF pinned-postfill GL ladder trace): checker PASS, operands/cycles == the AF trace, window 2816
#   random_c2to8  96 blocks, c_b uniform in 2..8 (every block-boundary spacing the schedule allows): checker PASS
#   negative controls on the ladder trace: one block's cycle count +1 and the next one's -1 (window kept), one
#                 AMAG changed by 64 logical units, one drain value +1 -- each must FAIL the cycle reference alone
#
#   bash sweeps/cbsg/tsweep/run_csa_vart_rtl_checks.sh
# Outputs: build/power_char/cbsg_20261005/tsweep/csa/rtl_checks/ (summary.txt).
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
OUT=$REPO/build/power_char/cbsg_20261005/tsweep/csa/rtl_checks
STIM=$REPO/build/power_char/cbsg_20261005/tsweep/csa/stim
AF_TRACE=$REPO/build/power_char/cbsg_20261005/af/pinned_fix/postfill/measure/gl_ladder/designs/payn/power/power_payn_array_cbsg_af.sv/array_streaming_cbsg_af_rtl.txt
SRC=designs/payn/variants/signed_segmented_csa/payn_array_signed_segmented_csa.sv
VTB=designs/payn/power/power_payn_array_csa_vart.sv
OTB=designs/payn/power/power_payn_array.sv
CHK=sweeps/cbsg/tsweep/cosim_streaming_vart.py
DEF="+define+PAYN_ARRAY_EXTERNAL_RTL+define+PAYN_ARRAY_DUT=payn_array_signed_segmented_csa+define+PAYN_SEG_LOW_W=9+define+SC_K=8+define+SC_M=16+define+SC_NH=8+define+SC_NW=8+define+SC_OWIDTH=24"
# RTL needs -debug_access+pp for $set_gate_level_monitoring("rtl_on", "sv") (as sweeps/run_csa_bp_rtl_checks.sh).
VCS_CMD='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
mkdir -p "$OUT" "$STIM"
trap 'echo "FAILED at line $LINENO: $BASH_COMMAND" | tee -a "$OUT/summary.txt" >&2' ERR
: > "$OUT/summary.txt"
note() { echo "$*" | tee -a "$OUT/summary.txt"; }

rtl_sim() {   # name tb defines [stim]
    local name=$1 tb=$2 defs=$3 stim=${4:-} b="$OUT/$1"
    rm -rf "$b"; mkdir -p "$b/$tb"
    [[ -z "$stim" ]] || cp "$stim" "$b/$tb/csa_vart_stim.txt"
    make -C "$REPO" sim TOP=Top BUILD_DIR="$b" TB="$tb" USE_DW=1 SIM_SRCS="$SRC" VCS_ARGS="$defs" \
        "VCS=$VCS_CMD" NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" > "$b/simulation.log" 2>&1
    grep -q '^PASS: streaming SC' "$b/simulation.log"
    ! grep -qE 'Error-\[|\$fatal|TIMEOUT|X-FAIL' "$b/simulation.log"
}

# ---- orig_T128: the original bench and checker ----
rtl_sim orig_T128 "$OTB" "$DEF+define+SC_T=128+define+SC_BATCHES=384"
OT="$OUT/orig_T128/$OTB/array_streaming_rtl.txt"
python3 designs/payn/cosim/cosim_streaming.py "$OT" > "$OUT/orig_T128/cosim.log" 2>&1
python3 "$CHK" "$OT" --json "$OUT/orig_T128/vart_check.json" > "$OUT/orig_T128/vart_check.log" 2>&1
note "orig_T128: $(cat "$OUT/orig_T128/cosim.log") | vart checker: $(head -n1 "$OUT/orig_T128/vart_check.log")"
GLT=$REPO/build/power_char/pinned_pass2_20261004/csa/gl_final/$OTB/array_streaming_rtl.txt
if cmp -s "$OT" "$GLT"; then note "orig_T128: RTL trace == headline GL trace byte for byte ($GLT)"
else note "orig_T128: RTL trace differs from the headline GL trace (operands: $(diff <(grep -v DRAIN "$OT") <(grep -v DRAIN "$GLT") >/dev/null && echo same || echo DIFFERENT))"; fi

# ---- repro_T128: vart bench replaying orig_T128's operands, c = 8 ----
python3 sweeps/cbsg/tsweep/make_csa_vart_stim.py --from-csa "$OT" --out "$STIM/repro_T128_from_rtl.stim.txt" \
    --json "$STIM/repro_T128_from_rtl.json" > /dev/null
rtl_sim repro_T128 "$VTB" "$DEF+define+SC_BATCHES=384" "$STIM/repro_T128_from_rtl.stim.txt"
RT="$OUT/repro_T128/$VTB/array_streaming_csa_vart_rtl.txt"
python3 "$CHK" "$RT" --stim "$STIM/repro_T128_from_rtl.stim.txt" --json "$OUT/repro_T128/vart_check.json" \
    > "$OUT/repro_T128/vart_check.log" 2>&1
grep -q '\[PASS\]' "$OUT/repro_T128/vart_check.log"
# Same operands and the same drain as the original bench: strip the format-only lines and compare.
diff <(grep -vE '^(STREAMCFG|BATCH)' "$OT") <(grep -vE '^(STREAMCFGV|BATCH|WINDOW)' "$RT") > "$OUT/repro_T128/trace_vs_orig.diff"
note "repro_T128: $(head -n1 "$OUT/repro_T128/vart_check.log"); operands + drain identical to orig_T128 (diff empty)"

# ---- ladder: the AF ladder run's operands and per-block cycles ----
python3 sweeps/cbsg/tsweep/make_csa_vart_stim.py --from-af "$AF_TRACE" --out "$STIM/ladder_from_af.stim.txt" \
    --json "$STIM/ladder_from_af.json" > /dev/null
rtl_sim ladder "$VTB" "$DEF+define+SC_BATCHES=384" "$STIM/ladder_from_af.stim.txt"
LT="$OUT/ladder/$VTB/array_streaming_csa_vart_rtl.txt"
python3 "$CHK" "$LT" --stim "$STIM/ladder_from_af.stim.txt" --af-trace "$AF_TRACE" \
    --json "$OUT/ladder/vart_check.json" > "$OUT/ladder/vart_check.log" 2>&1
grep -q '\[PASS\]' "$OUT/ladder/vart_check.log"
python3 - "$OUT/ladder/vart_check.json" <<'PY'
import json,sys; j=json.load(open(sys.argv[1])); assert j['window_clocks']==2816==j['af_window'] and j['blocks']==384, j
PY
note "ladder: $(head -n1 "$OUT/ladder/vart_check.log"); window $(grep -o 'window=[0-9]*' "$OUT/ladder/vart_check.log")"

# ---- random_c2to8 ----
python3 sweeps/cbsg/tsweep/make_csa_vart_stim.py --random 96 --seed 7 --cmin 2 --cmax 8 \
    --out "$STIM/random_c2to8.stim.txt" --json "$STIM/random_c2to8.json" > /dev/null
rtl_sim random_c2to8 "$VTB" "$DEF+define+SC_BATCHES=96" "$STIM/random_c2to8.stim.txt"
XT="$OUT/random_c2to8/$VTB/array_streaming_csa_vart_rtl.txt"
python3 "$CHK" "$XT" --stim "$STIM/random_c2to8.stim.txt" --json "$OUT/random_c2to8/vart_check.json" \
    > "$OUT/random_c2to8/vart_check.log" 2>&1
grep -q '\[PASS\]' "$OUT/random_c2to8/vart_check.log"
note "random_c2to8: $(head -n1 "$OUT/random_c2to8/vart_check.log") ; histogram $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cycle_histogram"])' "$OUT/random_c2to8/vart_check.json")"

# ---- negative controls (each must FAIL) ----
neg() {   # name python-edit
    local f="$OUT/neg_$1.txt"
    python3 - "$LT" "$f" "$2" <<'PY'
import sys
src,dst,mode=sys.argv[1:]
L=open(src).read().splitlines()
if mode=='cycles':      # block 20 +1 cycle, block 21 -1 cycle: window unchanged, operands unchanged
    for i,l in enumerate(L):
        f=l.split()
        if f[:2]==['BATCH','20']: L[i]=f'BATCH 20 {int(f[2])+1}'
        if f[:2]==['BATCH','21']: L[i]=f'BATCH 21 {int(f[2])-1}'
elif mode=='amag':
    i=next(i for i,l in enumerate(L) if l.startswith('AMAG')); f=L[i].split(); f[5]=str((int(f[5])+128)%256); L[i]=' '.join(f)
elif mode=='drain':
    i=next(i for i,l in enumerate(L) if l.startswith('DRAIN')); f=L[i].split(); f[1]=str(int(f[1])+1); L[i]=' '.join(f)
open(dst,'w').write('\n'.join(L)+'\n')
PY
    # Without the provenance options: the cycle reference alone must reject each edit.
    if python3 "$CHK" "$f" > "$OUT/neg_$1.log" 2>&1; then
        note "NEGATIVE CONTROL $1 PASSED the checker -- checker is not discriminating"; return 1
    fi
    note "neg_$1: FAIL as required ($(sed -n 2p "$OUT/neg_$1.log" | sed 's/^ *//'))"
}
neg cycles cycles
neg amag amag
neg drain drain
note "ALL RTL CHECKS PASS"
