#!/bin/bash
# Full DRC-marker population of a routed checkpoint, read-only on the route (Innovus runs in OUT_DIR).
#   bash sweeps/cbsg/af/run_drc_population.sh ENC_DAT TOP OUT_DIR
# e.g. apr/build/TSMC22/PAYN_SC_CSA_CBSG_AF/cbsg_af_20261005_distguide_spp_pins/payn_array_signed_segmented_csa_cbsg_af.final.enc.dat
# Then: python3 sweeps/cbsg/af/drc_population.py OUT_DIR [...]
set -Eeuo pipefail
[[ $# -eq 3 ]] || { echo "Usage: $0 ENC_DAT TOP OUT_DIR" >&2; exit 2; }
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ENC=$(readlink -f "$1"); TOP=$2; OUTD=$3
[[ -d "$ENC" ]] || { echo "missing $ENC" >&2; exit 2; }
mkdir -p "$OUTD"; OUTD=$(readlink -f "$OUTD")
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
cd "$OUTD"
echo "enc=$ENC top=$TOP" > inputs.txt
ENC="$ENC" TOP="$TOP" innovus -batch -no_gui -files "$REPO/sweeps/cbsg/af/drc_population.tcl" > innovus_probe.log 2>&1
grep -q DRCPOP_DONE innovus_probe.log
grep -E '^DRCPOP_|Verification Complete' innovus_probe.log
