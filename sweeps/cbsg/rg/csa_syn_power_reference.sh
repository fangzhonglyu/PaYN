#!/bin/bash
# Same-conditions reference for the RG GL power smoke (sweeps/cbsg/rg/run_syn_gl_checks.sh part "power"): the CSA
# baseline's synthesized netlist (TSMC22/PAYN_SC_CSA csa_20261002) with its ideal-clock synthesis SDF, the baseline
# power bench designs/payn/power/power_payn_array.sv (uniform 7-bit magnitudes, random signs, T = 128, M = 16),
# the APR phase's VCS flags (+neg_tchk +sdfverbose, max corner), SC_BATCHES blocks, then PrimeTime PX on the
# synthesized netlist without SPEF (sweeps/cbsg/rg/pt_syn_power_smoke.tcl).  Orientation only: zero wire load,
# no clock tree, short window -- the ratio RG/CSA under identical conditions, not an energy result.
#   bash sweeps/cbsg/rg/csa_syn_power_reference.sh        # SC_BATCHES=24 -> build/cbsg/rg/gl/csa_reference/
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$REPO"
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)} NTFY_CHNL= SNPSLMD_QUEUE=true PYTHONDONTWRITEBYTECODE=1
unset NETLIST_FILE SDC_FILE SDF_FILE VCS_ARGS
TARGET=TSMC22/PAYN_SC_CSA
RUN=${RUN:-csa_20261002}
TOP=payn_array_signed_segmented_csa
SYN=syn/build/$TARGET/$RUN
B=${SC_BATCHES:-24}
OUT=build/cbsg/rg/gl/csa_reference
TB=designs/payn/power/power_payn_array.sv
IDEAL=$OUT/idealclk_view
rm -rf "$OUT"; mkdir -p "$IDEAL/$TARGET/$RUN"
ln -s "$REPO/$SYN/$TOP.syn.v" "$IDEAL/$TARGET/$RUN/$TOP.syn.v"
python3 sweeps/cbsg/rg/sdf_ideal_clock.py "$SYN/$TOP.syn.sdf" "$IDEAL/$TARGET/$RUN/$TOP.syn.sdf" > "$OUT/idealclk_report.txt"
VCS_GL="vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -licwait 60 \$(VCS_ARGS) +incdir+\$(DESIGNS_DIR) -assert svaext"
make sim GL=syn TARGET="$TARGET" RUN="$RUN" TB="$TB" BUILD_DIR="$REPO/$OUT/sim" SDF_CORNER=max NO_SDF= \
    SYN_DIR="$REPO/$IDEAL" RTL_PREFLIGHT_CMD=true USE_DW=1 "VCS=$VCS_GL" \
    VCS_ARGS="+define+PAYN_ARRAY_DUT=$TOP+define+SC_K=8+define+SC_M=16+define+SC_NH=8+define+SC_NW=8+define+SC_OWIDTH=24+define+SC_T=128+define+SC_BATCHES=$B +neg_tchk +sdfverbose" \
    > "$OUT/simulation.log" 2>&1
python3 designs/payn/cosim/cosim_streaming.py "$OUT/sim/$TB/array_streaming_rtl.txt" > "$OUT/cosim.log" 2>&1
python3 sweeps/validate_sc_power_saif.py "$OUT/sim/$TB/dut.saif" --expected-period-ns 2.5 > "$OUT/saif_validation.log" 2>&1
mkdir -p "$OUT/pt"
(set -a; . "$SYN/TARGET_DEF"; set +a
 cd "$OUT/pt" && RG_SYN_DIR="$REPO/$SYN" SAIF_FILE="$REPO/$OUT/sim/$TB/dut.saif" SAIF_STRIP_PATH=Top/dut \
    pt_shell -file "$REPO/sweeps/cbsg/rg/pt_syn_power_smoke.tcl" > power_pt.log 2>&1)
echo "CSA reference: $(grep -o 'PASS: streaming SC SAIF captured.*' "$OUT/simulation.log" | head -1)"
echo "  cosim: $(tail -n 1 "$OUT/cosim.log")"
echo "  SAIF: $(tail -n 1 "$OUT/saif_validation.log" | cut -c1-160)"
echo "  timing violations in log: $(grep -c 'Timing violation' "$OUT/simulation.log")"
echo "  PT total power: $(grep -o 'Total Power *= *[0-9.e+-]*' "$OUT/pt/reports/power.rpt")"
