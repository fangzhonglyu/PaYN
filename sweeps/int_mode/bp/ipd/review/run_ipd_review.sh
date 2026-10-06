#!/bin/bash
# Adversarial review of the in-place-doubling BP variant (signed_segmented_csa_bp_ipd).
# Independent of the IPD task's scripts; writes only under build/rtl_preflight/bp_ipd_review/.
#
# Parts (PARTS env, default "pe pe_gl sc existing"):
#   pe        tb_ipd_pe_review.sv on the RTL: phase A IPD PE vs CSA PE (ring_in = 0,
#             every tile, every output, every cycle), phase B IPD PE vs a bit-exact
#             behavioural model with random laps, reset on lap edges, range limits.
#   pe_gl     the same bench with the synthesized IPD PE (csa_bp_ipd_20261004 netlist,
#             unit delay, NO_SDF, ARM_UD_MODEL + ARM_EN_X_SQUASH) in lock step with the RTL PE.
#   sc        SC transparency re-run: array cosim + 384-batch streaming for the IPD top
#             (tied off, and with INT junk) and the CSA top; traces must be byte-identical.
#   existing  default behaviour of the existing BP grid bench: run_bp_grid_checks.sh
#             (unchanged, SHAPES="2x2 4x4") into a review dir, then every per-case trace
#             is compared with the pre-IPD run in build/rtl_preflight/csa_bp_grid/.
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)
cd "$REPO"
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export USE_DW=1 NTFY_CHNL=
PARTS=${PARTS:-"pe pe_gl sc existing"}
OUT=build/rtl_preflight/bp_ipd_review
TB=sweeps/int_mode/bp/ipd/review/tb_ipd_pe_review.sv
NET=syn/build/TSMC22/PAYN_SC_CSA_BP_IPD/csa_bp_ipd_20261004/payn_array_signed_segmented_csa_bp_ipd.syn.v
VLIB="/afs/eecs.umich.edu/kits/ARM/TSMC_22ULL/arm_2020q4/sc7mcpp140z_base_svt_c30/r3p0/verilog/sc7mcpp140z_cln22ul_base_svt_c30.v /afs/eecs.umich.edu/kits/ARM/TSMC_22ULL/arm_2020q4/sc7mcpp140z_hpk_svt_c30/r3p0/verilog/sc7mcpp140z_cln22ul_hpk_svt_c30.v"
mkdir -p "$OUT"

vcs_compile() {   # build_dir extra args...
    local b=$1; shift
    rm -rf "$b"; mkdir -p "$b"
    vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp +incdir+designs \
        -assert svaext -timescale=1ns/1ps "$@" -o "$b/simv" -Mdir="$b/obj" \
        -y "$SYNOPSYS/dw/sim_ver" +libext+.v+ +incdir+"$SYNOPSYS/dw/sim_ver" \
        -top TbIpdPeReview > "$b/compile.log" 2>&1
}

status=0
if [[ " $PARTS " == *" pe "* ]]; then
    vcs_compile "$OUT/pe_build" "$TB" || { echo "pe: compile FAILED ($OUT/pe_build/compile.log)"; status=1; }
    for s in 1 2 3; do
        (cd "$OUT/pe_build" && ./simv +SEED=$s +ntb_random_seed=$s +NA=${NA:-60000} +NB=${NB:-240000} > "sim_seed$s.log" 2>&1)
        grep -h 'REVIEW' "$OUT/pe_build/sim_seed$s.log" | sed "s/^/pe seed $s: /"
        grep -q 'REVIEW PASS' "$OUT/pe_build/sim_seed$s.log" || status=1
    done
fi
if [[ " $PARTS " == *" pe_gl "* ]]; then
    # shellcheck disable=SC2086
    vcs_compile "$OUT/pe_gl_build" +define+REVIEW_GL+define+ARM_UD_MODEL+define+ARM_EN_X_SQUASH \
        +delay_mode_unit +notimingcheck $VLIB "$NET" "$TB" \
        || { echo "pe_gl: compile FAILED ($OUT/pe_gl_build/compile.log)"; status=1; }
    (cd "$OUT/pe_gl_build" && ./simv +SEED=7 +ntb_random_seed=7 +NA=${GNA:-10000} +NB=${GNB:-40000} > sim.log 2>&1)
    grep -h 'REVIEW' "$OUT/pe_gl_build/sim.log" | sed 's/^/pe_gl: /'
    grep -q 'REVIEW PASS' "$OUT/pe_gl_build/sim.log" || status=1
fi
if [[ " $PARTS " == *" sc "* ]]; then
    SC=$OUT/sc
    rm -rf "$SC"; mkdir -p "$SC"
    VCS_PP='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
    SHAPE="+define+PAYN_ARRAY_EXTERNAL_RTL+define+PAYN_SEG_LOW_W=9+define+SC_K=8+define+SC_M=16+define+SC_NH=8+define+SC_NW=8+define+SC_OWIDTH=24+define+SC_T=128"
    IPD_SRC=designs/payn/variants/signed_segmented_csa_bp_ipd/payn_array_signed_segmented_csa_bp_ipd.sv
    CSA_SRC=designs/payn/variants/signed_segmented_csa/payn_array_signed_segmented_csa.sv
    IDEF="$SHAPE+define+PAYN_ARRAY_DUT=payn_array_signed_segmented_csa_bp_ipd+define+PAYN_INT_PORTS"
    CDEF="$SHAPE+define+PAYN_ARRAY_DUT=payn_array_signed_segmented_csa"
    arr() { BUILD_DIR="$SC/$1" SIM_SRCS=$2 VCS_ARGS="$3" bash designs/payn/cosim/run_array.sh NTFY_CHNL= "VCS=$VCS_PP" > "$SC/$1.log" 2>&1; }
    strm() { BUILD_DIR="$SC/$1" SIM_SRCS=$2 bash designs/payn/cosim/run_power_array.sh NTFY_CHNL= "VCS=$VCS_PP" VCS_ARGS="$3+define+SC_BATCHES=384" > "$SC/$1.log" 2>&1; }
    arr ipd "$IPD_SRC" "$IDEF" & arr ipd_junk "$IPD_SRC" "$IDEF+define+PAYN_INT_RAW_JUNK" & arr csa "$CSA_SRC" "$CDEF" &
    strm ipd_s "$IPD_SRC" "$IDEF" & strm ipd_s_junk "$IPD_SRC" "$IDEF+define+PAYN_INT_RAW_JUNK" & strm csa_s "$CSA_SRC" "$CDEF" &
    wait
    AT=designs/payn/tb/test_payn_array.sv/array_rtl.txt
    ST=designs/payn/power/power_payn_array.sv/array_streaming_rtl.txt
    for n in ipd ipd_junk csa ipd_s ipd_s_junk csa_s; do grep -q '\[PASS\]' "$SC/$n.log" && echo "sc $n: PASS" || { echo "sc $n: FAIL"; status=1; }; done
    for n in ipd ipd_junk; do cmp "$SC/$n/$AT" "$SC/csa/$AT" && echo "sc array trace $n == csa ($(wc -l < "$SC/csa/$AT") lines)" || status=1; done
    for n in ipd_s ipd_s_junk; do cmp "$SC/$n/$ST" "$SC/csa_s/$ST" && echo "sc streaming trace $n == csa ($(wc -l < "$SC/csa_s/$ST") lines)" || status=1; done
    cmp "$SC/csa_s/$ST" build/rtl_preflight/bp_ipd/sc/ref_csa_stream/$ST && echo "sc: fresh CSA streaming trace == IPD task's ref_csa_stream" || status=1
fi
if [[ " $PARTS " == *" existing "* ]]; then
    E=$(realpath -m "$OUT/existing_grid")
    rm -rf "$E"
    OUT="$E" SHAPES="2x2 4x4" bash sweeps/int_mode/bp/run_bp_grid_checks.sh > "$REPO/build/rtl_preflight/bp_ipd_review/existing_grid_run.log" 2>&1
    echo "existing grid checks exit: $?"
    n=0; same=0; diffs=0
    for d in "$E"/*/; do
        c=$(basename "$d")
        for f in "$d"/*trace*.txt; do
            [[ -f "$f" ]] || continue
            ref="build/rtl_preflight/csa_bp_grid/$c/$(basename "$f")"
            [[ -f "$ref" ]] || continue
            n=$((n + 1))
            if cmp -s "$f" "$ref"; then same=$((same + 1)); else diffs=$((diffs + 1)); echo "existing: DIFF $c/$(basename "$f")"; fi
        done
    done
    echo "existing grid bench traces vs pre-IPD run (16:47): $same/$n identical, $diffs differ"
    (( diffs == 0 && n > 0 )) || status=1
fi
echo "IPD review: $([[ $status == 0 ]] && echo PASS || echo FAIL)"
exit $status
