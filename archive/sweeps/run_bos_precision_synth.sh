#!/bin/bash
# Native signed BOS precision builds. Optional INT8 arm is a fresh matched baseline.
# Usage: bash sweeps/run_bos_precision_synth.sh [8] [6] [4]
# Each arm: independent RTL matrix tests -> checked RTL workload SAIF -> synth
# -> vendor-cell functional test. Gate tests use NO_SDF unit delays only;
# this script makes no routed-power claim. Existing artifacts are never replaced.
set -Eeuo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
CAMPAIGN=${CAMPAIGN:-bos_precision_20261001}
[[ "$CAMPAIGN" =~ ^[A-Za-z0-9_]+$ ]] || { echo 'Invalid CAMPAIGN' >&2; exit 2; }
OUT="$REPO/build/bos_precision/$CAMPAIGN"
WIDTHS=("$@")
((${#WIDTHS[@]})) || WIDTHS=(6 4)
declare -A SEEN=()
for width in "${WIDTHS[@]}"; do
    case "$width" in 8|6|4) ;; *) echo "Unsupported precision: $width" >&2; exit 2;; esac
    [[ ! -v SEEN[$width] ]] || { echo "Repeated precision: $width" >&2; exit 2; }
    SEEN[$width]=1
done
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export SYNOPSYS=${SYNOPSYS:-/usr/caen/synopsys-synth-2021.06-SP1}
export USE_DW=1 NTFY_CHNL=
export TSMC22_CELL_TIER=sc7mcpp140z TSMC22_LIB_FLAVORS=svt_c30
export TSMC22_HPK_FLAVORS=svt_c30 TSMC22_HPK=1
export PERIOD=2.5 INPUT_DELAY=1.25 OUTPUT_DELAY=0.05
export MULTIBIT_INFER=1 CLOCK_GATE=1 MINPOWER=0 FLATTEN=0 SYN_AREA_HIGH_EFFORT=0 MAX_FANOUT=16
unset SYN_DEFINES POST_LOAD_SCRIPT SYN_SAIF_FILE SYN_SAIF_INSTANCE
unset MULTICYCLE_INPUT_PORTS MULTICYCLE_INPUT_CYCLES CLOCK_GATE_MAX_FANOUT
VCS_CMD='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
TEST=designs/baselines/binary_os/tb/test_binary_os_array.sv
POWER_TB=designs/baselines/binary_os/power/power_binary_os_array.sv
mkdir -p "$OUT"
run_width() (
    width=$1
    target=TSMC22/BOS_ARRAY_INT$width; top=binary_os_array_int$width
    if [[ "$width" == 8 ]]; then target=TSMC22/BOS_ARRAY; top=binary_os_array; fi
    run=${CAMPAIGN}_int${width}
    work="$OUT/int$width"
    syn="$REPO/syn/build/$target/$run"
    exec 9>"$OUT/int${width}.lock"
    flock -n 9 || { echo "INT$width already running" >&2; exit 2; }
    [[ ! -e "$work" && ! -e "$syn" ]] || { echo "INT$width: existing artifacts; choose a new CAMPAIGN" >&2; exit 2; }
    mkdir "$work"
    trap 'rc=$?; printf "FAIL exit=%s\n" "$rc" > "$work/status"; exit "$rc"' ERR
    defs="+define+BOS_IWIDTH=$width+define+BOS_GL_DUT=$top+define+BOS_NH=8+define+BOS_NW=8+define+BOS_OWIDTH=24"
    printf 'target=%s\ntop=%s\nrun=%s\nIWIDTH=%s NH=8 NW=8 OWIDTH=24 PERIOD=2.5 INPUT_DELAY=1.25 HPK=1 MULTIBIT=1 CLOCK_GATE=1\n' "$target" "$top" "$run" "$width" > "$work/inputs.txt"
    echo "[INT$width] RTL matrix/corner tests"
    make sim GL= TARGET= TOP=Top TB="$TEST" BUILD_DIR="$work/rtl_matmul" \
        VCS_ARGS="$defs" "VCS=$VCS_CMD" NTFY_CHNL= > "$work/rtl_matmul.log" 2>&1
    grep -q "PASS: binary OS INT$width array matched golden matmul" "$work/rtl_matmul.log"
    echo "[INT$width] checked RTL workload"
    make sim GL= TARGET= TOP=Top TB="$POWER_TB" BUILD_DIR="$work/rtl_workload" \
        VCS_ARGS="$defs+define+STIM_CYCLES_N=4096 -debug_access+pp" "VCS=$VCS_CMD" NTFY_CHNL= > "$work/rtl_workload.log" 2>&1
    grep -q 'PASS: binary OS power SAIF captured + output-checked; 4096 cycles (4096 MAC, 0 drain), 262144 useful MAC' "$work/rtl_workload.log"
    saif="$work/rtl_workload/$POWER_TB/dut.saif"
    python3 sweeps/validate_power_saif.py "$saif" > "$work/rtl_saif_validation.log" 2>&1
    echo "[INT$width] synthesis"
    RUN_NAME="$run" SYN_SAIF_FILE="$saif" SYN_SAIF_INSTANCE=Top/dut \
        make synth TARGET="$target" NTFY_CHNL= > "$work/synth.log" 2>&1
    [[ -s "$syn/$top.syn.v" && -s "$syn/area.rpt" && -s "$syn/timing.rpt" ]]
    echo "[INT$width] synthesized-cell functional test (unit delay, no power result)"
    make sim GL=syn TARGET="$target" RUN="$run" TB="$TEST" BUILD_DIR="$work/syn_functional" \
        NO_SDF=1 RTL_PREFLIGHT_CMD=true \
        VCS_ARGS="$defs+define+ARM_UD_MODEL +notimingcheck" "VCS=$VCS_CMD" NTFY_CHNL= \
        > "$work/syn_functional.log" 2>&1
    grep -q "PASS: binary OS INT$width array matched golden matmul" "$work/syn_functional.log"
    python3 - "$syn" "$top" "$width" "$work" <<'REPORT'
import csv,re,sys
from pathlib import Path
syn,top,width,work=Path(sys.argv[1]),sys.argv[2],int(sys.argv[3]),Path(sys.argv[4])
area=float(re.search(r'Total cell area:\s*([0-9.]+)',(syn/'area.rpt').read_text())[1])
slacks=re.findall(r'slack \((?:MET|VIOLATED)\)\s+([-+0-9.]+)',(syn/'timing.rpt').read_text())
assert slacks and min(map(float,slacks))>=0, 'Synthesis timing failed'
net=(syn/f'{top}.syn.v').read_text()
body=re.search(r'\bmodule\s+'+re.escape(top)+r'\s*\(.*?endmodule',net,re.S)[0]
for name,bits in [('a_in',8*width),('w_in',8*width),('acc_in_west',192),('acc_out_east',192)]:
    declaration=re.search(r'\b(?:input|output)\s+\[(\d+):(\d+)\]\s+'+name+r'\s*;',body)
    assert declaration and abs(int(declaration[1])-int(declaration[2]))+1==bits, f'Unexpected native port width: {name}'
row=dict(IWIDTH=width,N_H=8,N_W=8,OWIDTH=24,period_ns=2.5,input_delay_ns=1.25,top=top,run=syn.name,syn_area_um2=area,setup_slack_ns=min(map(float,slacks)),rtl_matmul='PASS',rtl_workload='PASS',syn_functional='PASS',native_ports='PASS',status='PASS')
with (work/'result.csv').open('w') as f:
    writer=csv.DictWriter(f,fieldnames=row);writer.writeheader();writer.writerow(row)
print(row)
REPORT
    printf 'PASS\n' > "$work/status"
    echo "[INT$width] complete: $work/result.csv"
)
pids=()
for width in "${WIDTHS[@]}"; do run_width "$width" & pids+=("$!"); done
status=0
for pid in "${pids[@]}"; do if wait "$pid"; then :; else status=1; fi; done
[[ "$status" == 0 ]] || exit "$status"
python3 - "$OUT" "${WIDTHS[@]}" <<'REPORT'
import csv,sys
from pathlib import Path
root=Path(sys.argv[1]);rows=[]
for width in sys.argv[2:]:
    with (root/f'int{width}'/'result.csv').open() as f: rows.append(next(csv.DictReader(f)))
with (root/'results.csv').open('w') as f:
    writer=csv.DictWriter(f,fieldnames=rows[0]);writer.writeheader();writer.writerows(rows)
print(root/'results.csv')
REPORT
