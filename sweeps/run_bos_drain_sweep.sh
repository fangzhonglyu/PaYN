#!/bin/bash
# BOS drain-amortization sweep: routed binary_os_array netlist, same 4096-cycle
# SAIF window, with a full N_W-cycle accumulator drain folded into the window
# after every BOS_DRAIN_PERIOD MAC cycles.  DRAIN_PERIOD=0 is the pure-MAC point
# (PaYN methodology: drain taken after $toggle_stop).
#
# Reuses the existing BOS_ARRAY APR run; only the workload changes.
# Results -> build/power_char/bos_drain_sweep.csv
set -u
cd "$(dirname "$0")/.."
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash 2>/dev/null
module load synopsys-lib-compiler/2022.03-SP3 synopsys-synth/2021.06-SP1 \
            primetime/2021.06-SP1 vcs/2020.12-SP2-1 \
            innovus/21.14.000 genus/21.14.000 2>/dev/null
export SYNOPSYS=${SYNOPSYS:-/usr/caen/synopsys-synth-2021.06-SP1}

T=TSMC22/BOS_ARRAY
TB="designs/baselines/binary_os/power/power_binary_os_array.sv"
N_W=8
PERIOD_NS=2.5
MACS_PER_CYCLE=64

apr=$(ls -1dt apr/build/$T/*/ 2>/dev/null | head -1 | xargs -r basename)
if [ -z "$apr" ]; then echo "no APR run for $T" >&2; exit 1; fi

CSV=build/power_char/bos_drain_sweep.csv
L=build/power_char/bos_drain_sweep.log
mkdir -p build/power_char
echo "drain_period,mac_cycles,drain_cycles,duty,power_mW,pJ_per_useful_MAC,status" > $CSV
: > $L
echo "BOS_ARRAY apr run = $apr" >> $L

for K in 0 32 64 128 256; do
  label="drain$K"
  bd=build/bos_drain/$label; rm -rf "$bd"
  echo "[$label] gate sim" >> $L
  make sim GL=apr TARGET=$T RUN=$apr BUILD_DIR="$bd" TB="$TB" \
       VCS_ARGS="+define+BOS_DRAIN_PERIOD=$K +define+STIM_CYCLES_N=4096" >> $L 2>&1
  saif=$(find "$bd" -name dut.saif 2>/dev/null | head -1)
  pass=$(grep "PASS: binary OS power SAIF" "$L" | tail -1)
  if [ -z "$pass" ] || [ -z "$saif" ]; then
    echo "[$label] SIM_FAIL" >> $L; echo "$K,,,,,,SIM_FAIL" >> $CSV; continue
  fi
  macs=$(sed -E 's/.*\(([0-9]+) MAC, ([0-9]+) drain\).*/\1/' <<< "$pass")
  drains=$(sed -E 's/.*\(([0-9]+) MAC, ([0-9]+) drain\).*/\2/' <<< "$pass")

  POWER_SAIF_VALIDATOR=sweeps/validate_power_saif.py \
    make power_apr TARGET=$T RUN=$apr SAIF="$saif" SAIF_STRIP_PATH=Top/dut >> $L 2>&1
  tot=$(grep -m1 "Total Power" apr/build/$T/$apr/reports/power.rpt 2>/dev/null \
        | grep -oE "[0-9.]+e[-+][0-9]+" | head -1)
  if [ -z "$tot" ]; then echo "$K,$macs,$drains,,,,PT_FAIL" >> $CSV; continue; fi
  cp -f apr/build/$T/$apr/reports/power.rpt "build/power_char/bos_${label}_power.rpt"

  read -r pw pj duty <<< "$(python3 -c "
tot=$tot; macs=$macs; drains=$drains
cycles=macs+drains
energy=tot*$PERIOD_NS*1e-9*cycles          # J over the whole window
useful=macs*$MACS_PER_CYCLE
print(f'{tot*1e3:.5f} {energy/useful*1e12:.5f} {macs/cycles:.4f}')")"
  echo "[$label] ${pw} mW  ${pj} pJ/useful-MAC  duty=${duty}" >> $L
  echo "$K,$macs,$drains,$duty,$pw,$pj,OK" >> $CSV
done

echo "[bos drain sweep done] -> $CSV" >> $L
column -t -s, "$CSV"
