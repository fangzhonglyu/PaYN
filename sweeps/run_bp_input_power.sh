#!/bin/bash
# BP input-precision power sweep: INT8 native BP_ARRAY netlist fed INT8/7/6 inputs
# (signed + all-positive), GL=apr + PT-PX. Reuses the existing BP_ARRAY APR run.
# Results -> build/power_char/bp_input_regimes.csv
set -u
cd /home/barrylyu/repos/PaYN
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash 2>/dev/null
module load synopsys-lib-compiler/2022.03-SP3 synopsys-synth/2021.06-SP1 primetime/2021.06-SP1 vcs/2020.12-SP2-1 innovus/21.14.000 genus/21.14.000 2>/dev/null
export SYNOPSYS=/usr/caen/synopsys-synth-2021.06-SP1 USE_DW=1
T=TSMC22/BP_ARRAY
TB="designs/baselines/binary_parallel/power/power_array_8.sv"
apr=$(ls -1dt apr/build/$T/*/ | head -1 | xargs basename)
CSV=build/power_char/bp_input_regimes.csv
echo "regime,input_bits,sign,power_mW,pJ_MAC,status" > $CSV
L=build/power_char/bp_input_regimes.log; : > $L
echo "BP_ARRAY (INT8 native) apr run = $apr" >> $L

# INT8 native HW; inputs quantized to {8,7,6} bits, signed and all-positive
for R in "int8_signed 8 s" "int7_signed 7 s" "int6_signed 6 s" \
         "int8_allpos 8 p" "int7_allpos 7 p" "int6_allpos 6 p"; do
  set -- $R; label=$1; ib=$2; sgn=$3
  defs="+define+BP_IWIDTH=8 +define+BP_INPUT_BITS=$ib +define+STIM_CYCLES_N=4096"
  [ "$sgn" = p ] && defs="$defs +define+BP_ALL_POSITIVE"
  bd=build/regimes_pwr/$label; rm -rf "$bd"
  echo "[$label] sim (INPUT_BITS=$ib sign=$sgn)" >> $L
  make sim GL=apr TARGET=$T RUN=$apr USE_DW=1 BUILD_DIR="$bd" TB="$TB" VCS_ARGS="$defs" >> $L 2>&1
  saif=$(find "$bd" -name dut.saif 2>/dev/null | head -1)
  if ! grep -q "PASS:" "$L" || [ -z "$saif" ]; then
    echo "[$label] SIM_FAIL" >> $L; echo "$label,$ib,$sgn,,,SIM_FAIL" >> $CSV; continue; fi
  POWER_SAIF_VALIDATOR=sweeps/validate_power_saif.py make power_apr TARGET=$T RUN=$apr \
       SAIF="$saif" SAIF_STRIP_PATH=Top/dut >> $L 2>&1
  tot=$(grep -m1 "Total Power" apr/build/$T/$apr/reports/power.rpt 2>/dev/null | grep -oE "[0-9.]+e[-+][0-9]+" | head -1)
  if [ -z "$tot" ]; then echo "$label,$ib,$sgn,,,PT_FAIL" >> $CSV; continue; fi
  pw=$(python3 -c "print(f'{$tot*1e3:.3f}')")
  pj=$(python3 -c "print(f'{$tot*2.5e-9/64*1e12:.4f}')")
  echo "[$label] DONE ${pw}mW $pj pJ/MAC" >> $L
  echo "$label,$ib,$sgn,$pw,$pj,OK" >> $CSV
done
echo "[input-regime sweep done]" >> $L
