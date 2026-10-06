#!/bin/bash
# PE-level random checks of the sub-ring BP PE (tb_sr_pe_review.sv), RTL:
#   for LAP_G in 1 2 4 8: phase A SR PE vs the CSA PE (ring_in = 0, every tile, every
#   output, every cycle), phase B SR PE vs a bit-exact per-edge behavioural model with
#   random lap runs (exactly LAP_G edges or any length), reset on lap edges, range
#   limits, plus a full-lap check (every tile doubles after each LAP_G-edge lap).
#   LAP_G = 1 is the in-place-doubling model, LAP_G = 8 the BP ring's.
#   Mutant controls (must FAIL): the DUT built with a different LAP_G than the model.
# Post-synthesis lock step: PARTS=gl G=<2|4> runs the bench with the synthesized SR PE
# (csa_bp_sr<G>_20261004 netlist, unit delay, NO_SDF, ARM_UD_MODEL + ARM_EN_X_SQUASH)
# in lock step with the RTL PE.  NEEDS AFS (ARM cell Verilog); not part of the default PARTS.
#   bash sweeps/int_mode/bp/sr/run_bp_sr_pe_review.sh
# Logs: build/rtl_preflight/bp_sr/pe_review/
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
cd "$REPO"
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
PARTS=${PARTS:-"rtl mutants"}
OUT=build/rtl_preflight/bp_sr/pe_review
TB=sweeps/int_mode/bp/sr/tb_sr_pe_review.sv
mkdir -p "$OUT"
vcs_compile() {   # build_dir extra args...
    local b=$1; shift
    rm -rf "$b"; mkdir -p "$b"
    vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp +incdir+designs \
        -assert svaext -timescale=1ns/1ps "$@" -o "$b/simv" -Mdir="$b/obj" \
        -y "$SYNOPSYS/dw/sim_ver" +libext+.v+ +incdir+"$SYNOPSYS/dw/sim_ver" \
        -top TbSrPeReview > "$b/compile.log" 2>&1
}
status=0
if [[ " $PARTS " == *" rtl "* ]]; then
    for g in 1 2 4 8; do
        ( vcs_compile "$OUT/build_g$g" +define+PAYN_LAP_G=$g "$TB" || { echo "g$g: compile FAILED"; exit 1; }
          for s in 1 2 3; do
              (cd "$OUT/build_g$g" && ./simv +SEED=$s +ntb_random_seed=$s +NA=${NA:-40000} +NB=${NB:-160000} > "sim_seed$s.log" 2>&1)
              grep -h 'REVIEW' "$OUT/build_g$g/sim_seed$s.log" | sed "s/^/LAP_G=$g seed $s: /"
              grep -q 'REVIEW PASS' "$OUT/build_g$g/sim_seed$s.log" || exit 1
          done ) > "$OUT/rtl_g$g.log" 2>&1 &
    done
    wait
    for g in 1 2 4 8; do cat "$OUT/rtl_g$g.log"; grep -c 'REVIEW PASS' "$OUT/rtl_g$g.log" | grep -q '^3$' || status=1; done
fi
if [[ " $PARTS " == *" mutants "* ]]; then
    for pair in "2 1" "2 4" "4 2" "4 8"; do
        set -- $pair
        b="$OUT/mutant_model$1_dut$2"
        vcs_compile "$b" +define+PAYN_LAP_G=$1+define+REVIEW_DUT_G=$2 "$TB" || { echo "mutant $pair: compile FAILED"; status=1; continue; }
        (cd "$b" && ./simv +SEED=5 +ntb_random_seed=5 +NA=2000 +NB=20000 > sim.log 2>&1)
        if grep -q 'REVIEW FAIL' "$b/sim.log" && grep -q 'MISMATCH' "$b/sim.log"; then
            echo "mutant (model LAP_G=$1, DUT LAP_G=$2): caught ($(grep -m1 'MISMATCH' "$b/sim.log" | cut -c1-90))"
        else
            echo "mutant (model LAP_G=$1, DUT LAP_G=$2): NOT caught"; status=1
        fi
    done
fi
if [[ " $PARTS " == *" gl "* ]]; then
    G=${G:-2}
    NET=syn/build/TSMC22/PAYN_SC_CSA_BP_SR$G/csa_bp_sr${G}_20261004/payn_array_signed_segmented_csa_bp_sr.syn.v
    VLIB="/afs/eecs.umich.edu/kits/ARM/TSMC_22ULL/arm_2020q4/sc7mcpp140z_base_svt_c30/r3p0/verilog/sc7mcpp140z_cln22ul_base_svt_c30.v /afs/eecs.umich.edu/kits/ARM/TSMC_22ULL/arm_2020q4/sc7mcpp140z_hpk_svt_c30/r3p0/verilog/sc7mcpp140z_cln22ul_hpk_svt_c30.v"
    [[ -s $NET ]] || { echo "gl: missing netlist $NET"; exit 1; }
    # shellcheck disable=SC2086
    vcs_compile "$OUT/gl_build_g$G" +define+PAYN_LAP_G=$G+define+REVIEW_GL \
        +define+REVIEW_GL_MODULE=InnerPESignedSegmentedCsaBpSrFlat_K8_M16_N_H8_N_W8_OWIDTH24_LOW_W9_LAP_G$G \
        +define+ARM_UD_MODEL+define+ARM_EN_X_SQUASH +delay_mode_unit +notimingcheck $VLIB "$NET" "$TB" \
        || { echo "gl: compile FAILED ($OUT/gl_build_g$G/compile.log)"; status=1; }
    (cd "$OUT/gl_build_g$G" && ./simv +SEED=7 +ntb_random_seed=7 +NA=${GNA:-10000} +NB=${GNB:-40000} > sim.log 2>&1)
    grep -h 'REVIEW' "$OUT/gl_build_g$G/sim.log" | sed "s/^/gl LAP_G=$G: /"
    grep -q 'REVIEW PASS' "$OUT/gl_build_g$G/sim.log" || status=1
fi
echo "SR PE review: $([[ $status == 0 ]] && echo PASS || echo FAIL)"
exit $status
