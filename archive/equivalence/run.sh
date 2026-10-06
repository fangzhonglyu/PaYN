#!/bin/bash
# Formality proof that the cleaned PaYN RTL (designs/payn/rtl) equals the
# qualified AF-IPD variant it replaced (archived under archive/designs/...):
# the single-PE top and the PE-grid wrapper, at K8/M16 (the old RTL's only
# shape; the cleaned RTL also has K16/M8).
#   bash archive/equivalence/run.sh     -> build/cleanup/equiv/{array,grid}.log
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-synth/2021.06-SP1
# The site module file for formality/2021.06-SP1 points at a nonexistent 2031.06 path.
export PATH=/usr/caen/formality-2021.06-SP1/bin:$PATH
export DW_ROOT=/usr/caen/synopsys-synth-2021.06-SP1
export DESIGNS=$REPO/designs
OLD=${OLD_VARIANT_DIR:-$REPO/archive/designs/payn/variants/signed_segmented_csa_cbsg_af_ipd}
OUT=$REPO/build/cleanup/equiv
mkdir -p "$OUT" && cd "$OUT"
status=0
check() {   # name ref_sv ref_top impl_sv impl_top [impl_params]
    REF_SV=$2 REF_TOP=$3 IMPL_SV=$4 IMPL_TOP=$5 IMPL_PARAMS=${6:-} \
        fm_shell -f "$REPO/archive/equivalence/fm_equiv.tcl" > "$1.log" 2>&1
    if grep -q "^EQUIVALENCE_RESULT $5 SUCCEEDED" "$1.log"; then echo "PASS $1"; else echo "FAIL $1 ($OUT/$1.log)"; status=1; fi
}
check array "$OLD/payn_array_signed_segmented_csa_cbsg_af_ipd.sv" payn_array_signed_segmented_csa_cbsg_af_ipd \
      "$DESIGNS/payn/rtl/payn_array.sv" payn_array
check grid "$OLD/inner_pe_grid_signed_segmented_csa_cbsg_af_ipd.sv" InnerPESignedSegmentedCsaBpIpdGridAfIpd \
      "$DESIGNS/payn/rtl/payn_pe_grid.sv" PaynPeGrid "K = 8, M = 16"
exit $status
