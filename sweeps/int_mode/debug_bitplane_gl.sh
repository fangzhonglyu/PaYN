#!/bin/bash
# One RTL + routed-GL run of the bit-plane INT bench, no PT-PX, for debugging.
#   bash sweeps/int_mode/debug_bitplane_gl.sh NAME BA BW L MROWS NCOLS DIST MODE [extra VCS args...]
# e.g. bash sweeps/int_mode/debug_bitplane_gl.sh small 8 8 256 1 16 uniform 2 +define+INTB_VCD
# Output: build/power_char/int_mode_energy_20261003/bitplane/debug/NAME/{rtl,gl}
# Same environment, netlist, SDF and VCS options as run_bitplane_energy.sh.
set -Eeuo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$REPO"
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export SYNOPSYS=${SYNOPSYS:-/usr/caen/synopsys-synth-2021.06-SP1}
export USE_DW=1 NTFY_CHNL=
export TSMC22_CELL_TIER=sc7mcpp140z TSMC22_LIB_FLAVORS=svt_c30
export TSMC22_HPK_FLAVORS=svt_c30 TSMC22_HPK=1
export PERIOD=2.5
unset NETLIST_FILE SDC_FILE SDF_FILE NO_SDF VCS_ARGS
TB=designs/payn/power/power_payn_array_int_bitplane.sv
VCS_CMD='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
OUT=$REPO/build/power_char/int_mode_energy_20261003/bitplane
SNAP=$OUT/rtl_snapshot_81881b0
name=$1 BA=$2 BW=$3 L=$4 MR=$5 NC=$6 DIST=$7 MODE=$8; shift 8
EXTRA="$*"
D=$OUT/debug/$name
rm -rf "$D"; mkdir -p "$D/rtl/$TB" "$D/gl/$TB"
python3 sweeps/int_mode/gen_bitplane_workload.py --ba "$BA" --bw "$BW" --L "$L" --mrows "$MR" \
    --ncols "$NC" --dist "$DIST" --seed 11 --out-dir "$D/rtl/$TB" > /dev/null
cp "$D/rtl/$TB"/intb_*.hex "$D/gl/$TB/"
defs="+define+INTB_BA=$BA +define+INTB_BW=$BW +define+INTB_L=$L +define+INTB_MROWS=$MR +define+INTB_NCOLS=$NC +define+INTB_SAIF_MODE=$MODE"
make sim TOP=Top BUILD_DIR="$D/rtl" TB="$TB" USE_DW=1 VCS_ARGS="+incdir+$SNAP $defs $EXTRA" \
    > "$D/rtl/simulation.log" 2>&1 || true
python3 sweeps/int_mode/check_bitplane_drain.py "$D/rtl/$TB" > "$D/rtl/check.log" 2>&1 || true
echo "RTL: $(tail -n 1 "$D/rtl/check.log")"
make sim GL=apr TARGET=TSMC22/PAYN_SC_CSA RUN=csa_20261002_distguide_spp_fixed TB="$TB" \
    BUILD_DIR="$D/gl" SDF_CORNER=max NO_SDF= RTL_PREFLIGHT_CMD=true \
    VCS_ARGS="+define+PAYN_ARRAY_DUT=payn_array_signed_segmented_csa $defs $EXTRA +neg_tchk +sdfverbose" \
    "VCS=$VCS_CMD" > "$D/gl/simulation.log" 2>&1 || true
python3 sweeps/int_mode/check_bitplane_drain.py "$D/gl/$TB" > "$D/gl/check.log" 2>&1 || true
echo "GL:  $(tail -n 1 "$D/gl/check.log")"
python3 sweeps/validate_routed_gl.py "$D/gl/simulation.log" \
    --expected-pass "PASS: INT bit-plane SAIF captured" \
    --approve-negative-iopath-clamp-ps 10 > "$D/gl/timing_validation.log" 2>&1 || true
echo "GL timing: $(grep -m1 '"status"' "$D/gl/timing_validation.log"), $(grep -c 'Timing violation' "$D/gl/simulation.log") violation reports"
