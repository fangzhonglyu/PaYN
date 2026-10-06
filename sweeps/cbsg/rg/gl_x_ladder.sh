#!/bin/bash
# Delay/X-model ladder for the C-BSG RG gate-level bench on a synthesis netlist (diagnosis helper for
# sweeps/cbsg/rg/run_syn_gl_checks.sh).  Compiles designs/payn/tb/test_payn_array_cbsg_rg.sv against the netlist
# in several configurations and plays one golden case in each:
#   ud_squash   NO_SDF, ARM_UD_MODEL + ARM_EN_X_SQUASH, unit delay, no timing checks (the accepted functional recipe)
#   ud_nosquash NO_SDF, ARM_UD_MODEL only (no X squash), unit delay, no timing checks
#   full_zero   NO_SDF, full library models (specify blocks), zero delay, no timing checks
#   full_nosdf  NO_SDF, full library models, specify-block delays, timing checks on, +neg_tchk
#   sdf_notc    max SDF, full models, +notimingcheck
#   sdf         max SDF, full models, +neg_tchk +sdfverbose (signoff configuration)
#   bash sweeps/cbsg/rg/gl_x_ladder.sh [CASE_DIR] [CONFIGS...]     (RUN env, default cbsg_rg_20261005)
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
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)} NTFY_CHNL= SNPSLMD_QUEUE=true
unset NETLIST_FILE SDC_FILE SDF_FILE VCS_ARGS
TARGET=TSMC22/PAYN_SC_CSA_CBSG_RG
RUN=${RUN:-cbsg_rg_20261005}
TB=designs/payn/tb/test_payn_array_cbsg_rg.sv
CASE=${1:-build/cbsg/golden/plain_u128}
shift || true
CONFIGS=${*:-"ud_squash ud_nosquash full_zero full_nosdf sdf_notc sdf"}
OUT=build/cbsg/rg/gl/$RUN/x_ladder
VCS_GL="vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -licwait 60 \$(VCS_ARGS) +incdir+\$(DESIGNS_DIR) -assert svaext"
one() {
    local cfg=$1 b="$OUT/$1" sdf=() args
    case "$cfg" in
        ud_squash)   args="+define+ARM_UD_MODEL+define+ARM_EN_X_SQUASH +delay_mode_unit +notimingcheck"; sdf=(NO_SDF=1) ;;
        ud_nosquash) args="+define+ARM_UD_MODEL +delay_mode_unit +notimingcheck"; sdf=(NO_SDF=1) ;;
        full_zero)   args="+delay_mode_zero +notimingcheck"; sdf=(NO_SDF=1) ;;
        full_nosdf)  args="+neg_tchk"; sdf=(NO_SDF=1) ;;
        sdf_notc)    args="+notimingcheck +sdfverbose"; sdf=(SDF_CORNER=max NO_SDF=) ;;
        sdf)         args="+neg_tchk +sdfverbose"; sdf=(SDF_CORNER=max NO_SDF=) ;;
        *) echo "unknown config $cfg"; return 1 ;;
    esac
    rm -rf "$b"; mkdir -p "$b"
    make sim GL=syn TARGET="$TARGET" RUN="$RUN" TB="$TB" BUILD_DIR="$REPO/$b" "${sdf[@]}" RTL_PREFLIGHT_CMD=true \
        "VCS=$VCS_GL" VCS_ARGS="$args" > "$b/compile.log" 2>&1
    (cd "$b" && "$REPO/$b/$TB/simv" +vcs+lic+wait +CASE="$REPO/$CASE" > sim.log 2>&1)
    echo "$cfg: $(grep -o 'CBSGRG_RESULT.*drain_total=[0-9]*' "$b/sim.log" || echo 'no result') | timing violations $(grep -c 'Timing violation' "$b/sim.log") | args: $args"
}
mkdir -p "$OUT"
for c in $CONFIGS; do one "$c" > "$OUT/$c.result" 2>&1 & done
wait
cat "$OUT"/*.result
