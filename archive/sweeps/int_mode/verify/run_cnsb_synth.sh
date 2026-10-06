#!/bin/bash
# Synthesize the CNSB INT-mode edge blocks with the PAYN_SC_CSA knobs (A7 SVT +
# HPK, 2.5 ns, 1.25 ns input delay, clock gating, multibit) so the round-1 hand
# estimates can be replaced by DC cell area.  New files only: RTL in rtl/, runs in
# syn_runs/<block>/ under this directory.  Existing repo files are untouched.
#   bash sweeps/int_mode/verify/run_cnsb_synth.sh            # sim + all blocks
#   BLOCKS="feed_r4_half" bash sweeps/int_mode/verify/run_cnsb_synth.sh
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export SYNOPSYS=${SYNOPSYS:-/usr/caen/synopsys-synth-2021.06-SP1}

python3 -B "$HERE/gen_cnsb_rtl.py"

# ---- functional check of the generated RTL against the Python reference ----
SIM="$HERE/sim"
mkdir -p "$SIM"
( cd "$SIM" && vcs -sverilog -full64 -timescale=1ns/1ps +incdir+"$REPO/designs" \
      "$HERE"/rtl/cnsb_feed_r4_half.sv "$HERE"/rtl/cnsb_feed_r16_half_hi.sv \
      "$HERE"/rtl/cnsb_feed_r16_half_lo.sv "$HERE"/rtl/cnsb_combiner_row_1st.sv \
      "$HERE"/rtl/cnsb_combiner_row_2st.sv "$HERE"/tb_cnsb_blocks.sv \
      -top tb_cnsb_blocks -o simv > vcs_compile.log 2>&1 && \
  ./simv +VDIR="$HERE/vectors" > sim.log 2>&1 )
grep -q "^PASS: CNSB blocks match Python reference" "$SIM/sim.log" || { cat "$SIM/sim.log"; exit 1; }
grep "^PASS" "$SIM/sim.log"
[[ "${SIM_ONLY:-0}" == 1 ]] && exit 0

# ---- synthesis, PAYN_SC_CSA knobs ----
export TECH=TSMC22 PERIOD=2.5 INPUT_DELAY=1.25 OUTPUT_DELAY=0.05
export TSMC22_CELL_TIER=sc7mcpp140z TSMC22_LIB_FLAVORS=svt_c30 TSMC22_HPK_FLAVORS=svt_c30
export ZERO_PINLESS_NET_ACTIVITY=1 TSMC22_HPK=1 MULTIBIT_INFER=1 CLOCK_GATE=1 MINPOWER=0
export FLATTEN=0 MAX_FANOUT=16 SYN_AREA_HIGH_EFFORT=0 USE_DW=1 DESIGN_ROOT="$REPO"
unset SYN_DEFINES POST_LOAD_SCRIPT SYN_SAIF_FILE SYN_SAIF_INSTANCE MULTICYCLE_INPUT_PORTS

declare -A TOPS=(
    [feed_r4_half]="cnsb_feed_r4_half:rtl/cnsb_feed_r4_half.sv"
    [feed_r16_half_hi]="cnsb_feed_r16_half_hi:rtl/cnsb_feed_r16_half_hi.sv"
    [feed_r16_half_lo]="cnsb_feed_r16_half_lo:rtl/cnsb_feed_r16_half_lo.sv"
    [combiner_row_1st]="cnsb_combiner_row_1st:rtl/cnsb_combiner_row_1st.sv"
    [combiner_row_2st]="cnsb_combiner_row_2st:rtl/cnsb_combiner_row_2st.sv"
    [sobol_pair_orig]="sobol_pair_orig:rtl/sobol_pair_preset.sv"
    [sobol_pair_preset]="sobol_pair_preset:rtl/sobol_pair_preset.sv"
)
BLOCKS=${BLOCKS:-"${!TOPS[*]}"}
run_block() (
    local blk=$1 spec=${TOPS[$1]}
    local top=${spec%%:*} src="$HERE/${spec#*:}" work="$HERE/syn_runs/$1"
    mkdir -p "$work"
    cd "$work"
    TOP=$top SRC_SV=$src dc_shell -f "$ASTRAEA_FLOW/syn/scripts/synth.tcl" > synth.log 2>&1 || true
    if grep -E -q '^(Error:|ERROR:)' synth.log || [[ ! -s area.rpt ]]; then
        echo "[$blk] FAILED (see $work/synth.log)"; return 1
    fi
    local area slack
    area=$(grep -m1 'Total cell area' area.rpt | awk '{print $4}')
    slack=$(grep -m1 'slack' timing.rpt | awk '{print $NF}')
    echo "[$blk] top=$top area=$area worst_slack=$slack"
)
MAX_JOBS=${MAX_JOBS:-3}
rc=0
for b in $BLOCKS; do
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || rc=1; done
    run_block "$b" &
done
while (( $(jobs -rp | wc -l) > 0 )); do wait -n || rc=1; done
exit $rc
