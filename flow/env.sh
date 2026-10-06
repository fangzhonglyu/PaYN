# Tool environment of the PaYN flow: source it (never execute it) before any make synth / apr / sim / power_apr.
# The Python entry points (route.py, measure.py, regress.py GL mode) source it for every tool command they run;
# flow/bos.sh sources it at the top.
#   source flow/env.sh
#
# Pins exactly the EDA versions every qualified PaYN result was produced with, points ASTRAEA_FLOW at the flow
# engine and SYNOPSYS at the DesignWare simulation library, and sets the APR / gate-level environment of the
# qualified routes (PaYN targets: 70 % utilization, 400 MHz, 1.25 ns input delay, 0.125 ns clock uncertainty,
# TSMC22 sc7mcpp140z SVT C30 + HPK, no APR power or multibit optimization).  Stage-specific knobs (guides,
# pre-place script, workload power optimization) are set by the stage that needs them, never here.

FLOW_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export FLOW_REPO

source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000

export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$FLOW_REPO/../ASTRAEA" && pwd)}
export SYNOPSYS=${SYNOPSYS:-/usr/caen/synopsys-synth-2021.06-SP1}

# APR / GL environment of the qualified PaYN routes.
export ZERO_PINLESS_NET_ACTIVITY=1
export USE_DW=1 NTFY_CHNL=
export TSMC22_CELL_TIER=sc7mcpp140z TSMC22_LIB_FLAVORS=svt_c30
export TSMC22_HPK_FLAVORS=svt_c30 TSMC22_HPK=1
export CORE_UTIL=0.70 CORE_ASPECT=1.000 PERIOD=2.5 INPUT_DELAY=1.25 OUTPUT_DELAY=0.05
export CLOCK_UNCERTAINTY=0.125 SC_PLACE_GUIDES=0 SC_NH=8 SC_NW=8
export APR_OPT_POWER=0 APR_MULTIBIT_FLOP_OPT=0 APR_LEAN_OPT=0
unset NETLIST_FILE SDC_FILE SDF_FILE PRE_PLACE_SCRIPT POST_LOAD_SCRIPT PRE_REPORT_SCRIPT POST_SCRIPT
unset APR_ACTIVITY_FILE APR_ACTIVITY_SCOPE APR_POWER_ANALYSIS_VIEW
unset APR_WORKLOAD_POWER_OPT APR_LEAKAGE_TO_DYNAMIC_RATIO APR_DETAIL_WIRE_LENGTH_OPT_EFFORT
unset APR_RESUME_FINAL SKIP_FILLER FORCE_STRONG_FINAL_DRC SKIP_FINAL_HOLD_OPT FORCE_FINAL_HOLD_OPT
unset SC_DISTRIBUTION_GUIDES SC_DIST_HIER_PREFIX SC_TILE_HIER_PREFIX NO_SDF VCS_ARGS SYN_DEFINES PAYN_TOP
unset SC_PIN_SPAN SC_PIN_LAYERS_H SC_PIN_LAYERS_V SC_PIN_TRACK_UM SC_PIN_MIN_PITCH_TRACKS
unset SC_PIN_SOUTH_CTRL_STEP_UM SC_PIN_PLAN_FILE SC_DIST_GUIDE_BAND SC_DIST_GUIDE_MARGIN SC_DIST_GUIDE_DENSITY

# Wait for Synopsys licenses instead of failing; never write Python bytecode into the repo.
export SNPSLMD_QUEUE=true PYTHONDONTWRITEBYTECODE=1

# VCS command for gate-level `make sim` (passed as VCS=...): the ASTRAEA default minus -debug_access.
export FLOW_VCS='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -licwait 60 $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
