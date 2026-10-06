#!/bin/bash
# RTL check of the WO-ring INT mode on the committed (routed) CSA RTL.
#   bash sweeps/int_mode/verify/wo_ring/run_rtl.sh            # all cases
#   CASES="fh_rand_1x1_200" bash sweeps/int_mode/verify/wo_ring/run_rtl.sh
# Compiles tb_wo_ring.sv once per grid shape against rtl_snapshot/ (a
# `git show HEAD:` copy of the CSA sources, so working-tree edits cannot leak
# in), generates stimulus with gen_and_check.py, runs VCS and checks the
# drained outputs against numpy.  Logs and work files go to build/.
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=${OUT:-$HERE/build}
mkdir -p "$OUT"

source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export SYNOPSYS=${SYNOPSYS:-/usr/caen/synopsys-synth-2021.06-SP1}

ALL=$(python3 "$HERE/gen_and_check.py" list | awk '{print $1}')
CASES=${CASES:-$ALL}

compile() {   # $1=PR $2=PC $3=msb|lsb (lsb: the shift-down ring wiring)
    local d="$OUT/simv_${1}x${2}${3/msb/}" def=""
    [[ "$3" == lsb ]] && def="+define+LSB"
    [[ -x "$d/simv" ]] && return 0
    mkdir -p "$d"
    (cd "$d" && vcs -sverilog -full64 -line -timescale=1ns/1ps -xprop=tmerge \
        -assert svaext +define+PR=$1 +define+PC=$2 $def \
        +incdir+"$HERE/rtl_snapshot" \
        -y "$SYNOPSYS/dw/sim_ver" +libext+.v+ +incdir+"$SYNOPSYS/dw/sim_ver" \
        "$HERE/tb_wo_ring.sv" -top tb_wo_ring -o simv > compile.log 2>&1) \
        || { echo "compile ${1}x${2} failed, see $d/compile.log"; exit 1; }
}

pass=0; fail=0
SUMMARY=${SUMMARY:-$OUT/summary.txt}; : > "$SUMMARY"
for c in $CASES; do
    read -r name pr pc ring < <(python3 "$HERE/gen_and_check.py" list | awk -v n="$c" '$1==n')
    compile "$pr" "$pc" "$ring"
    w="$OUT/$name"; mkdir -p "$w"
    python3 "$HERE/gen_and_check.py" gen "$name" "$w/stim.txt" "$w/meta.json"
    (cd "$w" && "$OUT/simv_${pr}x${pc}${ring/msb/}/simv" +stim="$w/stim.txt" +out="$w/drain.txt" > sim.log 2>&1) \
        || { echo "FAIL $name: simulation error (see $w/sim.log)" | tee -a "$SUMMARY"; fail=$((fail+1)); continue; }
    if python3 "$HERE/gen_and_check.py" check "$w/meta.json" "$w/drain.txt" | tee -a "$SUMMARY"; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
    fi
    rm -f "$w/stim.txt"     # large; regenerated deterministically on demand
done
echo "TOTAL pass=$pass fail=$fail" | tee -a "$SUMMARY"
