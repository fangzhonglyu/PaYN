#!/bin/bash
# Diagnostic DC compiles (NOT the synthesis of record) to attribute the kA-encoder area change between
# cbsg_af_20261005 (AF, 64 encoders 6,584.2 um2) and cbsg_af_ipd_20261005 (AF-IPD, 8,560.3 um2): the encoder
# RTL is a rename-only copy, but DC mapped it with ADDF/ADDH cells instead of CGENI/XNOR ripple cells.
# Every run uses the ASTRAEA synth.tcl with the PAYN_SC_CSA_CBSG_AF(_IPD) target knobs unchanged; only TOP /
# SRC_SV point at an experiment top.  Experiment RTL is generated into build/ (the variant RTL is not edited):
#   afipd_rerun   the AF-IPD top as synthesized (determinism check)
#   af_rerun      the AF top as synthesized (determinism / environment check against 39,925.98)
#   afipd_nocomb  AF-IPD without the combiner (int_out tied 0)
#   afipd_nobyp   AF-IPD without the INT bypass (a_bits = sc_a_bits, w_bits = sc_w_bits)
#   afipd_afpe    AF-IPD with the AF/CSA PE (no ring_q, no doubling muxes)
#   afipd_bypmod  AF-IPD with the INT bypass OR moved into its own submodule (u_byp_a / u_byp_w), so DC (FLATTEN=0,
#                 -no_autoungroup) cannot merge it into the thermometer / comparator cones
#   afipd_rawmc   the AF-IPD top with MULTICYCLE_INPUT_PORTS="a_raw_in* w_raw_in*" (2-cycle setup from the raw
#                 ports only; every other knob unchanged): tests whether the raw-port timing triggers the remap
# Runs in build/cbsg/af_ipd/syn/exp/<name>/ (synth.log, area.rpt, netlist); summary exp_summary.txt.
#   bash sweeps/cbsg/af_ipd/syn_encoder_experiment.sh [names...]
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
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
export DESIGN_ROOT=$REPO SNPSLMD_QUEUE=true
EXP=$REPO/build/cbsg/af_ipd/syn/exp
RTL=$EXP/rtl
V=designs/payn/variants/signed_segmented_csa_cbsg_af_ipd
mkdir -p "$RTL"
NAMES=("$@")
[[ ${#NAMES[@]} -gt 0 ]] || NAMES=(afipd_rerun af_rerun afipd_nocomb afipd_nobyp afipd_afpe afipd_bypmod afipd_rawmc)

# --- experiment RTL (generated from the variant files; each edit is checked to have applied) ---
gen() {
    local top=$V/payn_array_signed_segmented_csa_cbsg_af_ipd.sv
    # no combiner
    perl -0pe 's/PaynBpCombinerAfIpd #\(.*?\n    \);\n/assign int_out = 64'"'"'d0;\n    assign int_out_valid = 1'"'"'b0;\n/s' "$top" > "$RTL/top_nocomb.sv"
    # no bypass: peripheral copy with the two bypass assigns replaced, top copy including it
    perl -0pe 's/assign a_bits = sc_a_bits \| \(a_raw_in & \{\(N_H\*K\*M\)\{int_mode\}\}\);/assign a_bits = sc_a_bits;/; s/assign w_bits = sc_w_bits \| \(w_raw_in & \{\(N_W\*K\*M\)\{int_mode\}\}\);/assign w_bits = sc_w_bits;/' \
        $V/cbsg_af_ipd_peripheral.sv > "$RTL/peripheral_nobyp.sv"
    perl -pe 's#`include "payn/variants/signed_segmented_csa_cbsg_af_ipd/cbsg_af_ipd_peripheral.sv"#`include "'"$RTL"'/peripheral_nobyp.sv"#' "$top" > "$RTL/top_nobyp.sv"
    # AF/CSA PE in place of the IPD PE
    perl -0pe 's#`include "payn/variants/signed_segmented_csa_cbsg_af_ipd/inner_pe_signed_segmented_csa_cbsg_af_ipd.sv"#`include "payn/variants/signed_segmented_csa/inner_pe_signed_segmented_csa.sv"#;
               s/InnerPESignedSegmentedCsaBpIpdFlatAfIpd #\(/assign ring_q = 1'"'"'b0;\n    InnerPESignedSegmentedCsaFlat #(/;
               s/\n\s*\.ring_in\(ring_in & int_mode\),//; s/\n\s*\.ring_out\(ring_q\),//' "$top" > "$RTL/top_afpe.sv"
    # bypass in its own hierarchy
    perl -0pe 's/assign a_bits = sc_a_bits \| \(a_raw_in & \{\(N_H\*K\*M\)\{int_mode\}\}\);/CbsgAfIpdBypassExp #(.N(N_H*K*M)) u_byp_a (.sc(sc_a_bits), .raw(a_raw_in), .sel(int_mode), .bits(a_bits));/; s/assign w_bits = sc_w_bits \| \(w_raw_in & \{\(N_W\*K\*M\)\{int_mode\}\}\);/CbsgAfIpdBypassExp #(.N(N_W*K*M)) u_byp_w (.sc(sc_w_bits), .raw(w_raw_in), .sel(int_mode), .bits(w_bits));/' \
        $V/cbsg_af_ipd_peripheral.sv > "$RTL/peripheral_bypmod_body.sv"
    { printf '%s\n' 'module CbsgAfIpdBypassExp #(parameter int N = 1) (input logic [N-1:0] sc, input logic [N-1:0] raw, input logic sel, output logic [N-1:0] bits);' \
             '    assign bits = sc | (raw & {N{sel}});' 'endmodule'; cat "$RTL/peripheral_bypmod_body.sv"; } > "$RTL/peripheral_bypmod.sv"
    perl -pe 's#`include "payn/variants/signed_segmented_csa_cbsg_af_ipd/cbsg_af_ipd_peripheral.sv"#`include "'"$RTL"'/peripheral_bypmod.sv"#' "$top" > "$RTL/top_bypmod.sv"
    [[ $(grep -c "CbsgAfIpdBypassExp #(.N(" "$RTL/peripheral_bypmod.sv") == 2 ]] || { echo "gen bypmod failed"; return 1; }
    diff $V/cbsg_af_ipd_peripheral.sv "$RTL/peripheral_bypmod.sv" > "$RTL/peripheral_bypmod.diff"
    grep -q "assign int_out = 64'd0" "$RTL/top_nocomb.sv" && ! grep -q "PaynBpCombinerAfIpd #" "$RTL/top_nocomb.sv" || { echo "gen nocomb failed"; return 1; }
    [[ $(grep -c "assign [aw]_bits = sc_[aw]_bits;" "$RTL/peripheral_nobyp.sv") == 2 ]] || { echo "gen nobyp failed"; return 1; }
    grep -q "$RTL/peripheral_nobyp.sv" "$RTL/top_nobyp.sv" || { echo "gen nobyp top failed"; return 1; }
    grep -q "InnerPESignedSegmentedCsaFlat #(" "$RTL/top_afpe.sv" && ! grep -q "ring_in(ring_in" "$RTL/top_afpe.sv" \
        && ! grep -q "ring_out(ring_q)" "$RTL/top_afpe.sv" || { echo "gen afpe failed"; return 1; }
    diff "$top" "$RTL/top_nocomb.sv" > "$RTL/top_nocomb.diff"
    diff $V/cbsg_af_ipd_peripheral.sv "$RTL/peripheral_nobyp.sv" > "$RTL/peripheral_nobyp.diff"
    diff "$top" "$RTL/top_afpe.sv" > "$RTL/top_afpe.diff"
    return 0
}
gen || exit 1

run() {   # name target src
    local name=$1 tgt=$2 src=$3 d="$EXP/$1"
    rm -rf "$d"; mkdir -p "$d"
    (
        set -a; . "syn/targets/TSMC22/$tgt"; set +a
        export SRC_SV=$src
        cp "syn/targets/TSMC22/$tgt" "$d/TARGET_DEF"
        echo "export SRC_SV=$src  # experiment override" >> "$d/TARGET_DEF"
        [[ -n "${MULTICYCLE_INPUT_PORTS:-}" ]] && echo "export MULTICYCLE_INPUT_PORTS=\"$MULTICYCLE_INPUT_PORTS\"  # experiment override" >> "$d/TARGET_DEF"
        cd "$d" && dc_shell -f "$ASTRAEA_FLOW/syn/scripts/synth.tcl" > synth.log 2>&1
    )
    if grep -qE '^(Error:|ERROR:)' "$d/synth.log" || [[ ! -s "$d/area.rpt" ]]; then echo "$name: DC FAILED ($d/synth.log)"; return 1; fi
    echo "$name: done"
}

pids=()
for n in "${NAMES[@]}"; do
    case "$n" in
        afipd_rerun)  run "$n" PAYN_SC_CSA_CBSG_AF_IPD "$V/payn_array_signed_segmented_csa_cbsg_af_ipd.sv" & ;;
        af_rerun)     run "$n" PAYN_SC_CSA_CBSG_AF designs/payn/variants/signed_segmented_csa_cbsg_af/payn_array_signed_segmented_csa_cbsg_af.sv & ;;
        afipd_nocomb) run "$n" PAYN_SC_CSA_CBSG_AF_IPD "$RTL/top_nocomb.sv" & ;;
        afipd_nobyp)  run "$n" PAYN_SC_CSA_CBSG_AF_IPD "$RTL/top_nobyp.sv" & ;;
        afipd_afpe)   run "$n" PAYN_SC_CSA_CBSG_AF_IPD "$RTL/top_afpe.sv" & ;;
        afipd_bypmod) run "$n" PAYN_SC_CSA_CBSG_AF_IPD "$RTL/top_bypmod.sv" & ;;
        afipd_rawmc)  MULTICYCLE_INPUT_PORTS="a_raw_in* w_raw_in*" run "$n" PAYN_SC_CSA_CBSG_AF_IPD "$V/payn_array_signed_segmented_csa_cbsg_af_ipd.sv" & ;;
        *) echo "unknown experiment $n"; continue ;;
    esac
    pids+=("$!")
done
for p in "${pids[@]}"; do wait "$p"; done

{
echo "Encoder attribution experiments (diagnostic DC compiles, target knobs unchanged) $(date -Iseconds)"
printf "%-14s %10s %8s %10s %9s %9s %9s %6s %6s %6s\n" run total wns encoders enc_mean u_pe u_periph ADDF ADDH CGENI
for n in "${NAMES[@]}"; do
    d="$EXP/$n"; [[ -s "$d/area.rpt" ]] || { echo "$n: no area.rpt"; continue; }
    top=$(grep -m1 '^export TOP=' "$d/TARGET_DEF" | cut -d= -f2)
    tot=$(grep -m1 'Total cell area' "$d/area.rpt" | awk '{print $4}')
    wns=$(grep -m1 'slack (' "$d/timing.rpt" | awk '{print $NF}')
    enc=$(awk '$1 ~ /__u_ka$/ {s+=$2; n++} END {printf "%.1f %.1f", s, (n ? s/n : 0)}' "$d/area.rpt")
    upe=$(awk '$1=="u_pe" {print $2; exit}' "$d/area.rpt")
    uper=$(awk '$1=="u_peripheral" {print $2; exit}' "$d/area.rpt")
    mix=$(awk '/^module CbsgAfKaEncoder/ {on=1; next} on && /^endmodule/ {on=0} on && $1 ~ /^(ADDF|ADDH|CGENI)_/ {split($1, a, "_"); c[a[1]]++} END {printf "%d %d %d", c["ADDF"], c["ADDH"], c["CGENI"]}' "$d/$top.syn.v")
    printf "%-14s %10s %8s %10s %9s %9s %9s %6s %6s %6s\n" "$n" "$tot" "$wns" ${enc} "$upe" "$uper" ${mix}
done
echo "reference: cbsg_af_20261005 39925.98 (encoders 6584.2) / cbsg_af_ipd_20261005 44690.65 (encoders 8560.3)"
} | tee "$EXP/exp_summary.txt"
