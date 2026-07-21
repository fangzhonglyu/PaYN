#!/bin/bash
set -u
cd /home/barrylyu/repos/PaYN
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash 2>/dev/null
module load synopsys-lib-compiler/2022.03-SP3 synopsys-synth/2021.06-SP1 primetime/2021.06-SP1 vcs/2020.12-SP2-1 innovus/21.14.000 genus/21.14.000 2>/dev/null
export SYNOPSYS=/usr/caen/synopsys-synth-2021.06-SP1 USE_DW=1
OUT=build/power_char; mkdir -p $OUT
CSV=$OUT/sc_sweep.csv
TB="designs/payn/power/power_payn_array.sv"
ST=TSMC22/PAYN_SC_SWEEP
MAX=6
[ -f "$CSV" ] || echo "config,K,M,N,synA_um2,synSlk,aprA_um2,aprWNS,T,pwr_mW,pJ_MAC,cosim,status" > $CSV

run_cfg() {
  local K=$1 M=$2 N=$3 ; local cfg=k${K}m${M}n${N}
  grep -q "^$cfg,.*,OK$" "$CSV" 2>/dev/null && return   # resume: skip completed
  local L=$OUT/sc_$cfg.log ; : > "$L"
  local SD="PAYN_K=$K PAYN_M=$M PAYN_NH=$N PAYN_NW=$N"
  local DEF="+define+SC_K=$K +define+SC_M=$M +define+SC_NH=$N +define+SC_NW=$N"
  local bd=build/sweep/$cfg
  rm -rf "$bd"

  # 1) RTL cosim fail-fast
  echo "[$cfg] RTL cosim" >> "$L"
  make sim TB="$TB" USE_DW=1 BUILD_DIR="$bd/rtl" VCS_ARGS="$DEF +define+SC_T=64" >> "$L" 2>&1
  local tr=$(find "$bd/rtl" -name array_rtl.txt 2>/dev/null | head -1)
  if ! python3 designs/payn/cosim/cosim_array.py "$tr" 2>/dev/null | grep -q "\[PASS\]"; then
    echo "[$cfg] COSIM_FAIL" >> "$L"; echo "$cfg,$K,$M,$N,,,,,,,,FAIL,COSIM_FAIL" >> $CSV; return; fi

  # 2) synth
  echo "[$cfg] synth" >> "$L"
  RUN_NAME=$cfg SYN_DEFINES="$SD" make synth TARGET=$ST >> "$L" 2>&1
  local sd=syn/build/$ST/$cfg
  local synA=$(grep -m1 "Total cell area" "$sd/area.rpt" 2>/dev/null | grep -oE "[0-9.]+")
  local synSlk=$(grep -m1 "slack" "$sd/timing.rpt" 2>/dev/null | grep -oE "\-?[0-9.]+" | tail -1)
  if [ ! -f "$sd/payn_array.syn.v" ]; then echo "$cfg,$K,$M,$N,,$synSlk,,,,,,,SYNTH_FAIL" >> $CSV; return; fi

  # 3) apr
  echo "[$cfg] apr" >> "$L"
  RUN_NAME=$cfg make apr TARGET=$ST SYNTH_RUN=$cfg >> "$L" 2>&1
  local ad=apr/build/$ST/$cfg
  if [ ! -f "$ad/outputs/payn_array.apr.v" ]; then echo "$cfg,$K,$M,$N,$synA,$synSlk,,,,,,,APR_FAIL" >> $CSV; return; fi
  local aprA=$(awk '$1=="payn_array"{for(i=2;i<=NF;i++)if($i+0>500){print $i;exit}}' "$ad/reports/area.rpt" 2>/dev/null)
  local aprWNS=$(zcat "$ad/timingReports"/*postCTS.summary.gz 2>/dev/null | awk -F'|' '/WNS \(ns\)/{gsub(/ /,"",$3);print $3;exit}')

  # 4) GL sim (+ output cosim)
  echo "[$cfg] GL sim" >> "$L"
  make sim GL=apr TARGET=$ST RUN=$cfg USE_DW=1 BUILD_DIR="$bd/gl" TB="$TB" VCS_ARGS="$DEF +define+SC_T=128" >> "$L" 2>&1
  local saif=$(find "$bd/gl" -name dut.saif 2>/dev/null | head -1)
  local gtr=$(find "$bd/gl" -name array_rtl.txt 2>/dev/null | head -1)
  local cos=FAIL
  [ -n "$gtr" ] && python3 designs/payn/cosim/cosim_array.py "$gtr" 2>/dev/null | grep -q "\[PASS\]" && cos=PASS
  if [ -z "$saif" ] || grep -qE "X-FAIL|\\\$fatal" "$L"; then echo "$cfg,$K,$M,$N,$synA,$synSlk,$aprA,$aprWNS,128,,,$cos,SIM_FAIL" >> $CSV; return; fi

  # 5) power
  echo "[$cfg] power" >> "$L"
  POWER_SAIF_VALIDATOR=sweeps/validate_sc_power_saif.py make power_apr TARGET=$ST RUN=$cfg \
       SAIF="$saif" SAIF_STRIP_PATH=Top/dut >> "$L" 2>&1
  local tot=$(grep -m1 "Total Power" "$ad/reports/power.rpt" 2>/dev/null | grep -oE "[0-9.]+e[-+][0-9]+" | head -1)
  if [ -z "$tot" ]; then echo "$cfg,$K,$M,$N,$synA,$synSlk,$aprA,$aprWNS,128,,,$cos,PT_FAIL" >> $CSV; return; fi
  local pw=$(python3 -c "print(f'{$tot*1e3:.3f}')")
  local pj=$(python3 -c "print(f'{$tot*2.5e-9/($K*$M*$N*$N/128)*1e12:.4f}')")
  echo "[$cfg] DONE pwr=${pw}mW pJ/MAC=$pj cosim=$cos" >> "$L"
  echo "$cfg,$K,$M,$N,$synA,$synSlk,$aprA,$aprWNS,128,$pw,$pj,$cos,OK" >> $CSV
}

for K in 4 6 8; do for M in 8 16; do for N in 2 4 8; do
  run_cfg $K $M $N &
  while [ "$(jobs -rp | wc -l)" -ge $MAX ]; do wait -n; done
done; done; done
wait
echo "[SC sweep done] -> $CSV"
