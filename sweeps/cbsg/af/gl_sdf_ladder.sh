#!/bin/bash
# Delay-mode ladder for the C-BSG AF synthesized netlist on one golden case (default plain_u128), to locate the
# step at which a gate-level run first breaks (memory: zero -> unit -> max-SDF without timing checks -> max-SDF):
#   zero      NO_SDF, +delay_mode_zero +notimingcheck, full library models
#   unit      NO_SDF, +delay_mode_unit, timing checks ON, full library models (race exposure only)
#   sdf_notc  raw synthesis SDF, max corner, +neg_tchk +notimingcheck
#   sdf       raw synthesis SDF, max corner, +neg_tchk +sdfverbose (timing checks ON)
#   ideal_notc ideal-clock view of the synthesis SDF (sweeps/cbsg/af/sdf_ideal_clock.py: ICG CK->ECK IOPATHs = 0,
#             the clock model DC timed with), max corner, +neg_tchk +notimingcheck
#   ideal     the ideal-clock view, max corner, +neg_tchk +sdfverbose
# Each step compiles the functional bench on the netlist; its compile run plays the case with the load on the first
# edge after reset (settle 0), then the case is played again with +RESET_SETTLE=2 (two idle edges after reset).
#   bash sweeps/cbsg/af/gl_sdf_ladder.sh [CASE]      # RUN=cbsg_af_20261005
# Output: build/cbsg/af/gl/<RUN>/ladder/<step>/compile.log, summary ladder/ladder_summary.log
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$REPO"
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
export NTFY_CHNL= PYTHONDONTWRITEBYTECODE=1 SNPSLMD_QUEUE=true
unset NETLIST_FILE SDC_FILE SDF_FILE VCS_ARGS
TARGET=TSMC22/PAYN_SC_CSA_CBSG_AF
RUN=${RUN:-cbsg_af_20261005}
TOP=payn_array_signed_segmented_csa_cbsg_af
SYN=syn/build/$TARGET/$RUN
CASE=${1:-plain_u128}
OUT=build/cbsg/af/gl/$RUN/ladder
TB=designs/payn/tb/test_payn_array_cbsg_af.sv
VCS_GL="vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -licwait 60 \$(VCS_ARGS) +incdir+\$(DESIGNS_DIR) -assert svaext"
CDIR=build/cbsg/golden/$CASE
[[ -d "$CDIR" ]] || CDIR=build/cbsg/af/golden_extra/$CASE
[[ -d "$CDIR" ]] || { echo "unknown case $CASE" >&2; exit 2; }
rm -rf "$OUT"; mkdir -p "$OUT"
IDEAL=$OUT/idealclk_view
mkdir -p "$IDEAL/$TARGET/$RUN"
ln -s "$REPO/$SYN/$TOP.syn.v" "$IDEAL/$TARGET/$RUN/$TOP.syn.v"
python3 sweeps/cbsg/af/sdf_ideal_clock.py "$SYN/$TOP.syn.sdf" "$IDEAL/$TARGET/$RUN/$TOP.syn.sdf" \
    --report "$OUT/idealclk_report.txt" > /dev/null

step() {   # name make-args...
    local name=$1; shift
    local b="$OUT/$name"
    mkdir -p "$b/$TB"
    echo "$REPO/$CDIR" > "$b/$TB/cbsg_cases.txt"
    make sim GL=syn TARGET="$TARGET" RUN="$RUN" TB="$TB" BUILD_DIR="$REPO/$b" RTL_PREFLIGHT_CMD=true \
        "VCS=$VCS_GL" "$@" > "$b/compile.log" 2>&1
    (cd "$b/$TB" && ./simv +CASES="$REPO/$CDIR" +RESET_SETTLE=2 > settle2.log 2>&1)
    local lg res tv x tag
    for lg in "$b/compile.log" "$b/$TB/settle2.log"; do
        res=$(grep -m1 '^RESULT' "$lg" | grep -oE 'drain values [0-9]+ bad [0-9]+')
        tv=$(grep -c 'Timing violation in' "$lg")
        x=$(grep -c '^\[CHECK\].*: X,' "$lg")
        tag="settle 0"; [[ "$lg" == *settle2.log ]] && tag="settle 2"
        printf "%-10s %-8s %-4s %s; timing violations %s; X drains among the first printed %s; SDF warnings %s\n" "$name" \
            "$tag" "$(grep -q '^PASS: CBSG AF bench' "$lg" && echo PASS || echo FAIL)" "${res:-no RESULT}" "$tv" "$x" \
            "$(grep -oE 'Warning-\[SDF[A-Z_]+\]' "$lg" | sort | uniq -c | tr -s ' \n' ' ')"
    done
}

{
    echo "C-BSG AF GL delay-mode ladder, case $CASE, $SYN ($(date -Iseconds))"
    head -n 4 "$OUT/idealclk_report.txt"
    step zero     NO_SDF=1 VCS_ARGS="+delay_mode_zero +notimingcheck" &
    step unit     NO_SDF=1 VCS_ARGS="+delay_mode_unit" &
    step sdf_notc SDF_CORNER=max NO_SDF= VCS_ARGS="+neg_tchk +notimingcheck" &
    step sdf      SDF_CORNER=max NO_SDF= VCS_ARGS="+neg_tchk +sdfverbose" &
    step ideal_notc SDF_CORNER=max NO_SDF= SYN_DIR="$REPO/$IDEAL" VCS_ARGS="+neg_tchk +notimingcheck" &
    step ideal    SDF_CORNER=max NO_SDF= SYN_DIR="$REPO/$IDEAL" VCS_ARGS="+neg_tchk +sdfverbose" &
    wait
} 2>&1 | tee "$OUT/ladder_summary.log"
