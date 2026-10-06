#!/bin/bash
# RTL check of the CNSB / spatial-Booth INT mode on the unmodified CSA RTL.
#   bash sweeps/int_mode/verify/run_cnsb_rtl.sh            # all cases
#   CASES="top_int8_rand grid2x2_int8_rand" bash sweeps/int_mode/verify/run_cnsb_rtl.sh
# Builds under build/int_mode_verify/cnsb_rtl/ (one simv per grid shape).
set -Eeuo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$REPO"
V=sweeps/int_mode/verify
OUT=${OUT:-$REPO/build/int_mode_verify/cnsb_rtl}
mkdir -p "$OUT"

source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export SYNOPSYS=${SYNOPSYS:-/usr/caen/synopsys-synth-2021.06-SP1}

CASES=${CASES:-$(python3 $V/cnsb_rtl_cases.py list)}

shape_of() {   # case -> "top" or "PRxPC"
    python3 - "$1" <<'EOF'
import sys
sys.path.insert(0, "sweeps/int_mode/verify")
import cnsb_rtl_cases as c
k = c.CASES[sys.argv[1]]
print("top" if k["top"] else f"{k['grid'][0]}x{k['grid'][1]}")
EOF
}

build() {      # shape -> simv path
    local shape=$1 dir="$OUT/simv_$1" defs
    if [[ $shape == top ]]; then
        defs="+define+CNSB_USE_TOP"
    else
        defs="+define+CNSB_PR=${shape%x*}+define+CNSB_PC=${shape#*x}"
    fi
    if [[ ! -x $dir/simv ]]; then
        mkdir -p "$dir"
        (cd "$dir" && vcs -sverilog -full64 -timescale=1ns/1ps +vc -Mupdate -line \
            -xprop=tmerge -lca -assert svaext \
            +incdir+"$REPO/designs" \
            -y "$SYNOPSYS/dw/sim_ver" +libext+.v+ +incdir+"$SYNOPSYS/dw/sim_ver" \
            $defs "$REPO/$V/tb_cnsb_int.sv" -top tb_cnsb_int -o simv \
            > compile.log 2>&1) || { echo "compile failed: $dir/compile.log"; tail -30 "$dir/compile.log"; exit 1; }
    fi
    echo "$dir/simv"
}

fail=0
for c in $CASES; do
    shape=$(shape_of "$c")
    simv=$(build "$shape")
    d="$OUT/$c"; mkdir -p "$d"
    python3 $V/cnsb_rtl_cases.py gen "$c" "$d" > "$d/gen.log"
    (cd "$d" && "$simv" +stim="$d/stim.txt" +out="$d/out.txt" > sim.log 2>&1) || true
    if grep -q "Error\|FATAL\|Fatal" "$d/sim.log"; then
        echo "SIM-ERROR  $c (see $d/sim.log)"; grep -m3 "Error\|FATAL\|Fatal" "$d/sim.log"; fail=1; continue
    fi
    python3 $V/cnsb_rtl_cases.py check "$c" "$d" || fail=1
done
exit $fail
