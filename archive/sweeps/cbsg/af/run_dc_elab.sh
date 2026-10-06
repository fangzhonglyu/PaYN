#!/bin/bash
# DC synthesizability preflight for TSMC22/PAYN_SC_CSA_CBSG_AF (elaborate + check_design of the
# top, and a standalone compile of one kA encoder).  Not a synthesis run: synthesize with
#   RUN_NAME=<name> RTL_PREFLIGHT_CMD=true make synth TARGET=TSMC22/PAYN_SC_CSA_CBSG_AF NTFY_CHNL=
# Log: build/cbsg/af/dc_elab/dc_elab.log (CBSG_ELAB lines).
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
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
export DESIGN_ROOT=$REPO
# shellcheck disable=SC1091
source syn/targets/TSMC22/PAYN_SC_CSA_CBSG_AF
W=build/cbsg/af/dc_elab
rm -rf "$W"; mkdir -p "$W"
(cd "$W" && dc_shell -f "$REPO/sweeps/cbsg/af/dc_elab_check.tcl" > dc_elab.log 2>&1) || true
grep '^CBSG_ELAB' "$W/dc_elab.log"
grep -q '^CBSG_ELAB PASS' "$W/dc_elab.log"
