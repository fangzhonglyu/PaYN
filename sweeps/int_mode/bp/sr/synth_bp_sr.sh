#!/bin/bash
# Synthesize the sub-ring variants (LAP_G = 2, 4) with the PAYN_SC_CSA_BP knobs, as the IPD run was invoked.
set -uo pipefail
REPO=/home/barrylyu/repos/PaYN
cd "$REPO"
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
g=${1:?usage: synth_bp_sr.sh <LAP_G: 2|4>}
# Opt-in overrides (defaults unchanged): SR_RUN_NAME=<run dir name>, SR_SYNTH_LOG=<make log path>.
# With SR_RUN_NAME set, an existing run directory of that name is never reused.
run=${SR_RUN_NAME:-csa_bp_sr${g}_20261004}
log=${SR_SYNTH_LOG:-build/rtl_preflight/bp_sr/synth_make_sr$g.log}
if [[ -n "${SR_RUN_NAME:-}" && -e "syn/build/TSMC22/PAYN_SC_CSA_BP_SR$g/$run" ]]; then
    echo "synth sr$g: syn/build/TSMC22/PAYN_SC_CSA_BP_SR$g/$run exists, refusing to overwrite" >&2; exit 3
fi
mkdir -p "$(dirname "$log")"
RUN_NAME=$run RTL_PREFLIGHT_CMD=true make synth TARGET=TSMC22/PAYN_SC_CSA_BP_SR$g NTFY_CHNL= \
    > "$log" 2>&1
echo "synth sr$g exit $?"
