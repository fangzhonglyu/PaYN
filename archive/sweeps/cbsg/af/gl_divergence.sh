#!/bin/bash
# Edge-by-edge divergence between two gate-level delay modes of the C-BSG AF netlist on one case, using the
# probe sweeps/cbsg/af/gl_probe.sv (hierarchy-port samples at every negedge).  Diagnosis helper.
#   bash sweeps/cbsg/af/gl_divergence.sh [CASE]          # RUN=cbsg_af_20261005; modes zero vs ideal SDF
# Output: build/cbsg/af/gl/<RUN>/divergence/{zero,ideal}/.../gl_probe.txt and the first differing lines.
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
TARGET=TSMC22/PAYN_SC_CSA_CBSG_AF
RUN=${RUN:-cbsg_af_20261005}
TOP=payn_array_signed_segmented_csa_cbsg_af
SYN=syn/build/$TARGET/$RUN
CASE=${1:-plain_u128}
OUT=build/cbsg/af/gl/$RUN/divergence
TB=designs/payn/tb/test_payn_array_cbsg_af.sv
PROBE=$REPO/sweeps/cbsg/af/gl_probe.sv
VCS_GL="vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -licwait 60 \$(VCS_ARGS) +incdir+\$(DESIGNS_DIR) -assert svaext"
CDIR=build/cbsg/golden/$CASE
[[ -d "$CDIR" ]] || CDIR=build/cbsg/af/golden_extra/$CASE
rm -rf "$OUT"; mkdir -p "$OUT"
IDEAL=$OUT/idealclk_view
mkdir -p "$IDEAL/$TARGET/$RUN"
ln -s "$REPO/$SYN/$TOP.syn.v" "$IDEAL/$TARGET/$RUN/$TOP.syn.v"
python3 sweeps/cbsg/af/sdf_ideal_clock.py "$SYN/$TOP.syn.sdf" "$IDEAL/$TARGET/$RUN/$TOP.syn.sdf" > /dev/null
mode() {
    local name=$1; shift
    local b="$OUT/$name"
    mkdir -p "$b/$TB"
    echo "$REPO/$CDIR" > "$b/$TB/cbsg_cases.txt"
    make sim GL=syn TARGET="$TARGET" RUN="$RUN" TB="$TB" BUILD_DIR="$REPO/$b" RTL_PREFLIGHT_CMD=true \
        "VCS=$VCS_GL" "$@" > "$b/compile.log" 2>&1
    echo "$name: $(grep -m1 '^RESULT' "$b/compile.log" | grep -oE 'drain values [0-9]+ bad [0-9]+')"
}
mode zero  NO_SDF=1 VCS_ARGS="+delay_mode_zero +notimingcheck $PROBE -top GlProbe" &
mode ideal SDF_CORNER=max NO_SDF= SYN_DIR="$REPO/$IDEAL" VCS_ARGS="+neg_tchk +notimingcheck $PROBE -top GlProbe" &
wait
diff "$OUT/zero/$TB/gl_probe.txt" "$OUT/ideal/$TB/gl_probe.txt" | head -n 40 | cut -c1-240
