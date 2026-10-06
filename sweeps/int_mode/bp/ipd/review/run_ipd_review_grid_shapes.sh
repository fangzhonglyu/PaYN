#!/bin/bash
# Review: IPD PE grid on shapes the IPD matrix did not run (1x3: one PE row, the
# ring wave only moves east; 5x3: P_R > P_C, odd; 3x5), with the IPD task's own
# grid bench (designs/payn/tb/test_pe_grid_bp_ipd.sv) and checker
# (sweeps/int_mode/bp/ipd/check_bp_ipd_grid_trace.py), both unchanged.
# Every PE's lap must be 1 edge at offset r+c, every tile bit-exact, period = formula.
# Logs: build/rtl_preflight/bp_ipd_review/grid_shapes/
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
OUT=$(realpath -m build/rtl_preflight/bp_ipd_review/grid_shapes)
TB=designs/payn/tb/test_pe_grid_bp_ipd.sv
CHK=sweeps/int_mode/bp/ipd/check_bp_ipd_grid_trace.py
mkdir -p "$OUT"
status=0
# shape BA BW L NIG NJG DIST SEED FLAGS EXPECT
CASES=$(cat <<'EOF'
1x3 8 8  512 2 1 uniform     301 JUNK            pass
1x3 4 4  384 1 2 minxmax     302 -               pass
5x3 8 8  384 2 1 uniform     303 JUNK            pass
5x3 8 4  256 1 2 allmin      304 -               pass
3x5 8 8  256 1 2 uniform     305 RING_GATE_JUNK  pass
3x5 8 8  256 1 1 uniform     306 LAP_LEN=2       fail
5x3 8 8  256 1 1 uniform     307 NEG_RING_STRAY  fail
EOF
)
for shape in 1x3 5x3 3x5; do
    pr=${shape%x*} pc=${shape#*x}
    b="$OUT/build_$shape"; rm -rf "$b"; mkdir -p "$b"
    vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp \
        +incdir+designs -assert svaext -timescale=1ns/1ps +define+BPG_PR=$pr+define+BPG_PC=$pc \
        -o "$b/simv" -Mdir="$b/obj" -y "$SYNOPSYS/dw/sim_ver" +libext+.v+ +incdir+"$SYNOPSYS/dw/sim_ver" \
        "$TB" -top Top > "$OUT/compile_$shape.log" 2>&1 || { echo "compile $shape FAILED"; status=1; } &
done
wait
n=0
while read -r shape ba bw L nig njg dist seed flags expect; do
    [[ -n "$shape" ]] || continue
    n=$((n + 1))
    pr=${shape%x*} pc=${shape#*x}
    mrows=$(( pr * (8 / ba) * nig )); ncols=$(( 8 * pc * njg ))
    d="$OUT/c${n}_${shape}_${ba}${bw}_L${L}_${flags//[,=]/_}"
    rm -rf "$d"; mkdir -p "$d"
    plus=(); [[ $flags != - ]] && { IFS=, read -ra fl <<< "$flags"; for x in "${fl[@]}"; do plus+=("+$x"); done; }
    python3 sweeps/int_mode/bp/gen_bp_workload.py --ba "$ba" --bw "$bw" --L "$L" --mrows "$mrows" \
        --ncols "$ncols" --dist "$dist" --seed "$seed" --out-dir "$d" > "$d/gen.log"
    (cd "$d" && "$OUT/build_$shape/simv" +BA="$ba" +BW="$bw" +L="$L" +MROWS="$mrows" +NCOLS="$ncols" \
        "${plus[@]}" > sim.log 2>&1)
    if ! grep -q '^PASS: BP grid bench' "$d/sim.log"; then echo "$(basename "$d"): FAIL (sim error)"; status=1; continue; fi
    if python3 "$CHK" "$d" --json "$d/check.json" > "$d/check.log" 2>&1; then r=pass; else r=fail; fi
    if [[ $r == "$expect" ]]; then echo "$(basename "$d"): AS EXPECTED ($expect) $(tail -1 "$d/check.log" | cut -c1-260)"
    else echo "$(basename "$d"): UNEXPECTED ($r, wanted $expect) $(tail -1 "$d/check.log")"; status=1; fi
done <<< "$CASES"
echo "IPD review grid shapes: $([[ $status == 0 ]] && echo PASS || echo FAIL)"
exit $status
