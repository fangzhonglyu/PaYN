#!/bin/bash
# Full-precision hierarchy buckets (pt_sc_hier_buckets.tcl) for the SC power A/B.
# report_power -hier prints 3 significant digits, too coarse for the 0.01 mW
# deltas of the doubling muxes, so this re-runs the identical PT-PX analysis and
# sums leaf-cell power per bucket.  Nothing existing is overwritten: every arm
# writes a NEW directory (refuses if it exists) and each total must equal the
# original analysis' total (checked; the run fails otherwise).
#
#   pre-layout arms (csa lap sr4 sr2 ipd): netlist / SDC / SAIF from
#     <AB_OUT>/<arm>/inputs.txt (run_sc_prelayout_power_ab.sh); session as
#     pt_popcount_syn_power.tcl; total checked against <AB_OUT>/<arm>/power.rpt.
#   routed arms (routed_csa routed_lap): the pinned finals; session = a copy of
#     ASTRAEA apr/scripts/power.tcl (only its final `exit` replaced by the bucket
#     script) run in the new directory, which symlinks the APR run's outputs/ and
#     SDC read-only; SAIF = the APR run's activity/dut.saif (sha256 checked
#     against the pinned work dir's GL SAIF); total checked against the pinned
#     power_result/power.rpt.
#
# Usage: run_sc_power_buckets.sh AB_OUT BUCKET_OUT [arm ...]   (default: all seven)
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
cd "$REPO"
(($# >= 2)) || { echo "usage: $0 AB_OUT BUCKET_OUT [arm ...]" >&2; exit 2; }
AB=$1; BO=$2; shift 2
[[ "$AB" == /* ]] || AB=$REPO/$AB
[[ "$BO" == /* ]] || BO=$REPO/$BO
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export NTFY_CHNL= TSMC22_CELL_TIER=sc7mcpp140z TSMC22_LIB_FLAVORS=svt_c30 TSMC22_HPK_FLAVORS=svt_c30 TSMC22_HPK=1
FLOW_POWER=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}/apr/scripts/power.tcl
HERE=$REPO/sweeps/int_mode/bp/sr
mkdir -p "$BO"

total_of() { python3 -c 'import re,sys; print(re.search(r"Total Power\s*=\s*([0-9.eE+-]+)", open(sys.argv[1]).read())[1])' "$1"; }

pre_arm() (
    set -euo pipefail
    local arm=$1 w=$BO/$1
    mkdir "$w"   # refuse to overwrite
    eval "$(sed -n 's/^\(NETLIST\|SDC\|SAIF\)=\(.*\)$/\1="\2"/p' "$AB/$arm/inputs.txt")"
    local top; top=$(basename "$NETLIST" .syn.v)
    cp -p "$AB/$arm/inputs.txt" "$w/inputs.txt"
    cd "$w"
    TOP=$top NL=$NETLIST SDC=$SDC SAIF_FILE=$SAIF pt_shell -file "$HERE/pt_sc_prelayout_buckets.tcl" > pt.log 2>&1
    if grep -n '^\(Error:\|ERROR:\)' pt.log; then exit 1; fi
    grep -q '^SC_HIER_BUCKETS_DONE ' pt.log
    local a b; a=$(total_of "$AB/$arm/power.rpt"); b=$(total_of power.rpt)
    [[ "$a" == "$b" ]] || { echo "[$arm] total $b != original $a"; exit 1; }
    echo "[$arm] buckets done, total $b W (= original)"
)

routed_arm() (
    set -euo pipefail
    local arm=$1 w=$BO/$1 tgt run top pinned
    case $arm in
        routed_csa) tgt=PAYN_SC_CSA; run=csa_20261002_distguide_spp_pins; top=payn_array_signed_segmented_csa
                    pinned=$REPO/build/power_char/pinned_pass2_20261004/csa ;;
        routed_lap) tgt=PAYN_SC_CSA_BP; run=csa_bp_20261004_lap_distguide_spp_pins; top=payn_array_signed_segmented_csa_bp
                    pinned=$REPO/build/power_char/pinned_pass2_csa_bp_20261004_lap/csa_bp_lap ;;
        *) echo "unknown arm $arm" >&2; exit 2 ;;
    esac
    local apr=$REPO/apr/build/TSMC22/$tgt/$run
    local saif=$apr/activity/dut.saif
    local glsaif=$pinned/gl_final/designs/payn/power/power_payn_array.sv/dut.saif
    [[ "$(sha256sum < "$saif")" == "$(sha256sum < "$glsaif")" ]] || { echo "[$arm] APR activity SAIF != pinned GL SAIF"; exit 1; }
    mkdir "$w"   # refuse to overwrite
    cd "$w"
    ln -s "$apr/outputs" outputs
    ln -s "$apr/$top.syn.sdc" "$top.syn.sdc"
    # the flow script, with only its final `exit` replaced
    python3 - "$FLOW_POWER" "$HERE/pt_sc_hier_buckets.tcl" > power_buckets.tcl <<'PY'
import sys
lines = open(sys.argv[1]).read().rstrip("\n").split("\n")
assert lines[-1].strip() == "exit", lines[-1]
print("\n".join(lines[:-1]))
print(f"source {sys.argv[2]}")
print("exit")
PY
    sha256sum "$FLOW_POWER" "$saif" > inputs.sha256
    printf 'APR_RUN=%s\nSAIF=%s\nFLOW_POWER=%s\nPINNED=%s\n' "$apr" "$saif" "$FLOW_POWER" "$pinned" > inputs.txt
    TECH=TSMC22 TOP=$top SAIF_FILE=$saif SAIF_STRIP_PATH=Top/dut PERIOD=2.5 ZERO_PINLESS_NET_ACTIVITY=1 \
        pt_shell -file power_buckets.tcl > pt.log 2>&1
    if grep -n '^\(Error:\|ERROR:\)' pt.log; then exit 1; fi
    grep -q '^SC_HIER_BUCKETS_DONE ' pt.log
    local a b; a=$(total_of "$pinned/power_result/power.rpt"); b=$(total_of reports/power.rpt)
    [[ "$a" == "$b" ]] || { echo "[$arm] total $b != pinned $a"; exit 1; }
    echo "[$arm] buckets done, total $b W (= pinned)"
)

arms=("$@")
((${#arms[@]})) || arms=(csa lap sr4 sr2 ipd routed_csa routed_lap)
pids=()
for a in "${arms[@]}"; do
    case $a in routed_*) routed_arm "$a" & ;; *) pre_arm "$a" & ;; esac
    pids+=("$!")
done
status=0
for p in "${pids[@]}"; do wait "$p" || status=1; done
exit "$status"
